// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

/**
 * Taken from: https://github.com/balancer/balancer-v2-monorepo/blob/ac63d64018c6331248c7d77b9f317a06cced0243/pkg/vault/contracts/ProtocolFeesCollector.sol
 * @dev This an auxiliary contract to the Vault, deployed by it during construction. It offloads some of the tasks the
 * Vault performs to reduce its overall bytecode size.
 *
 * The current values for all protocol fee percentages are stored here, and any tokens charged as protocol fees are
 * sent to this contract, where they may be withdrawn by authorized entities. All authorization tasks are delegated
 * to the Vault's own authorizer.
 */
interface IProtocolFeesCollector {
    function getFlashLoanFeePercentage() external view returns (uint256);
}
