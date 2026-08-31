// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HindsightHook} from "../../src/HindsightHook.sol";
import {IFlashblockNumber} from "../../src/interfaces/IFlashblockNumber.sol";
import {HindsightUpkeep} from "../../src/integrations/chainlink/HindsightUpkeep.sol";

/// Fork test vs the REAL Base Sepolia PoolManager (0x05E7…3408) — the Chainlink
/// Automation dual-deploy target. No FlashblockNumber on Base → the hook runs on its
/// block.number fallback clock, and the full Chainlink checkUpkeep → performUpkeep
/// settlement cycle executes against real chain state.
contract BaseSepoliaFork is Test {
    IPoolManager constant POOL_MANAGER = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);

    HindsightHook hook;
    HindsightUpkeep upkeep;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liqRouter;
    PoolKey key;
    MockERC20 t0;
    MockERC20 t1;

    address constant TRADER = address(0xBEEF);
    address constant FORWARDER = address(0xF0);

    modifier onFork() {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://sepolia.base.org"));
        try vm.createSelectFork(rpc) {} catch {
            // NEVER `return` here: an early return in a modifier records a silent PASS,
            // making an unreachable RPC look like a proven fork run.
            vm.skip(true, "Base Sepolia RPC unreachable");
        }
        _setUpOnFork();
        _;
    }

    function _setUpOnFork() internal {
        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144)
        );
        // FlashblockNumber = address(0) ⇒ block.number fallback clock
        deployCodeTo(
            "HindsightHook.sol", abi.encode(POOL_MANAGER, IFlashblockNumber(address(0)), uint256(10), address(this)), flags
        );
        hook = HindsightHook(payable(flags));

        MockERC20 a = new MockERC20("dETH", "dETH", 18);
        MockERC20 b = new MockERC20("dUSDC", "dUSDC", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        t0.mint(address(this), 1_000_000e18);
        t1.mint(address(this), 1_000_000e18);

        swapRouter = new PoolSwapTest(POOL_MANAGER);
        liqRouter = new PoolModifyLiquidityTest(POOL_MANAGER);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        t0.approve(address(liqRouter), type(uint256).max);
        t1.approve(address(liqRouter), type(uint256).max);

        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        POOL_MANAGER.initialize(key, 79228162514264337593543950336);
        liqRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 5_000e18, salt: 0}),
            ""
        );

        upkeep = new HindsightUpkeep(hook, key);
        upkeep.setForwarder(0, FORWARDER);
    }

    function _swap(bool zeroForOne, int256 amount) internal {
        // The hook only honours a hookData beneficiary that signed the transaction, so
        // TRADER must be tx.origin and must hold real balances (round-2 audit M5).
        t0.mint(TRADER, 10_000e18);
        t1.mint(TRADER, 10_000e18);
        vm.startPrank(TRADER);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        vm.prank(TRADER, TRADER);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(TRADER)
        );
    }

    function test_fork_fallback_clock_active() public onFork {
        // no FlashblockNumber contract ⇒ stamp is block-derived
        assertEq(uint256(hook.currentStamp()), block.number * 10, "fallback clock in use");
    }

    function test_fork_chainlink_cycle_on_real_poolmanager() public onFork {
        _swap(true, -1e18);
        uint128 bond = hook.getSwap(0).bond;
        assertGt(uint256(bond), 0, "bond escrowed on real Base Sepolia PoolManager");

        // not matured yet
        (bool needed0,) = upkeep.checkUpkeep(abi.encode(uint8(0)));
        assertFalse(needed0);

        vm.roll(block.number + 8); // 8 blocks × 10 stamps = 80 > N+W (75)

        (bool needed, bytes memory data) = upkeep.checkUpkeep(abi.encode(uint8(0)));
        assertTrue(needed, "checkUpkeep sees the matured swap");

        uint256 before = t1.balanceOf(TRADER);
        vm.prank(FORWARDER);
        upkeep.performUpkeep(data);

        assertEq(hook.getSwap(0).status, 1, "settled by the Chainlink perform path");
        assertEq(t1.balanceOf(TRADER) - before, uint256(bond), "benign refund via Automation");
    }
}
