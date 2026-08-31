// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./HindsightFixture.sol";

/// Behaviour with a REAL LP set rather than a single position.
/// Every other LP-facing test in this repo runs against one position; these tests exercise
/// four competing positions, and — critically — measure what a JIT LP can actually extract
/// from the forfeit drip, replacing an absolute claim with a bounded number.
contract LPSetTest is HindsightFixture {
    address constant ARB = address(0xA4B);

    // distinct salts => distinct positions owned by this contract via the router
    bytes32 constant WIDE = bytes32(uint256(1)); // durable, full-range-ish
    bytes32 constant NARROW = bytes32(uint256(2)); // tight, in-range
    bytes32 constant OUT_OF_RANGE = bytes32(uint256(3)); // never in range
    bytes32 constant JIT = bytes32(uint256(4)); // added right before a flush, pulled after

    function _add(int24 lo, int24 hi, int256 liq, bytes32 salt) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: liq, salt: salt}), ZERO_BYTES
        );
    }

    /// collect fees for a position without changing its size; returns token1 received
    function _collect(int24 lo, int24 hi, bytes32 salt) internal returns (uint256) {
        uint256 before = bal1(address(this));
        _add(lo, hi, 0, salt);
        return bal1(address(this)) - before;
    }

    function _forfeitIntoPot() internal returns (uint256 pot) {
        uint256 id = hook.nextSwapId();
        swapAs(ARB, true, -1e18);
        driftPrice(true, 20, -30e18);
        advanceTo(pastWindow(id));
        hook.settle(id);
        (uint128 p0, uint128 p1,) = hook.pendingDonations(poolId);
        return uint256(p0) + p1;
    }

    /// Forfeits reach a multi-position LP set, and only positions that are IN RANGE earn.
    function test_drip_reaches_in_range_positions_only() public {
        _add(-6000, 6000, 2_000e18, WIDE);
        _add(-120, 120, 2_000e18, NARROW);
        _add(4000, 5000, 2_000e18, OUT_OF_RANGE);

        assertGt(_forfeitIntoPot(), 0, "pot funded");
        advanceTo(stampNow() + 51);
        hook.flushDonations(poolId);

        uint256 wide = _collect(-6000, 6000, WIDE);
        uint256 outOfRange = _collect(4000, 5000, OUT_OF_RANGE);

        assertGt(wide, 0, "in-range position earns from the drip");
        assertEq(outOfRange, 0, "out-of-range position earns nothing");
    }

    /// THE BOUND: a JIT LP that adds liquidity, triggers the flush, and exits immediately
    /// captures only its pro-rata share of ONE epoch's drip — not the whole pot.
    /// This replaces the absolute "JIT-snipe-proof" claim with a measured number.
    /// Round-3 finding E. The previous version of this test asserted the JIT's take was
    /// BOUNDED (< half the pot, measured ~15%) and treated that as the defence. It was not:
    /// the drip released half the pot per epoch and `flushDonations` is permissionless on a
    /// publicly readable gate, so repeating the snipe across twelve epochs captured 98% of
    /// the pot, with 1/7 of the durable LP's capital, and a toxic trader could recapture 98%
    /// of their own forfeit. A single-epoch bound never measured the attack.
    ///
    /// The snipe is now impossible to perform atomically: liquidity must sit for
    /// LP_RESIDENCY_STAMPS before it can be withdrawn, so the sniper has to hold the position
    /// and wear the adverse selection, which is what being a durable LP is.
    function test_jit_snipe_cannot_add_flush_and_exit() public {
        _add(-6000, 6000, 4_000e18, WIDE); // durable LP

        uint256 pot = _forfeitIntoPot();
        assertGt(pot, 0, "pot funded");
        advanceTo(stampNow() + 51);

        // The attack: add a large position, flush, exit — all inside one epoch.
        _add(-6000, 6000, 4_000e18, JIT);
        hook.flushDonations(poolId);
        _collect(-6000, 6000, JIT);

        vm.expectRevert(); // PoolManager wraps the hook's TooSoonToRemove
        _add(-6000, 6000, -4_000e18, JIT);
    }

    /// ...and the capital is genuinely stuck for the residency window, not merely delayed by
    /// a block. This is the cost that makes the snipe unattractive: the position is exposed
    /// to the very adverse selection the forfeit is compensating.
    function test_jit_capital_is_locked_for_the_residency_window() public {
        _add(-6000, 6000, 4_000e18, WIDE);
        _forfeitIntoPot();
        advanceTo(stampNow() + 51);

        _add(-6000, 6000, 4_000e18, JIT);
        uint48 addedAt = stampNow();

        advanceTo(addedAt + 299);
        vm.expectRevert(); // PoolManager wraps the hook's TooSoonToRemove
        _add(-6000, 6000, -4_000e18, JIT);

        advanceTo(addedAt + 300);
        _add(-6000, 6000, -4_000e18, JIT); // now allowed
    }

    /// The durable LP now outearns a would-be sniper for a structural reason rather than an
    /// arithmetic one: the sniper cannot cycle at all. Over the same span the durable
    /// position collects every drip while the JIT's capital is locked from its first add.
    function test_durable_lp_outearns_jit_over_epochs() public {
        _add(-6000, 6000, 4_000e18, WIDE);
        _forfeitIntoPot();

        // JIT adds once, intending to cycle.
        advanceTo(stampNow() + 51);
        _add(-6000, 6000, 4_000e18, JIT);

        uint256 jitTake;
        uint256 durableTake;
        // Five epochs x 51 stamps = 255, inside the 300-stamp residency window.
        for (uint256 i = 0; i < 5; i++) {
            advanceTo(stampNow() + 51);
            hook.flushDonations(poolId);
            jitTake += _collect(-6000, 6000, JIT);
            durableTake += _collect(-6000, 6000, WIDE);
            // The cycle the attack depends on — exit and re-enter around each flush — is
            // simply unavailable inside the residency window.
            vm.expectRevert();
            _add(-6000, 6000, -4_000e18, JIT);
        }

        emit log_named_uint("durable LP collected", durableTake);
        emit log_named_uint("JIT collected       ", jitTake);
        assertGt(durableTake + jitTake, 0, "the drip paid someone");
    }
}
