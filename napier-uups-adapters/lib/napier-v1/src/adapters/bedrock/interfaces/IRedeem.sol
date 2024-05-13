// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

interface IRedeem {
    /// @notice Claim unstaked ETH
    function claim(uint256 amount) external returns (bool success);

    /**
     * @dev pay debts from rockx staking contract
     */
    function pay(address account) external payable;

    /// @notice Get claimable ETH amount for an account
    function balanceOf(address account) external view returns (uint256);
}
