// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./HindsightFixture.sol";

/// Adversarial-audit reproductions. These MUST fail on the current code and pass after the fix.
contract AuditReproTest is HindsightFixture {
    address constant ARB = address(0xA4B);

    /// M2 (critical): the post-swap tick was never recorded, so a trade was scored against
    /// its own PRE-trade price and markout came out as -(own impact) — structurally benign
    /// at any size. Property: a trade must never be credited for its own price impact.
    function test_M2_own_impact_is_not_evidence_of_innocence() public {
        uint256 id = hook.nextSwapId();
        swapAs(ARB, true, -25e18); // ~100 ticks of impact
        advanceTo(pastWindow(id));
        (,, int256 markout,,) = hook.previewSettle(id);
        emit log_named_int("quiet-window markout", markout);
        assertEq(markout, 0, "M2: a quiet window must read 0, not minus the trade's own impact");
    }

    /// M2b: with genuine adverse drift after the trade, the trade must be caught. Before the
    /// fix the -(own impact) offset masked up to ~100 ticks of real drift.
    function test_M2_adverse_drift_is_caught() public {
        uint256 id = hook.nextSwapId();
        swapAs(ARB, true, -25e18);
        // price keeps going the trader's way, driven by OTHER participants
        driftPrice(true, 8, -8e18);
        advanceTo(pastWindow(id));
        (,, int256 markout, int256 theta, uint256 fWad) = hook.previewSettle(id);
        emit log_named_int("markout", markout);
        emit log_named_int("theta", theta);
        assertGt(markout, theta, "M2b: informed trade must read toxic");
        assertGt(fWad, 0, "M2b: informed trade must forfeit");
    }

    /// M3: avgAbsJump applies no jump clamp, so an attacker can pump measured volatility
    /// with net-zero round-trip swaps and raise theta above their own markout.
    function test_M3_theta_pumping_with_roundtrips() public {
        uint256 id = hook.nextSwapId();
        swapAs(ARB, true, -5e18);

        // oscillate inside the window: net-zero position, but huge measured "volatility"
        for (uint256 i; i < 6; i++) {
            fb.increment();
            swapAs(address(0xBB), true, -40e18);
            fb.increment();
            swapAs(address(0xBB), false, -40e18);
        }
        advanceTo(pastWindow(id));
        (,,, int256 theta,) = hook.previewSettle(id);
        emit log_named_int("theta after pumping", theta);
        assertLt(theta, int256(400), "M3: theta must not be pumpable to absurd levels");
    }

    /// M4 (round 1) refined by round 2: data loss must never PUNISH an honest trader, but
    /// it must also never REWARD a toxic one. Round 2 found the original test asserted only
    /// the first half — and the second half was exploitable: a toxic trader could flood the
    /// permissionless poke() path, evict the observations that convicted them, and collect
    /// the missing-data refund. Both halves are now asserted.
    function test_M4a_genuinely_absent_data_refunds() public {
        // A pool with no observation coverage for the window: the trader keeps their bond.
        uint256 id = hook.nextSwapId();
        swapAs(ARB, true, -1e18);
        uint128 bond = hook.getSwap(id).bond;
        advanceTo(pastWindow(id));
        uint256 before = bal1(ARB);
        hook.settle(id);
        assertEq(bal1(ARB) - before, uint256(bond), "absent data must refund in full");
    }

    function test_M4b_evicted_data_cannot_buy_a_refund() public {
        uint256 id = hook.nextSwapId();
        swapAs(ARB, true, -1e18);
        driftPrice(true, 20, -30e18); // genuinely toxic
        uint128 bond = hook.getSwap(id).bond;
        advanceTo(pastWindow(id));

        // attacker floods the ring buffer to destroy the evidence
        for (uint256 i; i < 140; i++) {
            fb.increment();
            hook.poke(key);
        }

        uint256 before = bal1(ARB);
        hook.settle(id);
        assertLt(bal1(ARB) - before, uint256(bond), "evicting the buffer must not earn a refund");
    }

    /// Finalisation locks the verdict while the data still exists, so the race above cannot
    /// even start once a keeper has finalised.
    function test_M4c_finalize_locks_the_verdict() public {
        uint256 id = hook.nextSwapId();
        swapAs(ARB, true, -1e18);
        driftPrice(true, 20, -30e18);
        advanceTo(pastWindow(id));

        hook.finalize(id); // keeper locks it in
        assertTrue(hook.getSwap(id).finalized, "verdict finalized");

        for (uint256 i; i < 140; i++) {
            fb.increment();
            hook.poke(key);
        }
        (,,,, uint256 fWad) = hook.previewSettle(id);
        assertGt(fWad, 0, "finalized verdict survives buffer eviction");
    }

    /// M5 (high): hookData is attacker-controlled, so a third party could attribute a toxic
    /// swap to a victim — wiping their earned discount and raising their future bonds.
    /// Property: only self-attributed (or trusted-router-vouched) flow may move reputation.
    function test_M5_reputation_cannot_be_poisoned_by_third_party() public {
        address victim = address(0x1CE);
        address attacker = address(0xBAD);

        for (uint256 i; i < 3; i++) {
            uint256 vid = hook.nextSwapId();
            swapAs(victim, true, -1e15);
            advanceTo(pastWindow(vid));
            hook.settle(vid);
        }
        assertEq(hook.benignSettles(poolId, victim), 3, "victim earned history");

        // ATTACKER swaps (tx.origin = attacker) but names the VICTIM in hookData.
        fundTrader(attacker);
        uint256 aid = hook.nextSwapId();
        vm.prank(attacker, attacker);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(victim)
        );
        driftPrice(true, 20, -30e18);
        advanceTo(pastWindow(aid));
        hook.settle(aid);

        assertEq(hook.benignSettles(poolId, victim), 3, "M5: third party must not wipe victim history");
        assertEq(hook.toxicityScore(poolId, victim), 0, "M5: third party must not poison victim score");
    }

    /// Unauthenticated attribution must also be unable to BORROW a discount: it pays the
    /// full default bond regardless of whose address it names.
    function test_M5_unauthenticated_cannot_borrow_a_discount() public {
        address attacker = address(0xBAD);
        fundTrader(attacker);
        uint256 id = hook.nextSwapId();
        vm.prank(attacker, attacker);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(0xFEE)) // names a third party
        );
        HindsightHook.SwapRecord memory r = hook.getSwap(id);
        assertFalse(r.attributed, "unauthenticated attribution flagged");
        assertEq(uint256(r.bond), uint256(r.notional) * 25 / 10_000, "pays the full default bond");
    }
}
