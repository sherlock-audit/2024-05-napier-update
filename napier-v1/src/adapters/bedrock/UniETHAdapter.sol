// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

// interfaces
import {IERC20, SafeERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/utils/SafeERC20.sol";
import {IWETH9} from "../../interfaces/IWETH9.sol";
import {IStaking} from "./interfaces/IStaking.sol";
import {IRedeem} from "./interfaces/IRedeem.sol";
import {UniETHSwapper} from "./UniETHSwapper.sol";

// libs
import {SafeCast} from "@openzeppelin/contracts@4.9.3/utils/math/SafeCast.sol";
import "../../Constants.sol" as Constants;

import {ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import {BaseLSTAdapter} from "../BaseLSTAdapter.sol";

/// @notice UniETHAdapter - euniETH (Napier uniETH Adapter)
/// @dev uniETH is a Bedrock staking token that represents ETH staked in Bedrock.
/// @dev This contract doesn't independently keep track of the uniETHn balance, so it is possible
/// for an attacker to directly transfer uniETH to this contract, increase the share price.
/// @dev This adapter supports only one withdrawal request at a time.
/// Bedrock doesn't track how much ETH is claimable per requestId.
/// So, we can't know a requestId has been redeemed for how much ETH and claim function claims all claimable ETH
/// regardless of requestId.
/// For this reason, this adapter doesn't support multiple withdrawal requests.
contract UniETHAdapter is BaseLSTAdapter {
    using SafeCast for uint256;

    /// @notice uniETH
    IERC20 constant UNIETH = IERC20(Constants.UNIETH);

    /// @notice Bedrock staking contract
    IStaking constant BEDROCK_STAKING = IStaking(Constants.BEDROCK_STAKING);

    /// @notice Periphery contract for uniETH/WETH swaps
    UniETHSwapper public swapper;

    error RequestInQueue();
    error OnlyWETHOrBedrock();
    error SwapAmountTooLarge();
    error TransactionTooOld();
    error RequestNotFinalized();
    error InvariantViolation();

    receive() external payable {
        if (
            msg.sender != Constants.WETH &&
            msg.sender != address(BEDROCK_STAKING) &&
            msg.sender != BEDROCK_STAKING.redeemContract()
        ) {
            revert OnlyWETHOrBedrock();
        }
    }

    constructor(
        address _owner,
        address _rebalancer,
        uint256 _maxStakeLimit,
        uint256 _stakeLimitIncreasePerBlock,
        address _swapper
    )
        ERC20("Napier uniETH Adapter", "euniETH")
        BaseLSTAdapter(_rebalancer, _maxStakeLimit, _stakeLimitIncreasePerBlock)
    {
        swapper = UniETHSwapper(_swapper);
        _transferOwnership(_owner);

        UNIETH.approve(address(BEDROCK_STAKING), type(uint256).max);
    }

    /// @dev No cap on the amount of staking.
    function _stake(uint256 stakeAmount) internal override returns (uint256) {
        if (stakeAmount == 0) return 0;

        IWETH9(Constants.WETH).withdraw(stakeAmount);
        uint256 _balance = UNIETH.balanceOf(address(this));
        BEDROCK_STAKING.mint{value: stakeAmount}({minToMint: 0, deadline: block.timestamp + 1});
        uint256 minted = UNIETH.balanceOf(address(this)) - _balance;
        if (minted == 0) revert InvariantViolation();

        return stakeAmount;
    }

    ///////////////////////////////////////////////////////////////////////////
    // Rebalancer functions
    ///////////////////////////////////////////////////////////////////////////

    /// @notice Claim all claimable ETH
    /// @dev Ensure requestId has been already finizalized before calling this function.
    function claimWithdrawal(uint256 _requestId) external override nonReentrant onlyRebalancer {
        // Check whether the request is from this adapter.
        if (queueWithdrawal[_requestId] == 0) revert NoPendingWithdrawal(); // Request is not from this adapter, not exist or already claimed

        // Bedrock doesn't support claiming ETH per requestId.
        // Someone can donate ETH with `redeemContract:pay` and add claimable ETH.
        // So, here make sure that the debt has been deleted from the queue.
        (, uint256 debt) = BEDROCK_STAKING.checkDebt(_requestId);
        if (debt > 0) revert RequestNotFinalized(); // Not finalized yet

        /// INTERACT ///
        uint256 claimable = IRedeem(BEDROCK_STAKING.redeemContract()).balanceOf(address(this)); // donation + unstaked ETH
        uint256 balanceBefore = address(this).balance;
        IRedeem(BEDROCK_STAKING.redeemContract()).claim(claimable);
        uint256 claimed = address(this).balance - balanceBefore;

        /// WRITE ///
        delete queueWithdrawal[_requestId];
        delete totalQueueEth;
        bufferEth += claimed.toUint128();

        IWETH9(Constants.WETH).deposit{value: claimed}();
        emit ClaimWithdrawal(_requestId, claimed);
    }

    /// @dev Escape hatch
    /// @param withdrawAmount Amount of ETH to withdraw in multiples of 32 ETH
    /// @param deadline Deadline for the withdrawal
    function requestWithdrawal(uint256 withdrawAmount, uint256 deadline) external nonReentrant onlyRebalancer {
        if (block.timestamp > deadline) revert TransactionTooOld();
        (uint256 queuedEth, uint256 _requestId) = _requestWithdrawal(withdrawAmount);
        if (queueWithdrawal[_requestId] != 0) revert WithdrawalPending();
        /// WRITE ///
        totalQueueEth += queuedEth.toUint128();
        queueWithdrawal[_requestId] = queuedEth;
    }

    function requestWithdrawalAll() external override nonReentrant onlyRebalancer {
        /// INTERACT ///
        uint256 balance = UNIETH.balanceOf(address(this));
        uint256 withdrawAmount = (BEDROCK_STAKING.exchangeRatio() * balance) / 1e18;

        (uint256 queuedEth, uint256 _requestId) = _requestWithdrawal(withdrawAmount);
        if (queueWithdrawal[_requestId] != 0) revert WithdrawalPending();
        /// WRITE ///
        totalQueueEth += queuedEth.toUint128();
        queueWithdrawal[_requestId] = queuedEth;
    }

    /// @dev No cap on withdrawal
    function _requestWithdrawal(uint256 withdrawAmount) internal override returns (uint256, uint256) {
        // Check whether adapter has any pending request. Only one request is allowed at a time.
        if (totalQueueEth > 0) revert RequestInQueue();

        // They can only allow withdrawal in multiples of 32 eth
        withdrawAmount -= (withdrawAmount % 32 ether);
        if (withdrawAmount == 0) revert InvalidWithdrawalAmount();
        /// INTERACT ///
        // Bedrock burns some uniETH from the balance of this adapter and tracks the debt.
        (, uint256 requestId) = BEDROCK_STAKING.getDebtQueue();
        requestId++; // Next debt index
        uint256 debtPrior = BEDROCK_STAKING.debtOf(address(this));
        BEDROCK_STAKING.redeemFromValidators({
            ethersToRedeem: withdrawAmount,
            maxToBurn: type(uint256).max,
            deadline: block.timestamp + 1
        });
        if (BEDROCK_STAKING.debtOf(address(this)) != debtPrior + withdrawAmount) revert InvariantViolation();

        emit RequestWithdrawal(requestId, withdrawAmount);
        return (withdrawAmount, requestId);
    }

    /// @notice Withdraw ETH from Bedrock instantly through pending ETH in Bedrock staking contract
    /// @dev Revert if Bedrock staking contract doesn't have enough pending ETH worth of `uniEthAmount` uniETH.
    /// @param uniEthAmount Amount of uniETH to burn. Limited to pending ETH in Bedrock staking contract.
    function withdraw(uint256 uniEthAmount) external nonReentrant onlyRebalancer {
        /// INTERACT ///
        uint256 balanceBefore = address(this).balance;
        BEDROCK_STAKING.instantSwap(uniEthAmount);
        uint256 received = address(this).balance - balanceBefore;

        IWETH9(Constants.WETH).deposit{value: received}();

        /// WRITE ///
        bufferEth += received.toUint128();
    }

    /// @notice Swap uniETH for ETH
    /// @dev This function is only callable by the rebalancer
    /// @param amount Amount of ETH to swap
    /// @param deadline Deadline for the swap
    /// @param minEthOut Minimum amount of ETH to receive
    /// @param data Data for the swap
    function swapUniETHForETH(
        uint256 amount,
        uint256 deadline,
        uint256 minEthOut,
        bytes calldata data
    ) external nonReentrant onlyRebalancer {
        if (amount >= 32 ether) revert SwapAmountTooLarge();

        /// INTERACT ///
        uint256 balanceBefore = IWETH9(Constants.WETH).balanceOf(address(this));
        SafeERC20.forceApprove(IERC20(Constants.UNIETH), address(swapper), amount + 1); // avoild storage value goes to 0
        swapper.swap(amount, deadline, minEthOut, data);
        uint256 received = IWETH9(Constants.WETH).balanceOf(address(this)) - balanceBefore;

        /// WRITE ///
        bufferEth += SafeCast.toUint128(received);
    }

    function totalAssets() public view override returns (uint256) {
        uint256 uniEthBalance = UNIETH.balanceOf(address(this));
        return totalQueueEth + bufferEth + (uniEthBalance * BEDROCK_STAKING.exchangeRatio()) / 1e18;
    }

    function setSwapper(address _swapper) external onlyOwner {
        swapper = UniETHSwapper(_swapper);
    }
}
