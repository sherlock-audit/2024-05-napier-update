// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "../mocks/MockStakeLimitUtils.sol";

import {SafeCast} from "@openzeppelin/contracts@4.9.3/utils/math/SafeCast.sol";

/// @dev This test is forked from the original Lido DAO test
/// https://github.com/lidofinance/lido-dao/blob/5fcedc6e9a9f3ec154e69cff47c2b9e25503a78a/test/0.4.24/staking-limit.test.js
contract StakingLimitsTest is Test {
    using SafeCast for *;

    MockStakeLimitUtils public limits;

    function setUp() public {
        limits = new MockStakeLimitUtils();
    }

    function testEncodeZeros() public {
        uint256 slot = limits.setStorageStakeLimitStruct(0, 0, 0, 0);
        assertEq(slot, 0);

        StakeLimitTypes.Data memory decodedSlot = limits.getStorageStakeLimit(slot);
        assertEq(decodedSlot.prevStakeBlockNumber, 0);
        assertEq(decodedSlot.prevStakeLimit, 0);
        assertEq(decodedSlot.maxStakeLimitGrowthBlocks, 0);
        assertEq(decodedSlot.maxStakeLimit, 0);
    }

    function testCheckStakingPauseAtStart() public {
        uint256 slot = limits.setStorageStakeLimitStruct(0, 0, 0, 0);
        bool paused = limits.isStakingPaused(slot);
        assertTrue(paused, "staking not paused");
    }

    function testCheckStakingPauseWithBlockNumber() public {
        uint32 prevStakeBlockNumber = 10;
        uint256 slot2 = limits.setStorageStakeLimitStruct(prevStakeBlockNumber, 0, 0, 0);
        bool paused2 = limits.isStakingPaused(slot2);
        assertFalse(paused2, "staking paused");
    }

    function testCheckStakingPauseUnpause() public {
        bool paused;
        uint256 slot = limits.setStorageStakeLimitStruct(1, 1, 1, 1);
        paused = limits.isStakingPaused(slot);
        assertFalse(paused, "staking paused");

        uint256 slot2 = limits.setStakeLimitPauseState(slot, true);
        paused = limits.isStakingPaused(slot2);
        assertTrue(paused, "staking not paused");

        uint256 slot3 = limits.setStakeLimitPauseState(slot, false);
        paused = limits.isStakingPaused(slot3);
        assertFalse(paused, "staking paused");
    }

    function testStakeLimitIncreaseLessThanMaxStake() public {
        uint96 maxStakeLimit = 5;
        uint32 maxStakeLimitIncreasePerBlock = 0;
        uint256 slot = limits.setStorageStakeLimitStruct(0, 0, 0, 0);
        limits.setStakingLimit(slot, maxStakeLimit, maxStakeLimitIncreasePerBlock);

        maxStakeLimit = 5;
        maxStakeLimitIncreasePerBlock = 5;
        limits.setStakingLimit(slot, maxStakeLimit, maxStakeLimitIncreasePerBlock);

        maxStakeLimit = 5;
        uint32 maxStakeLimitGrowthBlocks = 6;
        vm.expectRevert("TOO_LARGE_LIMIT_INCREASE");
        limits.setStakingLimit(slot, maxStakeLimit, maxStakeLimitGrowthBlocks);
    }

    function testStakeLimitRevertsOnLargeValues_RevertWhen_TooLargeMaxStakeLimit() public {
        uint256 maxStakeLimit = uint256(type(uint96).max) + 1;
        uint32 maxStakeLimitIncreasePerBlock = 1;
        uint256 slot = limits.setStorageStakeLimitStruct(0, 0, 0, 0);
        vm.expectRevert("TOO_LARGE_MAX_STAKE_LIMIT");
        limits.setStakingLimit(slot, maxStakeLimit, maxStakeLimitIncreasePerBlock);
    }

    function testStakeLimitRevertsOnLargeValues_RevertWhen_TooSmallLimitIncrease() public {
        uint96 maxStakeLimit = uint96(10 ** 18 * 2);
        uint32 maxStakeLimitIncreasePerBlock = 10;
        uint256 slot = limits.setStorageStakeLimitStruct(0, 0, 0, 0);
        vm.expectRevert("TOO_SMALL_LIMIT_INCREASE");
        limits.setStakingLimit(slot, maxStakeLimit, maxStakeLimitIncreasePerBlock);
    }

    function testUpdateCalculateStakeLimitWithDifferentBlocks() public {
        uint256 blockNumber = block.number;

        uint96 maxStakeLimit = 100;
        uint32 increasePerBlock = 50;
        uint32 maxStakeLimitGrowthBlocks = (maxStakeLimit / increasePerBlock).toUint32();

        uint256 slot = limits.setStorageStakeLimitStruct(
            blockNumber.toUint32(),
            0,
            maxStakeLimitGrowthBlocks,
            maxStakeLimit
        );

        uint96 currentStakeLimit2 = limits.calculateCurrentStakeLimit(slot).toUint96();
        assertEq(currentStakeLimit2, 0);

        vm.roll(blockNumber + 1);
        currentStakeLimit2 = limits.calculateCurrentStakeLimit(slot).toUint96();
        assertEq(currentStakeLimit2, 50);

        vm.roll(blockNumber + 1 + 3);
        currentStakeLimit2 = limits.calculateCurrentStakeLimit(slot).toUint96();
        assertEq(currentStakeLimit2, 100);
    }

    function testUpdateStakeLimit() public {
        uint256 blockNumber = block.number;

        uint96 maxStakeLimit = 100;
        uint32 increasePerBlock = 50;
        uint32 maxStakeLimitGrowthBlocks = (maxStakeLimit / increasePerBlock).toUint32();

        uint256 slot = limits.setStorageStakeLimitStruct(
            blockNumber.toUint32(),
            0,
            maxStakeLimitGrowthBlocks,
            maxStakeLimit
        );
        StakeLimitTypes.Data memory decodedSlot = limits.getStorageStakeLimit(slot);
        assertEq(decodedSlot.prevStakeBlockNumber, blockNumber);
        assertEq(decodedSlot.prevStakeLimit, 0);

        vm.roll(blockNumber + 3);

        uint96 currentStakeLimit2 = limits.calculateCurrentStakeLimit(slot).toUint96();
        assertEq(currentStakeLimit2, maxStakeLimit);

        uint96 deposit = 87;
        uint256 newSlot = limits.updatePrevStakeLimit(slot, currentStakeLimit2 - deposit);
        StakeLimitTypes.Data memory decodedNewSlot = limits.getStorageStakeLimit(newSlot);
        assertEq(decodedNewSlot.prevStakeBlockNumber, blockNumber + 3);
        assertEq(decodedNewSlot.prevStakeLimit, 13);

        // checking staking recovery
        vm.roll(blockNumber + 4);
        currentStakeLimit2 = limits.calculateCurrentStakeLimit(newSlot).toUint96();
        assertEq(currentStakeLimit2, 13 + increasePerBlock);

        vm.roll(blockNumber + 5);
        currentStakeLimit2 = limits.calculateCurrentStakeLimit(newSlot).toUint96();
        assertEq(currentStakeLimit2, maxStakeLimit);
    }

    function testMaxValues() public {
        uint32 max32 = type(uint32).max; // uint32
        uint96 max96 = type(uint96).max; // uint96

        uint96 maxStakeLimit = max96; // uint96
        uint32 maxStakeLimitGrowthBlocks = max32;
        uint96 maxPrevStakeLimit = max96; // uint96
        uint32 maxBlock = max32; // uint32

        // check that we CAN set max value
        uint256 maxSlot = limits.setStorageStakeLimitStruct(
            maxBlock,
            maxPrevStakeLimit,
            maxStakeLimitGrowthBlocks,
            maxStakeLimit
        );
        uint256 maxUint256 = type(uint256).max;
        assertEq(maxSlot, maxUint256);

        StakeLimitTypes.Data memory decodedRaw = limits.getStorageStakeLimit(maxSlot);

        uint96 decodedMaxLimit = decodedRaw.maxStakeLimit;
        uint32 decodedMaxStakeLimitGrowthBlocks = decodedRaw.maxStakeLimitGrowthBlocks;
        uint96 decodedPrevStakeLimit = decodedRaw.prevStakeLimit;
        uint32 decodedPrevStakeBlockNumber = decodedRaw.prevStakeBlockNumber;

        assertEq(decodedMaxLimit, max96);
        assertEq(decodedMaxStakeLimitGrowthBlocks, max32);
        assertEq(decodedPrevStakeLimit, max96);
        assertEq(decodedPrevStakeBlockNumber, max32);
    }

    function testConstantGasForCalculateCurrentStakeLimitRegardlessBlockNumber() public {}

    function testSetStakingLimitResetsPrevStakeLimitToTheNewMax() public {
        uint256 blockNumber = block.number;
        uint96 maxStakeLimit = 10000;
        uint32 maxStakeLimitGrowthBlocks = 100;
        uint96 prevStakeLimit = 5000;

        // set initial values
        uint256 slot = limits.setStorageStakeLimitStruct(
            blockNumber.toUint32(),
            prevStakeLimit,
            maxStakeLimitGrowthBlocks,
            maxStakeLimit
        );

        // check their correctness
        StakeLimitTypes.Data memory decodedRaw = limits.getStorageStakeLimit(slot);
        assertEq(decodedRaw.maxStakeLimit, maxStakeLimit);
        assertEq(decodedRaw.maxStakeLimitGrowthBlocks, maxStakeLimitGrowthBlocks);
        assertEq(decodedRaw.prevStakeLimit, prevStakeLimit);
        assertEq(decodedRaw.prevStakeBlockNumber, blockNumber);

        // pause stake
        slot = limits.setStakeLimitPauseState(slot, true);
        assertTrue(limits.isStakingPaused(slot));

        // setStakeLimit again
        slot = limits.setStakingLimit(slot, maxStakeLimit, maxStakeLimit / maxStakeLimitGrowthBlocks);
        decodedRaw = limits.getStorageStakeLimit(slot);
        assertEq(decodedRaw.prevStakeLimit, maxStakeLimit);

        // setStakeLimit again
        slot = limits.setStakingLimit(slot, maxStakeLimit * 2, 10);
        decodedRaw = limits.getStorageStakeLimit(slot);
        assertEq(decodedRaw.prevStakeLimit, maxStakeLimit * 2);

        // set stake limit lower than before
        slot = limits.setStakingLimit(slot, maxStakeLimit / 2, 100);
        decodedRaw = limits.getStorageStakeLimit(slot);
        assertEq(decodedRaw.prevStakeLimit, maxStakeLimit / 2);
    }
}
