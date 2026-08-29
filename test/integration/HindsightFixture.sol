// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {HindsightHook} from "../../src/HindsightHook.sol";
import {IFlashblockNumber} from "../../src/interfaces/IFlashblockNumber.sol";
import {MockFlashblockNumber} from "../../src/mocks/MockFlashblockNumber.sol";

/// Shared fixture: manager + hook + pool with deep liquidity + flashblock clock helpers.
contract HindsightFixture is Test, Deployers {
    HindsightHook hook;
    MockFlashblockNumber fb;
    PoolId poolId;

    uint48 constant T0 = 1000;
    uint24 constant BOND_BPS = 25;
    // default params: N=15, W=10, grace=3000, epoch=50

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        fb = new MockFlashblockNumber();
        fb.set(T0);

        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo(
            "HindsightHook.sol", abi.encode(manager, IFlashblockNumber(address(fb)), uint256(10)), flags
        );
        hook = HindsightHook(payable(flags));

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        poolId = key.toId();

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 5_000e18, salt: 0}),
            ZERO_BYTES
        );
    }

    // ── helpers ────────────────────────────────────────────────────────────────────
    function swapAs(address beneficiary, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta delta)
    {
        delta = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(beneficiary)
        );
    }

    /// Push price in one direction across `n` advancing flashblock stamps (toxic drift).
    function driftPrice(bool zeroForOne, uint256 n, int256 sizeEach) internal {
        for (uint256 i = 1; i <= n; i++) {
            fb.increment();
            swapAs(address(0xD41F7), zeroForOne, sizeEach);
        }
    }

    function advanceTo(uint48 stamp) internal {
        fb.set(stamp);
    }

    function stampNow() internal view returns (uint48) {
        return hook.currentStamp();
    }

    function bal0(address who) internal view returns (uint256) {
        return IERC20Minimal(Currency.unwrap(currency0)).balanceOf(who);
    }

    function bal1(address who) internal view returns (uint256) {
        return IERC20Minimal(Currency.unwrap(currency1)).balanceOf(who);
    }

    function pastWindow(uint256 swapId) internal view returns (uint48) {
        HindsightHook.SwapRecord memory r = hook.getSwap(swapId);
        return r.execStamp + 15 + 10 + 1; // N + W + 1
    }
}
