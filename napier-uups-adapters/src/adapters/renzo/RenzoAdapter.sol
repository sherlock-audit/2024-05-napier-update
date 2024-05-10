// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

// interfaces
import {IERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/IERC20.sol";
import {IWETH9} from "@napier/v1-tranche/interfaces/IWETH9.sol";
import {IRenzoRestakeManager} from "./interfaces/IRenzoRestakeManager.sol";
import {IRateProvider} from "./interfaces/IRateProvider.sol";

// libs
import {LSTAdapterStorage} from "../../Structs.sol";
import "../../Constants.sol" as Constants;

import {BaseLSTAdapterUpgradeable} from "../BaseLSTAdapterUpgradeable.sol";

/// @notice RenzoAdapter - eEzETH (Napier renzoETH Adapter)
contract RenzoAdapter is BaseLSTAdapterUpgradeable {
    /// @notice
    IERC20 constant EZETH = IERC20(Constants.EZETH);

    /// @notice
    IRenzoRestakeManager constant RENZO_RESTAKE_MANAGER = IRenzoRestakeManager(Constants.RENZO_RESTAKE_MANAGER);

    /// @notice
    IRateProvider constant RATE_PROVIDER = IRateProvider(Constants.RENZO_RATE_PROVIDER);

    error InvariantViolation();
    error ProtocolPaused();

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
        __ERC20_init("Napier ezETH Adapter", "eEzETH");

        EZETH.approve(address(RENZO_RESTAKE_MANAGER), type(uint256).max);
    }

    /// @notice Claim withdrawal from Renzo
    /// @dev Renzo doesn't have claim functionality yet.
    function claimWithdrawal(uint256) external pure override {
        revert NotImplemented();
    }

    ///////////////////////////////////////////////////////////////////////////
    // Rebalancer functions
    ///////////////////////////////////////////////////////////////////////////

    /// @notice Mint .
    /// @dev Need to check the current staking limit before staking to prevent DoS.
    function _stake(uint256 stakeAmount) internal override returns (uint256) {
        if (stakeAmount == 0) return 0;
        if (RENZO_RESTAKE_MANAGER.paused()) revert ProtocolPaused();
        uint256 balanceBefore = EZETH.balanceOf(address(this));
        IWETH9(Constants.WETH).withdraw(stakeAmount);
        RENZO_RESTAKE_MANAGER.depositETH{value: stakeAmount}(0);
        uint256 newBalance = EZETH.balanceOf(address(this));
        if (newBalance - balanceBefore == 0) revert InvariantViolation();

        return stakeAmount;
    }

    /// @dev Renzo doesn't have withdraw function yet.
    function requestWithdrawal() external pure override {
        revert NotImplemented();
    }

    /// @dev Renzo doesn't have withdraw function yet.
    function requestWithdrawalAll() external pure override {
        revert NotImplemented();
    }

    /// @dev Renzo doesn't have withdraw function yet.
    function _requestWithdrawal(uint256) internal pure override returns (uint256, uint256) {
        revert NotImplemented();
    }

    function totalAssets() public view override returns (uint256) {
        LSTAdapterStorage storage $ = _getStorage();

        return $.totalQueueEth + $.bufferEth + (EZETH.balanceOf(address(this)) * RATE_PROVIDER.getRate()) / 1e18;
    }
}
