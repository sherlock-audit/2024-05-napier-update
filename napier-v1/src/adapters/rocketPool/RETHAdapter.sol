// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

// interfaces
import {IWETH9} from "../../interfaces/IWETH9.sol";
import {IRocketStorage} from "./interfaces/IRocketStorage.sol";
import {IRocketDepositPool} from "./interfaces/IRocketDepositPool.sol";
import {IRocketDAOProtocolSettingsDeposit} from "./interfaces/IRocketDAOProtocolSettingsDeposit.sol";
import {IRocketTokenRETH as IRocketETH} from "./interfaces/IRocketTokenRETH.sol";

// libs
import {SafeCast} from "@openzeppelin/contracts@4.9.3/utils/math/SafeCast.sol";
import "../../Constants.sol" as Constants;

import {Swapper} from "./Swapper.sol";

import {ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts@4.9.3/security/ReentrancyGuard.sol";
import {BaseLSTVault} from "../BaseLSTVault.sol";

/// @notice RETHAdapter - erETH (Napier rETH Adapter)
/// @notice Rocket Pool allows users to unstake rETH instantly without waiting for the withdrawal queue up to a certain amount.
/// @dev This adapter doesn't use `withdrawalQueueEth` and `requestId` storage variables at all.
/// @dev `requestWithdrawal*` functions is not used at all because rETH doesn't have a withdrawal queue.
/// @dev important security note:
/// 1. The vault share price (erETH / WETH) increases as rETH accrues staking rewards.
/// In February 2024, maximum deposit in Rocket Pool cap was reached.
/// Due to the maximum deposit cap, the deposit amount may be not deposited fully into Rocket Pool.
/// Instead, the deposit may be swapped to rETH on secondary markets by an authorized rebalancer.
/// In this case, the share price would increase temporarily due to swap fees.
/// This loss is pro-rated among all erETH holders.
///
/// 2. This contract doesn't independently keep track of the rETH balance, so it is possible
/// for an attacker to directly transfer rETH to this contract, increase the share price.
contract RETHAdapter is BaseLSTVault, ReentrancyGuard {
    IWETH9 constant WETH = IWETH9(Constants.WETH);

    IRocketETH constant RETH = IRocketETH(Constants.RETH);

    /// @notice rocketDepositPool contract address key
    bytes32 immutable ROCKET_DEPOSIT_POOL_KEY = keccak256(abi.encodePacked("contract.address", "rocketDepositPool"));

    /// @notice rocketDAOProtocolSettingsDeposit contract address key
    bytes32 immutable ROCKET_DAO_SETTINGS_DEPOSIT_KEY =
        keccak256(abi.encodePacked("contract.address", "rocketDAOProtocolSettingsDeposit"));

    /// @notice registry contract address
    IRocketStorage immutable rocketStorage;

    /// @notice Amount of ETH available (Buffer), does not include pending withdrawal. Internal accounting of ETH
    uint256 public bufferEth;

    /// @notice Swapper contract for swapping ETH to rETH
    /// @dev This contract is set by the owner
    Swapper public swapper;

    error OnlyWETHOrRETH();
    error InvariantViolation();
    error MaxStakeExceeded();
    error SwapAmountTooLarge();
    error InsufficientCollateralInRocketPool();

    /// @notice _rocketStorageAddress is the address of the RocketStorage contract
    constructor(
        address _rebalancer,
        address _swapper,
        address _rocketStorageAddress
    ) BaseLSTVault(_rebalancer) ERC20("Napier rETH Adapter", "erETH") {
        swapper = Swapper(_swapper);
        rocketStorage = IRocketStorage(_rocketStorageAddress);
    }

    receive() external payable {
        // WETH or rETH contract can send ETH
        // though it is possible to forcefully send ETH to this contract
        if (msg.sender != Constants.WETH && msg.sender != Constants.RETH) {
            revert OnlyWETHOrRETH();
        }
    }

    /// @notice Handles prefunded deposits
    /// @return The amount of staked ETH
    /// @return The amount of shares minted
    function prefundedDeposit() external nonReentrant onlyTranche returns (uint256, uint256) {
        uint256 bufferEthCache = bufferEth; // cache storage reads
        uint256 assets = IWETH9(WETH).balanceOf(address(this)) - bufferEthCache; // amount of WETH deposited at this time
        uint256 shares = previewDeposit(assets);

        if (assets == 0) return (0, 0);
        if (shares == 0) revert ZeroShares();

        /// WRITE ///
        bufferEth = bufferEthCache + assets;
        _mint(msg.sender, shares);

        return (assets, shares);
    }

    function prefundedRedeem(address to) external override nonReentrant onlyTranche returns (uint256, uint256) {
        uint256 shares = balanceOf(address(this));
        uint256 assets = previewRedeem(shares);

        if (shares == 0) return (0, 0);
        if (assets == 0) revert ZeroAssets();
        // If the buffer is sufficient, redeem shares.
        uint256 bufferEthCache = bufferEth;
        if (assets > bufferEthCache) {
            // If the buffer is insufficient, try to withdraw as much as possible by burning rETH

            /// INTERACT ///
            uint256 ethToWithdraw = assets - bufferEthCache; // Add 1000 wei to avoid potential rounding errors
            if (ethToWithdraw > RETH.getTotalCollateral()) revert InsufficientCollateralInRocketPool();

            /// WRITE & INTERACT ///
            uint256 rethAmount = RETH.getRethValue(ethToWithdraw);

            // Actual withdrawal amount can be different from `ethToWithdraw`.
            // Add 1 wei to avoid potential rounding errors but it may cause an burn amount to exceed the balance
            bufferEthCache += _unstake(rethAmount + 1);

            // The following check is sanity check.
            // When adapter could not withdraw the expected amount of ETH due to rounding errors, it should revert.
            if (assets > bufferEthCache) revert InsufficientBuffer();
        }

        /// WRITE ///
        // Reduce the buffer and burn the shares
        unchecked {
            bufferEth = bufferEthCache - assets; // no underflow
        }

        _burn(address(this), shares);

        /// INTERACT ///
        IWETH9(WETH).transfer(to, assets);

        return (assets, shares);
    }

    ///////////////////////////////////////////////////////////////////////////
    // Rebalancer functions
    ///////////////////////////////////////////////////////////////////////////

    /// @notice Withdraw ETH from Rocket Pool to refill the buffer
    function withdraw() external nonReentrant onlyRebalancer {
        uint256 targetBufferEth = (totalAssets() * targetBufferPercentage) / BUFFER_PERCENTAGE_PRECISION;

        // If the buffer exceeds the target buffer, revert.
        // If the buffer is insufficient, request a withdrawal to refill the buffer.
        // note: use `>=` instead of `>` to prevent amount of ETH to withdraw to be 0
        uint256 bufferEthCache = bufferEth;
        if (bufferEthCache >= targetBufferEth) revert BufferTooLarge();

        uint256 withdrawAmount;
        unchecked {
            // Ensure that `withdrawAmount` is non-zero and withdrawalQueueEth is zero.
            withdrawAmount = targetBufferEth - bufferEthCache; // no underflow
        }

        // Get maximum amount of ETH that can be withdrawn
        uint256 totalCollaratel = RETH.getTotalCollateral();
        // Cap withdrawal amount if it exceeds total collateral
        if (withdrawAmount > totalCollaratel) {
            withdrawAmount = totalCollaratel;
        }

        /// WRITE & INTERACT ///
        uint256 rethAmount = RETH.getRethValue(withdrawAmount);
        bufferEth = bufferEthCache + _unstake(rethAmount);
    }

    /// @notice Withdraw all assets from Rocket Pool
    function withdrawAll() external nonReentrant onlyRebalancer {
        // Burn rETH for ETH
        uint256 withdrawAmt = RETH.balanceOf(address(this));

        // If RETH total collateral is smaller than withdraw amount, adjust it.
        if (RETH.getTotalCollateral() < RETH.getEthValue(RETH.balanceOf(address(this)))) {
            withdrawAmt = RETH.getRethValue(RETH.getTotalCollateral());
        }
        bufferEth += _unstake(withdrawAmt);
    }

    /// @notice Withdraw ETH from Rocket Pool by burning `rethAmount` amount of rETH
    /// @param rethAmount The amount of rETH to redeem
    /// @return The actual amount of ETH withdrawn
    function _unstake(uint256 rethAmount) internal returns (uint256) {
        // Burn rETH for ETH
        uint256 ethBalance = address(this).balance;
        RETH.burn(rethAmount);
        uint256 withdrawn = address(this).balance - ethBalance;
        if (withdrawn == 0) revert ZeroAssets();

        // Wrap ETH to WETH
        WETH.deposit{value: withdrawn}();
        return withdrawn;
    }

    /// @notice Mint rETH using WETH
    /// @dev This function is only callable by the rebalancer
    /// @dev note: erETH share price would decrease temporarily due to deposit fees charged by Rocket Pool.
    /// @dev Reverts if the current buffer percentage is less than the target buffer percentage
    /// @dev Reverts if the stake amount parameter exceeds the maximum stake amount.
    /// @dev This function may not stake the entire amount of WETH requested due to the minimum deposit amount or maximum deposit cap in Rocket Pool.
    /// @param stakeAmount Amount of WETH to stake
    function mintReth(uint256 stakeAmount) external nonReentrant onlyRebalancer {
        uint256 bufferEthCache = bufferEth; // save SLOAD
        uint256 targetBufferEth = (totalAssets() * targetBufferPercentage) / BUFFER_PERCENTAGE_PRECISION;

        // If the buffer is insufficient: Doesn't stake any of the deposit
        if (targetBufferEth >= bufferEthCache) revert InsufficientBuffer();

        uint256 maxStakeAmount;
        unchecked {
            maxStakeAmount = bufferEthCache - targetBufferEth; // non-zero, no underflow
        }
        if (stakeAmount > maxStakeAmount) revert MaxStakeExceeded();

        /// INTERACT ///
        // Mint rETH using WETH
        // Actual amount of ETH spent may be less than the requested amount.
        stakeAmount = _stake(stakeAmount); // stake amount can be 0
        /// WRITE ///
        bufferEth = bufferEthCache - stakeAmount;
    }

    /// @notice Mint rETH using WETH
    /// @dev Deposit to Rocket Pool requires a minimum deposit of some amount of ETH.
    /// @dev Rocket Pool takes fees from the deposit amount.
    /// @return The amount of WETH actually spent
    /// See IRocketDAOProtocolSettingsDeposit.sol for more details.
    /// https://github.com/rocket-pool/rocketpool/blob/9710596d82189c54f0dc35be3501cda13a155f4d/contracts/contract/deposit/RocketDepositPool.sol#L119
    function _stake(uint256 stakeAmount) internal override returns (uint256) {
        /// VALIDATE ///
        if (stakeAmount == 0) return 0;
        // Return early if minimum deposit amount is not met
        uint256 minimumDeposit = IRocketDAOProtocolSettingsDeposit(
            rocketStorage.getAddress(ROCKET_DAO_SETTINGS_DEPOSIT_KEY)
        ).getMinimumDeposit();
        if (stakeAmount <= minimumDeposit) return 0;

        IRocketDepositPool rocketDepositPool = IRocketDepositPool(rocketStorage.getAddress(ROCKET_DEPOSIT_POOL_KEY));

        // Cap deposit amount if it exceeds maximum deposit amount
        uint256 maximumDeposit = rocketDepositPool.getMaximumDepositAmount();
        if (stakeAmount > maximumDeposit) {
            stakeAmount = maximumDeposit;
        }

        /// INTERACT ///

        // Forward deposit to RP & get amount of rETH minted
        uint256 rEthBalBefore = RETH.balanceOf(address(this));
        // check: slither "arbitrary-send-eth"
        WETH.withdraw(stakeAmount);
        rocketDepositPool.deposit{value: stakeAmount}();
        uint256 minted = RETH.balanceOf(address(this)) - rEthBalBefore;

        if (minted == 0) revert InvariantViolation();
        return stakeAmount;
    }

    /// @notice Swap ETH for rETH
    /// @dev This function is only callable by the rebalancer
    /// @dev Swapper must send back remaining WETH to the caller after the swap to avoid stuck ETH
    /// @param ethValue Amount of ETH to swap
    /// @param deadline Deadline for the swap
    /// @param amountOutMin Minimum amount of rETH to receive
    /// @param data Data for the swap
    function swapEthForReth(
        uint256 ethValue,
        uint256 deadline,
        uint256 amountOutMin,
        bytes calldata data
    ) external nonReentrant onlyRebalancer {
        uint256 bufferEthCache = bufferEth; // save SLOAD
        uint256 targetBufferEth = (totalAssets() * targetBufferPercentage) / BUFFER_PERCENTAGE_PRECISION;

        // When the current buffer is smaller than the target, revert with underflow error
        // Note: Can't swap more than `maxEthToSwap` to avoid swapping too much ETH
        // and causing the buffer to be too low after the swap
        uint256 maxEthToSwap = bufferEthCache - targetBufferEth;

        if (ethValue > maxEthToSwap) revert SwapAmountTooLarge();

        /// INTERACT ///
        uint256 balanceBefore = WETH.balanceOf(address(this));
        WETH.approve(address(swapper), ethValue);
        swapper.swap(ethValue, deadline, amountOutMin, data);
        uint256 spent = balanceBefore - WETH.balanceOf(address(this));

        /// WRITE ///
        bufferEth = (bufferEthCache - spent);
    }

    function totalAssets() public view override returns (uint256) {
        uint256 balance = RETH.balanceOf(address(this));
        // `withdrawalQueueEth` is always 0 in this adapter
        return bufferEth + RETH.getEthValue(balance);
    }

    function bufferPresentPercentage() external view override returns (uint256) {
        return (bufferEth * BUFFER_PERCENTAGE_PRECISION) / totalAssets();
    }

    ///////////////////////////////////////////////////////////////////////////
    // Admin functions
    ///////////////////////////////////////////////////////////////////////////

    function setSwapper(address _swapper) external onlyOwner {
        swapper = Swapper(_swapper);
    }
}
