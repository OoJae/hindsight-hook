// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AutomationCompatibleInterface} from "./AutomationCompatibleInterface.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HindsightHook} from "../../HindsightHook.sol";

/// @title HindsightUpkeep — Chainlink Automation adapter for Hindsight
///
/// @notice Makes the Chainlink Automation network the liveness layer for Hindsight
/// settlement. Three upkeep modes, registered as three separate upkeeps against this one
/// contract (differing only in `checkData`), so each shows its own execution history in
/// the Automation dashboard:
///
///   mode 0 — SETTLE : settle matured swaps in bounded batches
///   mode 1 — FLUSH  : drip the forfeit pot to in-range LPs once per epoch
///   mode 2 — POKE   : checkpoint the pool price while settlement windows are open
///
/// Design notes:
///  - `performUpkeep` is gated to the upkeep's dedicated Forwarder (set post-registration
///    via `registry.getForwarder(upkeepId)`); the hook's own `settle()` stays permissionless
///    — Chainlink guarantees liveness, it never gatekeeps.
///  - checkUpkeep results are stale by execution time, so performUpkeep re-validates:
///    `settleBatch` skips already-settled ids instead of reverting (racing manual settles
///    can never brick a batch).
///  - performData stays under Base Sepolia's 1,000-byte cap: batches are ≤ MAX_BATCH ids.
///  - `s_scanStart` is a compaction cursor over the settled prefix. Swap ids are
///    chronological and maturity is time-ordered, so the earliest pending swap is always
///    the next to mature — the prefix pointer never strands a matured swap.
contract HindsightUpkeep is AutomationCompatibleInterface {
    error NotForwarder();
    error NotOwner();
    error BadMode();

    event ForwarderSet(uint8 indexed mode, address forwarder);
    event Performed(uint8 indexed mode, uint256 count);

    uint8 public constant MODE_SETTLE = 0;
    uint8 public constant MODE_FLUSH = 1;
    uint8 public constant MODE_POKE = 2;
    uint256 public constant MAX_BATCH = 24; // 24*32 + head/len words << 1,000-byte performData cap

    HindsightHook public immutable hook;
    PoolId public immutable poolId;
    address public owner;

    PoolKey internal poolKey;
    uint256 public s_scanStart; // settled-prefix compaction cursor
    mapping(uint8 => address) public s_forwarder; // per-mode dedicated Forwarder

    constructor(HindsightHook _hook, PoolKey memory _key) {
        hook = _hook;
        poolKey = _key;
        poolId = _key.toId();
        owner = msg.sender;
    }

    /// @notice Set after registering each upkeep: registry.getForwarder(upkeepId).
    function setForwarder(uint8 mode, address forwarder) external {
        if (msg.sender != owner) revert NotOwner();
        s_forwarder[mode] = forwarder;
        emit ForwarderSet(mode, forwarder);
    }

    // ───────────────────────────── checkUpkeep (eth_call) ─────────────────────────────
    function checkUpkeep(bytes calldata checkData)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint8 mode = abi.decode(checkData, (uint8));

        if (mode == MODE_SETTLE) {
            (uint256[] memory ids,) = hook.pendingMatured(s_scanStart, MAX_BATCH);
            return (ids.length > 0, abi.encode(MODE_SETTLE, ids));
        }

        if (mode == MODE_FLUSH) {
            (uint128 pot0, uint128 pot1, uint48 lastFlush) = hook.pendingDonations(poolId);
            bool due = (uint256(pot0) + pot1 > 0)
                && hook.currentStamp() >= lastFlush + _epochStamps();
            return (due, abi.encode(MODE_FLUSH, new uint256[](0)));
        }

        if (mode == MODE_POKE) {
            // Poke when settlement work exists (pending swaps) and the pool has no
            // observation at the current stamp — guarantees TWAP data in quiet markets.
            (uint48 newestStamp,, bool ok) = hook.newestObservation(poolId);
            bool anyPending = _anyPending();
            bool stale = !ok || newestStamp < hook.currentStamp();
            return (anyPending && stale, abi.encode(MODE_POKE, new uint256[](0)));
        }

        return (false, "");
    }

    // ──────────────────────────── performUpkeep (on-chain) ────────────────────────────
    function performUpkeep(bytes calldata performData) external override {
        (uint8 mode, uint256[] memory ids) = abi.decode(performData, (uint8, uint256[]));
        address fwd = s_forwarder[mode];
        if (fwd != address(0) ? msg.sender != fwd : msg.sender != owner) revert NotForwarder();

        if (mode == MODE_SETTLE) {
            uint256 n = hook.settleBatch(ids);
            _compact();
            emit Performed(MODE_SETTLE, n);
        } else if (mode == MODE_FLUSH) {
            hook.flushDonations(poolId);
            emit Performed(MODE_FLUSH, 1);
        } else if (mode == MODE_POKE) {
            hook.poke(poolKey);
            emit Performed(MODE_POKE, 1);
        } else {
            revert BadMode();
        }
    }

    // ─────────────────────────────────── internals ────────────────────────────────────
    function _compact() internal {
        uint256 i = s_scanStart;
        uint256 n = hook.nextSwapId();
        // advance past the settled prefix (bounded by batch size per perform)
        for (uint256 steps; i < n && steps < MAX_BATCH * 2; (i++, steps++)) {
            if (hook.getSwap(i).status == 0) break;
        }
        s_scanStart = i;
    }

    function _anyPending() internal view returns (bool) {
        uint256 n = hook.nextSwapId();
        uint256 i = s_scanStart;
        for (uint256 steps; i < n && steps < MAX_BATCH * 4; (i++, steps++)) {
            if (hook.getSwap(i).status == 0) return true;
        }
        return false;
    }

    function _epochStamps() internal view returns (uint16 epoch) {
        (,,,,,,,,, epoch,) = hook.poolParams(poolId);
    }
}
