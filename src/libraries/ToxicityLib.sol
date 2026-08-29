// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ToxicityLib
/// @notice EMA of realized toxic markout per beneficiary, and the bond multiplier curve.
/// @dev Only markout IN EXCESS of the threshold raises the score (benign noise never does).
library ToxicityLib {
    uint256 internal constant WAD = 1e18;

    /// @notice EMA update: score' = λ·score + (1−λ)·raw, all in WAD-scaled tick units.
    /// @param score   current EMA (WAD ticks)
    /// @param rawTicks max(0, markout − θ) from this settlement, in ticks
    /// @param lambdaWad decay λ (e.g. 0.9e18)
    function update(uint256 score, uint256 rawTicks, uint256 lambdaWad)
        internal
        pure
        returns (uint256)
    {
        // score is WAD-scaled ticks; rawTicks is plain ticks → scale by (WAD − λ) directly.
        return score * lambdaWad / WAD + rawTicks * (WAD - lambdaWad);
    }

    /// @notice Map score → bond multiplier m ∈ [minWad, maxWad]; score 0 ⇒ m0 (default 1.0
    ///         for unknown addresses comes from the caller passing score = defaultScore).
    /// @dev Linear: m = m0 + slope·score, clamped.
    function multiplier(uint256 score, uint256 m0Wad, uint256 slopeWadPerTick, uint256 minWad, uint256 maxWad)
        internal
        pure
        returns (uint256 m)
    {
        m = m0Wad + score * slopeWadPerTick / WAD;
        if (m < minWad) m = minWad;
        if (m > maxWad) m = maxWad;
    }
}
