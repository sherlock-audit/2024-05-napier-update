// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import {VyperDeployer} from "../lib/VyperDeployer.sol";

import {IWETH9} from "@napier/v1-tranche/src/interfaces/IWETH9.sol";
import {CurveTricryptoFactory} from "src/interfaces/external/CurveTricryptoFactory.sol";
import {IPoolFactory} from "src/interfaces/IPoolFactory.sol";

import {TrancheFactory} from "@napier/v1-tranche/src/TrancheFactory.sol";
import {PoolFactory} from "src/PoolFactory.sol";
import {TrancheRouter} from "src/TrancheRouter.sol";
import {NapierRouter} from "src/NapierRouter.sol";
import {Quoter} from "src/lens/Quoter.sol";

contract Deployer is Script {
    address trancheFactory;
    address poolFactory;
    address trancheRouter;
    address swapRouter;
    address quoter;

    function deployInfra(address owner, address weth, address tricryptoFactory) public {
        vm.startBroadcast();
        // // TrancheFactory
        // trancheFactory = deployTrancheFactory(owner);

        // Deploy  PoolFactory
        poolFactory = deployNapierPoolFactory(tricryptoFactory, owner);

        // Deploy TrancheRouter
        trancheRouter = deployTrancheRouter(trancheFactory, weth);

        // Deploy Napier SwapRouter
        swapRouter = deployNapierRouter(poolFactory, weth);
        PoolFactory(poolFactory).authorizeCallbackReceiver(swapRouter);

        // Deploy Quoter
        quoter = deployQuoter(poolFactory);
        PoolFactory(poolFactory).authorizeCallbackReceiver(quoter);
        vm.stopBroadcast();

        console2.log("COPY AND PASTE THE FOLLOWING LINES TO .env FILE");
        console2.log("POOL_FACTORY=%s", poolFactory);
        console2.log("TRANCHE_FACTORY=%s", trancheFactory);
        console2.log("TRANCHE_ROUTER=%s", trancheRouter);
        console2.log("SWAP_ROUTER=%s", swapRouter);
        console2.log("QUOTER=%s", quoter);
        console2.log("LIB_CREATE2_POOL='Check broadcast log'");
    }

    //// Deployer functions ////

    function deployTrancheFactory(address owner) public virtual returns (address) {
        return address(new TrancheFactory(owner));
    }

    function deployNapierPoolFactory(address tricryptoFactory, address owner) public virtual returns (address) {
        return address(new PoolFactory(tricryptoFactory, owner));
    }

    function deployQuoter(address factory) public virtual returns (address) {
        return address(new Quoter(PoolFactory(factory)));
    }

    function deployNapierRouter(address factory, address weth) public virtual returns (address) {
        return address(new NapierRouter(PoolFactory(factory), IWETH9(weth)));
    }

    function deployTrancheRouter(address factory, address weth) public virtual returns (address) {
        return address(new TrancheRouter(TrancheFactory(factory), IWETH9(weth)));
    }

    struct CurveV2Params {
        uint256 A;
        uint256 gamma;
        uint256 mid_fee;
        uint256 out_fee;
        uint256 fee_gamma;
        uint256 allowed_extra_profit;
        uint256 adjustment_step;
        uint256 ma_time;
        uint256[2] initial_prices;
    }

    function deployTricrypto(
        address factory,
        string memory name,
        string memory symbol,
        address[3] memory pts,
        address weth,
        uint256 implementationId,
        CurveV2Params memory params
    ) public returns (address) {
        bytes memory data = abi.encodeWithSignature(
            "deploy_pool(string,string,address[3],address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[2])",
            name,
            symbol,
            pts,
            weth,
            implementationId,
            // The order of the members in the struct must match the order of the arguments in the function signature
            params
        );
        (bool s, bytes memory ret) = factory.call(data);
        if (!s) revert("CurveV2Factory: deploy_pool failed");
        return abi.decode(ret, (address));
    }

    function deployTricryptoFactory(VyperDeployer deployer, address admin) public virtual returns (address) {
        address math = deployer.deployContract("lib/tricrypto-ng/contracts/main/CurveCryptoMathOptimized3", "shanghai");
        address views =
            deployer.deployContract("lib/tricrypto-ng/contracts/main/CurveCryptoViews3Optimized", "shanghai");
        address amm_blueprint =
            deployer.deployBlueprint("lib/tricrypto-ng/contracts/main/CurveTricryptoOptimizedWETH", "shanghai");
        address factory = deployer.deployContract(
            "lib/tricrypto-ng/contracts/main/CurveTricryptoFactory", abi.encode(admin, admin), "shanghai"
        );
        CurveTricryptoFactory(factory).set_pool_implementation(amm_blueprint, 0);
        CurveTricryptoFactory(factory).set_views_implementation(views);
        CurveTricryptoFactory(factory).set_math_implementation(math);
        return factory;
    }

    function deployTranche(address factory, address adapter, uint256 maturity, uint256 issuanceFee)
        public
        returns (address)
    {
        return TrancheFactory(factory).deployTranche(adapter, maturity, issuanceFee);
    }

    function deployPool(
        address factory,
        address tricrypto,
        address underlying,
        IPoolFactory.PoolConfig memory poolConfig
    ) public returns (address) {
        return IPoolFactory(factory).deploy(tricrypto, underlying, poolConfig);
    }
}
