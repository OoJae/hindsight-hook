// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {OperatedFlashblockNumber} from "../src/OperatedFlashblockNumber.sol";

/// Deploys our operated flashblock counter (testnet only — mainnet uses the official
/// instance). The deployer EOA is owner + sole builder; the keeper bot ticks it.
contract DeployFlashblockNumber is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address operator = vm.addr(pk);

        vm.startBroadcast(pk);
        address[] memory builders = new address[](1);
        builders[0] = operator;
        OperatedFlashblockNumber fb = new OperatedFlashblockNumber(operator, builders);
        vm.stopBroadcast();

        console2.log("OperatedFlashblockNumber:", address(fb));
        console2.log("operator/builder:", operator);
    }
}
