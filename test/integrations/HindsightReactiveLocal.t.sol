// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../integration/HindsightFixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {HindsightCallback} from "../../src/integrations/reactive/HindsightCallback.sol";
import {HindsightReactive} from "../../src/integrations/reactive/HindsightReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

/// Local tests for the Reactive integration.
/// The test contract plays the callback proxy: it deploys HindsightCallback (so it is
/// both the authorized sender and the rvm_id) and calls it the way the proxy would.
contract HindsightCallbackTest is HindsightFixture {
    HindsightCallback cb;
    address constant TRADER = address(0xBEEF);

    function setUp() public override {
        super.setUp();
        cb = new HindsightCallback(address(this), hook, poolId);
    }

    function test_settle_via_callback() public {
        swapAs(TRADER, true, -1e17);
        advanceTo(pastWindow(0));
        cb.settle(address(this), 0);
        assertEq(hook.getSwap(0).status, 1, "settled through the Reactive callback path");
    }

    function test_immature_callback_never_reverts() public {
        swapAs(TRADER, true, -1e17);
        cb.settle(address(this), 0); // early delivery — must no-op, not revert
        assertEq(hook.getSwap(0).status, 0, "still pending");
    }

    function test_unknown_id_callback_never_reverts() public {
        cb.settle(address(this), 999);
    }

    function test_auth_sender_and_rvm_id() public {
        vm.expectRevert();
        vm.prank(address(0xBAD));
        cb.settle(address(this), 0); // not the authorized sender (proxy)

        vm.expectRevert();
        cb.settle(address(0xBAD), 0); // wrong rvm id
    }

    function test_sweep_settles_and_compacts() public {
        swapAs(TRADER, true, -1e17);
        fb.increment();
        swapAs(TRADER, false, -1e17);
        advanceTo(pastWindow(1));

        cb.settleSweep(address(this), 24);
        assertEq(hook.getSwap(0).status, 1);
        assertEq(hook.getSwap(1).status, 1);
        assertEq(cb.s_cursor(), 2, "cursor compacted past settled prefix");
    }

    function test_flush_callback() public {
        uint256 id = hook.nextSwapId();
        swapAs(TRADER, true, -1e18);
        driftPrice(true, 20, -30e18);
        advanceTo(pastWindow(id));
        hook.settle(id);
        advanceTo(stampNow() + 51);
        cb.flushDonations(address(this)); // must not revert; drips
    }
}

contract HindsightReactiveTest is HindsightFixture {
    HindsightReactive rsc;
    uint256 constant ORIGIN = 1301;
    address constant HOOK_ADDR = address(0x1234);
    address constant CB = address(0xCB99);

    bytes32 constant SWAP_RECORDED_T0 =
        0x68ac09ad42d02bbeb744c7646eda0da05627e4e3fe954881385a3be7536ea0a2;
    uint256 constant CRON10 = 0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687;

    function setUp() public override {
        // no fixture needed; RSC is standalone. vm=true locally (no system contract).
        rsc = new HindsightReactive(ORIGIN, address(0x1234), CB);
    }

    function _log(uint256 topic0, uint256 topic1) internal pure returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: ORIGIN,
            _contract: address(0x1234),
            topic_0: topic0,
            topic_1: topic1,
            topic_2: 0,
            topic_3: 0,
            data: "",
            block_number: 1,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function test_swapRecorded_emits_settle_callback() public {
        vm.recordLogs();
        rsc.react(_log(uint256(SWAP_RECORDED_T0), 42));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        // Callback(chain_id indexed, contract indexed, gas_limit indexed, payload)
        assertEq(uint256(logs[0].topics[1]), ORIGIN);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), CB);
        bytes memory payload = abi.decode(logs[0].data, (bytes));
        assertEq(payload, abi.encodeWithSignature("settle(address,uint256)", address(0), uint256(42)));
    }

    function test_cron10_emits_sweep_callback() public {
        vm.recordLogs();
        rsc.react(_log(CRON10, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        bytes memory payload = abi.decode(logs[0].data, (bytes));
        assertEq(payload, abi.encodeWithSignature("settleSweep(address,uint256)", address(0), uint256(24)));
    }

    function test_unknown_topic_is_ignored() public {
        vm.recordLogs();
        rsc.react(_log(0xdead, 0));
        assertEq(vm.getRecordedLogs().length, 0);
    }
}
