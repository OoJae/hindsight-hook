// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HindsightFixture} from "./HindsightFixture.sol";
import {HindsightHook} from "../../src/HindsightHook.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// Round-2 audit findings M4-M7: one executable repro each, written BEFORE the fix so the
/// exploit is on record. Each asserts the FIXED behaviour, so before the fix they fail.
contract AuditRepro2Test is HindsightFixture {
    address constant USER = address(0x5E12);
    address constant SOLVER = address(0x501E4);
    address constant KEEPER = address(0xEE9E);

    // ── M5: the bond is charged to the swapper and refunded to someone else ──────────

    /// A solver that merely builds the calldata must not be able to redirect the refund of
    /// a bond that came out of the user's own swap output.
    function test_M5_hookData_cannot_redirect_someone_elses_refund() public {
        fundTrader(USER);
        uint256 solverBefore = bal1(SOLVER);
        uint256 userBefore = bal0(USER);

        // USER signs the tx; the calldata names SOLVER as beneficiary.
        vm.prank(USER, USER);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(SOLVER)
        );

        HindsightHook.SwapRecord memory r = hook.getSwap(0);
        assertGt(r.bond, 0, "a bond must have been escrowed");
        // exact-input zeroForOne: USER pays currency0, and the bond is withheld from the
        // currency1 output — so the bond came out of USER's proceeds, not SOLVER's.
        assertLt(bal0(USER), userBefore, "USER paid for the swap");

        advanceTo(pastWindow(0));
        hook.settle(0);

        assertEq(bal1(SOLVER), solverBefore, "SOLVER must not collect a refund it never paid");
    }

    /// With empty hookData through a plain router the payee must not be the router, or the
    /// refund is stranded in a contract that ended its call long before settlement.
    function test_M5_empty_hookData_does_not_strand_the_refund_in_the_router() public {
        fundTrader(USER);
        uint256 routerBefore = bal1(address(swapRouter));

        vm.prank(USER, USER);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        uint256 userAfterSwap = bal1(USER);
        advanceTo(pastWindow(0));
        hook.settle(0);

        assertEq(bal1(address(swapRouter)), routerBefore, "refund must not land in the router");
        assertGt(bal1(USER), userAfterSwap, "the refund must reach the party that paid the bond");
    }

    // ── M4: theta is pumpable by padding your own settlement window ──────────────────

    /// M4/M9, closed at the root rather than bounded.
    ///
    /// v6 clamped how far a trader could pump theta (171 ticks -> 31). v7 removes the
    /// channel: theta is measured over `[exec-600, exec-1]`, a window that has already
    /// closed when the swap lands, so padding the settlement window moves it by exactly
    /// zero. This asserts the *equality*, not a bound — a bound would still be a mechanism
    /// with a price on it.
    function test_M4_in_window_padding_cannot_move_theta_at_all() public {
        swapAs(USER, true, -1e18);
        HindsightHook.SwapRecord memory r = hook.getSwap(0);
        int24 thetaAtExecution = r.fTheta;
        (,,, int256 thetaBefore,) = hook.previewSettle(0);

        // The exact vector that reached theta=171 on the pre-fix build: round trips landing
        // INSIDE the settlement window [exec+15, exec+25].
        advanceTo(r.execStamp + 50);
        for (uint256 i = 0; i < 5; i++) {
            fb.increment();
            swapAs(address(0xADD1), true, -30e18);
            fb.increment();
            swapAs(address(0xADD1), false, -30e18);
        }
        advanceTo(r.execStamp + 76);

        (,, int256 markout, int256 thetaAfter,) = hook.previewSettle(0);
        assertGt(markout, 0, "precondition: the padding did move the price");
        assertEq(thetaAfter, thetaBefore, "padding the settlement window must not move theta");
        assertEq(thetaAfter, int256(thetaAtExecution), "theta is whatever it was at execution");
    }

    /// Guard against the test above being vacuous: theta must actually RESPOND to
    /// volatility, just to volatility that happened before the trade. If the trailing window
    /// were dead code theta would sit at its floor everywhere, and an equality assertion
    /// would prove nothing.
    ///
    /// (A third test asserting "two swaps with identical pre-history get identical theta"
    /// was written and then deleted: their settlement windows overlap, so it passed on the
    /// OLD sourcing too. Both tests kept here fail on the old code — verified by reverting
    /// _theta and re-running.)
    function test_M4_theta_responds_to_PRE_trade_volatility() public {
        // A quiet-history swap: theta should sit at the floor.
        swapAs(USER, true, -1e18);
        int24 quietTheta = hook.getSwap(0).fTheta;

        // Now make the tape violent BEFORE the next swap...
        for (uint256 i = 0; i < 10; i++) {
            fb.increment();
            swapAs(address(0xADD1), i % 2 == 0, -40e18);
        }
        fb.increment();
        swapAs(USER, true, -1e18);
        int24 loudTheta = hook.getSwap(hook.nextSwapId() - 1).fTheta;

        assertEq(quietTheta, 3, "quiet pre-trade history leaves theta at its floor");
        assertGt(loudTheta, quietTheta,
            "a violent PRE-trade tape must widen theta, else the vol term is dead code");
    }

    // ── M6: setParams must not be able to confiscate an in-flight bond ───────────────

    function test_M6_retune_cannot_confiscate_a_pending_benign_bond() public {
        swapAs(USER, true, -1e18);
        HindsightHook.SwapRecord memory r = hook.getSwap(0);
        uint256 bond = r.bond;
        uint256 userAfterSwap = bal1(USER);

        // The worst retune the bounds currently allow: collapse maturity+window+grace so the
        // in-flight bond is instantly past grace, and max the keeper tip.
        vm.expectRevert();
        hook.setParams(
            poolId,
            HindsightHook.HindsightParams({
                bondBps: 25,
                maturityStamps: 0,
                twapWindowStamps: 1,
                graceStamps: 1,
                thetaMinTicks: 3,
                thetaVolMultX10: 14,
                rampTicks: 20,
                maxJumpTicks: 60,
                keeperTipBps: 1000,
                epochStamps: 50,
                sizeTierCap: 10e18
            })
        );

        advanceTo(pastWindow(0));
        hook.settle(0);
        assertEq(bal1(USER) - userAfterSwap, bond, "a benign pending bond must still refund in full");
    }

    /// thetaMinTicks is unbounded above, so the owner can switch the mechanism off entirely.
    function test_M6_theta_min_is_bounded() public {
        vm.expectRevert();
        hook.setParams(
            poolId,
            HindsightHook.HindsightParams({
                bondBps: 25,
                maturityStamps: 50,
                twapWindowStamps: 25,
                graceStamps: 3000,
                thetaMinTicks: type(int24).max,
                thetaVolMultX10: 14,
                rampTicks: 20,
                maxJumpTicks: 60,
                keeperTipBps: 500,
                epochStamps: 50,
                sizeTierCap: 10e18
            })
        );
    }

    // ── M10 (found live on v5): a finalized verdict must outrank the grace deadline ──

    /// Observed on the live v5 deployment: the Reactive lane went down for ~30 minutes, and
    /// five swaps whose windows had already been finalized BENIGN (markout 22-27 vs theta 31)
    /// were auto-forfeited in full when they were finally settled past grace. `finalize` is
    /// permissionless and locks the measurement the instant the window closes, so waiting can
    /// no longer destroy anything — the grace forfeit must apply only to UNMEASURED swaps.
    function test_M10_finalized_benign_verdict_survives_a_grace_lapse() public {
        swapAs(USER, true, -1e18);
        HindsightHook.SwapRecord memory r = hook.getSwap(0);
        uint256 userAfterSwap = bal0(USER) + bal1(USER);

        // Window closes; anyone finalizes (the keeper lane, the trader, a passing bot).
        advanceTo(pastWindow(0));
        hook.finalize(0);
        assertTrue(hook.getSwap(0).finalized, "verdict locked while the data existed");

        // ...then nobody settles for far longer than the grace period.
        advanceTo(r.execStamp + 50 + 25 + 3000 + 500);
        hook.settle(0);

        assertEq(uint256(hook.getSwap(0).status), 1, "recorded benign must settle as a refund");
        assertEq(
            bal0(USER) + bal1(USER) - userAfterSwap,
            uint256(r.bond),
            "a measured-benign bond must not be confiscated for late settlement"
        );
    }

    /// The corollary: lateness alone is no longer punished. If the window's observations are
    /// still intact when a late settlement arrives, the swap is MEASURED rather than
    /// confiscated — `settle` finalizes implicitly, so it grades on real data.
    ///
    /// The escape hatch this used to guard is still shut, but by the precise mechanism rather
    /// than a blunt deadline: a window whose data was DESTROYED forfeits in full
    /// (`AuditRepro.t.sol::test_M4b_evicted_data_cannot_buy_a_refund` and
    /// `EvictionExploit.t.sol`). Waiting out the ring buffer therefore still costs the whole
    /// bond; waiting while the data survives simply gets you the verdict you earned.
    function test_M10_late_settlement_with_intact_data_is_measured_not_confiscated() public {
        swapAs(USER, true, -1e18);
        HindsightHook.SwapRecord memory r = hook.getSwap(0);
        uint256 userAfterSwap = bal0(USER) + bal1(USER);

        advanceTo(r.execStamp + 50 + 25 + 3000 + 500); // long past grace, never finalized
        hook.settle(0);

        assertEq(uint256(hook.getSwap(0).status), 1, "intact data grades benign, not forfeit");
        assertEq(
            bal0(USER) + bal1(USER) - userAfterSwap,
            uint256(r.bond),
            "benign flow keeps its bond however late the keeper is"
        );
    }

    // ── M7: waiting out grace must not pay a keeper more than settling ───────────────

    function test_M7_prompt_settlement_weakly_dominates_waiting_for_grace() public {
        // Two identical benign swaps: settle one promptly, let the other lapse past grace.
        swapAs(USER, true, -1e18);
        swapAs(address(0xB0B), true, -1e18);

        advanceTo(pastWindow(0));
        uint256 keeperBefore = bal1(KEEPER);
        vm.prank(KEEPER);
        hook.settle(0);
        uint256 promptTip = bal1(KEEPER) - keeperBefore;

        // Now let swap 1 lapse: past exec + maturity + window + grace.
        HindsightHook.SwapRecord memory r1 = hook.getSwap(1);
        advanceTo(r1.execStamp + 50 + 25 + 3000 + 1);
        uint256 keeperBefore2 = bal1(KEEPER);
        vm.prank(KEEPER);
        hook.settle(1);
        uint256 lapsedTip = bal1(KEEPER) - keeperBefore2;

        assertLe(
            lapsedTip,
            promptTip == 0 ? r1.bond / 2 : promptTip,
            "letting a bond lapse must not pay the keeper strictly more than settling it"
        );
    }
}
