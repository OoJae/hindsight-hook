// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HindsightHook} from "../../HindsightHook.sol";

/// @title HindsightCallback — Reactive Network destination shim (Unichain Sepolia)
///
/// @notice Receives callbacks from the Reactive Network callback proxy
/// (0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4 on Unichain Sepolia) and forwards them
/// into the Hindsight hook. The RSC on Reactive Lasna watches the hook's SwapRecorded
/// events and cron topics, and requests these callbacks.
///
/// Rules honored:
///  - the first argument of every callback function is the reserved `address` slot the
///    Reactive infra overwrites with the RVM id (= RSC deployer) — authenticated via
///    `rvmIdOnly`, sender via `authorizedSenderOnly` (the callback proxy)
///  - callbacks NEVER revert (a reverting callback burns gas and creates debt for
///    nothing): settlement uses the hook's non-reverting `trySettle`/`settleBatch`
contract HindsightCallback is AbstractCallback {
    event SettleForwarded(uint256 indexed swapId, bool settled);
    event SweepForwarded(uint256 nSettled, uint256 newCursor);
    event FlushForwarded(bool ok);

    HindsightHook public immutable hook;
    PoolId public immutable poolId;
    uint256 public s_cursor; // settled-prefix compaction cursor (ids are chronological)

    constructor(address _callbackProxy, HindsightHook _hook, PoolId _poolId)
        payable
        AbstractCallback(_callbackProxy)
    {
        hook = _hook;
        poolId = _poolId;
    }

    /// @notice Settle one swap (triggered by the RSC on SwapRecorded, ≥5s later).
    function settle(address rvmId, uint256 swapId)
        external
        authorizedSenderOnly
        rvmIdOnly(rvmId)
    {
        emit SettleForwarded(swapId, hook.trySettle(swapId));
    }

    /// @notice Sweep for matured-unsettled swaps (Cron10 retry lane).
    function settleSweep(address rvmId, uint256 limit)
        external
        authorizedSenderOnly
        rvmIdOnly(rvmId)
    {
        (uint256[] memory ids,) = hook.pendingMatured(s_cursor, limit == 0 ? 24 : limit);
        uint256 n;
        if (ids.length > 0) n = hook.settleBatch(ids);
        // compact past the fully-settled prefix
        uint256 i = s_cursor;
        uint256 total = hook.nextSwapId();
        for (uint256 steps; i < total && steps < 64; (i++, steps++)) {
            if (hook.getSwap(i).status == 0) break;
        }
        s_cursor = i;
        emit SweepForwarded(n, i);
    }

    /// @notice Drip the forfeit pot to LPs (Cron100 lane).
    function flushDonations(address rvmId) external authorizedSenderOnly rvmIdOnly(rvmId) {
        try hook.flushDonations(poolId) {
            emit FlushForwarded(true);
        } catch {
            emit FlushForwarded(false);
        }
    }
}
