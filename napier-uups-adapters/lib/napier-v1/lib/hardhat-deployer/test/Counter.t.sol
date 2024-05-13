// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test, console2} from "forge-std/Test.sol";
import {HardhatDeployer} from "src/HardhatDeployer.sol";
import {Counter} from "src/mocks/Counter.sol";

contract CounterTest is Test {
    Counter public counter;

    function setUp() public {
        counter = Counter(HardhatDeployer.deployContract("artifacts/src/mocks/Counter.sol/Counter.json", abi.encode(1)));
    }

    function test_constructor() public {
        assertEq(counter.number(), 1);
    }

    function test_Increment() public {
        counter.setNumber(0);
        counter.increment();
        assertEq(counter.number(), 1);
    }

    function testFuzz_SetNumber(uint256 x) public {
        counter.setNumber(x);
        assertEq(counter.number(), x);
    }
}
