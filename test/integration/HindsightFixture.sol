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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// Shared fixture: manager + hook + pool with deep liquidity + flashblock clock helpers.
contract HindsightFixture is Test, Deployers {
    HindsightHook hook;
    MockFlashblockNumber fb;
    PoolId poolId;

    uint48 constant T0 = 1000;
    uint24 constant BOND_BPS = 25;
    // live params: N=50, W=25, grace=3000, epoch=50

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        fb = new MockFlashblockNumber();
        fb.set(T0);

        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo(
            "HindsightHook.sol", abi.encode(manager, IFlashblockNumber(address(fb)), uint256(10), address(this)), flags
        );
        hook = HindsightHook(payable(flags));

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        poolId = key.toId();

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 5_000e18, salt: 0}),
            ZERO_BYTES
        );

        // Mirror the live configuration that script/02 applies at deploy time, so the
        // suite exercises the real parameters rather than _defaultParams().
        hook.setParams(
            poolId,
            HindsightHook.HindsightParams({
                bondBps: 25,
                maturityStamps: 50,
                twapWindowStamps: 25,
                graceStamps: 3000,
                thetaMinTicks: 3,
                thetaVolMultX10: 14,
                rampTicks: 20,
                maxJumpTicks: 60,
                keeperTipBps: 500,
                epochStamps: 50,
                sizeTierCap: 10e18
            })
        );
    }

    // ── helpers ────────────────────────────────────────────────────────────────────
    mapping(address => bool) internal funded;

    /// @dev Give a test identity real balances/approvals so it can swap as itself.
    function fundTrader(address who) internal {
        if (funded[who] || who == address(this)) return;
        funded[who] = true;
        MockERC20(Currency.unwrap(currency0)).transfer(who, 100_000e18);
        MockERC20(Currency.unwrap(currency1)).transfer(who, 100_000e18);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Swap as a real user: `beneficiary` is both msg.sender and tx.origin, which is
    ///         what makes the hook's self-attribution authentic (see `_resolveTrader`).
    function swapAs(address beneficiary, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta delta)
    {
        fundTrader(beneficiary);
        vm.prank(beneficiary, beneficiary);
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
        return r.execStamp + r.fMaturity + r.fWindow + 1; // read the frozen window
    }
}
