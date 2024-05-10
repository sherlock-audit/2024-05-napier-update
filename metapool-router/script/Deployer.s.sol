// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

import "forge-std/Script.sol";

import {INapierPool} from "@napier/v1-pool/src/interfaces/INapierPool.sol";
import {TwocryptoFactory} from "src/interfaces/external/TwocryptoFactory.sol";
import {Twocrypto} from "src/interfaces/external/Twocrypto.sol";
import {IVault} from "src/interfaces/external/balancer/IVault.sol";

import {MetapoolFactory} from "src/MetapoolFactory.sol";
import {MetapoolRouter} from "src/MetapoolRouter.sol";
import {Quoter} from "src/Quoter.sol";

interface Create2Deployer {
    function deploy(uint256 value, bytes32 salt, bytes memory code) external;
    function computeAddress(bytes32 salt, bytes32 codeHash) external view returns (address);
}

contract Deployer is Script {
    Create2Deployer constant CREATE2_DEPLOYER = Create2Deployer(0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2);

    address metapoolFactory;
    address metapoolRouter;
    address quoter;

    function deploy(address _owner, address _weth, address _triLSTPool, address _twocryptoFactory, address _vault)
        public
    {
        vm.startBroadcast();
        // Deploy MetapoolFactory
        metapoolFactory = deployMetapoolFactory(_owner, _weth, _twocryptoFactory);

        // Deploy MetapoolRouter
        metapoolRouter = deployMetapoolRouter(metapoolFactory, _triLSTPool, _vault);

        // Deploy Quoter
        quoter = deployQuoter(metapoolFactory, _vault);
        vm.stopBroadcast();

        console2.log("COPY AND PASTE THE FOLLOWING LINES TO .env FILE");
        console2.log("METAPOOL_FACTORY=%s", metapoolFactory);
        console2.log("METAPOOL_ROUTER=%s", metapoolRouter);
        console2.log("METAPOOL_QUOTER=%s", quoter);
    }

    //// Deployer functions ////

    function deployMetapoolFactory(address _owner, address _weth, address _twocryptoFactory)
        internal
        virtual
        returns (address)
    {
        return address(new MetapoolFactory(_owner, _weth, TwocryptoFactory(_twocryptoFactory)));
    }

    function deployMetapoolRouter(address _metaFactory, address _triLSTPool, address _valut)
        internal
        virtual
        returns (address)
    {
        return address(new MetapoolRouter(MetapoolFactory(_metaFactory), INapierPool(_triLSTPool), IVault(_valut)));
    }

    function deployQuoter(address _metaFactory, address _valut) internal virtual returns (address) {
        return address(new Quoter(MetapoolFactory(_metaFactory), IVault(_valut)));
    }

    function deployTwocryptoMeta(
        address _metaFactory,
        string memory _name,
        string memory _symbol,
        address _pt,
        address _triLSTPool,
        uint256 _implementationIdx,
        MetapoolFactory.TwocryptoParams memory _params
    ) internal returns (address) {
        bytes memory data = abi.encodeWithSelector(
            MetapoolFactory.deployMetapool.selector,
            _pt,
            _triLSTPool,
            _implementationIdx,
            // Too long string causes Twocrypto to revert in constructor
            _name,
            _symbol,
            // The order of the members in the struct must match the order of the arguments in the function signature
            _params
        );
        (bool s, bytes memory ret) = _metaFactory.call(data);
        if (!s) revert("TwoCryptoMeta: deploy_pool failed");
        return abi.decode(ret, (address));
    }
}
