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

/// Fork tests against REAL Unichain Sepolia state:
///   - the real PoolManager (0x00b036…62ac)
///   - the real, builder-maintained FlashblockNumber proxy (0x056466…1a42)
/// The full bond → markout → refund/forfeit cycle runs against actual chain state.
/// To simulate time passing, the counter's storage slot is discovered and advanced.
/// Run: UNICHAIN_SEPOLIA_RPC_URL=https://sepolia.unichain.org forge test --mc UnichainSepoliaFork
contract UnichainSepoliaFork is Test {
    IPoolManager constant POOL_MANAGER = IPoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
    address constant FLASHBLOCKS = 0x056466f1a50a6B5e4DCCF106074ee0083D721a42;

    HindsightHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liqRouter;
    PoolKey key;
    PoolId poolId;
    MockERC20 t0;
    MockERC20 t1;

    address constant TRADER = address(0xBEEF);
    bytes32 counterSlot;
    bool slotFound;

    modifier onFork() {
        string memory rpc = vm.envOr("UNICHAIN_SEPOLIA_RPC_URL", string("https://sepolia.unichain.org"));
        try vm.createSelectFork(rpc) {} catch {
            // NEVER `return` here: an early return in a modifier records a silent PASS,
            // making an unreachable RPC look like a proven fork run.
            vm.skip(true, "Unichain Sepolia RPC unreachable");
        }
        _setUpOnFork();
        _;
    }

    function _setUpOnFork() internal {
        // deploy the hook to a flag-correct address inside the fork
        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo(
            "HindsightHook.sol",
            abi.encode(POOL_MANAGER, IFlashblockNumber(FLASHBLOCKS), uint256(10), address(this)),
            flags
        );
        hook = HindsightHook(payable(flags));

        // fresh demo tokens + routers + pool on the real PoolManager
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
        POOL_MANAGER.initialize(key, 79228162514264337593543950336); // 1:1
        poolId = key.toId();

        liqRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 5_000e18, salt: 0}),
            ""
        );

        _discoverCounterSlot();
    }

    /// Find which storage slot of the proxy holds the live counter value.
    function _discoverCounterSlot() internal {
        uint256 live = IFlashblockNumber(FLASHBLOCKS).getFlashblockNumber();
        for (uint256 i = 0; i < 64; i++) {
            if (uint256(vm.load(FLASHBLOCKS, bytes32(i))) == live) {
                counterSlot = bytes32(i);
                slotFound = true;
                return;
            }
        }
    }

    function _advanceFlashblocks(uint256 by) internal {
        uint256 live = IFlashblockNumber(FLASHBLOCKS).getFlashblockNumber();
        if (slotFound) {
            vm.store(FLASHBLOCKS, counterSlot, bytes32(live + by));
            require(IFlashblockNumber(FLASHBLOCKS).getFlashblockNumber() == live + by, "advance failed");
        } else {
            // last resort: replace the proxy with a mock preserving the live value
            deployCodeTo("MockFlashblockNumber.sol", FLASHBLOCKS);
            (bool ok,) = FLASHBLOCKS.call(abi.encodeWithSignature("set(uint256)", live + by));
            require(ok, "etch advance failed");
        }
    }

    function _swap(address beneficiary, bool zeroForOne, int256 amount) internal {
        swapRouter.swap(
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

    function test_fork_official_counter_is_live_and_authoritative() public onFork {
        uint256 live = IFlashblockNumber(FLASHBLOCKS).getFlashblockNumber();
        assertGt(live, 0, "official Sepolia counter is live");
        assertEq(uint256(hook.currentStamp()), live, "hook reads the official counter");
        // and it is NOT the block-derived floor (the bug this test guards against)
        assertTrue(uint256(hook.currentStamp()) != block.number * 10, "not using fallback");
    }

    function test_fork_full_cycle_refund_on_real_poolmanager() public onFork {
        _swap(TRADER, true, -1e18);
        uint128 bond = hook.getSwap(0).bond;
        assertGt(uint256(bond), 0, "bond escrowed on real PoolManager");

        _advanceFlashblocks(26); // past N + W
        uint256 before = t1.balanceOf(TRADER);
        hook.settle(0);
        assertEq(t1.balanceOf(TRADER) - before, uint256(bond), "benign refund on fork");
    }

    function test_fork_full_cycle_forfeit_on_real_poolmanager() public onFork {
        _swap(TRADER, true, -1e18);
        uint128 bond = hook.getSwap(0).bond;

        // sustained directional drift through the settlement window
        for (uint256 i; i < 20; i++) {
            _advanceFlashblocks(1);
            _swap(address(0xD41F7), true, -30e18);
        }
        _advanceFlashblocks(10);

        uint256 before = t1.balanceOf(TRADER);
        hook.settle(0);
        uint256 refund = t1.balanceOf(TRADER) - before;
        assertLt(refund, uint256(bond), "toxic flow forfeits on fork");
    }
}
