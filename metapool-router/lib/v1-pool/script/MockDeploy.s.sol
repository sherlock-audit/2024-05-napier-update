// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {Deployer} from "./Deployer.s.sol";
import {NapierHardhatDeployer} from "./NapierHardhatDeployer.sol";

import {IERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import {INapierRouter} from "src/interfaces/INapierRouter.sol";
import {ITranche} from "@napier/v1-tranche/src/interfaces/ITranche.sol";
import {IPoolFactory} from "src/interfaces/IPoolFactory.sol";

interface MockWETH is IERC20 {
    function mint(address to, uint256 amount) external;
}

contract TestDeploy is Deployer {
    address constant SEPOLIA_TRICRYPTO_FACTORY = 0x898af82d705A1e368b4673a253374081Fc221FF1;
    uint256 constant TRICRYPTO_IMPLEMENTATION_ID = 0;

    address tricrypto;
    address pool;

    function run() public {
        trancheFactory = vm.envAddress("TRANCHE_FACTORY");
        address weth = vm.envAddress("WETH");
        address underlying = vm.envAddress("UNDERLYING");
        address[3] memory pts = [vm.envAddress("PT1"), vm.envAddress("PT2"), vm.envAddress("PT3")];

        IPoolFactory.PoolConfig memory poolConfig = IPoolFactory.PoolConfig({
            initialAnchor: 1.2 * 1e18,
            scalarRoot: 8 * 1e18,
            lnFeeRateRoot: 0.000995 * 1e18,
            protocolFeePercent: 80,
            feeRecipient: msg.sender
        });

        // Curve v2 Pool Configuration
        CurveV2Params memory params = CurveV2Params({
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

        deployInfra({owner: msg.sender, weth: weth, tricryptoFactory: SEPOLIA_TRICRYPTO_FACTORY});

        vm.startBroadcast();
        tricrypto = deployTricrypto(
            SEPOLIA_TRICRYPTO_FACTORY,
            "Curve fi Tricrypto UNDERLYING-PT1-PT2-PT3",
            "TriCrypto-UNDERLYING-PT1-PT2-PT3",
            pts,
            weth,
            TRICRYPTO_IMPLEMENTATION_ID,
            params
        );
        pool = deployPool(poolFactory, tricrypto, underlying, poolConfig);
        vm.stopBroadcast();

        console2.log("TRICRYPTO=%s", tricrypto);
        console2.log("POOL=%s", pool);

        vm.startBroadcast();
        uint256 ONE_UNDERLYING = 10 ** ERC20(underlying).decimals();
        MockWETH(weth).mint(msg.sender, 10000000 * ONE_UNDERLYING);

        /// ISSUE PTS
        for (uint256 i = 0; i < pts.length; i++) {
            IERC20(underlying).approve(address(pts[i]), type(uint256).max);
            ITranche(pts[i]).issue(msg.sender, 100000 * ONE_UNDERLYING);
        }

        /// ADD LIQUIDITY TO TRICRYPTO
        for (uint256 i = 0; i < pts.length; i++) {
            IERC20(pts[i]).approve(swapRouter, type(uint256).max);
        }
        uint256 underlyingIn = 3000 * ONE_UNDERLYING;
        IERC20(underlying).approve(swapRouter, underlyingIn);

        /// ADD LIQUIDITY TO NAPIER POOL THROUGH ROUTER
        INapierRouter(swapRouter).addLiquidity(
            pool,
            3000 * ONE_UNDERLYING,
            [1000 * ONE_UNDERLYING, 1000 * ONE_UNDERLYING, 1000 * ONE_UNDERLYING],
            0,
            msg.sender,
            block.timestamp + 10000
        );
        vm.stopBroadcast();
    }
}

contract TestOptimizedDeploy is TestDeploy {
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
