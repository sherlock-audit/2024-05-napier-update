// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import {CurveTricryptoFactory} from "src/interfaces/external/CurveTricryptoFactory.sol";
import {CurveTricryptoOptimizedWETH} from "src/interfaces/external/CurveTricryptoOptimizedWETH.sol";
import {ITranche} from "@napier/v1-tranche/src/interfaces/ITranche.sol";
import {NapierPool} from "src/NapierPool.sol";
import {NapierRouter} from "src/NapierRouter.sol";
import {IQuoter} from "src/interfaces/IQuoter.sol";

/// @notice This script is used to test Tricrypto pool and router
contract NapierRouterAction is Script {
    CurveTricryptoOptimizedWETH tricrypto = CurveTricryptoOptimizedWETH(vm.envAddress("TRICRYPTO"));
    NapierRouter router = NapierRouter(payable(vm.envAddress("SWAP_ROUTER")));
    IQuoter quoter = IQuoter(vm.envAddress("QUOTER"));
    address pool = vm.envAddress("POOL");

    function run() public {
        address[3] memory coins = CurveTricryptoFactory(tricrypto.factory()).get_coins(address(tricrypto));
        uint256 ONE_UNDERLYING = 10 ** ERC20(coins[0]).decimals();

        vm.startBroadcast();

        for (uint256 i = 0; i < coins.length; i++) {
            IERC20(coins[i]).approve(address(router), type(uint256).max);
            IERC20(ITranche(coins[i]).yieldToken()).approve(address(router), type(uint256).max);
        }
        NapierPool(pool).underlying().approve(address(router), type(uint256).max);
        IERC20(pool).approve(address(router), type(uint256).max);
        {
            uint256 amountIn = 10 * ONE_UNDERLYING;
            uint256 _before = gasleft();
            router.addLiquidity(pool, amountIn, [amountIn, amountIn, amountIn], 0, msg.sender, block.timestamp + 10000);
            console2.log("gas usage: ", _before - gasleft());
        }
        {
            uint256 ptIn = 800 * ONE_UNDERLYING;
            uint256 _before = gasleft();
            router.swapPtForUnderlying(pool, 0, ptIn, 100, msg.sender, block.timestamp + 10000);
            console2.log("gas usage: ", _before - gasleft());
        }
        {
            uint256 ptOut = 800 * ONE_UNDERLYING;
            uint256 _before = gasleft();
            router.swapUnderlyingForPt(pool, 0, ptOut, 10 * ptOut, msg.sender, block.timestamp + 10000);
            console2.log("gas usage: ", _before - gasleft());
        }
        {
            uint256 ptOut = 10 * ONE_UNDERLYING;
            uint256 _before = gasleft();
            router.swapUnderlyingForPt(pool, 1, ptOut, 10 * ptOut, msg.sender, block.timestamp + 10000);
            console2.log("gas usage: ", _before - gasleft());
        }
        {
            uint256 ytIn = 10 * ONE_UNDERLYING;
            uint256 _before = gasleft();
            router.swapYtForUnderlying(pool, 2, ytIn, 100, msg.sender, block.timestamp + 10000);
            console2.log("gas usage: ", _before - gasleft());
        }
        {
            uint256 ytOut = 1 * ONE_UNDERLYING;
            uint256 _before = gasleft();
            router.swapUnderlyingForYt(pool, 2, ytOut, ytOut, msg.sender, block.timestamp + 10000);
            console2.log("gas usage: ", _before - gasleft());
        }
        {
            uint256 liquidity = NapierPool(pool).balanceOf(msg.sender);
            uint256 _before = gasleft();
            router.removeLiquidity(pool, liquidity / 10, 1, [uint256(1), 1, 1], msg.sender, block.timestamp + 10000);
            console2.log("gas usage: ", _before - gasleft());
        }
        {
            uint256 amountIn = 99 * ONE_UNDERLYING;
            uint256 index = 1; // 0, 1, 2
            (, uint256 approxUnderlyingDeposit) =
                quoter.quoteAddLiquidityOneUnderlyingKeepYt(NapierPool(pool), index, amountIn);
            uint256 _before = gasleft();
            router.addLiquidityOneUnderlyingKeepYt(
                pool, index, amountIn, 0, msg.sender, block.timestamp + 10000, approxUnderlyingDeposit
            );
            console2.log("gas usage: ", _before - gasleft());
        }
        vm.stopBroadcast();
    }
}
