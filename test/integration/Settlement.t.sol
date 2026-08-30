// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./HindsightFixture.sol";
import {Vm} from "forge-std/Vm.sol";

contract SettlementTest is HindsightFixture {
    address constant TRADER = address(0xBEEF);
    address constant KEEPER = address(0xCAFE);

    function test_settle_reverts_before_maturity() public {
        swapAs(TRADER, true, -1e18);
        advanceTo(T0 + 5); // window not closed
        vm.expectRevert(HindsightHook.NotMatured.selector);
        hook.settle(0);
    }

    function test_settle_reverts_on_unknown_swap() public {
        vm.expectRevert(HindsightHook.UnknownSwap.selector);
        hook.settle(42);
    }

    function test_settle_reverts_on_double_settle() public {
        swapAs(TRADER, true, -1e18);
        advanceTo(pastWindow(0));
        hook.settle(0);
        vm.expectRevert(HindsightHook.AlreadySettled.selector);
        hook.settle(0);
    }

    function test_benign_refund_goes_to_beneficiary_not_router() public {
        swapAs(TRADER, true, -1e18);
        uint128 bond = hook.getSwap(0).bond;
        advanceTo(pastWindow(0));

        uint256 before = bal1(TRADER);
        vm.prank(KEEPER);
        hook.settle(0);

        assertEq(bal1(TRADER) - before, uint256(bond), "full refund to beneficiary");
        assertEq(hook.getSwap(0).status, 1, "status refunded");
    }

    function test_refund_pays_no_keeper_tip() public {
        swapAs(TRADER, true, -1e18);
        advanceTo(pastWindow(0));
        uint256 before = bal1(KEEPER);
        vm.prank(KEEPER);
        hook.settle(0);
        assertEq(bal1(KEEPER), before, "tip only comes from forfeits");
    }

    function test_toxic_forfeit_with_keeper_tip() public {
        swapAs(TRADER, true, -1e18);
        uint128 bond = hook.getSwap(0).bond;

        driftPrice(true, 20, -30e18); // sustained same-direction drift through the window
        advanceTo(pastWindow(0));

        uint256 traderBefore = bal1(TRADER);
        uint256 keeperBefore = bal1(KEEPER);
        vm.recordLogs();
        vm.prank(KEEPER);
        hook.settle(0);

        uint256 refund = bal1(TRADER) - traderBefore;
        uint256 tip = bal1(KEEPER) - keeperBefore;
        assertLt(refund, uint256(bond), "toxic flow does not get a full refund");
        assertGt(tip, 0, "keeper tipped from the forfeit");

        // Part of the forfeit may already have been dripped to LPs inside the settle
        // callback (epoch flush). Conservation: refund + tip + pot + flushed == bond.
        uint256 flushed = _sumFlushed();
        (uint128 pot0, uint128 pot1,) = hook.pendingDonations(poolId);
        assertEq(uint256(refund) + tip + pot0 + pot1 + flushed, uint256(bond), "bond fully accounted");
        // Custody invariant: the hook holds exactly the un-flushed pot in real tokens.
        assertEq(bal1(address(hook)), uint256(pot1), "hook custody == pot");
        assertEq(hook.getSwap(0).status, 2, "status forfeited");
    }

    function _sumFlushed() internal returns (uint256 flushed) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("DonationFlushed(bytes32,uint128,uint128)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) {
                (uint128 a0, uint128 a1) = abi.decode(logs[i].data, (uint128, uint128));
                flushed += uint256(a0) + a1;
            }
        }
    }

    /// Rotating the whole ring buffer DESTROYS evidence rather than lacking it. Round 2 of
    /// the audit showed that rewarding this with a refund let any toxic trade buy its way
    /// out, so an evicted window now forfeits; a genuinely dataless window still refunds
    /// (see AuditRepro.test_M4a/M4b).
    function test_evicted_window_does_not_earn_a_refund() public {
        swapAs(TRADER, true, -1e18);
        uint128 bond = hook.getSwap(0).bond;
        uint48 windowEnd = hook.getSwap(0).execStamp + 50 + 25;

        advanceTo(windowEnd + 1);
        for (uint256 i = 0; i < 130; i++) {
            fb.increment();
            hook.poke(key);
        }

        uint256 before = bal1(TRADER);
        hook.settle(0);
        assertLt(bal1(TRADER) - before, uint256(bond), "evicted evidence must not be rewarded");
    }

    /// Waiting out the RING BUFFER is the escape hatch that must stay shut: if the window's
    /// observations are gone by the time anyone settles, the bond forfeits in full.
    ///
    /// Note this is deliberately NOT "settled late ⇒ forfeit". An earlier version keyed the
    /// auto-forfeit purely off the grace deadline, which confiscated bonds that had already
    /// been measured benign whenever the keeper lane stalled — observed live on v5, where
    /// five swaps carrying markout 22-27 against theta 31 lost their entire bond because
    /// settlement arrived thirty minutes late. Lateness with intact data is now measured;
    /// only unmeasurable windows forfeit.
    function test_auto_forfeit_when_the_window_data_is_gone() public {
        swapAs(TRADER, true, -1e18);
        uint128 bond = hook.getSwap(0).bond;
        advanceTo(pastWindow(0));

        // Flood the 128-slot buffer so nothing covering the window survives, then let the
        // grace period lapse on top of it.
        for (uint256 i; i < 140; i++) {
            fb.increment();
            hook.poke(key);
        }
        advanceTo(hook.getSwap(0).execStamp + 75 + 3000 + 1);
        (, bool dataOk,,,) = hook.previewSettle(0);
        assertFalse(dataOk, "precondition: the window's observations are gone");

        uint256 traderBefore = bal1(TRADER);
        uint256 meBefore = bal1(address(this));
        vm.recordLogs();
        hook.settle(0);

        assertEq(bal1(TRADER), traderBefore, "no refund once the measurement is destroyed");
        uint256 tip = bal1(address(this)) - meBefore; // we were the settle caller
        uint256 flushed = _sumFlushed();
        (uint128 pot0, uint128 pot1,) = hook.pendingDonations(poolId);
        assertEq(tip + flushed + pot0 + pot1, uint256(bond), "entire bond goes to tip + LP pot/flush");
        assertEq(tip, 0, "an ungraded forfeit pays the keeper nothing (M7)");
    }

    function test_reverted_swap_leaves_no_record() public {
        // A swap that reverts (price limit) must not create a record or escrow — the
        // structural revert-spam immunity claim, demonstrated.
        uint256 idBefore = hook.nextSwapId();
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({amountSpecified: -1e18, zeroForOne: true, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(TRADER)
        );
        assertEq(hook.nextSwapId(), idBefore, "reverted tx never enters the measurement");
    }

    function test_two_sided_reversion_is_benign() public {
        // Trade pushes price down, market bounces back within the window ⇒ refund.
        swapAs(TRADER, true, -5e18);
        uint128 bond = hook.getSwap(0).bond;
        driftPrice(false, 20, -30e18); // opposite-direction flow: price reverts
        advanceTo(pastWindow(0));

        uint256 before = bal1(TRADER);
        hook.settle(0);
        assertEq(bal1(TRADER) - before, uint256(bond), "mean-reverting flow fully refunded");
    }
}
