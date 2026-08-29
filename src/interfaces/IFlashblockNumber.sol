// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Interface for Uniswap's FlashblockNumber contract (github.com/Uniswap/flashblocks_number_contract).
/// @dev The counter is MONOTONIC and does NOT reset per L2 block. Allowlisted builders increment it once
///      per flashblock (~200ms on Unichain). Official proxies:
///      Unichain mainnet (130):  0x3c3a8a41e095c76b03f79f70955fff3b03cf753e
///      Unichain Sepolia (1301): 0x056466f1a50a6b5e4dccf106074ee0083d721a42
interface IFlashblockNumber {
    function getFlashblockNumber() external view returns (uint256);
}
