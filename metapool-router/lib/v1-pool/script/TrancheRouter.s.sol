// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/Script.sol";

import {IWETH9} from "@napier/v1-tranche/src/interfaces/IWETH9.sol";
import {ITrancheFactory} from "@napier/v1-tranche/src/interfaces/ITrancheFactory.sol";
import {TrancheRouter} from "src/TrancheRouter.sol";

contract TrancheRouterDeploy is Script {
    function run() public {
        address weth = vm.envAddress("WETH");
        ITrancheFactory trancheFactory = ITrancheFactory(vm.envAddress("TRANCHE_FACTORY"));

        vm.startBroadcast();
        TrancheRouter trancheRouter = new TrancheRouter(trancheFactory, IWETH9(weth));
        vm.stopBroadcast();

        console2.log("TRANCHE_ROUTER=%s", address(trancheRouter));
    }
}
