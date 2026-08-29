// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFlashblockNumber} from "../interfaces/IFlashblockNumber.sol";

/// @notice Test/demo stand-in for the official FlashblockNumber contract.
contract MockFlashblockNumber is IFlashblockNumber {
    uint256 internal number;

    function getFlashblockNumber() external view returns (uint256) {
        return number;
    }

    function set(uint256 n) external {
        require(n >= number, "monotonic");
        number = n;
    }

    function increment() external {
        unchecked { ++number; }
    }
}
