// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title ILiquidityPool - Interface for liquidity pool operations
/// @notice This interface defines functions for interacting with a liquidity pool.
interface ILiquidityPool {
    /// @notice Deposit ETH into the liquidity pool
    /// @return The amount of liquidity tokens minted
    function deposit() external payable returns (uint256);

    /// @notice Deposit ETH into the liquidity pool with a referral address
    /// @param _referral The address of the referral
    /// @return The amount of liquidity tokens minted
    function deposit(address _referral) external payable returns (uint256);

    /// @notice Deposit ETH into the liquidity pool for a specific user with a referral address
    /// @param _user The address of the user
    /// @param _referral The address of the referral
    /// @return The amount of liquidity tokens minted
    function deposit(address _user, address _referral) external payable returns (uint256);

    /// @notice Deposit ETH into the liquidity pool and transfer liquidity tokens to a specific recipient
    /// @param _recipient The address of the recipient
    /// @param _amount The amount of ETH to deposit
    /// @param _referral The address of the referral
    /// @return The amount of liquidity tokens minted
    function depositToRecipient(address _recipient, uint256 _amount, address _referral) external returns (uint256);

    /// @notice Withdraw liquidity tokens from the liquidity pool and transfer ETH to a specific recipient
    /// @param _recipient The address of the recipient
    /// @param _amount The amount of liquidity tokens to withdraw
    /// @return The amount of ETH withdrawn
    function withdraw(address _recipient, uint256 _amount) external returns (uint256);

    /// @notice Request withdrawal of liquidity tokens
    /// @param _recipient The address of the recipient
    /// @param _amount The amount of liquidity tokens to withdraw
    /// @return The amount of liquidity tokens requested to withdraw
    function requestWithdraw(address _recipient, uint256 _amount) external returns (uint256);

    /// @notice Request withdrawal of membership NFT along with a fee
    /// @param _recipient The address of the recipient
    /// @param _amount The amount of membership NFT to withdraw
    /// @param _fee The fee amount to be charged
    /// @return The amount of membership NFT requested to withdraw
    function requestMembershipNFTWithdraw(address _recipient, uint256 _amount, uint256 _fee) external returns (uint256);
}
