// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HindsightHook} from "../src/HindsightHook.sol";
import {HindsightCallback} from "../src/integrations/reactive/HindsightCallback.sol";

/// Deploys the Reactive destination shim on UNICHAIN SEPOLIA, pre-funded for callbacks.
/// IMPORTANT: deploy with the SAME key you will use for the RSC on Lasna (RVM id auth).
/// env: PRIVATE_KEY, HOOK, POOL_ID (bytes32), CALLBACK_PROXY (default: official 1301 proxy)
contract DeployReactiveCallback is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envOr("CALLBACK_PROXY", 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4);
        bytes32 poolId = vm.envBytes32("POOL_ID");

        vm.startBroadcast(pk);
        HindsightCallback cb = new HindsightCallback{value: 0.02 ether}(
            proxy, HindsightHook(payable(vm.envAddress("HOOK"))), PoolId.wrap(poolId)
        );
        vm.stopBroadcast();

        console2.log("HindsightCallback:", address(cb));
        console2.log("fund reserves too: cast send", proxy, '"depositTo(address)"', address(cb));
    }
}
