// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IeETH - Interface for eETH (Elastic Ethereum) token
/// @notice This interface defines functions for interacting with the eETH token.
interface IeETH {
    /// @notice Get the name of the token
    /// @return The name of the token
    function name() external pure returns (string memory);

    /// @notice Get the symbol of the token
    /// @return The symbol of the token
    function symbol() external pure returns (string memory);

    /// @notice Get the number of decimals used by the token
    /// @return The number of decimals
    function decimals() external pure returns (uint8);

    /// @notice Get the total number of shares of eETH
    /// @return The total number of shares
    function totalShares() external view returns (uint256);

    /// @notice Get the number of shares owned by a specific user
    /// @param _user The address of the user
    /// @return The number of shares owned by the user
    function shares(address _user) external view returns (uint256);

    /// @notice Get the balance of eETH tokens for a specific user
    /// @param _user The address of the user
    /// @return The balance of eETH tokens
    function balanceOf(address _user) external view returns (uint256);

    /// @notice Initialize the eETH token with the liquidity pool address
    /// @param _liquidityPool The address of the liquidity pool
    function initialize(address _liquidityPool) external;

    /// @notice Mint eETH shares for a specific user
    /// @param _user The address of the user
    /// @param _share The number of shares to mint
    function mintShares(address _user, uint256 _share) external;

    /// @notice Burn eETH shares for a specific user
    /// @param _user The address of the user
    /// @param _share The number of shares to burn
    function burnShares(address _user, uint256 _share) external;

    /// @notice Transfer eETH tokens from one address to another
    /// @param _sender The address of the sender
    /// @param _recipient The address of the recipient
    /// @param _amount The amount of eETH tokens to transfer
    /// @return True if the transfer was successful, otherwise false
    function transferFrom(address _sender, address _recipient, uint256 _amount) external returns (bool);

    /// @notice Transfer eETH tokens to a specific recipient
    /// @param _recipient The address of the recipient
    /// @param _amount The amount of eETH tokens to transfer
    /// @return True if the transfer was successful, otherwise false
    function transfer(address _recipient, uint256 _amount) external returns (bool);

    /// @notice Approve another address to spend eETH tokens on behalf of the sender
    /// @param _spender The address allowed to spend the tokens
    /// @param _amount The maximum amount of tokens the spender is allowed to spend
    /// @return True if the approval was successful, otherwise false
    function approve(address _spender, uint256 _amount) external returns (bool);

    /// @notice Increase the allowance for a spender
    /// @param _spender The address allowed to spend the tokens
    /// @param _increaseAmount The additional amount of tokens to allow spending
    /// @return True if the increase was successful, otherwise false
    function increaseAllowance(address _spender, uint256 _increaseAmount) external returns (bool);

    /// @notice Decrease the allowance for a spender
    /// @param _spender The address allowed to spend the tokens
    /// @param _decreaseAmount The amount of tokens to reduce from the allowance
    /// @return True if the decrease was successful, otherwise false
    function decreaseAllowance(address _spender, uint256 _decreaseAmount) external returns (bool);

    /// @notice Permit spending of eETH tokens by another address
    /// @param owner The owner of the tokens
    /// @param spender The address allowed to spend the tokens
    /// @param value The amount of tokens allowed to be spent
    /// @param deadline The deadline by which the permit is valid
    /// @param v The recovery byte of the signature
    /// @param r The R part of the signature
    /// @param s The S part of the signature
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
