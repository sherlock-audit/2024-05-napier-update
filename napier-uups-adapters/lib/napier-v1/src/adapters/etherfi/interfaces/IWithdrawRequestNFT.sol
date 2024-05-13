// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title IWithdrawRequestNFT - Interface for managing withdrawal requests as NFTs
/// @notice This interface defines functions for managing withdrawal requests represented as NFTs.
interface IWithdrawRequestNFT {
    /// @notice Struct representing a withdrawal request
    struct WithdrawRequest {
        uint96 amountOfEEth; // Amount of EEth requested for withdrawal
        uint96 shareOfEEth; // Share of EEth associated with the withdrawal request
        bool isValid; // Indicates if the withdrawal request is valid
        uint32 feeGwei; // Fee in Gwei associated with the withdrawal request
    }

    /// @notice Initialize the contract with necessary addresses
    /// @param _liquidityPoolAddress The address of the liquidity pool
    /// @param _eEthAddress The address of the EEth token contract
    /// @param _membershipManager The address of the membership manager contract
    function initialize(address _liquidityPoolAddress, address _eEthAddress, address _membershipManager) external;

    /// @notice Submit a request for withdrawal
    /// @param amountOfEEth The amount of EEth requested for withdrawal
    /// @param shareOfEEth The share of EEth associated with the withdrawal request
    /// @param requester The address of the requester
    /// @param fee The fee amount to be paid
    /// @return The request ID
    function requestWithdraw(
        uint96 amountOfEEth,
        uint96 shareOfEEth,
        address requester,
        uint256 fee
    ) external payable returns (uint256);

    /// @notice Claim a withdrawal request
    /// @param requestId The ID of the withdrawal request
    function claimWithdraw(uint256 requestId) external;

    /// @notice Get details of a withdrawal request
    /// @param requestId The ID of the withdrawal request
    /// @return WithdrawRequest struct containing details of the request
    function getRequest(uint256 requestId) external view returns (WithdrawRequest memory);

    /// @notice Check if a withdrawal request is finalized
    /// @param requestId The ID of the withdrawal request
    /// @return True if the request is finalized, otherwise false
    function isFinalized(uint256 requestId) external view returns (bool);

    /// @notice Invalidate a withdrawal request
    /// @param requestId The ID of the withdrawal request to invalidate
    function invalidateRequest(uint256 requestId) external;

    /// @notice Finalize withdrawal requests up to a specified upper bound
    /// @param upperBound The upper bound of withdrawal requests to finalize
    function finalizeRequests(uint256 upperBound) external;

    /// @notice Update the admin status of an address
    /// @param _address The address to update
    /// @param _isAdmin The admin status to set
    function updateAdmin(address _address, bool _isAdmin) external;

    /// @notice Get the ID of the last finalized withdrawal request
    /// @return The ID of the last finalized withdrawal request
    function lastFinalizedRequestId() external view returns (uint32);
}
