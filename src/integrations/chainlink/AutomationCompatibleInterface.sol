// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Vendored from @chainlink/contracts v1.5.0
///         (smartcontractkit/chainlink: contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol)
interface AutomationCompatibleInterface {
    /// @notice Simulated off-chain by every Automation node as an eth_call each block.
    function checkUpkeep(bytes calldata checkData)
        external
        returns (bool upkeepNeeded, bytes memory performData);

    /// @notice Executed on-chain by the upkeep's dedicated Forwarder when checkUpkeep
    ///         returns true.
    function performUpkeep(bytes calldata performData) external;
}
