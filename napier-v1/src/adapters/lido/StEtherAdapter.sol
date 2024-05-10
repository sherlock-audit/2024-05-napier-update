// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

import {IWETH9} from "../../interfaces/IWETH9.sol";
import {IStETH} from "./interfaces/IStETH.sol";
import {IWithdrawalQueueERC721} from "./interfaces/IWithdrawalQueueERC721.sol";

import {SafeCast} from "@openzeppelin/contracts@4.9.3/utils/math/SafeCast.sol";
import "../../Constants.sol" as Constants;

import {ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import {BaseLSTAdapter} from "../BaseLSTAdapter.sol";

/// @title StETHAdapter - estETH
/// @dev Important security note:
/// 1. The vault share price (estETH / WETH) increases as stETH accrues staking rewards.
/// StETH withdrawals are processed by the Lido withdrawal queue contract.
/// While waiting for the stETH withdrawal request to be finalized, estETH holders don't receive
/// staking rewards from the pending stETH and still take risks during withdrawal.
///
/// 2. This contract doesn't independently keep track of the stETH balance, so it is possible
/// for an attacker to directly transfer stETH to this contract, increase the share price.
contract StEtherAdapter is BaseLSTAdapter {
    using SafeCast for uint256;

    error InvariantViolation();
    error WithdrawalBelowMinimum();

    /// @notice stETH
    IStETH constant STETH = IStETH(Constants.STETH);

    /// @dev Lido WithdrawalQueueERC721
    IWithdrawalQueueERC721 constant LIDO_WITHDRAWAL_QUEUE = IWithdrawalQueueERC721(Constants.LIDO_WITHDRAWAL_QUEUE);

    receive() external payable {}

    constructor(
        address _rebalancer,
        uint256 _maxStakeLimit,
        uint256 _stakeLimitIncreasePerBlock
    ) BaseLSTAdapter(_rebalancer, _maxStakeLimit, _stakeLimitIncreasePerBlock) ERC20("Napier StETH Adapter", "eStETH") {
        STETH.approve(address(LIDO_WITHDRAWAL_QUEUE), type(uint256).max);
    }

    /// @notice Claim withdrawal from Lido
    /// @dev Reverts if there is no pending withdrawal
    /// @dev Reverts if the withdrawal request has not been finalized yet by Lido
    /// @dev note estETH scale may be decreased if Lido has been slashed by misbehavior.
    function claimWithdrawal(uint256 _requestId) external override nonReentrant {
        if (queueWithdrawal[_requestId] == 0) revert NoPendingWithdrawal();

        /// INTERACT ///
        // Claimed amount can be less than requested amount due to slashing.
        uint256 balanceBefore = address(this).balance;
        LIDO_WITHDRAWAL_QUEUE.claimWithdrawal(_requestId);
        uint256 claimed = address(this).balance - balanceBefore;

        /// WRITE ///
        totalQueueEth -= queueWithdrawal[_requestId].toUint128();
        delete queueWithdrawal[_requestId];
        bufferEth += claimed.toUint128();

        IWETH9(Constants.WETH).deposit{value: claimed}();
        emit ClaimWithdrawal(_requestId, claimed);
    }

    /// @dev Lido has a limit on the amount of ETH that can be staked.
    /// @dev Need to check the current staking limit before staking to prevent DoS.
    function _stake(uint256 stakeAmount) internal override returns (uint256) {
        if (stakeAmount == 0) return 0;

        uint256 stakeLimit = STETH.getCurrentStakeLimit();
        if (stakeAmount > stakeLimit) {
            // Cap stake amount
            stakeAmount = stakeLimit;
        }

        IWETH9(Constants.WETH).withdraw(stakeAmount);
        uint256 _stETHAmt = STETH.submit{value: stakeAmount}(address(this));

        if (_stETHAmt == 0) revert InvariantViolation();
        return stakeAmount;
    }

    /// @inheritdoc BaseLSTAdapter
    /// @dev Lido has a limit on the amount of ETH that can be unstaked.
    function requestWithdrawalAll() external override nonReentrant onlyRebalancer {
        /// INTERACT ///
        (uint256 queuedEth, uint256 _requestId) = _requestWithdrawal(STETH.balanceOf(address(this)));
        if (queueWithdrawal[_requestId] != 0) revert WithdrawalPending();
        /// WRITE ///
        totalQueueEth += queuedEth.toUint128();
        queueWithdrawal[_requestId] = queuedEth;
    }

    /// @dev note stETH holders don't receive rewards but still take risks during withdrawal.
    function _requestWithdrawal(uint256 withdrawAmount) internal override returns (uint256, uint256) {
        // Validate withdrawAmount - https://docs.lido.fi/contracts/withdrawal-queue-erc721/#request
        // The minimal amount for a request is 100 wei, and the maximum is 1000 eth
        if (withdrawAmount < LIDO_WITHDRAWAL_QUEUE.MIN_STETH_WITHDRAWAL_AMOUNT()) revert WithdrawalBelowMinimum();
        uint256 halfWithdrawalLimit = LIDO_WITHDRAWAL_QUEUE.MAX_STETH_WITHDRAWAL_AMOUNT() / 2;
        if (withdrawAmount > halfWithdrawalLimit) withdrawAmount = halfWithdrawalLimit; // half of the maximum

        // stETH amount
        uint256[] memory _amounts = new uint256[](1);

        /// INTERACT ///
        // The amount of ether that will be withdrawn is limited to
        // the number of stETH tokens transferred to this contract at the moment of request.
        // So, we will not receive the rewards for the period of time while these tokens stay in the queue.
        _amounts[0] = withdrawAmount;
        uint256[] memory _requestIds = LIDO_WITHDRAWAL_QUEUE.requestWithdrawals(_amounts, address(this)); // Dev: Ensure id is not 0
        if (_requestIds[0] == 0) revert InvariantViolation();
        emit RequestWithdrawal(_requestIds[0], withdrawAmount);
        /// WRITE ///
        return (withdrawAmount, _requestIds[0]);
    }

    function totalAssets() public view override returns (uint256) {
        uint256 stEthBalance = STETH.balanceOf(address(this));
        return totalQueueEth + bufferEth + stEthBalance;
    }
}
