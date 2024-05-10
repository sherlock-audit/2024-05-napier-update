// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

interface IStaking {
    /**
     * @dev mint xETH with ETH
     */
    function mint(uint256 minToMint, uint256 deadline) external payable returns (uint256 minted);

    /**
     * @dev redeem N * 32Ethers, which will turn off validadators,
     * note this function is asynchronous, the caller will only receive his ethers
     * after the validator has turned off.
     *
     * this function is dedicated for institutional operations.
     *
     * redeem keeps the ratio invariant
     */
    function redeemFromValidators(
        uint256 ethersToRedeem,
        uint256 maxToBurn,
        uint256 deadline
    ) external returns (uint256 burned);

    /**
     * @dev instant payment as much as possible from pending ethers at CURRENT exchangeRatio
     */
    function instantSwap(uint256 tokenAmount) external;

    /**
     * @dev preview instant payment at CURRENT exchangeRatio
     */
    function previewInstantSwap(uint256 tokenAmount) external view returns (uint256);

    /**
     * @dev return exchange ratio for 1 uniETH to ETH, multiplied by 1e18
     */
    function exchangeRatio() external view returns (uint256);

    /**
     * @dev return debt for an account
     * @dev After waiting for the validator to turn off, the debt will be paid off and users receive their ethers directly.
     */
    function debtOf(address account) external view returns (uint256);

    /**
     * @dev return debt queue index
     * @dev the first and last index of the debt queue at the moment
     */
    function getDebtQueue() external view returns (uint256 first, uint256 last);

    /**
     * @dev return debt of index
     */
    function checkDebt(uint256 index) external view returns (address account, uint256 amount);

    /**
     * @dev return the address of redeeming contract for user to pull ethers
     */
    function redeemContract() external view returns (address);
}
