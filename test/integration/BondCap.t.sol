// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./HindsightFixture.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// Spec A3: the bond is capped at the linearized cost of moving the pool by the
/// toxicity threshold — manipulation is never +EV, thin pools degrade safely.
contract BondCapTest is HindsightFixture {
    address constant TRADER = address(0xBEEF);

    function test_cap_does_not_bind_on_deep_liquidity() public {
        // fixture pool: 5000e18 liquidity at 1:1 → cap ≈ 5000e18·3/20000 = 0.75e18,
        // vastly above the 25bps bond on a 1e18 swap.
        swapAs(TRADER, true, -1e18);
        HindsightHook.SwapRecord memory r = hook.getSwap(0);
        // bond == exactly 25bps of the unspecified amount (uncapped)
        assertEq(uint256(r.bond), uint256(r.notional) * 25 / 10_000, "uncapped at depth");
    }

    function test_cap_binds_on_thin_liquidity() public {
        // Fresh thin pool on the same hook: different tickSpacing = different poolId.
        PoolKey memory thinKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: 60,
            hooks: key.hooks
        });
        manager.initialize(thinKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            thinKey,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e15, salt: 0}),
            ZERO_BYTES
        );

        uint256 id = hook.nextSwapId();
        fundTrader(TRADER);
        vm.prank(TRADER, TRADER);
        swapRouter.swap(
            thinKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e14, // large vs 1e15 liquidity, but stays in range
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(TRADER)
        );

        HindsightHook.SwapRecord memory r = hook.getSwap(id);
        uint256 uncapped = uint256(r.notional) * 25 / 10_000;
        assertGt(uint256(r.bond), 0, "bond still charged");
        assertLt(uint256(r.bond), uncapped, "manipulation-cost cap binds on thin pool");
    }

    function test_capped_bond_still_refunds_exactly() public {
        PoolKey memory thinKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: 60,
            hooks: key.hooks
        });
        manager.initialize(thinKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            thinKey,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e15, salt: 0}),
            ZERO_BYTES
        );
        uint256 id = hook.nextSwapId();
        fundTrader(TRADER);
        vm.prank(TRADER, TRADER);
        swapRouter.swap(
            thinKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e14,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(TRADER)
        );
        uint128 bond = hook.getSwap(id).bond;
        advanceTo(pastWindow(id));
        uint256 before = bal1(TRADER);
        hook.settle(id);
        assertEq(bal1(TRADER) - before, uint256(bond), "capped bond refunds exactly");
    }

    function test_range_exit_pays_standard_uncapped_bond() public {
        // A swap that exits the initialized range leaves zero active liquidity — such
        // fills pay the standard bond (documented: max price move = max markout
        // exposure; capping against edge liquidity would let toxic flow dodge bonds).
        PoolKey memory thinKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: 60,
            hooks: key.hooks
        });
        manager.initialize(thinKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            thinKey,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e15, salt: 0}),
            ZERO_BYTES
        );
        uint256 id = hook.nextSwapId();
        fundTrader(TRADER);
        vm.prank(TRADER, TRADER);
        swapRouter.swap(
            thinKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -6e14, // blows through the range
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(TRADER)
        );
        HindsightHook.SwapRecord memory r = hook.getSwap(id);
        assertEq(uint256(r.bond), uint256(r.notional) * 25 / 10_000, "standard bond on range exit");
    }

    function test_preview_uses_conservative_cap() public view {
        // deep pool: preview equals plain 25bps
        uint256 q = hook.previewBond(poolId, address(0xDEAD), 1e18);
        assertEq(q, 1e18 * 25 / 10_000);
    }
}
