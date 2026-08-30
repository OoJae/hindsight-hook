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

    // ── avgAbsJump ──────────────────────────────────────────────────────────────────
    // This is theta's only input, and until now it had no direct unit coverage at all.

    function test_avgAbsJump_is_the_mean_of_consecutive_absolute_jumps() public {
        buf.write(10, 100);
        buf.write(11, 105);   // +5
        buf.write(12, 102);   // -3
        buf.write(13, 112);   // +10
        (uint256 mean, uint16 n) = buf.avgAbsJump(10, 13, 0);
        assertEq(n, 3, "three consecutive pairs inside the window");
        assertEq(mean, (5 + 3 + 10) / 3, "mean of |5|,|3|,|10|");
    }

    function test_avgAbsJump_clamps_each_jump_independently() public {
        buf.write(10, 0);
        buf.write(11, 1000);  // +1000, clamped to 10
        buf.write(12, 1002);  // +2, unaffected
        (uint256 mean, uint16 n) = buf.avgAbsJump(10, 12, 10);
        assertEq(n, 2);
        assertEq(mean, (10 + 2) / 2, "the spike contributes at most maxJumpTicks");
    }

    /// The clamp is per-jump against the RAW previous tick — it does not carry a clamped
    /// value forward the way twap() does. A spike therefore inflates at most one jump, and
    /// the return to trend inflates at most one more.
    function test_avgAbsJump_clamp_does_not_carry_forward() public {
        buf.write(10, 0);
        buf.write(11, 1000);
        buf.write(12, 0);
        (uint256 mean, uint16 n) = buf.avgAbsJump(10, 12, 10);
        assertEq(n, 2);
        assertEq(mean, 10, "both legs of the spike clamp to 10, not one clamped and one raw");
    }

    /// The observation immediately BEFORE the window seeds the baseline, so the first
    /// in-window jump is measured against it rather than being skipped.
    function test_avgAbsJump_seeds_the_baseline_from_before_the_window() public {
        buf.write(5, 100);    // outside, but becomes prevTick
        buf.write(10, 108);   // +8 measured against the pre-window observation
        buf.write(11, 110);   // +2
        (uint256 mean, uint16 n) = buf.avgAbsJump(10, 11, 0);
        assertEq(n, 2, "the pre-window observation seeds, it does not itself count");
        assertEq(mean, (8 + 2) / 2);
    }

    function test_avgAbsJump_empty_window_reports_zero_jumps() public {
        buf.write(10, 100);
        buf.write(11, 105);
        (uint256 mean, uint16 n) = buf.avgAbsJump(50, 60, 0);
        assertEq(n, 0, "no observations in range");
        assertEq(mean, 0);
    }

    /// nJumps is what distinguishes "the pool was quiet" from "we have no data". theta
    /// treats both as sigma = 0 (fail-shut), which is deliberate: fail-OPEN would let a
    /// trader wait for a data-free window and be acquitted unconditionally.
    function test_avgAbsJump_single_observation_yields_no_jump() public {
        buf.write(10, 100);
        (uint256 mean, uint16 n) = buf.avgAbsJump(10, 20, 0);
        assertEq(n, 0, "one point is not a jump");
        assertEq(mean, 0);
    }

    function test_avgAbsJump_window_is_inclusive_at_both_ends() public {
        buf.write(10, 100);
        buf.write(11, 110);
        buf.write(12, 130);
        (, uint16 nAll) = buf.avgAbsJump(10, 12, 0);
        (, uint16 nCut) = buf.avgAbsJump(10, 11, 0);
        assertEq(nAll, 2);
        assertEq(nCut, 1, "`to` is inclusive: cutting it to 11 drops exactly the last jump");
    }

    /// A trailing window ending strictly before a stamp must not see that stamp. This is
    /// what makes theta unwritable by the swap it prices.
    function test_avgAbsJump_excludes_the_stamp_above_to() public {
        buf.write(10, 100);
        buf.write(11, 101);
        buf.write(12, 900);   // the swap's own print
        (uint256 mean, uint16 n) = buf.avgAbsJump(10, 11, 0);
        assertEq(n, 1);
        assertEq(mean, 1, "the print at stamp 12 is invisible to a window ending at 11");
    }

    function testFuzz_avgAbsJump_never_exceeds_the_clamp(uint256 seed) public {
        uint48 stamp = 1;
        int24 tick = 0;
        for (uint256 i = 0; i < 40; i++) {
            tick = int24(int256(uint256(keccak256(abi.encode(seed, i))) % 4001) - 2000);
            buf.write(stamp, tick);
            stamp += uint48(uint256(keccak256(abi.encode(seed, i, "dt"))) % 5 + 1);
        }
        (uint256 mean,) = buf.avgAbsJump(1, stamp, 10);
        assertLe(mean, 10, "the mean of clamped jumps cannot exceed the clamp");
    }
}
