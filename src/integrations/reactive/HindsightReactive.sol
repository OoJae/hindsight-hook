// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractPausableReactive} from "reactive-lib/abstract-base/AbstractPausableReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

/// @title HindsightReactive — the Reactive Smart Contract (deploys to Reactive Lasna)
///
/// @notice Watches the Hindsight hook on Unichain Sepolia and drives settlement via
/// Reactive callbacks — the fully on-chain, cross-network keeper:
///
///   SwapRecorded (origin 1301)  → callback settle(swapId) on Unichain Sepolia
///   Cron10  (~1 min on Lasna)   → callback settleSweep()  — retry lane for anything the
///                                 direct path missed (relayer hiccups, early deliveries)
///   Cron100 (~12 min)           → callback flushDonations() — LP forfeit drip
///
/// Deployment notes (from Reactive docs + field reports):
///  - deploy with the SAME EOA as HindsightCallback on 1301 (RVM id auth)
///  - constructor subscriptions can be rejected while the contract is being created →
///    activateSubscriptions() is the post-deploy fallback; resubscribe() repairs
///    subscriptions after a zero-balance deactivation
///  - callback gas ≥1M (the documented chain-1301 failure mode is 63/64-rule starvation)
contract HindsightReactive is AbstractPausableReactive {
    // Redeclared with the identical signature → identical topic0 as the hook's event.
    event SwapRecorded(
        uint256 indexed swapId,
        bytes32 indexed poolId,
        address indexed trader,
        bool zeroForOne,
        uint128 notional,
        uint128 bond,
        uint48 execStamp,
        int24 execTick
    );

    // Lasna legacy system-contract cron topics (dev.reactive.network/reactive-library)
    uint256 private constant CRON10_TOPIC =
        0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687;
    uint256 private constant CRON100_TOPIC =
        0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    uint64 private constant SETTLE_GAS = 1_000_000;
    uint64 private constant SWEEP_GAS = 3_000_000;
    uint64 private constant FLUSH_GAS = 1_000_000;

    uint256 public immutable originChainId; // 1301
    address public immutable hook;          // HindsightHook on Unichain Sepolia
    address public immutable callbackContract; // HindsightCallback on Unichain Sepolia

    constructor(uint256 _originChainId, address _hook, address _callbackContract) payable {
        originChainId = _originChainId;
        hook = _hook;
        callbackContract = _callbackContract;
        // NOTE: no constructor subscriptions — the system contract rejects subscribe()
        // from contracts still being created (verified live on Lasna). Call
        // activateSubscriptions() right after deployment instead.
    }

    /// @notice Post-deploy fallback: the system contract can reject subscriptions from
    ///         contracts still being created.
    function activateSubscriptions() external rnOnly onlyOwner {
        _subscribeAll();
    }

    /// @notice Repair after zero-balance deactivation (refund lREACT first).
    function resubscribe() external rnOnly onlyOwner {
        _subscribeAll();
    }

    function _subscribeAll() internal {
        service.subscribe(
            originChainId,
            hook,
            uint256(SwapRecorded.selector),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        service.subscribe(
            block.chainid, address(service), CRON10_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        service.subscribe(
            block.chainid, address(service), CRON100_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    function getPausableSubscriptions() internal view override returns (Subscription[] memory) {
        Subscription[] memory subs = new Subscription[](3);
        subs[0] = Subscription(
            originChainId, hook, uint256(SwapRecorded.selector), REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        subs[1] = Subscription(
            block.chainid, address(service), CRON10_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        subs[2] = Subscription(
            block.chainid, address(service), CRON100_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        return subs;
    }

    // ─────────────────────────────── ReactVM entry point ───────────────────────────────
    function react(LogRecord calldata log) external override vmOnly {
        if (log.topic_0 == uint256(SwapRecorded.selector)) {
            // topic_1 = swapId. First payload arg is the reserved RVM-id address slot.
            emit Callback(
                originChainId,
                callbackContract,
                SETTLE_GAS,
                abi.encodeWithSignature("settle(address,uint256)", address(0), log.topic_1)
            );
        } else if (log.topic_0 == CRON10_TOPIC) {
            emit Callback(
                originChainId,
                callbackContract,
                SWEEP_GAS,
                abi.encodeWithSignature("settleSweep(address,uint256)", address(0), uint256(24))
            );
        } else if (log.topic_0 == CRON100_TOPIC) {
            emit Callback(
                originChainId,
                callbackContract,
                FLUSH_GAS,
                abi.encodeWithSignature("flushDonations(address)", address(0))
            );
        }
    }
}
