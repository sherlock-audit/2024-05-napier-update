// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import {HardhatDeployer} from "hardhat-deployer/HardhatDeployer.sol";

import {Deployer} from "./Deployer.s.sol";
import {NapierHardhatDeployer} from "./NapierHardhatDeployer.sol";

import {IPoolFactory} from "src/interfaces/IPoolFactory.sol";
import "@napier/v1-tranche/src/Constants.sol" as Constants;

/// @dev *** SET THESE VARIABLES ***
contract MainnetParameters {
    address constant TRICRYPTO_FACTORY = 0x0c0e5f2fF0ff18a3be9b835635039256dC4B4963;
    uint256 constant TRICRYPTO_IMPLEMENTATION_ID = 0;

    IPoolFactory.PoolConfig config = IPoolFactory.PoolConfig({
        initialAnchor: 1.2 * 1e18,
        scalarRoot: 8 * 1e18,
        lnFeeRateRoot: 0.000995 * 1e18,
        protocolFeePercent: 80,
        feeRecipient: msg.sender
    });

    // @notice Tricrypto parameters
    Deployer.CurveV2Params params = Deployer.CurveV2Params({
        A: 270_000_000,
        gamma: 0.019 * 1e18,
        mid_fee: 1_000_000, // 0.01%
        out_fee: 20_000_000, // 0.20%
        fee_gamma: 0.22 * 1e18, // 0.22
        allowed_extra_profit: 0.000002 * 1e18,
        adjustment_step: 0.00049 * 1e18,
        ma_time: 3600,
        initial_prices: [uint256(1e18), 1e18]
    });
}

contract ProductionDeploy is Deployer, MainnetParameters {
    /// @notice Env variables: OWNER
    function deployInfra() public {
        address owner = vm.envAddress("OWNER");
        super.deployInfra(owner, Constants.WETH, TRICRYPTO_FACTORY);
    }

    /// @notice Env variables: OWNER, TRANCHE_FACTORY and POOL_FACTORY
    function deployPeripheries() public {
        poolFactory = vm.envAddress("POOL_FACTORY");
        trancheFactory = vm.envAddress("TRANCHE_FACTORY");

        vm.startBroadcast();
        // Deploy TrancheRouter
        trancheRouter = deployTrancheRouter(trancheFactory, Constants.WETH);

        // Deploy Napier SwapRouter
        swapRouter = deployNapierRouter(poolFactory, Constants.WETH);
        IPoolFactory(poolFactory).authorizeCallbackReceiver(swapRouter);

        // Deploy Quoter
        quoter = deployQuoter(poolFactory);
        IPoolFactory(poolFactory).authorizeCallbackReceiver(quoter);
        vm.stopBroadcast();

        console2.log("COPY AND PASTE THE FOLLOWING LINES TO .env FILE");
        console2.log("TRANCHE_ROUTER=%s", trancheRouter);
        console2.log("SWAP_ROUTER=%s", swapRouter);
        console2.log("QUOTER=%s", quoter);
    }

    address tricrypto;
    address pool;

    /// @notice Env variables: UNDERLYING, NAME, SYMBOL, PT1, PT2, PT3, POOL_FACTORY
    function deployPool() public {
        address underlying = vm.envAddress("UNDERLYING");
        string memory name = vm.envString("NAME");
        string memory symbol = vm.envString("SYMBOL");
        address[3] memory pts = [vm.envAddress("PT1"), vm.envAddress("PT2"), vm.envAddress("PT3")];
        poolFactory = vm.envAddress("POOL_FACTORY");
        _deployPool(underlying, name, symbol, pts, config, params);
    }

    function _deployPool(
        address underlying,
        string memory name,
        string memory symbol,
        address[3] memory pts,
        IPoolFactory.PoolConfig memory _config,
        CurveV2Params memory _params
    ) internal {
        require(poolFactory != address(0), "PoolFactory not set");
        vm.startBroadcast();
        tricrypto =
            deployTricrypto(TRICRYPTO_FACTORY, name, symbol, pts, Constants.WETH, TRICRYPTO_IMPLEMENTATION_ID, _params);
        pool = deployPool(poolFactory, tricrypto, underlying, _config);
        vm.stopBroadcast();

        console2.log("TRICRYPTO=%s", tricrypto);
        console2.log("POOL=%s", pool);
    }

    //// DEPLOYER FUNCTIONS ////

    function deployNapierPoolFactory(address _tricryptoFactory, address _owner) public override returns (address) {
        return NapierHardhatDeployer.deployNapierPoolFactory(_tricryptoFactory, _owner);
    }

    function deployQuoter(address factory) public override returns (address) {
        return NapierHardhatDeployer.deployQuoter(factory);
    }

    function deployNapierRouter(address factory, address weth) public override returns (address) {
        return NapierHardhatDeployer.deployNapierRouter(factory, weth);
    }

    function deployTrancheRouter(address factory, address weth) public override returns (address) {
        return NapierHardhatDeployer.deployTrancheRouter(factory, weth);
    }
}

interface Create2Deployer {
    function deploy(uint256 value, bytes32 salt, bytes memory code) external;
    function computeAddress(bytes32 salt, bytes32 codeHash) external view returns (address);
}

contract ProductionDeterministicDeploy is Deployer, MainnetParameters {
    Create2Deployer constant CREATE2_DEPLOYER = Create2Deployer(0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2);

    /// @notice Env variables: OWNER, TRANCHE_FACTORY, POOL_FACTORY, TRANCHE_ROUTER_SALT, SWAP_ROUTER_SALT and QUOTER_SALT
    /// @notice salt is a bytes32 value
    function deployPeripheriesWithSalts() public {
        poolFactory = vm.envAddress("POOL_FACTORY");
        trancheFactory = vm.envAddress("TRANCHE_FACTORY");

        vm.startBroadcast();
        // Deploy TrancheRouter
        trancheRouter = deployTrancheRouter(trancheFactory, Constants.WETH);

        // Deploy Napier SwapRouter
        swapRouter = deployNapierRouter(poolFactory, Constants.WETH);
        IPoolFactory(poolFactory).authorizeCallbackReceiver(swapRouter);

        // Deploy Quoter
        quoter = deployQuoter(poolFactory);
        IPoolFactory(poolFactory).authorizeCallbackReceiver(quoter);
        vm.stopBroadcast();

        console2.log("COPY AND PASTE THE FOLLOWING LINES TO .env FILE");
        console2.log("TRANCHE_ROUTER=%s", trancheRouter);
        console2.log("SWAP_ROUTER=%s", swapRouter);
        console2.log("QUOTER=%s", quoter);
    }

    //// DEPLOYER FUNCTIONS ////

    function deployQuoter(address factory) public override returns (address) {
        return deployCreate2(
            "artifacts/src/lens/Quoter.sol/Quoter.json", abi.encode(factory), vm.envBytes32("QUOTER_SALT")
        );
    }

    function deployNapierRouter(address factory, address weth) public override returns (address) {
        return deployCreate2(
            "artifacts/src/NapierRouter.sol/NapierRouter.json",
            abi.encode(factory, weth),
            vm.envBytes32("SWAP_ROUTER_SALT")
        );
    }

    function deployTrancheRouter(address factory, address weth) public override returns (address) {
        return deployCreate2(
            "artifacts/src/TrancheRouter.sol/TrancheRouter.json",
            abi.encode(factory, weth),
            vm.envBytes32("TRANCHE_ROUTER_SALT")
        );
    }

    function deployCreate2(string memory path, bytes memory constructorArgs, bytes32 salt) public returns (address) {
        bytes memory creationCode = bytes.concat(HardhatDeployer.getBytecode(path), constructorArgs);
        address computed = CREATE2_DEPLOYER.computeAddress(salt, keccak256(creationCode));
        CREATE2_DEPLOYER.deploy(0, salt, creationCode);
        return computed;
    }
}
