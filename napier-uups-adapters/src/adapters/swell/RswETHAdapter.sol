// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

// interfaces
import {IWETH9} from "@napier/v1-tranche/interfaces/IWETH9.sol";
import {IRswETH} from "./interfaces/IRswETH.sol";

import {BaseLSTAdapterUpgradeable} from "../BaseLSTAdapterUpgradeable.sol";
import {LSTAdapterStorage} from "../../Structs.sol";
import "../../Constants.sol" as Constants;

/// @notice RswETHAdapter - eRswETH (Napier rswETH Adapter)
/// @notice rswETH is an ERC-20 Liquid Restaking Token that provides liquidity
/// for users who are wanting to "restake" their ETH into restaking protocols
/// such as EigenLayer without having their restaked ETH locked.
contract RswETHAdapter is BaseLSTAdapterUpgradeable {
    /// @notice RswETH
    IRswETH constant RSWETH = IRswETH(Constants.RSWETH);

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
        __ERC20_init("Napier rswETH Adapter", "eRswETH");
    }

    /// @notice Claim withdrawal from Swell
    /// @dev Swell RswETH doesn't have claim functionality yet.
    function claimWithdrawal(uint256) external pure override {
        revert NotImplemented();
    }

    ///////////////////////////////////////////////////////////////////////////
    // Rebalancer functions
    ///////////////////////////////////////////////////////////////////////////

    /// @notice Withdraw ETH from Rocket Pool to refill the buffer
    function withdraw() external pure {
        revert NotImplemented();
    }

    /// @notice Withdraw all assets from Rocket Pool
    function withdrawAll() external pure {
        revert NotImplemented();
    }

    /// @notice Stake ETH for rswETH
    /// @dev Swell RswETH doesn't have a stake limit
    function _stake(uint256 stakeAmount) internal override returns (uint256) {
        if (stakeAmount == 0) return 0;

        IWETH9(Constants.WETH).withdraw(stakeAmount);
        uint256 _rswETHAmt = RSWETH.balanceOf(address(this));
        RSWETH.deposit{value: stakeAmount}();
        _rswETHAmt = RSWETH.balanceOf(address(this)) - _rswETHAmt;
        if (_rswETHAmt == 0) revert InvariantViolation();

        return stakeAmount;
    }

    /// @dev Swell RswETH doesn't have withdraw function yet.
    function requestWithdrawal() external pure override {
        revert NotImplemented();
    }

    /// @dev Swell RswETH doesn't have withdraw function yet.
    function requestWithdrawalAll() external pure override {
        revert NotImplemented();
    }

    /// @dev Swell RswETH doesn't have withdraw function yet.
    function _requestWithdrawal(uint256) internal pure override returns (uint256, uint256) {
        revert NotImplemented();
    }

    function totalAssets() public view override returns (uint256) {
        LSTAdapterStorage storage $ = _getStorage();

        uint256 bal = RSWETH.balanceOf(address(this));
        return $.totalQueueEth + $.bufferEth + (bal * RSWETH.rswETHToETHRate()) / 1e18;
    }
}
