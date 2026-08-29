// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {HindsightHook} from "../../src/HindsightHook.sol";
import {MockFlashblockNumber} from "../../src/mocks/MockFlashblockNumber.sol";

/// Invariant-test handler: random swaps / clock advances / settles / pokes / flushes.
/// Ghost accounting tracks the sum of PENDING bonds per currency.
contract Handler is Test {
    HindsightHook public hook;
    MockFlashblockNumber public fb;
    PoolSwapTest public swapRouter;
    PoolKey public key;
    PoolId public poolId;

    address[3] public actors = [address(0xA1), address(0xA2), address(0xA3)];

    // ghosts
    uint256 public outstanding0; // Σ bonds of pending swaps denominated in currency0
    uint256 public outstanding1;
    uint256 public swapsExecuted;
    uint256 public settlesExecuted;

    constructor(
        HindsightHook _hook,
        MockFlashblockNumber _fb,
        PoolSwapTest _swapRouter,
        PoolKey memory _key
    ) {
        hook = _hook;
        fb = _fb;
        swapRouter = _swapRouter;
        key = _key;
        poolId = _key.toId();
        IERC20Minimal(Currency.unwrap(key.currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(address(swapRouter), type(uint256).max);
    }

    function doSwap(uint256 actorSeed, bool zeroForOne, uint256 size) external {
        size = bound(size, 1e12, 3e18);
        address beneficiary = actors[actorSeed % 3];
        uint256 idBefore = hook.nextSwapId();

        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(size),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(beneficiary)
        ) {
            // record new bonds (a single swap records exactly one)
            uint256 idAfter = hook.nextSwapId();
            for (uint256 id = idBefore; id < idAfter; id++) {
                HindsightHook.SwapRecord memory r = hook.getSwap(id);
                if (r.bondIsCurrency0) outstanding0 += r.bond;
                else outstanding1 += r.bond;
            }
            swapsExecuted++;
        } catch {}
    }

    function advanceClock(uint256 by) external {
        by = bound(by, 1, 40);
        fb.set(hook.currentStamp() + uint48(by));
    }

    function doSettle(uint256 idSeed) external {
        uint256 n = hook.nextSwapId();
        if (n == 0) return;
        uint256 id = idSeed % n;
        HindsightHook.SwapRecord memory r = hook.getSwap(id);
        if (r.status != 0) return;

        try hook.settle(id) {
            if (r.bondIsCurrency0) outstanding0 -= r.bond;
            else outstanding1 -= r.bond;
            settlesExecuted++;
        } catch {}
    }

    function doPoke() external {
        hook.poke(key);
    }

    function doFlush() external {
        try hook.flushDonations(poolId) {} catch {}
    }
}
