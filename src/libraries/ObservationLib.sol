// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ObservationLib
/// @notice Flashblock-stamped ring buffer of pool ticks + settlement-window TWAP.
/// @dev Robustness over elegance: time-weighted average with successive-jump clamping
///      (each observation's move vs the previous accepted tick is clamped to ±maxJumpTicks,
///      the per-flashblock contribution cap from the mechanism spec). A time-weighted
///      median is noted as future work; jump-clamped TWA gives similar spike resistance
///      at a fraction of the complexity.
library ObservationLib {
    uint16 internal constant CARDINALITY = 128;

    struct Observation {
        uint48 stamp; // flashblock number (monotonic, does not reset per block)
        int24 tick;
    }

    struct Buffer {
        Observation[CARDINALITY] obs;
        uint16 index; // next write slot
        uint16 count; // number of valid entries (saturates at CARDINALITY)
    }

    /// @notice Record (stamp, tick) if stamp advanced past the newest entry.
    function write(Buffer storage self, uint48 stamp, int24 tick) internal returns (bool written) {
        uint16 newestIdx = self.count == 0 ? 0 : (self.index + CARDINALITY - 1) % CARDINALITY;
        if (self.count != 0 && self.obs[newestIdx].stamp >= stamp) return false;
        self.obs[self.index] = Observation({stamp: stamp, tick: tick});
        self.index = (self.index + 1) % CARDINALITY;
        if (self.count < CARDINALITY) self.count++;
        return true;
    }

    /// @notice Like `write`, but REFRESHES the newest entry in place when the stamp matches.
    /// @dev Required for the post-swap tick: `beforeSwap` already wrote the pre-swap price at
    ///      this same stamp, so a plain `write` would be a no-op and the trade's own impact
    ///      would never enter the series — leaving swaps scored against their own pre-trade
    ///      price. Backwards stamps are ignored rather than corrupting the buffer.
    function writeOrUpdate(Buffer storage self, uint48 stamp, int24 tick) internal {
        if (self.count != 0) {
            uint16 newestIdx = (self.index + CARDINALITY - 1) % CARDINALITY;
            if (self.obs[newestIdx].stamp == stamp) {
                self.obs[newestIdx].tick = tick;
                return;
            }
            if (self.obs[newestIdx].stamp > stamp) return; // clock went backwards: ignore
        }
        write(self, stamp, tick);
    }

    /// @notice Jump-clamped time-weighted average tick over stamps [from, to].
    /// @return avgTick  the TWAP tick
    /// @return nObs     observations that informed the window (incl. the one entering it)
    /// @return ok       false when the window has no usable data (caller MUST refund — spec:
    ///                  missing data can never punish a trader)
    function twap(Buffer storage self, uint48 from, uint48 to, int24 maxJumpTicks)
        public
        view
        returns (int24 avgTick, uint16 nObs, bool ok)
    {
        if (to <= from || self.count == 0) return (0, 0, false);

        // Walk chronologically: oldest entry is at `index` when full, else at 0.
        uint16 start = self.count == CARDINALITY ? self.index : 0;

        int256 weighted; // Σ tick_i · overlap_i
        uint256 duration; // Σ overlap_i
        int24 prevTick;
        bool havePrev;
        uint48 prevStamp;

        for (uint16 i = 0; i < self.count; i++) {
            Observation memory o = self.obs[(start + i) % CARDINALITY];

            // Clamp the jump vs the previously accepted tick (contribution cap).
            int24 t = o.tick;
            if (havePrev && maxJumpTicks > 0) {
                int256 jump = int256(t) - int256(prevTick);
                if (jump > int256(maxJumpTicks)) t = int24(int256(prevTick) + int256(maxJumpTicks));
                else if (jump < -int256(maxJumpTicks)) t = int24(int256(prevTick) - int256(maxJumpTicks));
            }

            if (havePrev) {
                // prevTick held over [prevStamp, o.stamp); intersect with [from, to].
                uint48 a = prevStamp > from ? prevStamp : from;
                uint48 b = o.stamp < to ? o.stamp : to;
                if (b > a) {
                    weighted += int256(prevTick) * int256(uint256(b - a));
                    duration += b - a;
                    nObs++;
                }
            }
            prevTick = t;
            prevStamp = o.stamp;
            havePrev = true;
            if (o.stamp >= to) break;
        }

        // The newest observation holds from its stamp to the window end.
        if (havePrev && prevStamp < to) {
            uint48 a = prevStamp > from ? prevStamp : from;
            if (to > a) {
                weighted += int256(prevTick) * int256(uint256(to - a));
                duration += to - a;
                nObs++;
            }
        }

        if (duration == 0) return (0, 0, false);
        avgTick = int24(weighted / int256(duration));
        ok = true;
    }


    /// @notice Mean absolute tick jump between consecutive observations whose stamps fall
    ///         in [from, to] — a cheap realized-volatility proxy used to scale the toxicity
    ///         threshold θ (spec 3.4): trending/volatile windows widen θ so benign momentum
    ///         flow is not confiscated.
    function avgAbsJump(Buffer storage self, uint48 from, uint48 to, int24 maxJumpTicks)
        public
        view
        returns (uint256 meanJumpTicks, uint16 nJumps)
    {
        if (self.count == 0) return (0, 0);
        uint16 start = self.count == CARDINALITY ? self.index : 0;
        uint256 sumAbs;
        int24 prevTick;
        bool havePrev;
        for (uint16 i = 0; i < self.count; i++) {
            Observation memory o = self.obs[(start + i) % CARDINALITY];
            if (o.stamp < from) { prevTick = o.tick; havePrev = true; continue; }
            if (o.stamp > to) break;
            if (havePrev) {
                int256 j = int256(o.tick) - int256(prevTick);
                uint256 absJ = uint256(j < 0 ? -j : j);
                // Same contribution cap the TWAP applies: a single spike must not be able to
                // inflate theta (which would let the trade that caused it escape as "benign").
                if (maxJumpTicks > 0 && absJ > uint256(uint24(maxJumpTicks))) {
                    absJ = uint256(uint24(maxJumpTicks));
                }
                sumAbs += absJ;
                nJumps++;
            }
            prevTick = o.tick;
            havePrev = true;
        }
        if (nJumps == 0) return (0, 0);
        meanJumpTicks = sumAbs / nJumps;
    }

    /// @notice Volatility-scaled toxicity threshold, computed entirely inside the library.
    /// @dev Lives here rather than in the hook for two reasons. It saves the hook an external
    ///      call (it used to call `avgAbsJump` and then do the arithmetic itself), and the
    ///      hook is 200 bytes from the EIP-170 limit. Integer division twice, exactly as the
    ///      hook did it — the backtest was corrected to match this, not the other way round.
    function theta(
        Buffer storage self,
        uint48 from,
        uint48 to,
        int24 maxJumpTicks,
        int24 thetaMinTicks,
        uint16 thetaVolMultX10
    ) public view returns (int256) {
        (uint256 vol,) = avgAbsJump(self, from, to, maxJumpTicks);
        return int256(uint256(int256(thetaMinTicks))) + int256(vol * thetaVolMultX10 / 10);
    }

    /// @notice Newest stamp ≤ `at` exists? Used to check data coverage.

    /// @notice Oldest retained observation. Used to tell "we never had data for this window"
    ///         (refund) apart from "the data existed and was evicted" (do not reward).
    function oldest(Buffer storage self) internal view returns (uint48 stamp, bool full) {
        if (self.count == 0) return (0, false);
        full = self.count == CARDINALITY;
        uint16 idx = full ? self.index : 0;
        return (self.obs[idx].stamp, full);
    }

    /// @notice Newest observation (stamp, tick); ok=false when empty.
    function newest(Buffer storage self) internal view returns (uint48 stamp, int24 tick, bool ok) {
        if (self.count == 0) return (0, 0, false);
        Observation memory o = self.obs[(self.index + CARDINALITY - 1) % CARDINALITY];
        return (o.stamp, o.tick, true);
    }
}
