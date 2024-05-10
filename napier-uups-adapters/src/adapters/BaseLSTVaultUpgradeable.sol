// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable@4.9.3/token/ERC20/IERC20Upgradeable.sol";
import {WETH} from "../Constants.sol";

import {LSTAdapterStorage} from "../Structs.sol";

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable@4.9.3/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {BaseAdapterUpgradeable} from "../BaseAdapterUpgradeable.sol";

/// @notice Adapter for Liquid Staking Token (LST)
/// @dev This contract is NOT compatible with EIP4626 standard
abstract contract BaseLSTVaultUpgradeable is BaseAdapterUpgradeable, ERC4626Upgradeable {
    /// @dev keccak256(abi.encode(uint256(keccak256("napier.adapter.lst")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant LST_ADAPTER_STORAGE_LOCATION = 0xf38a73bc4b2ec3cca65ebfd6e5f091d1a7d7926bf27004d09fdee655c28c5400;

    uint256 constant BUFFER_PERCENTAGE_PRECISION = 1e18; // 1e18 = 100%
    uint256 constant MIN_BUFFER_PERCENTAGE = 0.01 * 1e18; // 1%

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
        if (_getStorage().rebalancer != msg.sender) revert NotRebalancer();
        _;
    }

    /// @notice Reverts if the caller is not the Tranche
    modifier onlyTranche() {
        if (_getStorage().tranche != msg.sender) revert NotTranche();
        _;
    }

    /// @dev Initialize parameters on a derived contract
    function __BaseLSTVault_init(address _owner) internal onlyInitializing {
        __BaseAdapter_init(_owner);
        __ERC4626_init(IERC20Upgradeable(WETH));
    }

    function _getStorage() internal pure returns (LSTAdapterStorage storage $) {
        assembly {
            $.slot := LST_ADAPTER_STORAGE_LOCATION
        }
    }

    ////////////////////////////////////////////////////////
    /// VIEW METHOD
    ////////////////////////////////////////////////////////

    function underlying() public pure returns (address) {
        return WETH;
    }

    /// @dev Adapter itself is the target token
    function target() public view returns (address) {
        return address(this);
    }

    function rebalancer() public view returns (address) {
        return _getStorage().rebalancer;
    }

    function targetBufferPercentage() public view returns (uint256) {
        return _getStorage().targetBufferPercentage;
    }

    function tranche() public view returns (address) {
        return _getStorage().tranche;
    }

    function scale() external view override returns (uint256) {
        return convertToAssets(1e18);
    }

    ////////////////////////////////////////////////////////
    /// ADMIN METHOD
    ////////////////////////////////////////////////////////

    function setRebalancer(address _rebalancer) external onlyOwner {
        _getStorage().rebalancer = _rebalancer;
    }

    function setTranche(address _tranche) external onlyOwner {
        LSTAdapterStorage storage $ = _getStorage();

        if ($.tranche != address(0)) {
            revert TrancheAlreadySet();
        }
        if (_tranche == address(0)) {
            revert ZeroAddress();
        }
        $.tranche = _tranche;
    }

    /// @notice Set the maximum buffer percentage
    /// @param _targetBufferPercentage The maximum buffer percentage in WAD
    function setTargetBufferPercentage(uint256 _targetBufferPercentage) external onlyRebalancer {
        if (_targetBufferPercentage < MIN_BUFFER_PERCENTAGE || _targetBufferPercentage > BUFFER_PERCENTAGE_PRECISION) {
            revert InvalidBufferPercentage();
        }
        _getStorage().targetBufferPercentage = _targetBufferPercentage;
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
