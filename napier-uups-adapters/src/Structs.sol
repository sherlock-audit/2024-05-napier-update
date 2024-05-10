// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

import {StakeLimitTypes} from "@napier/v1-tranche/utils/StakeLimitUtils.sol";

/// @custom:storage-location erc7201:napier.adapter.lst
struct LSTAdapterStorage {
    /// @notice Rebalancer of the ETH buffer, can be set by the owner
    /// @notice The account can request a withdrawal
    address rebalancer;
    /// @notice Desired buffer percentage in WAD
    uint256 targetBufferPercentage;
    /// @notice Tranche contract for restricting access to prefundedDeposit and prefundedRedeem
    address tranche;
    /// @notice Total of ETH pending withdrawal request
    uint128 totalQueueEth;
    /// @notice Amount of ETH available (Buffer), does not include pending withdrawal. Internal accounting of ETH
    uint128 bufferEth;
    /// @notice Mapping of the withdrawal request ID to the amount of ETH
    mapping(uint256 requestId => uint256 queueEth) queueWithdrawal;
    /// @notice Packed data for the stake limit state
    StakeLimitTypes.Uint256Data packedStakeLimitData;
}
