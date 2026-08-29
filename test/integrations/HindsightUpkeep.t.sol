// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../integration/HindsightFixture.sol";
import {HindsightUpkeep} from "../../src/integrations/chainlink/HindsightUpkeep.sol";

contract HindsightUpkeepTest is HindsightFixture {
    HindsightUpkeep upkeep;
    address constant TRADER = address(0xBEEF);
    address constant FORWARDER_SETTLE = address(0xF0);
    address constant FORWARDER_FLUSH = address(0xF1);
    address constant FORWARDER_POKE = address(0xF2);

    function setUp() public override {
        super.setUp();
        upkeep = new HindsightUpkeep(hook, key);
        upkeep.setForwarder(0, FORWARDER_SETTLE);
        upkeep.setForwarder(1, FORWARDER_FLUSH);
        upkeep.setForwarder(2, FORWARDER_POKE);
    }

    function _check(uint8 mode) internal view returns (bool needed, bytes memory data) {
        return upkeep.checkUpkeep(abi.encode(mode));
    }

    // ── settle mode ────────────────────────────────────────────────────────────────
    function test_settle_not_needed_before_maturity() public {
        swapAs(TRADER, true, -1e17);
        (bool needed,) = _check(0);
        assertFalse(needed);
    }

    function test_settle_check_then_perform() public {
        swapAs(TRADER, true, -1e17);
        fb.increment();
        swapAs(TRADER, false, -1e17);
        advanceTo(pastWindow(1));

        (bool needed, bytes memory data) = _check(0);
        assertTrue(needed);
        (, uint256[] memory ids) = abi.decode(data, (uint8, uint256[]));
        assertEq(ids.length, 2);
        assertLe(data.length, 1000, "under Base Sepolia performData cap");

        vm.prank(FORWARDER_SETTLE);
        upkeep.performUpkeep(data);
        assertEq(hook.getSwap(0).status, 1);
        assertEq(hook.getSwap(1).status, 1);
        assertEq(upkeep.s_scanStart(), 2, "compaction advanced past settled prefix");
    }

    function test_perform_skips_raced_settles() public {
        swapAs(TRADER, true, -1e17);
        advanceTo(pastWindow(0));
        (, bytes memory data) = _check(0);
        hook.settle(0); // race: someone settles manually between check and perform
        vm.prank(FORWARDER_SETTLE);
        upkeep.performUpkeep(data); // must not revert
        assertEq(hook.getSwap(0).status, 1);
    }

    function test_perform_gated_to_forwarder() public {
        swapAs(TRADER, true, -1e17);
        advanceTo(pastWindow(0));
        (, bytes memory data) = _check(0);
        vm.expectRevert(HindsightUpkeep.NotForwarder.selector);
        vm.prank(address(0xBAD));
        upkeep.performUpkeep(data);
        // wrong-mode forwarder is also rejected
        vm.expectRevert(HindsightUpkeep.NotForwarder.selector);
        vm.prank(FORWARDER_FLUSH);
        upkeep.performUpkeep(data);
    }

    // ── flush mode ─────────────────────────────────────────────────────────────────
    function test_flush_needed_only_with_pot_and_epoch() public {
        (bool needed,) = _check(1);
        assertFalse(needed, "no pot yet");

        // create a forfeit → pot
        uint256 id = hook.nextSwapId();
        swapAs(TRADER, true, -1e18);
        driftPrice(true, 20, -30e18);
        advanceTo(pastWindow(id));
        hook.settle(id);

        advanceTo(stampNow() + 51); // past epoch
        (bool needed2, bytes memory data) = _check(1);
        assertTrue(needed2);
        vm.prank(FORWARDER_FLUSH);
        upkeep.performUpkeep(data); // drips
    }

    // ── poke mode ──────────────────────────────────────────────────────────────────
    function test_poke_needed_when_window_open_and_stale() public {
        swapAs(TRADER, true, -1e17);
        fb.increment(); // clock moved, no new observation, swap pending
        (bool needed, bytes memory data) = _check(2);
        assertTrue(needed);
        vm.prank(FORWARDER_POKE);
        upkeep.performUpkeep(data);
        (bool neededAfter,) = _check(2);
        assertFalse(neededAfter, "fresh observation written");
    }

    function test_poke_not_needed_without_pending_swaps() public {
        fb.increment();
        (bool needed,) = _check(2);
        assertFalse(needed);
    }
}
