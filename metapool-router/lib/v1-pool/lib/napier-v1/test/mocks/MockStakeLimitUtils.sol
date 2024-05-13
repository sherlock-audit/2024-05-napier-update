// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "src/utils/StakeLimitUtils.sol";

contract MockStakeLimitUtils {
    using StakeLimitTypes for StakeLimitTypes.Uint256Data;
    using StakeLimitTypes for StakeLimitTypes.Data;
    using StakeLimitUtils for StakeLimitTypes.Data;

    event StakeLimitValue(uint256 currentLimit);

    StakeLimitTypes.Uint256Data private packedDdata;

    function getStorageStakeLimit(uint256 slotValue) public returns (StakeLimitTypes.Data memory) {
        packedDdata.value = slotValue;
        return packedDdata.getStorageStakeLimitStruct();
    }

    function setStorageStakeLimitStruct(
        uint32 _prevStakeBlockNumber,
        uint96 _prevStakeLimit,
        uint32 _maxStakeLimitGrowthBlocks,
        uint96 _maxStakeLimit
    ) public returns (uint256 ret) {
        StakeLimitTypes.Data memory data;
        data.prevStakeBlockNumber = _prevStakeBlockNumber;
        data.prevStakeLimit = _prevStakeLimit;
        data.maxStakeLimitGrowthBlocks = _maxStakeLimitGrowthBlocks;
        data.maxStakeLimit = _maxStakeLimit;

        packedDdata.setStorageStakeLimitStruct(data);
        return packedDdata.value;
    }

    function calculateCurrentStakeLimit(uint256 _slotValue) public returns (uint256 limit) {
        packedDdata.value = _slotValue;
        return packedDdata.getStorageStakeLimitStruct().calculateCurrentStakeLimit();
    }

    function emitCurrentStakeLimit(uint256 _slotValue) public {
        uint256 limit = calculateCurrentStakeLimit(_slotValue);
        emit StakeLimitValue(limit);
    }

    function isStakingPaused(uint256 _slotValue) public returns (bool) {
        packedDdata.value = _slotValue;
        return packedDdata.getStorageStakeLimitStruct().isStakingPaused();
    }

    function setStakingLimit(
        uint256 _slotValue,
        uint256 _maxStakeLimit,
        uint256 _stakeLimitIncreasePerBlock
    ) public returns (uint256) {
        packedDdata.value = _slotValue;
        packedDdata.setStorageStakeLimitStruct(
            packedDdata.getStorageStakeLimitStruct().setStakingLimit(_maxStakeLimit, _stakeLimitIncreasePerBlock)
        );
        return packedDdata.value;
    }

    function updatePrevStakeLimit(uint256 _slotValue, uint256 _newPrevLimit) public returns (uint256) {
        packedDdata.value = _slotValue;
        packedDdata.setStorageStakeLimitStruct(
            packedDdata.getStorageStakeLimitStruct().updatePrevStakeLimit(_newPrevLimit)
        );
        return packedDdata.value;
    }

    function setStakeLimitPauseState(uint256 _slotValue, bool _isPaused) public returns (uint256) {
        packedDdata.value = _slotValue;
        packedDdata.setStorageStakeLimitStruct(
            packedDdata.getStorageStakeLimitStruct().setStakeLimitPauseState(_isPaused)
        );
        return packedDdata.value;
    }
}
