// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

interface ILRTDepositPool {
    function depositAsset(
        address asset,
        uint256 depositAmount,
        uint256 minRSETHAmountExpected,
        string calldata referralId
    ) external;

    function depositETH(uint256 minRSETHAmountExpected, string calldata referralId) external payable;

    function getTotalAssetDeposits(address asset) external view returns (uint256);

    function getRsETHAmountToMint(address asset, uint256 depositAmount) external view returns (uint256);

    function getAssetCurrentLimit(address asset) external view returns (uint256);

    function minAmountToDeposit() external view returns (uint256);

    function paused() external view returns (bool);
}
