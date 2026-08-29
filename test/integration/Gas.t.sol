// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./HindsightFixture.sol";
import {console2} from "forge-std/console2.sol";

contract GasProbe is HindsightFixture {
    function test_gas_numbers() public {
        // baseline-ish: swap gas WITH the hook attached
        uint256 g0 = gasleft();
        swapAs(address(0xBEEF), true, -1e18);
        uint256 swapGas = g0 - gasleft();

        advanceTo(pastWindow(0));
        g0 = gasleft();
        hook.settle(0);
        uint256 settleRefundGas = g0 - gasleft();

        // forfeit path
        uint256 id = hook.nextSwapId();
        swapAs(address(0xBEEF), true, -1e18);
        driftPrice(true, 20, -30e18);
        advanceTo(pastWindow(id));
        g0 = gasleft();
        hook.settle(id);
        uint256 settleForfeitGas = g0 - gasleft();

        g0 = gasleft();
        hook.poke(key);
        uint256 pokeGas = g0 - gasleft();

        console2.log("swap (incl hook + router):", swapGas);
        console2.log("settle refund:", settleRefundGas);
        console2.log("settle forfeit (+donate flush):", settleForfeitGas);
        console2.log("poke:", pokeGas);
    }
}
