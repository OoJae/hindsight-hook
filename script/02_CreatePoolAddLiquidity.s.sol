// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HindsightHook} from "../src/HindsightHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// Testnet demo environment: two demo tokens, a Hindsight pool at 5bps, deep liquidity,
/// plus swap/liquidity routers for scripted flows and the frontend.
/// env: PRIVATE_KEY, POOL_MANAGER, HOOK
contract CreatePoolAddLiquidity is Script {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address hook = vm.envAddress("HOOK");

        vm.startBroadcast(pk);

        MockERC20 tokenA = new MockERC20("Hindsight Demo ETH", "dETH", 18);
        MockERC20 tokenB = new MockERC20("Hindsight Demo USDC", "dUSDC", 18);
        (MockERC20 t0, MockERC20 t1) =
            address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        t0.mint(msg.sender, 1_000_000e18);
        t1.mint(msg.sender, 1_000_000e18);

        PoolSwapTest swapRouter = new PoolSwapTest(poolManager);
        PoolModifyLiquidityTest liqRouter = new PoolModifyLiquidityTest(poolManager);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        t0.approve(address(liqRouter), type(uint256).max);
        t1.approve(address(liqRouter), type(uint256).max);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 500, // 5 bps headline — the whole point: volatile pair at a low static fee
            tickSpacing: 10,
            hooks: IHooks(hook)
        });
        poolManager.initialize(key, SQRT_PRICE_1_1);

        liqRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 50_000e18, salt: 0}),
            ""
        );

        // Set the LIVE parameters here, so the deployment is reproducible from the repo.
        // Until v7 this was done out-of-band with an ad-hoc `cast send`, which meant the
        // parameters the live pools actually run could not be derived from any committed
        // file — and HindsightFixture's comment claiming "deployments do this in script/02"
        // described a step that did not exist.
        HindsightHook(payable(hook)).setParams(
            key.toId(),
            HindsightHook.HindsightParams({
                bondBps: 25,
                maturityStamps: 50,      // 10s at 200ms flashblocks
                twapWindowStamps: 25,    // 5s settlement window
                graceStamps: 3000,
                thetaMinTicks: 3,
                thetaVolMultX10: 14,     // k = 1.4 x trailing realized vol
                rampTicks: 20,
                maxJumpTicks: 60,
                keeperTipBps: 500,
                epochStamps: 50,
                sizeTierCap: 10e18
            })
        );

        vm.stopBroadcast();

        console2.log("token0:", address(t0));
        console2.log("token1:", address(t1));
        console2.log("swapRouter:", address(swapRouter));
        console2.log("liquidityRouter:", address(liqRouter));
        console2.log("pool initialized at 5bps with hook:", hook);
    }
}
