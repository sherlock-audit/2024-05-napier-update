// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

import "forge-std/Test.sol";

import {Deployer} from "./Deployer.s.sol";

import {MetapoolFactory} from "src/MetapoolFactory.sol";
import {MetapoolRouter} from "src/MetapoolRouter.sol";
import {Quoter} from "src/Quoter.sol";
import "@napier/v1-tranche/src/Constants.sol" as Constants;

/// @dev *** SET THESE VARIABLES ***
contract MainnetParameters {
    address constant MAINNET_TWOCRYPTO_FACTORY = 0x98EE851a00abeE0d95D08cF4CA2BdCE32aeaAF7F;
    address constant MAINNET_BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    MetapoolFactory.TwocryptoParams twocryptoParams = MetapoolFactory.TwocryptoParams({
        A: 400_000,
        gamma: 0.000145 * 1e18,
        mid_fee: 0.26 * 1e8,
        out_fee: 0.45 * 1e8,
        fee_gamma: 0.00023 * 1e18,
        allowed_extra_profit: 0.000002 * 1e18,
        adjustment_step: 0.000146 * 1e18,
        ma_time: 866,
        initial_price: 3 * 1e18 // price of the coins[1] against the coins[0]
    });
}

contract ProductionDeploy is Deployer, MainnetParameters {
    address twocrypto;

    /// @notice envs : OWNER and TRI_LST_POOL
    function deployFactoryAndPeripheries() public {
        deploy(
            vm.envAddress("OWNER"),
            Constants.WETH,
            vm.envAddress("TRI_LST_POOL"),
            MAINNET_TWOCRYPTO_FACTORY,
            MAINNET_BALANCER_VAULT
        );
    }

    /// @notice envs : OWNER, TRI_LST_POOL, METAPOOL_FACTORY, PT, NAME, SYMBOL and IMPLEMENTATION_ID
    function deployTwocryptoMeta() public {
        metapoolFactory = vm.envAddress("METAPOOL_FACTORY");

        vm.startBroadcast();
        twocrypto = deployTwocryptoMeta({
            _metaFactory: metapoolFactory,
            _name: vm.envString("NAME"),
            _symbol: vm.envString("SYMBOL"),
            _pt: vm.envAddress("PT"),
            _triLSTPool: vm.envAddress("TRI_LST_POOL"),
            _implementationIdx: vm.envUint("IMPLEMENTATION_ID"),
            _params: twocryptoParams
        });
        vm.stopBroadcast();
        console2.log("TWOCRYPTO=%s", twocrypto);
    }
}

contract ProductionDeployCREATE2 is ProductionDeploy {
    //// DEPLOYER FUNCTIONS ////

    function deployQuoter(address _metaFactory, address _valut) internal override returns (address) {
        return deployCreate2(type(Quoter).creationCode, abi.encode(_metaFactory, _valut), vm.envBytes32("QUOTER_SALT"));
    }

    function deployMetapoolRouter(address _metaFactory, address _triLSTPool, address _valut)
        internal
        override
        returns (address)
    {
        return deployCreate2(
            type(MetapoolRouter).creationCode,
            abi.encode(_metaFactory, _triLSTPool, _valut),
            vm.envBytes32("ROUTER_SALT")
        );
    }

    function deployMetapoolFactory(address _owner, address _weth, address _twocryptoFactory)
        internal
        override
        returns (address)
    {
        return deployCreate2(
            type(MetapoolFactory).creationCode,
            abi.encode(_owner, _weth, _twocryptoFactory),
            vm.envBytes32("FACTORY_SALT")
        );
    }

    function deployCreate2(bytes memory code, bytes memory constructorArgs, bytes32 salt) internal returns (address) {
        bytes memory creationCode = bytes.concat(code, constructorArgs);
        address computed = CREATE2_DEPLOYER.computeAddress(salt, keccak256(creationCode));
        CREATE2_DEPLOYER.deploy(0, salt, creationCode);
        return computed;
    }
}
