// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/Script.sol";

import {Tranche} from "src/Tranche.sol";
import {TrancheFactory} from "src/TrancheFactory.sol";
import {YieldToken} from "src/YieldToken.sol";

import {StEtherAdapter} from "src/adapters/lido/StEtherAdapter.sol";
import {SFrxETHAdapter} from "src/adapters/frax/SFrxETHAdapter.sol";
import {RETHAdapter} from "src/adapters/rocketPool/RETHAdapter.sol";
import {Swapper} from "src/adapters/rocketPool/Swapper.sol";

contract ProductionDeployer is Script {
    uint256 maturity = vm.envUint("MATURITY");
    uint256 issuanceFee = vm.envUint("ISSUANCE_FEE");
    address rebalancer = vm.envAddress("REBALANCER");

    address constant ROCKET_STORAGE = 0x1d8f8f00cfa6758d7bE78336684788Fb0ee0Fa46;
    address constant RETH_ETH_POOL = 0x0f3159811670c117c372428D4E69AC32325e4D0F;

    function run() public {
        // Use option --private-key 0x... or --ledger
        vm.startBroadcast();

        Swapper swapper = new Swapper(RETH_ETH_POOL);

        StEtherAdapter stethAdapter = new StEtherAdapter({
            _rebalancer: rebalancer,
            _maxStakeLimit: 100 ether,
            _stakeLimitIncreasePerBlock: 0
        });
        SFrxETHAdapter sfrxethAdapter = new SFrxETHAdapter({
            _rebalancer: rebalancer,
            _maxStakeLimit: 100 ether,
            _stakeLimitIncreasePerBlock: 0
        });
        RETHAdapter rethAdapter = new RETHAdapter({
            _rebalancer: rebalancer,
            _swapper: address(swapper),
            _rocketStorageAddress: ROCKET_STORAGE
        });

        console2.log("stethAdapter :>>", address(stethAdapter));
        console2.log("sfrxethAdapter :>>", address(sfrxethAdapter));
        console2.log("rethAdapter :>>", address(rethAdapter));

        // // Only Management can deploy tranches
        // address lidoTranche = factory.deployTranche(address(stethAdapter), maturity, issuanceFee);
        // address frxTranche = factory.deployTranche(address(sfrxethAdapter), maturity, issuanceFee);
        // address rTranche = factory.deployTranche(address(rethAdapter), maturity, issuanceFee);

        // console2.log("lidoTranche :>>", lidoTranche);
        // console2.log("frxTranche :>>", frxTranche);
        // console2.log("rTranche :>>", rTranche);

        vm.stopBroadcast();
    }
}
