// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {Deployer} from "./Deployer.s.sol";

import {IERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/IERC20.sol";
import {IWETH9} from "@napier/v1-tranche/src/interfaces/IWETH9.sol";
import {CurveTricryptoOptimizedWETH} from "@napier/v1-pool/src/interfaces/external/CurveTricryptoOptimizedWETH.sol";
import {INapierPool} from "@napier/v1-pool/src/interfaces/INapierPool.sol";
import {ITranche} from "@napier/v1-tranche/src/interfaces/ITranche.sol";
import {Twocrypto} from "src/interfaces/external/Twocrypto.sol";

import {MockVault} from "../test/mocks/MockVault.sol";
import {MetapoolFactory} from "src/MetapoolFactory.sol";
import {MetapoolRouter} from "src/MetapoolRouter.sol";

interface MockWETH is IWETH9 {
    function mint(address to, uint256 amount) external;
}

contract TestDeploy is Deployer {
    address constant SEPOLIA_TWOCRYPTO_FACTORY = 0x98EE851a00abeE0d95D08cF4CA2BdCE32aeaAF7F;
    uint256 constant IMPLEMENTATION_ID = 0;

    address twocrypto;

    MetapoolFactory.TwocryptoParams twocryptoParams = MetapoolFactory.TwocryptoParams({
        A: 400_000,
        gamma: 0.000145 * 1e18,
        mid_fee: 0.26 * 1e8,
        out_fee: 0.45 * 1e8,
        fee_gamma: 0.00023 * 1e18,
        allowed_extra_profit: 0.000002 * 1e18,
        adjustment_step: 0.000146 * 1e18,
        ma_time: 866,
        /// Note: 1 Tricrypto LP token (coin1) consists of sum of 3 coin for each.
        // 1 Tricrypto LP token (coin1) ~ 3 coin0
        initial_price: 3 * 1e18 // price of the coins[1] against the coins[0]
    });

    function run() public {
        address pt = vm.envAddress("PT");
        address triLSTPool = vm.envAddress("TRI_LST_POOL");

        (address weth,) = INapierPool(triLSTPool).getAssets();

        vm.startBroadcast();

        address vault = address(new MockVault(msg.sender, 0));
        MockWETH(weth).mint(vault, 10000000 ether); // Flash loan reserve

        deploy(msg.sender, weth, triLSTPool, SEPOLIA_TWOCRYPTO_FACTORY, vault);

        twocrypto = deployTwocryptoMeta(
            metapoolFactory, "3LSTPT/HogePT", "3LSTHOGEPT", pt, triLSTPool, IMPLEMENTATION_ID, twocryptoParams
        );
        vm.stopBroadcast();

        console2.log("COPY AND PASTE THE FOLLOWING LINES TO .env FILE");
        console2.log("METAPOOL_FACTORY=%s", metapoolFactory);
        console2.log("METAPOOL_ROUTER=%s", metapoolRouter);
        console2.log("METAPOOL_QUOTER=%s", quoter);
        console2.log("TWOCRYPTO=%s", twocrypto);

        vm.startBroadcast();
        MockWETH(weth).mint(msg.sender, 10000000 ether);
        twocryptoMeta_deposit();
        vm.stopBroadcast();
    }

    function twocryptoMeta_deposit() public {
        address pt = vm.envAddress("PT");
        address triLSTPool = vm.envAddress("TRI_LST_POOL");

        (address weth, address _tricrypto) = INapierPool(triLSTPool).getAssets();
        CurveTricryptoOptimizedWETH tricrypto = CurveTricryptoOptimizedWETH(_tricrypto);

        /// ADD LIQUIDITY TO TRICRYPTO POOL
        address[3] memory coins = [tricrypto.coins(0), tricrypto.coins(1), tricrypto.coins(2)];
        for (uint256 i = 0; i < 3; i++) {
            IWETH9(weth).approve(coins[i], type(uint256).max);
            IERC20(coins[i]).approve(address(tricrypto), type(uint256).max);
            ITranche(coins[i]).issue(msg.sender, 100000 ether);
        }
        uint256 basePoolAmount = tricrypto.add_liquidity([uint256(1000 ether), 1000 ether, 1000 ether], 0);

        /// ADD LIQUIDITY TO TWOCRYPTO POOL
        IWETH9(weth).approve(pt, type(uint256).max);
        uint256 ptAmount = ITranche(pt).issue(msg.sender, 3000 ether);

        IERC20(pt).approve(twocrypto, type(uint256).max);
        tricrypto.approve(twocrypto, type(uint256).max);
        Twocrypto(twocrypto).add_liquidity([ptAmount, basePoolAmount], 0, msg.sender);
    }
}
