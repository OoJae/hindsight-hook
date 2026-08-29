// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title BondMathLib
/// @notice Pure bond-sizing math for Hindsight.
library BondMathLib {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    /// @notice Size the refundable bond for a swap.
    /// @param notional        the swap's unspecified-currency amount (what the bond is charged against)
    /// @param bondBps         base bond rate b0 (e.g. 25 = 0.25%)
    /// @param multiplierWad   reputation multiplier m in WAD (1e18 = 1.0). New addresses default 1.0.
    /// @param sizeTierCap     Q*: above this notional, discounts (m < 1) are floored to 1.0
    /// @param absoluteCap     κ·L_active·θ manipulation-cost cap (0 = no cap)
    /// @dev Bond can never exceed the notional itself (it is charged out of the swap's
    ///      unspecified amount, so > notional would revert the swap).
    function bond(
        uint256 notional,
        uint256 bondBps,
        uint256 multiplierWad,
        uint256 sizeTierCap,
        uint256 absoluteCap
    ) internal pure returns (uint256 b) {
        uint256 m = multiplierWad;
        // Size tier: whales get no reputation discount — kills reputation laundering (spec B2).
        if (sizeTierCap != 0 && notional > sizeTierCap && m < WAD) m = WAD;
        b = notional * bondBps / BPS;          // base bond
        b = b * m / WAD;                        // reputation scaling
        if (absoluteCap != 0 && b > absoluteCap) b = absoluteCap; // thin-pool manipulation cap (spec A3)
        if (b > notional) b = notional;         // structural cap
    }
}
