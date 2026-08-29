// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ToxicityLib} from "../../src/libraries/ToxicityLib.sol";

contract ToxicityLibTest is Test {
    function test_update_decays_toward_zero_on_benign_flow() public pure {
        uint256 s = 100e18;
        for (uint256 i; i < 10; i++) s = ToxicityLib.update(s, 0, 0.9e18);
        assertLt(s, 35e18); // 0.9^10 ≈ 0.349
    }

    function test_update_rises_on_toxic_flow() public pure {
        uint256 s = ToxicityLib.update(0, 50, 0.9e18);
        assertEq(s, 5e18); // (1-λ)·raw = 0.1·50 in WAD ticks
    }

    function test_multiplier_clamps() public pure {
        assertEq(ToxicityLib.multiplier(0, 1e18, 0.1e18, 0.1e18, 3e18), 1e18);
        assertEq(ToxicityLib.multiplier(1e30, 1e18, 0.1e18, 0.1e18, 3e18), 3e18);
    }

    function testFuzz_multiplier_bounded(uint256 score) public pure {
        score = bound(score, 0, 1e36);
        uint256 m = ToxicityLib.multiplier(score, 1e18, 0.1e18, 0.1e18, 3e18);
        assertGe(m, 0.1e18);
        assertLe(m, 3e18);
    }

    function testFuzz_update_converges_to_raw(uint256 raw) public pure {
        raw = bound(raw, 0, 1000);
        uint256 s = 0;
        for (uint256 i; i < 200; i++) s = ToxicityLib.update(s, raw, 0.9e18);
        // steady state = raw (in WAD): allow 1% tolerance
        assertApproxEqRel(s, raw * 1e18, 0.01e18);
    }
}
