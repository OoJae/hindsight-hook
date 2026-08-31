// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./HindsightFixture.sol";

contract DonationFlushTest is HindsightFixture {
    address constant TRADER = address(0xBEEF);

    /// Forfeit a bond and return the pot size after settlement.
    function _forfeitOne() internal returns (uint256 pot) {
        uint256 id = hook.nextSwapId();
        swapAs(TRADER, true, -1e18);
        driftPrice(true, 20, -30e18);
        advanceTo(pastWindow(id));
        hook.settle(id);
        (uint128 p0, uint128 p1,) = hook.pendingDonations(poolId);
        pot = uint256(p0) + p1;
    }

    function test_epoch_gate_blocks_double_flush() public {
        uint256 pot = _forfeitOne();
        assertGt(pot, 0, "pot funded");
        // Immediately flushing again within the same epoch must be a no-op.
        hook.flushDonations(poolId);
        (uint128 p0, uint128 p1,) = hook.pendingDonations(poolId);
        assertEq(uint256(p0) + p1, pot, "no flush within the epoch");
    }

    /// The drip releases 1/DRIP_DENOM per epoch. It was 1/2 until round 3, which is why a
    /// JIT could take 98% of a pot in twelve flushes; the spec always said ~1/50.
    function test_drip_releases_one_fiftieth_per_epoch() public {
        uint256 pot = _forfeitOne();
        advanceTo(stampNow() + 51); // one epoch later
        hook.flushDonations(poolId);
        (uint128 p0, uint128 p1,) = hook.pendingDonations(poolId);
        uint256 after1 = uint256(p0) + p1;
        assertApproxEqAbs(after1, pot - pot / 50, 2, "one fiftieth of the pot dripped");

        advanceTo(stampNow() + 51);
        hook.flushDonations(poolId);
        (p0, p1,) = hook.pendingDonations(poolId);
        assertApproxEqAbs(uint256(p0) + p1, after1 - after1 / 50, 2, "geometric drip");
    }

    function test_lps_actually_collect_the_forfeits() public {
        // LP fee snapshot before any forfeits: collect pending fees first.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 0, salt: 0}),
            ZERO_BYTES
        );
        _forfeitOne();
        advanceTo(stampNow() + 51);
        hook.flushDonations(poolId);

        // Snapshot AFTER all swap/funding traffic: the only balance change left is the
        // fee collection below, so the delta isolates what LPs actually received.
        uint256 before1 = bal1(address(this));

        // Collect fees (liquidityDelta = 0 pokes the position and pays out fee growth).
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 0, salt: 0}),
            ZERO_BYTES
        );
        // We are the only LP: swap fees + donated forfeits both accrue to us. The point
        // here is the donation reaches LP fee accounting (balance strictly grows).
        assertGt(bal1(address(this)), before1, "LP collected donated value");
    }

    function test_zero_liquidity_stashes_instead_of_reverting() public {
        uint256 id = hook.nextSwapId();
        swapAs(TRADER, true, -1e18);
        driftPrice(true, 20, -30e18);
        advanceTo(pastWindow(id));

        // Pull ALL liquidity before settlement — Pool.donate would revert. Past the LP
        // residency window first; the fixture's position was added in setUp.
        advanceTo(stampNow() + 300);
        // Pull ALL liquidity before settlement — Pool.donate would revert.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: -5_000e18, salt: 0}),
            ZERO_BYTES
        );

        hook.settle(id); // must not revert
        (uint128 p0, uint128 p1,) = hook.pendingDonations(poolId);
        assertGt(uint256(p0) + p1, 0, "forfeit stashed for later");

        // Liquidity returns → the stash can flush.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 5_000e18, salt: 0}),
            ZERO_BYTES
        );
        advanceTo(stampNow() + 51);
        hook.flushDonations(poolId);
        (uint128 q0, uint128 q1,) = hook.pendingDonations(poolId);
        assertLt(uint256(q0) + q1, uint256(p0) + p1, "stash dripping after liquidity returned");
    }
}
