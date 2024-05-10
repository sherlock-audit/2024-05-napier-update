// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {INapierPool} from "@napier/v1-pool/src/interfaces/INapierPool.sol";
import {ITranche} from "@napier/v1-tranche/src/interfaces/ITranche.sol";
import {TwocryptoFactory} from "./interfaces/external/TwocryptoFactory.sol";

import {Errors} from "./Errors.sol";

import {Ownable2Step} from "@openzeppelin/contracts@4.9.3/access/Ownable2Step.sol";

/// @notice A factory contract for deploying TwoCrypto metapools (Technically it is just regular twocrypto pool with PT and tricrypto LP token)
/// @dev It's a wrapper around the TwocryptoFactory contract with additional checks
contract MetapoolFactory is Ownable2Step {
    /// @notice The TwocryptoFactory contract
    TwocryptoFactory public immutable twocryptoFactory;

    /// @notice The WETH9 address
    address public immutable WETH9;

    /// @notice Mapping (metapool -> deployed by this factory). True if the metapool was deployed by this factory
    mapping(address metapool => bool) public isPtMetapool;

    /// @notice A parameter struct for deploying a metapool
    struct TwocryptoParams {
        uint256 A;
        uint256 gamma;
        uint256 mid_fee;
        uint256 out_fee;
        uint256 fee_gamma;
        uint256 allowed_extra_profit;
        uint256 adjustment_step;
        uint256 ma_time;
        uint256 initial_price;
    }

    constructor(address owner, address _WETH9, TwocryptoFactory _twocryptoFactory) {
        WETH9 = _WETH9;
        twocryptoFactory = _twocryptoFactory;

        _transferOwnership(owner);
    }

    /// @notice Deploys a TwocryptoNG from Factory contract
    /// NOTE: This metapool is not typical metapool, Technically it is just a pool with 2 volatile coins,
    /// where one of the coins is PT, and the other is triLST-PT tricrypto LP token (like rETH-PT, sfrxETH-PT, stETH-PT)
    /// @dev Reverts if:
    /// - The NapierPool's underlying is not WETH
    /// - The PT's underlying is not WETH
    /// - Maturity of the PT is longer than the maturity of the NapierPool
    /// - Name or symbol are too long
    /// @param pt The Principal Token address
    /// @param pool The NapierPool address for the metapool to use (Underlying token of those PTs must be WETH)
    /// @custom:param implementation_idx The index of the implementation to use
    /// @param name The name of the metapool
    /// @param symbol The symbol of the metapool
    /// @param params The metapool parameters
    /// @return metapool The address of the deployed metapool (coin0 is PT, coin1 is tricrypto LP token)
    function deployMetapool(
        address pt,
        address pool,
        uint256, /* implementation_idx */
        string calldata name,
        string calldata symbol,
        TwocryptoParams calldata params
    ) external onlyOwner returns (address metapool) {
        (address underlying, address tricrypto) = INapierPool(pool).getAssets();

        /// CHECK
        if (underlying != WETH9) revert Errors.MetapoolFactoryWETHMismatch();
        if (ITranche(pt).underlying() != WETH9) revert Errors.MetapoolFactoryWETHMismatch();
        if (ITranche(pt).maturity() > INapierPool(pool).maturity()) revert Errors.MetapoolFactoryMaturityTooLong();

        // Deploy twocrypto
        address[2] memory coins = [pt, tricrypto];
        uint256 implementation_idx;
        // Workaround for stack too deep error
        assembly { implementation_idx := calldataload(0x44) }// forgefmt: disable-line
        bytes memory data = abi.encodeWithSelector(
            TwocryptoFactory.deploy_pool.selector,
            name, // name
            symbol, // symbol
            coins, // coins
            implementation_idx, // implementation_idx
            // Avoid stack too deep error by passing params as a struct instead of individual parameters
            // Note: the order of members in the struct must match the order of the parameters in the function
            params
        );
        (bool success, bytes memory ret) = address(twocryptoFactory).call(data);
        if (!success) revert Errors.MetapoolFactoryFailedToDeployMetapool();
        metapool = abi.decode(ret, (address));
        isPtMetapool[metapool] = true;
    }
}
