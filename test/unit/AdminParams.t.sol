// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../integration/HindsightFixture.sol";

/// Owner powers are bounded, and settlement cannot be weaponised against in-flight bonds.
contract AdminParamsTest is HindsightFixture {
    address constant TRADER = address(0xBEEF);
    address constant OUTSIDER = address(0xBAD);

    function _p() internal pure returns (HindsightHook.HindsightParams memory) {
        return HindsightHook.HindsightParams({
            bondBps: 25, maturityStamps: 50, twapWindowStamps: 25, graceStamps: 3000,
            thetaMinTicks: 3, thetaVolMultX10: 14, rampTicks: 20, maxJumpTicks: 60,
            keeperTipBps: 500, epochStamps: 50, sizeTierCap: 10e18
        });
    }

    function test_only_owner_can_set_params() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(HindsightHook.NotOwner.selector);
        hook.setParams(poolId, _p());
    }

    function test_bounds_reject_owner_overreach() public {
        HindsightHook.HindsightParams memory p = _p();

        p.keeperTipBps = 10_000; // owner takes 100% of every forfeit
        vm.expectRevert(HindsightHook.BadParams.selector);
        hook.setParams(poolId, p);

        p = _p(); p.graceStamps = 0; // instant auto-forfeit of everything pending
        vm.expectRevert(HindsightHook.BadParams.selector);
        hook.setParams(poolId, p);

        p = _p(); p.thetaMinTicks = 0; // universal toxicity
        vm.expectRevert(HindsightHook.BadParams.selector);
        hook.setParams(poolId, p);

        p = _p(); p.rampTicks = 0;
        vm.expectRevert(HindsightHook.BadParams.selector);
        hook.setParams(poolId, p);

        p = _p(); p.twapWindowStamps = 0;
        vm.expectRevert(HindsightHook.BadParams.selector);
        hook.setParams(poolId, p);

        p = _p(); p.bondBps = 500; // 5% bonds
        vm.expectRevert(HindsightHook.BadParams.selector);
        hook.setParams(poolId, p);
    }

    /// The owner retunes as aggressively as the bounds allow, then settles immediately:
    /// a pending benign swap must still be refunded, and the owner cannot take the bond.
    function test_worst_legal_retune_cannot_confiscate_a_pending_bond() public {
        uint256 id = hook.nextSwapId();
        swapAs(TRADER, true, -1e18);
        uint128 bond = hook.getSwap(id).bond;

        // The attack: params are read at SETTLE time, so collapsing maturity+window+grace
        // would push this already-escrowed bond past its grace deadline and auto-forfeit it
        // at 100%, bypassing theta and the ramp. The bounds must refuse it outright.
        HindsightHook.HindsightParams memory p = _p();
        p.keeperTipBps = 1000;      // max legal skim
        p.maturityStamps = 0;
        p.twapWindowStamps = 1;
        p.graceStamps = 1;
        vm.expectRevert(HindsightHook.BadParams.selector);
        hook.setParams(poolId, p);

        // ...and the bond is still refunded in full on its original schedule. The previous
        // version of this test performed the retune and then asserted
        // `assertGe(traderDelta + ownerGain, 0)` on UNSIGNED values — vacuously true, so it
        // passed while the confiscation succeeded. (Round-2 audit M6.)
        advanceTo(pastWindow(id));
        uint256 traderBefore = bal1(TRADER);
        hook.settle(id);
        assertEq(bal1(TRADER) - traderBefore, uint256(bond), "benign pending bond refunds in full");
    }

    /// The deadline may still be moved LATER — the ratchet is one-directional, so an owner
    /// can lengthen a settlement horizon (we did exactly that, 3+2s to 10+5s) but can never
    /// shorten one out from under an escrowed bond.
    function test_retune_may_lengthen_the_deadline() public {
        HindsightHook.HindsightParams memory p = _p();
        p.maturityStamps = 50;
        p.twapWindowStamps = 25;
        hook.setParams(poolId, p);
        (, uint16 maturity, uint16 window,,,,,,,,) = hook.poolParams(poolId);
        assertEq(maturity, 50);
        assertEq(window, 25);
    }

    function test_two_step_ownership() public {
        address newOwner = address(0xC0FFEE);
        hook.transferOwnership(newOwner);
        assertEq(hook.owner(), address(this), "owner unchanged until accepted");

        vm.prank(OUTSIDER);
        vm.expectRevert(HindsightHook.NotOwner.selector);
        hook.acceptOwnership();

        vm.prank(newOwner);
        hook.acceptOwnership();
        assertEq(hook.owner(), newOwner, "ownership transferred");
        assertEq(hook.pendingOwner(), address(0));
    }
}
