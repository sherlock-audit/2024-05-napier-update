// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

// interfaces
import {IWETH9} from "@napier/v1-tranche/interfaces/IWETH9.sol";
import {IPufferVault} from "./interfaces/IPufferVault.sol";
import {IPufferDepositor, Permit} from "./interfaces/IPufferDepositor.sol";
import {IStETH} from "@napier/v1-tranche/adapters/lido/interfaces/IStETH.sol";

// libs
import {SafeCast} from "@openzeppelin/contracts@4.9.3/utils/math/SafeCast.sol";
import {LSTAdapterStorage} from "../../Structs.sol";
import "../../Constants.sol" as Constants;

import {BaseLSTAdapterUpgradeable} from "../BaseLSTAdapterUpgradeable.sol";

/// @notice PufETHAdapter - ePufETH (Napier pufETH Adapter)
/// @notice Puffer is a decentralized native liquid restaking protocol (nLRP) built on Eigenlayer
/// It makes native restaking on Eigenlayer more accessible, allowing anyone to run an Ethereum Proof of Stake
/// (PoS) validator while supercharging their rewards.
contract PufETHAdapter is BaseLSTAdapterUpgradeable {
    /// @notice stETH
    IStETH constant STETH = IStETH(Constants.STETH);

    /// @notice pufETH
    IPufferVault constant PUFETH = IPufferVault(Constants.PUFETH);

    /// @notice Puffer Depositor
    IPufferDepositor constant PUFFER_DEPOSITOR = IPufferDepositor(Constants.PUF_DEPOSITOR);

    error OnlyWETHOrRETH();
    error InvariantViolation();

    receive() external payable {}

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _rebalancer,
        uint256 _maxStakeLimit,
        uint256 _stakeLimitIncreasePerBlock
    ) public initializer {
        __BaseLSTAdapter_init(_owner, _rebalancer, _maxStakeLimit, _stakeLimitIncreasePerBlock);
        __ERC20_init("Napier pufETH Adapter", "ePufETH");

        PUFETH.approve(address(PUFFER_DEPOSITOR), type(uint256).max);
        STETH.approve(address(PUFFER_DEPOSITOR), type(uint256).max);
    }

    /// @notice Claim withdrawal from Puffer
    /// @dev Puffer doesn't have claim functionality yet.
    function claimWithdrawal(uint256) external pure override {
        revert NotImplemented();
    }

    ///////////////////////////////////////////////////////////////////////////
    // Rebalancer functions
    ///////////////////////////////////////////////////////////////////////////

    /// @notice Puffer allows stETH or wstETH via PufferDepositor.
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
        uint256 _stETHAmt = STETH.balanceOf(address(this));
        STETH.submit{value: stakeAmount}(address(this));
        _stETHAmt = STETH.balanceOf(address(this)) - _stETHAmt;
        if (_stETHAmt == 0) revert InvariantViolation();

        // Stake stETH to PufferDepositor
        uint256 _pufETHAmt = PUFFER_DEPOSITOR.depositStETH(Permit(block.timestamp, _stETHAmt, 0, 0, 0));

        if (_pufETHAmt == 0) revert InvariantViolation();

        return stakeAmount;
    }

    /// @dev Puffer doesn't have withdraw function yet.
    function requestWithdrawal() external pure override {
        revert NotImplemented();
    }

    /// @dev Puffer doesn't have withdraw function yet.
    function requestWithdrawalAll() external pure override {
        revert NotImplemented();
    }

    /// @dev Puffer doesn't have withdraw function yet.
    function _requestWithdrawal(uint256) internal pure override returns (uint256, uint256) {
        revert NotImplemented();
    }

    function totalAssets() public view override returns (uint256) {
        LSTAdapterStorage storage $ = _getStorage();

        uint256 share = PUFETH.balanceOf(address(this));
        return $.totalQueueEth + $.bufferEth + PUFETH.convertToAssets(share);
    }
}
