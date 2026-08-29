// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title MarkoutLib
/// @notice Pure math for ex-post markout classification.
/// @dev Works entirely in tick space: one v4 tick = a 1.0001x price step ≈ 1.0 bps,
///      so tick deltas ARE (approximately) basis points. This composes exactly with
///      the pool's own price representation and needs no external oracle.
library MarkoutLib {
    /// @notice Signed markout of a trade, in ticks (~bps).
    /// @param execTick   pool tick recorded right after the swap executed
    /// @param settleTick TWAP tick over the finalized settlement window
    /// @param zeroForOne trade direction (true = sold token0, price of token0 falls ⇒ tick falls)
    /// @return markoutTicks positive ⇒ price kept moving in the trade's favor ⇒ informed/toxic
    /// @dev zeroForOne pushes the tick DOWN; if the tick is still lower at settlement, the
    ///      seller "knew" — their trade predicted the move. Symmetrically for oneForZero.
    function markout(int24 execTick, int24 settleTick, bool zeroForOne)
        internal
        pure
        returns (int256 markoutTicks)
    {
        int256 drift = int256(settleTick) - int256(execTick);
        markoutTicks = zeroForOne ? -drift : drift;
    }

    /// @notice Forfeit fraction in WAD (1e18 = forfeit the entire bond).
    /// @param markoutTicks   signed markout from `markout()`
    /// @param thresholdTicks toxicity threshold θ (vol-scaled by the caller)
    /// @param rampTicks      width of the linear ramp beyond θ (full forfeit at θ + ramp)
    /// @dev Linear ramp: 0 at markout ≤ θ, 1e18 at markout ≥ θ + ramp. Two-sided by design:
    ///      negative markout (price reverted / mean-reverting flow) is always a full refund.
    function forfeitWad(int256 markoutTicks, int256 thresholdTicks, int256 rampTicks)
        internal
        pure
        returns (uint256)
    {
        if (markoutTicks <= thresholdTicks) return 0;
        int256 excess = markoutTicks - thresholdTicks;
        if (rampTicks <= 0 || excess >= rampTicks) return 1e18;
        return uint256(excess) * 1e18 / uint256(rampTicks);
    }
}
