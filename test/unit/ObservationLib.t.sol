// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ObservationLib} from "../../src/libraries/ObservationLib.sol";

contract ObservationLibTest is Test {
    using ObservationLib for ObservationLib.Buffer;

    ObservationLib.Buffer internal buf;

    function test_write_and_newest() public {
        assertTrue(buf.write(10, 100));
        assertTrue(buf.write(11, 105));
        (uint48 s, int24 t, bool ok) = buf.newest();
        assertTrue(ok);
        assertEq(s, 11);
        assertEq(t, 105);
    }

    function test_write_rejects_stale_stamp() public {
        assertTrue(buf.write(10, 100));
        assertFalse(buf.write(10, 999)); // same stamp
        assertFalse(buf.write(9, 999));  // older stamp
        (, int24 t,) = buf.newest();
        assertEq(t, 100);
    }

    function test_twap_flat_price() public {
        buf.write(10, 100);
        buf.write(20, 100);
        (int24 avg, uint16 n, bool ok) = buf.twap(10, 30, 0);
        assertTrue(ok);
        assertGt(n, 0);
        assertEq(avg, 100);
    }

    function test_twap_step_change_weighted() public {
        // tick 100 over [10,20), tick 200 over [20,30) ⇒ avg 150 over [10,30)
        buf.write(10, 100);
        buf.write(20, 200);
        (int24 avg,, bool ok) = buf.twap(10, 30, 0);
        assertTrue(ok);
        assertEq(avg, 150);
    }

    function test_twap_window_clip() public {
        buf.write(0, 100);
        buf.write(100, 900); // newest holds from 100 onward
        // window [100, 110] sees only tick 900
        (int24 avg,, bool ok) = buf.twap(100, 110, 0);
        assertTrue(ok);
        assertEq(avg, 900);
    }

    function test_twap_jump_clamp_caps_spike() public {
        buf.write(10, 100);
        buf.write(20, 100);
        buf.write(21, 10_000); // manipulation spike
        buf.write(22, 100);
        buf.write(30, 100);
        (int24 avgClamped,, bool ok1) = buf.twap(10, 30, 50); // jumps clamped to ±50
        (int24 avgRaw,, bool ok2) = buf.twap(10, 30, 0);      // unclamped
        assertTrue(ok1 && ok2);
        assertLt(avgClamped, avgRaw);
        // clamped path: spike contributes at most prev+50 for 1 stamp of 20
        assertLe(int256(avgClamped), 110);
    }

    function test_twap_empty_window_not_ok() public {
        (,, bool ok) = buf.twap(10, 30, 0);
        assertFalse(ok);
    }

    function test_twap_data_before_window_extends_forward() public {
        // Single old observation before the window: price is known and holds through it.
        buf.write(5, 123);
        (int24 avg,, bool ok) = buf.twap(10, 30, 0);
        assertTrue(ok);
        assertEq(avg, 123);
    }

    function test_ring_wraparound() public {
        for (uint48 i = 1; i <= 200; i++) buf.write(i, int24(int256(uint256(i))));
        // oldest surviving stamp is 73 (200-128+1); twap over recent region still works
        (int24 avg,, bool ok) = buf.twap(150, 200, 0);
        assertTrue(ok);
        assertGt(avg, 149);
        assertLt(avg, 201);
        (uint48 s,,) = buf.newest();
        assertEq(s, 200);
    }

    function testFuzz_twap_bounded_by_min_max_written(uint48 seed) public {
        int24 lo = type(int24).max;
        int24 hi = type(int24).min;
        uint48 stamp = 1;
        for (uint256 i; i < 20; i++) {
            int24 t = int24(int256(uint256(keccak256(abi.encode(seed, i))) % 2000) - 1000);
            if (buf.write(stamp, t)) {
                if (t < lo) lo = t;
                if (t > hi) hi = t;
            }
            stamp += uint48(uint256(keccak256(abi.encode(seed, i, "dt"))) % 5 + 1);
        }
        (int24 avg,, bool ok) = buf.twap(1, stamp + 1, 0);
        if (ok) {
            assertGe(avg, lo);
            assertLe(avg, hi);
        }
    }
}
