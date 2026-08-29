// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// Demo flows for the video:
///   MODE=retail  — one benign swap (settles to a full refund)
///   MODE=arb     — a directional burst that will register toxic markout
/// env: PRIVATE_KEY, SWAP_ROUTER, TOKEN0, TOKEN1, HOOK, MODE, BENEFICIARY (optional)
contract ScriptedSwaps is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        PoolSwapTest swapRouter = PoolSwapTest(vm.envAddress("SWAP_ROUTER"));
        address beneficiary = vm.envOr("BENEFICIARY", vm.addr(pk));
        string memory mode = vm.envString("MODE");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(vm.envAddress("TOKEN0")),
            currency1: Currency.wrap(vm.envAddress("TOKEN1")),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(vm.envAddress("HOOK"))
        });

        vm.startBroadcast(pk);
        if (keccak256(bytes(mode)) == keccak256("retail")) {
            _swap(swapRouter, key, true, -1e18, beneficiary);
            console2.log("retail swap sent (benign; expect full bond refund)");
        } else {
            for (uint256 i; i < 8; i++) {
                _swap(swapRouter, key, true, -25e18, beneficiary);
            }
            console2.log("arb burst sent (directional; expect forfeit at settlement)");
        }
        vm.stopBroadcast();
    }

    function _swap(
        PoolSwapTest router,
        PoolKey memory key,
        bool zeroForOne,
        int256 amount,
        address beneficiary
    ) internal {
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(beneficiary)
        );
    }
}
