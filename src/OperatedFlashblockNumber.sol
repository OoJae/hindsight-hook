// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFlashblockNumber} from "./interfaces/IFlashblockNumber.sol";

/// @notice Testnet stand-in for Uniswap's official FlashblockNumber contract, mirroring
///         the V1 pattern: an owner-managed allowlist of "builder" addresses increments a
///         monotonic flashblock counter (~every 200ms). On Unichain mainnet the hook
///         would point at the official builder-maintained instance
///         (0x3c3a8a41e095c76b03f79f70955fff3b03cf753e); we operate this one on testnet
///         because the official Sepolia counter is builder-gated and may not tick.
contract OperatedFlashblockNumber is IFlashblockNumber {
    error NotOwner();
    error NotBuilder();
    error NotMonotonic();

    address public owner;
    mapping(address => bool) public builders;
    uint256 internal number;

    event FlashblockIncremented(uint256 number);
    event BuilderSet(address indexed builder, bool allowed);

    constructor(address _owner, address[] memory _builders) {
        owner = _owner;
        for (uint256 i; i < _builders.length; i++) {
            builders[_builders[i]] = true;
            emit BuilderSet(_builders[i], true);
        }
    }

    function getFlashblockNumber() external view returns (uint256) {
        return number;
    }

    function incrementFlashblockNumber() external {
        if (!builders[msg.sender]) revert NotBuilder();
        unchecked { ++number; }
        emit FlashblockIncremented(number);
    }

    /// @notice Batch catch-up for keepers that fell behind wall-clock flashblock cadence.
    function setFlashblockNumber(uint256 n) external {
        if (!builders[msg.sender]) revert NotBuilder();
        if (n <= number) revert NotMonotonic();
        number = n;
        emit FlashblockIncremented(n);
    }

    function setBuilder(address builder, bool allowed) external {
        if (msg.sender != owner) revert NotOwner();
        builders[builder] = allowed;
        emit BuilderSet(builder, allowed);
    }
}
