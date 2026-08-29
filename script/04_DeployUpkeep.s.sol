// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HindsightHook} from "../src/HindsightHook.sol";
import {HindsightUpkeep} from "../src/integrations/chainlink/HindsightUpkeep.sol";

/// Deploys the Chainlink Automation adapter (run on Base Sepolia after 01+02).
/// Post-deploy: register 3 upkeeps at automation.chain.link against this contract with
/// checkData abi.encode(uint8(mode)) for modes 0/1/2, then call setForwarder(mode,
/// registry.getForwarder(upkeepId)) for each.
/// env: PRIVATE_KEY, HOOK, TOKEN0, TOKEN1
contract DeployUpkeep is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(vm.envAddress("TOKEN0")),
            currency1: Currency.wrap(vm.envAddress("TOKEN1")),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(vm.envAddress("HOOK"))
        });

        vm.startBroadcast(pk);
        HindsightUpkeep upkeep = new HindsightUpkeep(HindsightHook(payable(vm.envAddress("HOOK"))), key);
        vm.stopBroadcast();

        console2.log("HindsightUpkeep:", address(upkeep));
        console2.log("checkData mode 0 (settle):", vm.toString(abi.encode(uint8(0))));
        console2.log("checkData mode 1 (flush): ", vm.toString(abi.encode(uint8(1))));
        console2.log("checkData mode 2 (poke):  ", vm.toString(abi.encode(uint8(2))));
    }
}
