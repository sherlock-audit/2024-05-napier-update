// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/Script.sol";

import {TrancheFactory} from "src/TrancheFactory.sol";

import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockAdapter} from "./MockAdapter.sol";
import {StEtherAdapter} from "src/adapters/lido/StEtherAdapter.sol";
import {SFrxETHAdapter} from "src/adapters/frax/SFrxETHAdapter.sol";
import {RETHAdapter} from "src/adapters/rocketPool/RETHAdapter.sol";
import {Swapper} from "src/adapters/rocketPool/Swapper.sol";

contract ProductionDeployer is Script {
    address constant ROCKET_STORAGE = 0x1d8f8f00cfa6758d7bE78336684788Fb0ee0Fa46;
    address constant RETH_ETH_POOL = 0x0f3159811670c117c372428D4E69AC32325e4D0F;

    function run() public {
        address owner = vm.envAddress("OWNER");
        address rebalancer = vm.envAddress("REBALANCER");
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

        stethAdapter.transferOwnership(owner);
        sfrxethAdapter.transferOwnership(owner);
        rethAdapter.transferOwnership(owner);

        vm.stopBroadcast();
    }

    // function run() public {
    //     vm.startBroadcast();
    //     MockERC20 yieldToken = new MockERC20("yield-bearingETH", "ybETH", 18);
    //     MockAdapter mockAdapter = new MockAdapter(vm.envAddress("WETH"), address(yieldToken), 0);
    //     console2.log("address(mockAdapter) :>>", address(mockAdapter));

    //     address t = TrancheFactory(vm.envAddress("TRANCHE_FACTORY")).deployTranche(
    //         address(mockAdapter),
    //         5 * 365 days + block.timestamp,
    //         0
    //     );
    //     vm.stopBroadcast();
    //     console2.log("t :>>", t);
    // }
}
