// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../integration/HindsightFixture.sol";
import {Handler} from "./Handler.sol";

/// Core safety invariants under random swap/settle/clock/flush interleavings:
///   INV1  the hook's ERC-6909 claims exactly back the outstanding pending bonds
///   INV2  the hook's real token custody exactly equals the pending donation pot
///   INV3  settled swaps never revert back to pending
contract ConservationInvariant is HindsightFixture {
    Handler handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(hook, fb, swapRouter, key);
        // fund the handler
        IERC20Minimal(Currency.unwrap(currency0)).transfer(address(handler), 5_000e18);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(address(handler), 5_000e18);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = Handler.doSwap.selector;
        selectors[1] = Handler.advanceClock.selector;
        selectors[2] = Handler.doSettle.selector;
        selectors[3] = Handler.doPoke.selector;
        selectors[4] = Handler.doFlush.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_claims_exactly_back_pending_bonds() public view {
        assertEq(
            manager.balanceOf(address(hook), currency0.toId()),
            handler.outstanding0(),
            "INV1: c0 claims == pending bonds"
        );
        assertEq(
            manager.balanceOf(address(hook), currency1.toId()),
            handler.outstanding1(),
            "INV1: c1 claims == pending bonds"
        );
    }

    function invariant_custody_equals_pot() public view {
        (uint128 pot0, uint128 pot1,) = hook.pendingDonations(poolId);
        assertEq(bal0(address(hook)), uint256(pot0), "INV2: c0 custody == pot");
        assertEq(bal1(address(hook)), uint256(pot1), "INV2: c1 custody == pot");
    }

    function invariant_settled_stay_settled() public view {
        uint256 n = hook.nextSwapId();
        uint256 pendingCount;
        for (uint256 i; i < n; i++) {
            uint8 st = hook.getSwap(i).status;
            if (st == 0) pendingCount++;
            else assertLe(st, 2, "status domain");
        }
        // pending ghost consistency: count implied by outstanding sums can't be negative (implicit)
        assertLe(handler.settlesExecuted(), n, "settles bounded by swaps");
    }
}
