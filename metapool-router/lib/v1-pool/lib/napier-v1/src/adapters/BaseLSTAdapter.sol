// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

import {IWETH9} from "../interfaces/IWETH9.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts@4.9.3/security/ReentrancyGuard.sol";

import {StakeLimitTypes, StakeLimitUtils} from "../utils/StakeLimitUtils.sol";
import {SafeCast} from "@openzeppelin/contracts@4.9.3/utils/math/SafeCast.sol";
import {WETH} from "../Constants.sol";

import {BaseAdapter} from "../BaseAdapter.sol";
import {BaseLSTVault} from "./BaseLSTVault.sol";

/// @notice Adapter for Liquid Staking Token (LST)
/// @dev This adapter facilitates immediate ETH withdrawals without a waiting period.
/// It maintains an ETH buffer to enable these withdrawals. The size of this buffer is determined
/// by a specified desired buffer percentage. The maintenance of the buffer
/// are handled by a designated account.
/// @dev LST Adapter is NOT compatible with EIP4626 standard. We don't expect it to be used by other contracts other than Tranche.
abstract contract BaseLSTAdapter is BaseLSTVault, ReentrancyGuard {
    using SafeCast for uint256;
    using StakeLimitTypes for StakeLimitTypes.Uint256Data;
    using StakeLimitTypes for StakeLimitTypes.Data;
    using StakeLimitUtils for StakeLimitTypes.Data;

    uint256 constant DEFAULT_MAX_STAKE_LIMIT = 10_000 ether;
    uint256 constant DEFAULT_STAKE_LIMIT_INCREASE_PER_BLOCK = 0.00015 ether; // About 1 ether recovery per 1 day

    /// @notice Total of ETH pending withdrawal request
    uint128 public totalQueueEth;

    /// @notice Amount of ETH available (Buffer), does not include pending withdrawal. Internal accounting of ETH
    uint128 public bufferEth;

    /// @notice Mapping of the withdrawal request ID to the amount of ETH
    mapping(uint256 requestId => uint256 queueEth) public queueWithdrawal;

    /// @notice Packed data for the stake limit state
    StakeLimitTypes.Uint256Data internal packedStakeLimitData;

    error WithdrawalPending();
    error InvalidWithdrawalAmount();
    error NoPendingWithdrawal();

    event StakingLimitSet(uint256 maxStakeLimit, uint256 stakeLimitIncreasePerBlock);
    event StakingPaused();
    event StakingUnpaused();
    event ClaimWithdrawal(uint256 requestId, uint256 queueAmount);
    event RequestWithdrawal(uint256 requestId, uint256 queueAmount);

    /// @dev Adapter itself is the target token
    constructor(
        address _rebalancer,
        uint256 _maxStakeLimit,
        uint256 _stakeLimitIncreasePerBlock
    ) BaseLSTVault(_rebalancer) {
        rebalancer = _rebalancer;
        // Set the initial stake limit state
        StakeLimitTypes.Data memory data = StakeLimitTypes.Data({
            prevStakeBlockNumber: uint32(block.number),
            prevStakeLimit: 0,
            maxStakeLimitGrowthBlocks: 0,
            maxStakeLimit: 0
        });
        packedStakeLimitData.setStorageStakeLimitStruct(
            data.setStakingLimit(
                _maxStakeLimit == 0 ? DEFAULT_MAX_STAKE_LIMIT : _maxStakeLimit,
                _stakeLimitIncreasePerBlock == 0 ? DEFAULT_STAKE_LIMIT_INCREASE_PER_BLOCK : _stakeLimitIncreasePerBlock
            )
        );
    }

    ////////////////////////////////////////////////////////
    /// ADAPTER METHOD
    ////////////////////////////////////////////////////////

    /// @notice Handles prefunded deposits
    /// @return The amount of staked ETH
    /// @return The amount of shares minted
    function prefundedDeposit() external nonReentrant onlyTranche returns (uint256, uint256) {
        uint256 bufferEthCache = bufferEth; // cache storage reads
        uint256 queueEthCache = totalQueueEth; // cache storage reads
        uint256 assets = IWETH9(WETH).balanceOf(address(this)) - bufferEthCache; // amount of WETH deposited at this time
        uint256 shares = previewDeposit(assets);

        if (assets == 0) return (0, 0);
        if (shares == 0) revert ZeroShares();

        // Calculate the target buffer amount considering the user's deposit.
        // bufferRatio is defined as the ratio of ETH balance to the total assets in the adapter in ETH.
        // Formula:
        // desiredBufferRatio = (totalQueueEth + bufferEth + assets - s) / (totalQueueEth + bufferEth + stakedEth + assets)
        // Where:
        // assets := Amount of ETH the user is depositing
        // s := Amount of ETH to stake at this time, s <= bufferEth + assets.
        //
        // Thus, the formula can be simplified to:
        // s = (totalQueueEth + bufferEth + assets) - (totalQueueEth + bufferEth + stakedEth + assets) * desiredBufferRatio
        //   = (totalQueueEth + bufferEth + assets) - targetBufferEth
        //
        // Flow:
        // If `s` <= 0, don't stake any ETH.
        // If `s` < bufferEth + assets, stake `s` amount of ETH.
        // If `s` >= bufferEth + assets, all available ETH can be staked in theory.
        // However, we cap the stake amount. This is to prevent the buffer from being completely drained.
        //
        // Let `a` be the available amount of ETH in the buffer after the deposit. `a` is calculated as:
        // a = (bufferEth + assets) - s
        uint256 targetBufferEth = ((totalAssets() + assets) * targetBufferPercentage) / BUFFER_PERCENTAGE_PRECISION;

        /// WRITE ///
        _mint(msg.sender, shares);

        uint256 availableEth = bufferEthCache + assets; // non-zero

        // If the buffer is insufficient or staking is paused, doesn't stake any of the deposit
        StakeLimitTypes.Data memory data = packedStakeLimitData.getStorageStakeLimitStruct();
        if (targetBufferEth >= availableEth + queueEthCache || data.isStakingPaused()) {
            /// WRITE ///
            bufferEth = availableEth.toUint128();
            return (assets, shares);
        }

        // Calculate the amount of ETH to stake
        uint256 stakeAmount; // can be 0
        unchecked {
            stakeAmount = availableEth + queueEthCache - targetBufferEth; // non-zero, no underflow
        }
        // If the calculated stake amount exceeds the available ETH, simply assign the available ETH to the stake amount.
        // Possible scenarios:
        // - Target buffer percentage was changed to a lower value and there is a large withdrawal request pending.
        // - There is a pending withdrawal request and the available ETH are not left in the buffer.
        // - There is no pending withdrawal request and the available ETH are not left in the buffer.
        if (stakeAmount > availableEth) {
            // Note: Admins should be aware of this situation and take action to refill the buffer.
            // - Pause staking to prevent further staking until the buffer is refilled
            // - Update stake limit to a lower value
            // - Increase the target buffer percentage
            stakeAmount = availableEth; // All available ETH
        }

        // If the amount of ETH to stake exceeds the current stake limit, cap the stake amount.
        // This is to prevent the buffer from being completely drained. This is not a complete solution.
        uint256 currentStakeLimit = StakeLimitUtils.calculateCurrentStakeLimit(data); // can be 0 if the stake limit is exhausted
        if (stakeAmount > currentStakeLimit) {
            stakeAmount = currentStakeLimit;
        }
        /// WRITE ///
        // Update the stake limit state in the storage
        packedStakeLimitData.setStorageStakeLimitStruct(data.updatePrevStakeLimit(currentStakeLimit - stakeAmount));

        /// INTERACT ///
        // Deposit into the yield source
        // Actual amount of ETH spent may be less than the requested amount.
        stakeAmount = _stake(stakeAmount); // stake amount can be 0

        /// WRITE ///
        bufferEth = (availableEth - stakeAmount).toUint128(); // no underflow theoretically

        return (assets, shares);
    }

    /// @notice Handles prefunded redemptions
    /// @dev Withdraw from the buffer. If the buffer is insufficient, revert with an error
    /// @param recipient The address to receive the redeemed WETH
    /// @return The amount of redeemed WETH
    /// @return The amount of shares burned
    function prefundedRedeem(address recipient) external virtual onlyTranche returns (uint256, uint256) {
        uint256 shares = balanceOf(address(this));
        uint256 assets = previewRedeem(shares);

        if (shares == 0) return (0, 0);
        if (assets == 0) revert ZeroAssets();

        uint256 bufferEthCache = bufferEth;
        // If the buffer is insufficient, shares cannot be redeemed immediately
        // Need to wait for the withdrawal to be completed and the buffer to be refilled.
        if (assets > bufferEthCache) revert InsufficientBuffer();

        unchecked {
            /// WRITE ///
            // Reduce the buffer and burn the shares
            bufferEth = (bufferEthCache - assets).toUint128(); // no underflow
            _burn(address(this), shares);
        }

        /// INTERACT ///
        IWETH9(WETH).transfer(recipient, assets);

        return (assets, shares);
    }

    ////////////////////////////////////////////////////////
    /// VIRTUAL METHOD
    ////////////////////////////////////////////////////////

    /// @notice Request a withdrawal of ETH
    /// @dev This function is called by only the rebalancer
    /// @dev Reverts if there is a pending withdrawal request
    /// @dev Reverts if the buffer is sufficient to cover the desired buffer percentage of the total assets
    function requestWithdrawal() external virtual nonReentrant onlyRebalancer {
        uint256 targetBufferEth = (totalAssets() * targetBufferPercentage) / BUFFER_PERCENTAGE_PRECISION;

        // If the buffer exceeds the target buffer, revert.
        // If the buffer is insufficient, request a withdrawal to refill the buffer.
        // note: use `>=` instead of `>` to prevent amount of ETH to withdraw to be 0
        uint256 sum = bufferEth + totalQueueEth;
        if (sum >= targetBufferEth) revert BufferTooLarge();

        unchecked {
            uint256 withdrawAmount = targetBufferEth - sum; // no underflow

            /// WRITE & INTERACT ///
            // Record the pending withdrawal request
            // Request a withdrawal
            (uint256 queueAmount, uint256 _requestId) = _requestWithdrawal(withdrawAmount);

            if (queueWithdrawal[_requestId] != 0) revert WithdrawalPending();
            totalQueueEth += queueAmount.toUint128();
            queueWithdrawal[_requestId] = queueAmount;
        }
    }

    /// @notice Request a withdrawal of all staked ETH
    /// @dev This function is called by only the rebalancer
    /// @dev Reverts if there is a pending withdrawal request
    function requestWithdrawalAll() external virtual;

    /// @notice Claim the finized withdrawal request
    /// @param _requestId The request Id of the withdrawal request
    /// @dev This function is called by anyone
    /// @dev Reverts if there is no pending withdrawal request
    function claimWithdrawal(uint256 _requestId) external virtual;

    /// @notice Request a withdrawal of the given amount of ETH from the yield source
    /// @param withdrawAmount The amount of ETH to withdraw
    /// @return queueAmount The amount of ETH withdrawn
    /// @return requestId The request Id of the withdrawal request
    function _requestWithdrawal(
        uint256 withdrawAmount
    ) internal virtual returns (uint256 queueAmount, uint256 requestId);

    ////////////////////////////////////////////////////////
    /// VIEW METHOD
    ////////////////////////////////////////////////////////

    /// @notice Returns the present buffer percentage in WAD. e.g) 10% => 0.1 * 1e18
    function bufferPresentPercentage() external view override returns (uint256) {
        return ((bufferEth + totalQueueEth) * BUFFER_PERCENTAGE_PRECISION) / totalAssets();
    }

    /// @notice Check staking state: whether it's paused or not
    function isStakingPaused() external view returns (bool) {
        return packedStakeLimitData.getStorageStakeLimitStruct().isStakingPaused();
    }

    /// @notice Returns how much Ether can be staked into a yield source (Lido, RocketPool, etc.)
    /// @dev Special return values:
    /// - 0 if staking is paused or if limit is exhausted.
    function getCurrentStakeLimit() external view returns (uint256) {
        StakeLimitTypes.Data memory data = packedStakeLimitData.getStorageStakeLimitStruct();
        if (data.isStakingPaused()) {
            return 0;
        }
        return data.calculateCurrentStakeLimit();
    }

    ////////////////////////////////////////////////////////
    /// ADMIN METHOD
    ////////////////////////////////////////////////////////

    /// @notice Sets the staking rate limit
    ///
    /// ▲ Stake limit
    /// │.....  .....   ........ ...            ....     ... Stake limit = max
    /// │      .       .        .   .   .      .    . . .
    /// │     .       .              . .  . . .      . .
    /// │            .                .  . . .
    /// │──────────────────────────────────────────────────> Time
    /// │     ^      ^          ^   ^^^  ^ ^ ^     ^^^ ^     Stake events
    ///
    /// @dev Reverts if:
    /// - `_maxStakeLimit` == 0
    /// - `_maxStakeLimit` >= 2^96
    /// - `_maxStakeLimit` < `_stakeLimitIncreasePerBlock`
    /// - `_maxStakeLimit` / `_stakeLimitIncreasePerBlock` >= 2^32 (only if `_stakeLimitIncreasePerBlock` != 0)
    ///
    /// Emits `StakingLimitSet` event
    ///
    /// @param _maxStakeLimit max stake limit value
    /// @param _stakeLimitIncreasePerBlock stake limit increase per single block
    function setStakingLimit(uint256 _maxStakeLimit, uint256 _stakeLimitIncreasePerBlock) external onlyOwner {
        StakeLimitTypes.Data memory data = packedStakeLimitData.getStorageStakeLimitStruct();
        /// WRITE ///
        packedStakeLimitData.setStorageStakeLimitStruct(
            data.setStakingLimit(_maxStakeLimit, _stakeLimitIncreasePerBlock)
        );
        emit StakingLimitSet(_maxStakeLimit, _stakeLimitIncreasePerBlock);
    }

    function pauseStaking() external onlyOwner {
        StakeLimitTypes.Data memory data = packedStakeLimitData.getStorageStakeLimitStruct();
        /// WRITE ///
        packedStakeLimitData.setStorageStakeLimitStruct(data.setStakeLimitPauseState(true));
        emit StakingPaused();
    }

    function unpauseStaking() external onlyOwner {
        StakeLimitTypes.Data memory data = packedStakeLimitData.getStorageStakeLimitStruct();
        /// WRITE ///
        packedStakeLimitData.setStorageStakeLimitStruct(data.setStakeLimitPauseState(false));
        emit StakingUnpaused();
    }
}
