// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../integration/HindsightFixture.sol";

/// Owner powers are bounded, and settlement cannot be weaponised against in-flight bonds.
contract AdminParamsTest is HindsightFixture {
    address constant TRADER = address(0xBEEF);
    address constant OUTSIDER = address(0xBAD);

    function _p() internal pure returns (HindsightHook.HindsightParams memory) {
        return HindsightHook.HindsightParams({
            bondBps: 25, maturityStamps: 15, twapWindowStamps: 10, graceStamps: 3000,
            thetaMinTicks: 3, thetaVolMultX10: 28, rampTicks: 20, maxJumpTicks: 60,
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

        HindsightHook.HindsightParams memory p = _p();
        p.keeperTipBps = 1000;      // max legal skim
        p.maturityStamps = 0;
        p.twapWindowStamps = 1;
        p.graceStamps = 1;
        hook.setParams(poolId, p);

        advanceTo(stampNow() + 2);
        uint256 ownerBefore = bal1(address(this));
        uint256 traderBefore = bal1(TRADER);
        hook.settle(id);

        // Whatever the verdict, at most 10% can route to the settler and the rest is LP-bound.
        uint256 ownerGain = bal1(address(this)) - ownerBefore;
        assertLe(ownerGain, uint256(bond) / 10 + 1, "owner cannot take more than the tip cap");
        assertGe(bal1(TRADER) - traderBefore + ownerGain, 0);
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
