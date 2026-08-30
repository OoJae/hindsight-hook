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

    /// M4: the observation ring buffer (128 slots) can be flushed by permissionless poke()
    /// well inside the ~10min grace window. Data loss must REFUND, never punish.
    function test_M4_buffer_flush_does_not_punish_trader() public {
        uint256 id = hook.nextSwapId();
        swapAs(ARB, true, -1e18);
        uint128 bond = hook.getSwap(id).bond;
        advanceTo(pastWindow(id));

        // flush the entire ring buffer with permissionless pokes, still inside grace
        for (uint256 i; i < 130; i++) {
            fb.increment();
            hook.poke(key);
        }
        uint256 before = bal1(ARB);
        hook.settle(id);
        assertEq(bal1(ARB) - before, uint256(bond), "M4: lost data must refund, not forfeit");
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
        assertEq(hook.benignSettles(victim), 3, "victim earned history");

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

        assertEq(hook.benignSettles(victim), 3, "M5: third party must not wipe victim history");
        assertEq(hook.toxicityScore(victim), 0, "M5: third party must not poison victim score");
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
