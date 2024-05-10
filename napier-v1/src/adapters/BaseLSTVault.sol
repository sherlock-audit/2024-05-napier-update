// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

import {IWETH9} from "../interfaces/IWETH9.sol";
import {WETH} from "../Constants.sol";

import {ERC4626} from "@openzeppelin/contracts@4.9.3/token/ERC20/extensions/ERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts@4.9.3/security/ReentrancyGuard.sol";
import {BaseAdapter} from "../BaseAdapter.sol";

/// @notice Adapter for Liquid Staking Token (LST)
/// @dev This contract is NOT compatible with EIP4626 standard
abstract contract BaseLSTVault is BaseAdapter, ERC4626 {
    uint256 constant BUFFER_PERCENTAGE_PRECISION = 1e18; // 1e18 = 100%
    uint256 constant MIN_BUFFER_PERCENTAGE = 0.01 * 1e18; // 1%

    /// @notice Rebalancer of the ETH buffer, can be set by the owner
    /// @notice The account can request a withdrawal
    address public rebalancer;

    /// @notice Desired buffer percentage in WAD
    uint256 public targetBufferPercentage = 0.1 * 1e18; // 10% desired buffer percentage

    /// @notice Tranche contract for restricting access to prefundedDeposit and prefundedRedeem
    address public tranche;

    error NotTranche();
    error ZeroAssets();
    error ZeroShares();
    error ZeroAddress();
    error TrancheAlreadySet();
    error InsufficientBuffer();
    error BufferTooLarge();
    error InvalidBufferPercentage();
    error NotRebalancer();
    error NotImplemented();

    /// @notice Reverts if the caller is not the rebalancer
    modifier onlyRebalancer() {
        if (rebalancer != msg.sender) revert NotRebalancer();
        _;
    }

    /// @notice Reverts if the caller is not the Tranche
    modifier onlyTranche() {
        if (tranche != msg.sender) revert NotTranche();
        _;
    }

    /// @dev Adapter itself is the target token
    constructor(address _rebalancer) BaseAdapter(WETH, address(this)) ERC4626((IWETH9(WETH))) {
        rebalancer = _rebalancer;
    }

    function scale() external view override returns (uint256) {
        return convertToAssets(1e18);
    }

    ////////////////////////////////////////////////////////
    /// ADMIN METHOD
    ////////////////////////////////////////////////////////

    function setRebalancer(address _rebalancer) external onlyOwner {
        rebalancer = _rebalancer;
    }

    function setTranche(address _tranche) external onlyOwner {
        if (tranche != address(0)) {
            revert TrancheAlreadySet();
        }
        if (_tranche == address(0)) {
            revert ZeroAddress();
        }
        tranche = _tranche;
    }

    /// @notice Set the maximum buffer percentage
    /// @param _targetBufferPercentage The maximum buffer percentage in WAD
    function setTargetBufferPercentage(uint256 _targetBufferPercentage) external onlyRebalancer {
        if (_targetBufferPercentage < MIN_BUFFER_PERCENTAGE || _targetBufferPercentage > BUFFER_PERCENTAGE_PRECISION) {
            revert InvalidBufferPercentage();
        }
        targetBufferPercentage = _targetBufferPercentage;
    }

    /////////////////////////////////////////////////////////
    /// VIRTUAL METHOD
    /////////////////////////////////////////////////////////

    /// @notice Stake the given amount of ETH into the yield source
    /// @dev If necessary, skip the staking process by returning 0 when `stakeAmount` is 0, otherwise tx will revert
    /// @dev Check an external protocol's staking limit
    /// @param stakeAmount The amount of ETH to stake (can be 0)
    /// @return The actual amount of ETH spent
    function _stake(uint256 stakeAmount) internal virtual returns (uint256);

    /// @dev Must be overridden by inheriting contracts
    /// @inheritdoc ERC4626
    function totalAssets() public view virtual override returns (uint256) {}

    /// @notice Returns the present buffer percentage in WAD. e.g) 10% => 0.1 * 1e18
    function bufferPresentPercentage() external view virtual returns (uint256);

    /////////////////////////////////////////////////////////
    /// NOT IMPLEMENTED METHOD
    /////////////////////////////////////////////////////////

    /// @notice direct deposit,mint,redeem,withdraw should be reverted.
    function deposit(uint256, address) public pure override returns (uint256) {
        revert NotImplemented();
    }

    function mint(uint256, address) public pure override returns (uint256) {
        revert NotImplemented();
    }

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert NotImplemented();
    }

    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert NotImplemented();
    }
}
