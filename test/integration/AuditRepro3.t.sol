// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HindsightFixture} from "./HindsightFixture.sol";
import {HindsightHook} from "../../src/HindsightHook.sol";

/// Round-3 audit. Repros written BEFORE the fixes, so the exploits are on record.
contract AuditRepro3Test is HindsightFixture {
    address constant USER = address(0x5E12);
    address constant FLOOD = address(0xF100D);

    // ── R1: rampTicks is still retroactive over in-flight bonds ─────────────────────

    /// M6 stopped the owner pulling in the settlement DEADLINE. But `rampTicks` is still read
    /// live at settle time (HindsightHook.sol:473) while theta is now snapshotted at
    /// execution, and setParams only requires `rampTicks >= 1`. So after a bond is escrowed
    /// the owner can set ramp = 1 and convert a proportional forfeit into a total one.
    function test_R1_owner_cannot_maximise_forfeits_on_in_flight_bonds() public {
        // A trade that reads MILDLY toxic: markout a few ticks past theta but inside the
        // ramp, so the shipped parameters give a PARTIAL forfeit. That is the case the ramp
        // exists for, and the case the owner can retroactively convert into a total loss.
        swapAs(USER, true, -1e18);
        driftPrice(true, 3, -1e18);
        advanceTo(pastWindow(0));

        (,,, , uint256 fWadBefore) = hook.previewSettle(0);
        assertGt(fWadBefore, 0, "precondition: reads toxic");
        assertLt(fWadBefore, 1e18, "precondition: only a PARTIAL forfeit at the shipped ramp");

        // ramp=1 was the exploit: MarkoutLib returns a FULL forfeit for any excess >= ramp,
        // so ramp=1 and the forbidden ramp=0 are identical. The bound is now `>= 2`.
        HindsightHook.HindsightParams memory p = _liveParams();
        p.rampTicks = 1;
        vm.expectRevert(HindsightHook.BadParams.selector);
        hook.setParams(poolId, p);

        // And even a legal tightening cannot reach an escrowed bond: the ramp is frozen in
        // the record at execution.
        p.rampTicks = 2;
        hook.setParams(poolId, p);
        (,,, , uint256 fWadAfter) = hook.previewSettle(0);
        assertEq(fWadAfter, fWadBefore, "a retune must not touch an in-flight forfeit");
    }

    // ── R2: permissionless poke() deflates theta for everyone ───────────────────────

    /// `avgAbsJump` counts EVERY consecutive pair, including pairs whose tick did not move.
    /// `poke()` is permissionless and writes (currentStamp, currentTick), so same-tick pokes
    /// at successive stamps each contribute a ZERO jump and drag the mean down. Under v7
    /// theta reads a shared TRAILING window, so this deflates the threshold for every
    /// subsequent swap at once — and forfeits are donated to in-range LPs, which makes a
    /// large LP the natural attacker rather than a pure griefer.
    function test_R2_poke_flooding_deflates_theta_for_everyone() public {
        // Make the tape genuinely volatile so theta SHOULD be well above its floor.
        for (uint256 i = 0; i < 12; i++) {
            fb.increment();
            swapAs(address(0xADD1), i % 2 == 0, -40e18);
        }
        fb.increment();
        swapAs(USER, true, -1e18);
        int24 honestTheta = hook.getSwap(hook.nextSwapId() - 1).fTheta;
        assertGt(honestTheta, 3, "precondition: a volatile tape widens theta");

        // Now flood the 128-slot buffer with same-tick checkpoints. No capital, only gas.
        vm.startPrank(FLOOD, FLOOD);
        for (uint256 i = 0; i < 140; i++) {
            fb.increment();
            hook.poke(key);
        }
        vm.stopPrank();

        fb.increment();
        swapAs(USER, true, -1e18);
        int24 floodedTheta = hook.getSwap(hook.nextSwapId() - 1).fTheta;

        assertLt(floodedTheta, honestTheta, "EXPLOIT: pokes deflated the shared threshold");
        assertEq(floodedTheta, 3, "EXPLOIT: theta driven all the way to its floor for gas alone");
    }

    // ── R3 (audit, CRITICAL): the M6 ratchet guards the deadline SUM, not the window's
    //     POSITION. maturityStamps is read live at settle time, so the owner can slide an
    //     in-flight swap's measurement window with hindsight, at zero ratchet cost.

    function test_R3_relocating_the_window_no_longer_reaches_in_flight_swaps() public {
        swapAs(USER, true, -25e18);
        HindsightHook.SwapRecord memory r = hook.getSwap(0);

        // Let the price do something interesting AFTER execution, then pick the window that
        // suits. Drift up first, then back down.
        driftPrice(true, 20, -30e18);
        uint48 afterDrift = stampNow();
        driftPrice(false, 20, -30e18);
        advanceTo(afterDrift + 200);

        HindsightHook.HindsightParams memory p = _liveParams();
        uint256 sumBefore = uint256(p.maturityStamps) + p.twapWindowStamps + p.graceStamps;

        // Slide maturity late, pay for it out of grace: the SUM is unchanged, so the M6
        // clause passes with equality and consumes no ratchet headroom. Repeatable forever.
        p.maturityStamps = 200;
        p.graceStamps = uint16(sumBefore - p.maturityStamps - p.twapWindowStamps);
        assertEq(uint256(p.maturityStamps) + p.twapWindowStamps + p.graceStamps, sumBefore,
            "the deadline sum is untouched, which is all M6 checks");
        hook.setParams(poolId, p);   // must NOT revert -- that is the finding

        // setParams still ACCEPTS this (the sum is unchanged, which is all the ratchet
        // constrains) -- but it no longer reaches swaps already in flight, because the whole
        // verdict tuple is frozen in the record.
        (,,, int256 thetaAfter,) = hook.previewSettle(0);
        assertEq(thetaAfter, int256(r.fTheta), "theta frozen");
        assertEq(uint256(hook.getSwap(0).fMaturity), 50, "maturity frozen at execution");
        assertEq(uint256(hook.getSwap(0).fWindow), 25, "window frozen at execution");
    }

    /// The consequence: the markout a swap is judged on must NOT change when the owner moves
    /// the window afterwards. Before the fix this asserted the opposite and passed.
    function test_R3_markout_a_swap_is_judged_on_is_fixed_at_execution() public {
        swapAs(USER, true, -25e18);
        driftPrice(true, 20, -30e18);
        advanceTo(pastWindow(0));
        (,, int256 markoutBefore,,) = hook.previewSettle(0);

        HindsightHook.HindsightParams memory p = _liveParams();
        p.maturityStamps = 200;
        p.graceStamps = uint16(uint256(3075) - p.maturityStamps - p.twapWindowStamps);
        hook.setParams(poolId, p);
        advanceTo(stampNow() + 400);

        (,, int256 markoutAfter,,) = hook.previewSettle(0);
        assertEq(markoutAfter, markoutBefore,
            "the markout must not depend on params set after the swap landed");
    }

    function _liveParams() internal pure returns (HindsightHook.HindsightParams memory) {
        return HindsightHook.HindsightParams({
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
        });
    }
}
