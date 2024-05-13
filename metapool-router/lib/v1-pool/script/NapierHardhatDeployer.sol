// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import {HardhatDeployer} from "hardhat-deployer/HardhatDeployer.sol";

/// @notice Script to deploy contracts compiled with Hardhat
/// Ensure that size of contracts doesn't exceed the limit of 24KB.
library NapierHardhatDeployer {
    function deployNapierPoolFactory(address tricryptoFactory, address owner) internal returns (address) {
        return HardhatDeployer.deployContract(
            "artifacts/src/PoolFactory.sol/PoolFactory.json",
            abi.encode(tricryptoFactory, owner),
            HardhatDeployer.Library({
                name: "Create2PoolLib",
                path: "src/libs/Create2PoolLib.sol",
                libAddress: HardhatDeployer.deployContract("artifacts/src/libs/Create2PoolLib.sol/Create2PoolLib.json")
            })
        );
    }

    function deployQuoter(address factory) internal returns (address) {
        return HardhatDeployer.deployContract("artifacts/src/lens/Quoter.sol/Quoter.json", abi.encode(factory));
    }

    function deployNapierRouter(address factory, address weth) internal returns (address) {
        return HardhatDeployer.deployContract(
            "artifacts/src/NapierRouter.sol/NapierRouter.json", abi.encode(factory, weth)
        );
    }

    function deployTrancheRouter(address factory, address weth) internal returns (address) {
        return HardhatDeployer.deployContract(
            "artifacts/src/TrancheRouter.sol/TrancheRouter.json", abi.encode(factory, weth)
        );
    }
}
