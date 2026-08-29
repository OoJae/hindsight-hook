// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BondMathLib} from "../../src/libraries/BondMathLib.sol";

contract BondMathLibTest is Test {
    function test_base_bond() public pure {
        // 25 bps of 1e18 notional, multiplier 1.0
        assertEq(BondMathLib.bond(1e18, 25, 1e18, 0, 0), 25e14);
    }

    function test_reputation_discount_applies_below_tier() public pure {
        // m = 0.1 ⇒ 10% of base bond
        assertEq(BondMathLib.bond(1e18, 25, 0.1e18, 10e18, 0), 25e13);
    }

    function test_whale_discount_floored_above_tier() public pure {
        // notional above Q* ⇒ discount removed (m -> 1.0)
        uint256 whale = BondMathLib.bond(100e18, 25, 0.1e18, 10e18, 0);
        assertEq(whale, 100e18 * 25 / 10_000);
    }

    function test_penalty_multiplier_not_floored() public pure {
        // m > 1 must NOT be reduced by the size tier
        uint256 b = BondMathLib.bond(100e18, 25, 3e18, 10e18, 0);
        assertEq(b, 100e18 * 25 / 10_000 * 3);
    }

    function test_absolute_cap_binds() public pure {
        assertEq(BondMathLib.bond(1e18, 25, 1e18, 0, 1e12), 1e12);
    }

    function testFuzz_bond_never_exceeds_notional(uint256 n, uint256 bps, uint256 m) public pure {
        n = bound(n, 0, type(uint128).max);
        bps = bound(bps, 0, 10_000);
        m = bound(m, 0, 10e18);
        assertLe(BondMathLib.bond(n, bps, m, 0, 0), n);
    }

    function testFuzz_bond_monotone_in_notional_same_tier(uint256 n1, uint256 n2) public pure {
        n1 = bound(n1, 0, 1e30);
        n2 = bound(n2, n1, 1e30);
        // no size tier, no cap ⇒ monotone
        assertLe(BondMathLib.bond(n1, 25, 1e18, 0, 0), BondMathLib.bond(n2, 25, 1e18, 0, 0));
    }
}
