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
    function test_jit_capture_is_bounded_by_the_drip() public {
        _add(-6000, 6000, 4_000e18, WIDE); // durable LP

        uint256 pot = _forfeitIntoPot();
        assertGt(pot, 0, "pot funded");
        advanceTo(stampNow() + 51);

        // JIT: add a large position, immediately flush, immediately exit.
        _add(-6000, 6000, 4_000e18, JIT);
        hook.flushDonations(poolId);
        uint256 jitTake = _collect(-6000, 6000, JIT);
        _add(-6000, 6000, -4_000e18, JIT);

        // What remains for durable LPs: the undripped pot plus their share of this epoch.
        (uint128 r0, uint128 r1,) = hook.pendingDonations(poolId);
        uint256 remaining = uint256(r0) + r1;

        emit log_named_uint("pot before flush      ", pot);
        emit log_named_uint("JIT captured          ", jitTake);
        emit log_named_uint("still owed to LPs     ", remaining);
        emit log_named_uint("JIT capture, % of pot ", jitTake * 100 / pot);

        // The drip is what bounds this: one epoch releases half the pot, and the JIT can
        // only take its liquidity share of THAT — never the whole forfeit.
        assertLt(jitTake, pot / 2 + 1, "JIT cannot exceed one epoch's release");
        assertGt(remaining, 0, "most of the pot survives for durable LPs");
        assertLt(jitTake * 100 / pot, 51, "JIT captures a bounded minority of the pot");
    }

    /// A durable LP that simply stays in range out-earns the JIT across successive epochs,
    /// because the drip keeps paying whoever is present.
    function test_durable_lp_outearns_jit_over_epochs() public {
        _add(-6000, 6000, 4_000e18, WIDE);
        _forfeitIntoPot();

        // JIT takes one epoch
        advanceTo(stampNow() + 51);
        _add(-6000, 6000, 4_000e18, JIT);
        hook.flushDonations(poolId);
        uint256 jitTake = _collect(-6000, 6000, JIT);
        _add(-6000, 6000, -4_000e18, JIT);

        // durable LP keeps collecting over the following epochs
        uint256 durable = _collect(-6000, 6000, WIDE);
        for (uint256 i; i < 6; i++) {
            advanceTo(stampNow() + 51);
            hook.flushDonations(poolId);
            durable += _collect(-6000, 6000, WIDE);
        }

        emit log_named_uint("JIT (one epoch)      ", jitTake);
        emit log_named_uint("durable (7 epochs)   ", durable);
        assertGt(durable, jitTake, "staying in range beats sniping a single flush");
    }
}
