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

/// M0 SPIKE: verify the afterSwapReturnDelta bond-escrow math for ALL FOUR swap configs.
/// The single riskiest assumption in the build — course material has inconsistent signs.
/// Asserts, per config:
///   (a) the swapper's unspecified-currency movement is worse by exactly `bond`
///   (b) the hook's ERC-6909 claim balance grows by exactly `bond`
///   (c) settlement completes (no CurrencyNotSettled)
contract DeltaSignsSpike is Test, Deployers {
    HindsightHook hook;
    MockFlashblockNumber fb;
    PoolId poolId;

    uint24 constant BOND_BPS = 25;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        fb = new MockFlashblockNumber();
        fb.set(1000);

        address flags = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // avoid collisions with precompiles/other deployments
        );
        deployCodeTo(
            "HindsightHook.sol",
            abi.encode(manager, IFlashblockNumber(address(fb)), uint256(10)),
            flags
        );
        hook = HindsightHook(payable(flags));

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        poolId = key.toId();

        // deep liquidity so scripted price pushes stay in range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 5_000e18, salt: 0}),
            ZERO_BYTES
        );
    }

    function _balances() internal view returns (uint256 b0, uint256 b1) {
        b0 = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));
        b1 = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta delta) {
        delta = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(this)) // beneficiary: refunds/reputation attach to us, not the router
        );
    }

    /// exactInput zeroForOne: unspecified = currency1 (output). Bond skimmed from output.
    function test_exactIn_zeroForOne() public {
        uint256 claimsBefore = manager.balanceOf(address(hook), currency1.toId());
        (, uint256 u1Before) = _balances();

        _swap(true, -1e18);

        (, uint256 u1After) = _balances();
        uint256 received = u1After - u1Before;
        uint256 bond = manager.balanceOf(address(hook), currency1.toId()) - claimsBefore;

        assertGt(bond, 0, "bond escrowed");
        // received = coreOutput − bond; bond = BOND_BPS/1e4 of coreOutput
        // ⇒ bond = received * 25 / (10000 − 25)
        assertApproxEqAbs(bond, received * BOND_BPS / (10_000 - BOND_BPS), 2, "bond is 25bps of output");
        assertEq(uint256(hook.getSwap(0).bond), bond, "record matches escrow");
    }

    /// exactInput oneForZero: unspecified = currency0 (output).
    function test_exactIn_oneForZero() public {
        uint256 claimsBefore = manager.balanceOf(address(hook), currency0.toId());
        (uint256 u0Before,) = _balances();

        _swap(false, -1e18);

        (uint256 u0After,) = _balances();
        uint256 received = u0After - u0Before;
        uint256 bond = manager.balanceOf(address(hook), currency0.toId()) - claimsBefore;

        assertGt(bond, 0);
        assertApproxEqAbs(bond, received * BOND_BPS / (10_000 - BOND_BPS), 2);
    }

    /// exactOutput zeroForOne: unspecified = currency0 (input). Bond added to what user pays.
    function test_exactOut_zeroForOne() public {
        uint256 claimsBefore = manager.balanceOf(address(hook), currency0.toId());
        (uint256 u0Before,) = _balances();

        _swap(true, 1e18); // want exactly 1e18 of currency1 out

        (uint256 u0After,) = _balances();
        uint256 paid = u0Before - u0After;
        uint256 bond = manager.balanceOf(address(hook), currency0.toId()) - claimsBefore;

        assertGt(bond, 0);
        // paid = coreInput + bond; bond = 25bps of coreInput ⇒ bond = paid * 25 / 10025
        assertApproxEqAbs(bond, paid * BOND_BPS / (10_000 + BOND_BPS), 2, "bond is 25bps of input");
    }

    /// exactOutput oneForZero: unspecified = currency1 (input).
    function test_exactOut_oneForZero() public {
        uint256 claimsBefore = manager.balanceOf(address(hook), currency1.toId());
        (, uint256 u1Before) = _balances();

        _swap(false, 1e18);

        (, uint256 u1After) = _balances();
        uint256 paid = u1Before - u1After;
        uint256 bond = manager.balanceOf(address(hook), currency1.toId()) - claimsBefore;

        assertGt(bond, 0);
        assertApproxEqAbs(bond, paid * BOND_BPS / (10_000 + BOND_BPS), 2);
    }

    /// The other M0 spike: donate from the hook's own unlock callback (settle refund path
    /// exercises unlock + burn + take; forfeit path adds donate) — smoke both.
    function test_settle_refund_smoke() public {
        _swap(true, -1e18);
        uint128 bond = hook.getSwap(0).bond;
        assertGt(uint256(bond), 0);

        // No further price movement ⇒ benign ⇒ refund.
        fb.set(1000 + 15 + 10 + 1); // past exec + N + W
        uint256 meBefore = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));
        hook.settle(0);
        uint256 meAfter = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));
        assertEq(meAfter - meBefore, uint256(bond), "full bond refunded to trader");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, "escrow cleared");
    }

    function test_settle_forfeit_smoke() public {
        _swap(true, -1e18);

        // Keep pushing the price the same direction during the window ⇒ toxic markout.
        for (uint256 i = 1; i <= 25; i++) {
            fb.set(1000 + i);
            _swap(true, -30e18);
        }
        fb.set(1000 + 26);

        uint128 bond = hook.getSwap(0).bond;
        uint256 hookTokBefore = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(hook));
        uint256 meBefore = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));
        hook.settle(0);
        uint256 meAfter = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 hookTokAfter = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(hook));

        // Toxic: refund < bond; the rest went to keeper tip (also us) + donation pot custody.
        uint256 gotBack = meAfter - meBefore;
        assertLt(gotBack, uint256(bond), "trader did not get the full bond back");
        assertGt(hookTokAfter + gotBack, hookTokBefore, "value conserved into pot + payouts");
    }

}
