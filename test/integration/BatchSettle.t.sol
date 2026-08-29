// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./HindsightFixture.sol";

contract BatchSettleTest is HindsightFixture {
    address constant TRADER = address(0xBEEF);

    function _threeSwaps() internal {
        swapAs(TRADER, true, -1e17);
        fb.increment();
        swapAs(TRADER, false, -1e17);
        fb.increment();
        swapAs(TRADER, true, -1e17);
    }

    function test_pendingMatured_empty_before_maturity() public {
        _threeSwaps();
        (uint256[] memory ids, uint256 cursor) = hook.pendingMatured(0, 10);
        assertEq(ids.length, 0, "nothing matured yet");
        assertEq(cursor, 3, "cursor advanced past scanned records");
    }

    function test_pendingMatured_finds_matured_and_skips_settled() public {
        _threeSwaps();
        advanceTo(pastWindow(2)); // all three matured
        hook.settle(1);           // settle the middle one manually

        (uint256[] memory ids,) = hook.pendingMatured(0, 10);
        assertEq(ids.length, 2);
        assertEq(ids[0], 0);
        assertEq(ids[1], 2);
    }

    function test_pendingMatured_respects_limit_and_cursor() public {
        _threeSwaps();
        advanceTo(pastWindow(2));
        (uint256[] memory ids, uint256 cursor) = hook.pendingMatured(0, 2);
        assertEq(ids.length, 2);
        (uint256[] memory rest,) = hook.pendingMatured(cursor, 2);
        assertEq(rest.length, 1);
        assertEq(rest[0], 2);
    }

    function test_trySettle_skips_instead_of_reverting() public {
        _threeSwaps();
        assertFalse(hook.trySettle(0), "immature: skip");
        assertFalse(hook.trySettle(99), "unknown: skip");
        advanceTo(pastWindow(2));
        assertTrue(hook.trySettle(0), "matured: settles");
        assertFalse(hook.trySettle(0), "already settled: skip");
    }

    function test_settleBatch_mixed_states() public {
        _threeSwaps();
        advanceTo(pastWindow(2));
        hook.settle(1); // racing manual settle

        uint256[] memory ids = new uint256[](4);
        ids[0] = 0;
        ids[1] = 1;  // already settled — must be skipped, not revert
        ids[2] = 2;
        ids[3] = 77; // unknown — skipped
        uint256 n = hook.settleBatch(ids);
        assertEq(n, 2, "settled exactly the two ready ones");
        assertEq(hook.getSwap(0).status, 1);
        assertEq(hook.getSwap(2).status, 1);
    }

    function test_batch_settle_pays_keeper_tips_on_forfeits() public {
        uint256 id = hook.nextSwapId();
        swapAs(TRADER, true, -1e18);
        driftPrice(true, 20, -30e18);
        advanceTo(pastWindow(id));

        (uint256[] memory ids,) = hook.pendingMatured(0, 50);
        assertGt(ids.length, 0);
        vm.prank(address(0xCAFE));
        uint256 n = hook.settleBatch(ids);
        assertEq(n, ids.length, "all matured settled in one batch");
    }
}
