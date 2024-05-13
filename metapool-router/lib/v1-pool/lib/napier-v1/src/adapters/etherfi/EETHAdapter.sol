// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

import {IERC721Receiver} from "@openzeppelin/contracts@4.9.3/token/ERC721/IERC721Receiver.sol";
import {SafeCast} from "@openzeppelin/contracts@4.9.3/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";

import {IWithdrawRequestNFT} from "./interfaces/IWithdrawRequestNFT.sol";
import {ILiquidityPool} from "./interfaces/ILiquidityPool.sol";
import {IWETH9} from "../../interfaces/IWETH9.sol";
import {IeETH} from "./interfaces/IeETH.sol";

import "../../Constants.sol" as Constants;

import {BaseLSTAdapter} from "../BaseLSTAdapter.sol";

/// @title EEtherAdapter - eeETH
/// @dev Important security note:
/// 1. The staking rewards are distributed to the eETH holders by the rebasing mechanism
/// where its balance is updated automatically on all the addresses.
/// The rebase mechanism is implemented via shares where the share represents the eETH holder's
/// share in the total amount of ether controlled by the ether.fi protocol.
///
/// 2. This contract doesn't independently keep track of the eETH balance, so it is possible
/// for an attacker to directly transfer eETH to this contract, increase the share price.
contract EEtherAdapter is BaseLSTAdapter, IERC721Receiver {
    using SafeCast for uint256;

    error InvariantViolation();
    error RequestInQueue();
    error WithdrawalBelowMinimum();

    /// @notice eETH
    IeETH constant EETH = IeETH(Constants.EETH);

    /// @dev EtherFi WithdrawRequestNFT
    IWithdrawRequestNFT constant ETHERFI_WITHDRAW_NFT = IWithdrawRequestNFT(Constants.ETHERFI_WITHDRAW_REQUEST);

    /// @dev EtherFi LiquidityPool
    ILiquidityPool constant LIQUIDITY_POOL = ILiquidityPool(Constants.ETHERFI_LP);

    receive() external payable {}

    constructor(
        address _rebalancer,
        uint256 _maxStakeLimit,
        uint256 _stakeLimitIncreasePerBlock
    ) BaseLSTAdapter(_rebalancer, _maxStakeLimit, _stakeLimitIncreasePerBlock) ERC20("Napier EETH Adapter", "eeETH") {
        EETH.approve(address(LIQUIDITY_POOL), type(uint256).max);
    }

    /// @notice Claim withdrawal from etherfi
    /// @dev Reverts if there is no pending withdrawal
    /// @dev Reverts if the withdrawal request is in queue by etherfi
    /// @dev note eeETH scale may be decreased as etherfi has the withdrawal fee.
    function claimWithdrawal(uint256 _requestId) external override nonReentrant {
        if (queueWithdrawal[_requestId] == 0) revert NoPendingWithdrawal();

        /// ASSERT ///
        // EtherFi is completing withdraws internally and its number is set to lastFinalizedRequestId.
        // If _requstId is finalized on etherfi, it's reverted.
        if (_requestId < ETHERFI_WITHDRAW_NFT.lastFinalizedRequestId()) revert RequestInQueue();

        /// INTERACT ///
        // Claimed amount can be less than requested amount due to slashing.
        uint256 balanceBefore = address(this).balance;
        ETHERFI_WITHDRAW_NFT.claimWithdraw(_requestId);
        uint256 claimed = address(this).balance - balanceBefore;
        /// WRITE ///
        totalQueueEth -= queueWithdrawal[_requestId].toUint128();
        delete queueWithdrawal[_requestId];

        /// WRITE ///
        bufferEth += claimed.toUint128();

        IWETH9(Constants.WETH).deposit{value: claimed}();
        emit ClaimWithdrawal(_requestId, claimed);
    }

    /// @notice Stake ether to etherfi liquidity pool
    /// @dev EtherFi doesn't have stake limit.
    function _stake(uint256 stakeAmount) internal override returns (uint256) {
        if (stakeAmount == 0) return 0;

        IWETH9(Constants.WETH).withdraw(stakeAmount);
        uint256 _eETHAmt = LIQUIDITY_POOL.deposit{value: stakeAmount}();

        if (_eETHAmt == 0) revert InvariantViolation();
        return stakeAmount;
    }

    /// @inheritdoc BaseLSTAdapter
    function requestWithdrawalAll() external override nonReentrant onlyRebalancer {
        /// INTERACT ///
        (uint256 queuedEth, uint256 _requestId) = _requestWithdrawal(EETH.balanceOf(address(this)));
        if (queueWithdrawal[_requestId] != 0) revert WithdrawalPending();
        /// WRITE ///
        totalQueueEth += queuedEth.toUint128();
        queueWithdrawal[_requestId] = queuedEth;
    }

    /// @notice Request withdrawal for custom amount
    function requestWithdrawal(uint256 withdrawAmount) external nonReentrant onlyRebalancer {
        if (withdrawAmount > EETH.balanceOf(address(this))) revert InvalidWithdrawalAmount();
        /// INTERACT ///
        (uint256 queuedEth, uint256 _requestId) = _requestWithdrawal(withdrawAmount);
        if (queueWithdrawal[_requestId] != 0) revert WithdrawalPending();
        /// WRITE ///
        totalQueueEth += queuedEth.toUint128();
        queueWithdrawal[_requestId] = queuedEth;
    }

    /// @inheritdoc BaseLSTAdapter
    function _requestWithdrawal(uint256 withdrawAmount) internal override returns (uint256, uint256) {
        // The max amount for a request is 500 ether to chunk the large withdrawals into smaller ones.
        if (withdrawAmount < 100) revert WithdrawalBelowMinimum();
        if (withdrawAmount > 500 ether) withdrawAmount = 500 ether;

        /// INTERACT ///
        // The amount of ether that will be withdrawn is limited to
        // the number of eETH tokens transferred to this contract at the moment of request.
        // So, we will not receive the rewards for the period of time while these tokens stay in the queue.
        uint256 _requestId = LIQUIDITY_POOL.requestWithdraw(address(this), withdrawAmount); // Dev: Ensure id is not 0
        if (_requestId == 0) revert InvariantViolation();

        /// WRITE ///
        emit RequestWithdrawal(_requestId, withdrawAmount);
        return (withdrawAmount, _requestId);
    }

    function totalAssets() public view override returns (uint256) {
        uint256 eEthBalance = EETH.balanceOf(address(this));
        return totalQueueEth + bufferEth + eEthBalance;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return 0x150b7a02; // bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))
    }
}
