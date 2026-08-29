// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {HindsightReactive} from "../src/integrations/reactive/HindsightReactive.sol";

/// Deploys the RSC on REACTIVE LASNA (rpc https://lasna-rpc.rnk.dev/, chain 5318007).
/// SAME key as 05a. If reactscan shows no active subscriptions after deploy, call
/// activateSubscriptions().
/// env: PRIVATE_KEY, HOOK (on 1301), REACTIVE_CALLBACK (from 05a), ORIGIN_CHAIN_ID (1301)
contract DeployReactiveRsc is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 origin = vm.envOr("ORIGIN_CHAIN_ID", uint256(1301));

        vm.startBroadcast(pk);
        HindsightReactive rsc = new HindsightReactive{value: 0.2 ether}(
            origin, vm.envAddress("HOOK"), vm.envAddress("REACTIVE_CALLBACK")
        );
        vm.stopBroadcast();

        console2.log("HindsightReactive (Lasna):", address(rsc));
        console2.log("monitor: https://lasna.reactscan.net/rvm/<your deployer address>");
    }
}
