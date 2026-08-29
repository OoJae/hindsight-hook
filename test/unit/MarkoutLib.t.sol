// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarkoutLib} from "../../src/libraries/MarkoutLib.sol";

contract MarkoutLibTest is Test {
    int24 constant MIN_TICK = -887272;
    int24 constant MAX_TICK = 887272;

    // zeroForOne (selling token0) pushes tick DOWN; continued downward drift = toxic.
    function test_markout_zeroForOne_towardTrade_isPositive() public pure {
        // exec at tick 100, settles at tick 40: price kept falling after a sell ⇒ informed
        int256 m = MarkoutLib.markout(100, 40, true);
        assertEq(m, 60);
    }

    function test_markout_zeroForOne_reversion_isNegative() public pure {
        int256 m = MarkoutLib.markout(100, 150, true); // price bounced back ⇒ benign
        assertEq(m, -50);
    }

    function test_markout_oneForZero_towardTrade_isPositive() public pure {
        int256 m = MarkoutLib.markout(100, 160, false); // bought token0, price kept rising
        assertEq(m, 60);
    }

    function testFuzz_markout_antisymmetric_in_direction(int24 execTick, int24 settleTick) public pure {
        execTick = int24(bound(execTick, MIN_TICK, MAX_TICK));
        settleTick = int24(bound(settleTick, MIN_TICK, MAX_TICK));
        int256 a = MarkoutLib.markout(execTick, settleTick, true);
        int256 b = MarkoutLib.markout(execTick, settleTick, false);
        assertEq(a, -b);
    }

    function test_forfeit_zero_at_or_below_threshold() public pure {
        assertEq(MarkoutLib.forfeitWad(10, 10, 10), 0);
        assertEq(MarkoutLib.forfeitWad(-100, 10, 10), 0);
    }

    function test_forfeit_full_at_ramp_end() public pure {
        assertEq(MarkoutLib.forfeitWad(20, 10, 10), 1e18); // θ=10, ramp=10, markout=20 ⇒ 100%
        assertEq(MarkoutLib.forfeitWad(500, 10, 10), 1e18);
    }

    function test_forfeit_linear_midpoint() public pure {
        assertEq(MarkoutLib.forfeitWad(15, 10, 10), 0.5e18);
    }

    function test_forfeit_degenerate_ramp_is_cliff() public pure {
        assertEq(MarkoutLib.forfeitWad(11, 10, 0), 1e18);
        assertEq(MarkoutLib.forfeitWad(10, 10, 0), 0);
    }

    function testFuzz_forfeit_bounded(int256 m, int256 t, int256 r) public pure {
        m = bound(m, -1e6, 1e6);
        t = bound(t, 0, 1e6);
        r = bound(r, 0, 1e6);
        uint256 f = MarkoutLib.forfeitWad(m, t, r);
        assertLe(f, 1e18);
    }

    function testFuzz_forfeit_monotone_in_markout(int256 m1, int256 m2) public pure {
        m1 = bound(m1, -1e6, 1e6);
        m2 = bound(m2, m1, 1e6);
        assertLe(MarkoutLib.forfeitWad(m1, 10, 20), MarkoutLib.forfeitWad(m2, 10, 20));
    }
}
