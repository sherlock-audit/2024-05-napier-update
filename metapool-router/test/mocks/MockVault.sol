// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import {IERC20, SafeERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/utils/SafeERC20.sol";

import {IVault} from "src/interfaces/external/balancer/IVault.sol";
import {IFlashLoanRecipient} from "src/interfaces/external/balancer/IFlashLoanRecipient.sol";
import {IProtocolFeesCollector} from "src/interfaces/external/balancer/IProtocolFeesCollector.sol";

import {Math} from "@openzeppelin/contracts@4.9.3/utils/math/Math.sol";
import "./BalancerErrors.sol";

/// @dev Forked from Balancer V2's `Fees` contract.
abstract contract Fees is IVault {
    using SafeERC20 for IERC20;

    uint256 public flashLoanFeePercentage;
    address public protocolFeesCollector;

    /**
     * @dev Returns the protocol fee amount to charge for a flash loan of `amount`.
     */
    function _calculateFlashLoanFeeAmount(uint256 amount) internal view returns (uint256) {
        // Fixed point multiplication introduces error: we round up, which means in certain scenarios the charged
        // percentage can be slightly higher than intended.
        uint256 percentage = flashLoanFeePercentage;
        return Math.mulDiv(amount, percentage, 1e18, Math.Rounding.Up);
    }

    function _payFeeAmount(IERC20 token, uint256 amount) internal {
        if (amount > 0) {
            token.safeTransfer(protocolFeesCollector, amount);
        }
    }

    function setFlashLoanFeePercentage(uint256 _flashLoanFeePercentage) external {
        flashLoanFeePercentage = _flashLoanFeePercentage;
    }
}

/**
 * @dev Forked from Balancer V2's `FlashLoans` contract.
 * @dev Handles Flash Loans through the Vault. Calls the `receiveFlashLoan` hook on the flash loan recipient
 * contract, which implements the `IFlashLoanRecipient` interface.
 */
abstract contract FlashLoans is Fees {
    using SafeERC20 for IERC20;

    event FlashLoan(IFlashLoanRecipient indexed recipient, IERC20 indexed token, uint256 amount, uint256 feeAmount);

    function flashLoan(
        IFlashLoanRecipient recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external override {
        // InputHelpers.ensureInputLengthMatch(tokens.length, amounts.length);
        require(tokens.length == amounts.length, "Tokens and amounts length mismatch");

        uint256[] memory feeAmounts = new uint256[](tokens.length);
        uint256[] memory preLoanBalances = new uint256[](tokens.length);

        // Used to ensure `tokens` is sorted in ascending order, which ensures token uniqueness.
        IERC20 previousToken = IERC20(address(0));

        for (uint256 i = 0; i < tokens.length; ++i) {
            IERC20 token = tokens[i];
            uint256 amount = amounts[i];

            _require(token > previousToken, token == IERC20(address(0)) ? Errors.ZERO_TOKEN : Errors.UNSORTED_TOKENS);
            previousToken = token;

            preLoanBalances[i] = token.balanceOf(address(this));
            feeAmounts[i] = _calculateFlashLoanFeeAmount(amount);

            _require(preLoanBalances[i] >= amount, Errors.INSUFFICIENT_FLASH_LOAN_BALANCE);
            token.safeTransfer(address(recipient), amount);
        }

        recipient.receiveFlashLoan(tokens, amounts, feeAmounts, userData);

        for (uint256 i = 0; i < tokens.length; ++i) {
            IERC20 token = tokens[i];
            uint256 preLoanBalance = preLoanBalances[i];

            // Checking for loan repayment first (without accounting for fees) makes for simpler debugging, and results
            // in more accurate revert reasons if the flash loan protocol fee percentage is zero.
            uint256 postLoanBalance = token.balanceOf(address(this));
            _require(postLoanBalance >= preLoanBalance, Errors.INVALID_POST_LOAN_BALANCE);

            // No need for checked arithmetic since we know the loan was fully repaid.
            uint256 receivedFeeAmount = postLoanBalance - preLoanBalance;
            _require(receivedFeeAmount >= feeAmounts[i], Errors.INSUFFICIENT_FLASH_LOAN_FEE_AMOUNT);

            _payFeeAmount(token, receivedFeeAmount);
            emit FlashLoan(recipient, token, amounts[i], receivedFeeAmount);
        }
    }
}

/// @title MockVault
/// @dev A mock Balancer.fi Vault contract for testing purposes.
contract MockVault is FlashLoans {
    constructor(address _protocolFeesCollector, uint256 _flashLoanFeePercentage) {
        protocolFeesCollector = _protocolFeesCollector;
        flashLoanFeePercentage = _flashLoanFeePercentage;
    }

    function getProtocolFeesCollector() external view returns (IProtocolFeesCollector) {
        return IProtocolFeesCollector(protocolFeesCollector);
    }
}
