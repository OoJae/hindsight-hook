// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {HindsightHook} from "../src/HindsightHook.sol";
import {IFlashblockNumber} from "../src/interfaces/IFlashblockNumber.sol";

/// Mines a CREATE2 salt for the required flag bits and deploys HindsightHook.
/// env: PRIVATE_KEY, POOL_MANAGER, FLASHBLOCK_NUMBER (0x0 to run on block.number fallback)
contract DeployHook is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address flashblocks = vm.envOr("FLASHBLOCK_NUMBER", address(0));

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        address hookOwner = vm.addr(pk);
        bytes memory ctorArgs =
            abi.encode(poolManager, IFlashblockNumber(flashblocks), uint256(10), hookOwner);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(HindsightHook).creationCode, ctorArgs);
        console2.log("mined hook address:", hookAddress);

        vm.startBroadcast(pk);
        HindsightHook hook =
            new HindsightHook{salt: salt}(poolManager, IFlashblockNumber(flashblocks), 10, hookOwner);
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "address mismatch");
        console2.log("HindsightHook deployed:", address(hook));
        console2.log("owner:", hookOwner);
    }
}
