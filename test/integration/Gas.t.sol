// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./HindsightFixture.sol";
import {console2} from "forge-std/console2.sol";

contract GasProbe is HindsightFixture {
    /// Steady-state gas. Each figure is measured after warm-up so one-time costs (funding,
    /// cold storage, first-touch of the observation buffer) are not billed to it.
    function test_gas_numbers() public {
        fundTrader(address(0xBEEF));
        fundTrader(address(0xD41F7));

        // warm everything: one full swap + settle cycle before measuring
        uint256 warm = hook.nextSwapId();
        swapAs(address(0xBEEF), true, -1e15);
        advanceTo(pastWindow(warm));
        hook.settle(warm);

        // ── swap (router + hook, steady state) ──
        fb.increment();
        uint256 id = hook.nextSwapId();
        uint256 g0 = gasleft();
        swapAs(address(0xBEEF), true, -1e18);
        uint256 swapGas = g0 - gasleft();

        // ── settle: benign refund ──
        advanceTo(pastWindow(id));
        g0 = gasleft();
        hook.settle(id);
        uint256 settleRefundGas = g0 - gasleft();

        // ── settle: toxic forfeit (includes the donation drip) ──
        uint256 toxicId = hook.nextSwapId();
        swapAs(address(0xBEEF), true, -1e18);
        driftPrice(true, 20, -30e18);
        advanceTo(pastWindow(toxicId));
        g0 = gasleft();
        hook.settle(toxicId);
        uint256 settleForfeitGas = g0 - gasleft();

        // ── poke ──
        fb.increment();
        g0 = gasleft();
        hook.poke(key);
        uint256 pokeGas = g0 - gasleft();

        console2.log("swap (incl hook + test router):", swapGas);
        console2.log("settle refund:", settleRefundGas);
        console2.log("settle forfeit (+donate drip):", settleForfeitGas);
        console2.log("poke:", pokeGas);
    }
}
