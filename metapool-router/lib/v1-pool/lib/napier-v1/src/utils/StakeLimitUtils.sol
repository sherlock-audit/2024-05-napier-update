// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

/// @notice Forked from Lido StakeLimitUtils.sol: https://github.com/lidofinance/lido-dao/blob/5fcedc6e9a9f3ec154e69cff47c2b9e25503a78a/contracts/0.4.24/lib/StakeLimitUtils.sol
/// Changes made to the original:
/// - Solidity version pragma updated to 0.8.10 from 0.4.24 and replaced unsupported syntax with new syntax like `type(uint96).max`.
/// - Removed `setStakeLimitUnlimited` function.
/// - Original library uses Unstructured Storage pattern. This library uses `storage` references instead.

// We need to pack four variables into the same 256bit-wide storage slot
// to lower the costs per each staking request.
//
// As a result, slot's memory aligned as follows:
//
// MSB ------------------------------------------------------------------------------> LSB
// 256____________160_________________________128_______________32_____________________ 0
// |_______________|___________________________|________________|_______________________|
// | maxStakeLimit | maxStakeLimitGrowthBlocks | prevStakeLimit | prevStakeBlockNumber  |
// |<-- 96 bits -->|<---------- 32 bits ------>|<-- 96 bits --->|<----- 32 bits ------->|
//
//
// NB: Internal representation conventions:
//
// - the `maxStakeLimitGrowthBlocks` field above represented as follows:
// `maxStakeLimitGrowthBlocks` = `maxStakeLimit` / `stakeLimitIncreasePerBlock`
//           32 bits                 96 bits               96 bits
//
//
// - the "staking paused" state is encoded by `prevStakeBlockNumber` being zero,
// - the "staking unlimited" state is encoded by `maxStakeLimit` being zero and `prevStakeBlockNumber` being non-zero.
//
library StakeLimitTypes {
    /**
     * @dev Storage slot representation. Packed into a single slot
     */
    struct Uint256Data {
        uint256 value;
    }

    /**
     * @dev Internal representation struct (slot-wide)
     */
    struct Data {
        uint32 prevStakeBlockNumber; // block number of the previous stake submit
        uint96 prevStakeLimit; // limit value (<= `maxStakeLimit`) obtained on the previous stake submit
        uint32 maxStakeLimitGrowthBlocks; // limit regeneration speed expressed in blocks (Blocks needed to restore max stake limit from the fully exhausted state)
        uint96 maxStakeLimit; // maximum limit value
    }

    /// @dev Storage offset for `maxStakeLimit` (bits)
    uint256 internal constant MAX_STAKE_LIMIT_OFFSET = 160;
    /// @dev Storage offset for `maxStakeLimitGrowthBlocks` (bits)
    uint256 internal constant MAX_STAKE_LIMIT_GROWTH_BLOCKS_OFFSET = 128;
    /// @dev Storage offset for `prevStakeLimit` (bits)
    uint256 internal constant PREV_STAKE_LIMIT_OFFSET = 32;
    /// @dev Storage offset for `prevStakeBlockNumber` (bits)
    uint256 internal constant PREV_STAKE_BLOCK_NUMBER_OFFSET = 0;

    /**
     * @dev Read stake limit state from the unstructured storage position
     * @param self storage reference to the stake limit state
     */
    function getStorageStakeLimitStruct(Uint256Data storage self) internal view returns (Data memory stakeLimit) {
        uint256 slotValue = self.value;
        stakeLimit.prevStakeBlockNumber = uint32(slotValue >> PREV_STAKE_BLOCK_NUMBER_OFFSET);
        stakeLimit.prevStakeLimit = uint96(slotValue >> PREV_STAKE_LIMIT_OFFSET);
        stakeLimit.maxStakeLimitGrowthBlocks = uint32(slotValue >> MAX_STAKE_LIMIT_GROWTH_BLOCKS_OFFSET);
        stakeLimit.maxStakeLimit = uint96(slotValue >> MAX_STAKE_LIMIT_OFFSET);
    }

    /**
     * @dev Write stake limit state to the unstructured storage position
     * @param self storage reference to the stake limit state
     * @param _data stake limit state structure instance
     */
    function setStorageStakeLimitStruct(Uint256Data storage self, Data memory _data) internal {
        uint256 slotValue = (uint256(_data.prevStakeBlockNumber) << PREV_STAKE_BLOCK_NUMBER_OFFSET) |
            (uint256(_data.prevStakeLimit) << PREV_STAKE_LIMIT_OFFSET) |
            (uint256(_data.maxStakeLimitGrowthBlocks) << MAX_STAKE_LIMIT_GROWTH_BLOCKS_OFFSET) |
            (uint256(_data.maxStakeLimit) << MAX_STAKE_LIMIT_OFFSET);
        assembly {
            sstore(self.slot, slotValue)
        }
    }
}

/**
 * @notice Interface library with helper functions to deal with stake limit struct in a more high-level approach.
 */
library StakeLimitUtils {
    /**
     * @notice Calculate stake limit for the current block.
     * @dev using `_constGasMin` to make gas consumption independent of the current block number
     */
    function calculateCurrentStakeLimit(StakeLimitTypes.Data memory _data) internal view returns (uint256 limit) {
        uint256 stakeLimitIncPerBlock;
        if (_data.maxStakeLimitGrowthBlocks != 0) {
            stakeLimitIncPerBlock = _data.maxStakeLimit / _data.maxStakeLimitGrowthBlocks;
        }

        uint256 blocksPassed = block.number - _data.prevStakeBlockNumber;
        uint256 projectedLimit = _data.prevStakeLimit + blocksPassed * stakeLimitIncPerBlock;

        limit = _constGasMin(projectedLimit, _data.maxStakeLimit);
    }

    /**
     * @notice check if staking is on pause
     */
    function isStakingPaused(StakeLimitTypes.Data memory _data) internal pure returns (bool) {
        return _data.prevStakeBlockNumber == 0;
    }

    /**
     * @notice update stake limit repr with the desired limits
     * @dev input `_data` param is mutated and the func returns effectiv ely the same pointer
     * @param _data stake limit state struct
     * @param _maxStakeLimit stake limit max value
     * @param _stakeLimitIncreasePerBlock stake limit increase (restoration) per block
     */
    function setStakingLimit(
        StakeLimitTypes.Data memory _data,
        uint256 _maxStakeLimit,
        uint256 _stakeLimitIncreasePerBlock
    ) internal view returns (StakeLimitTypes.Data memory) {
        require(_maxStakeLimit != 0, "ZERO_MAX_STAKE_LIMIT");
        require(_maxStakeLimit <= type(uint96).max, "TOO_LARGE_MAX_STAKE_LIMIT");
        require(_maxStakeLimit >= _stakeLimitIncreasePerBlock, "TOO_LARGE_LIMIT_INCREASE");
        require(
            (_stakeLimitIncreasePerBlock == 0) || (_maxStakeLimit / _stakeLimitIncreasePerBlock <= type(uint32).max),
            "TOO_SMALL_LIMIT_INCREASE"
        );

        // reset prev stake limit to the new max stake limit if
        if (
            _data.prevStakeBlockNumber ==
            // staking was paused or
            0 ||
            // staking was unlimited or
            _data.maxStakeLimit == 0 ||
            // new maximum limit value is lower than the value obtained on the previous stake submit
            _maxStakeLimit < _data.prevStakeLimit
        ) {
            _data.prevStakeLimit = uint96(_maxStakeLimit);
        }
        _data.maxStakeLimitGrowthBlocks = _stakeLimitIncreasePerBlock != 0
            ? uint32(_maxStakeLimit / _stakeLimitIncreasePerBlock)
            : 0;

        _data.maxStakeLimit = uint96(_maxStakeLimit);

        if (_data.prevStakeBlockNumber != 0) {
            _data.prevStakeBlockNumber = uint32(block.number);
        }

        return _data;
    }

    /**
     * @notice update stake limit repr after submitting user's eth
     * @dev input `_data` param is mutated and the func returns effectively the same pointer
     * @param _data stake limit state struct
     * @param _newPrevStakeLimit new value for the `prevStakeLimit` field
     */
    function updatePrevStakeLimit(
        StakeLimitTypes.Data memory _data,
        uint256 _newPrevStakeLimit
    ) internal view returns (StakeLimitTypes.Data memory) {
        assert(_newPrevStakeLimit <= type(uint96).max);
        assert(_data.prevStakeBlockNumber != 0);

        _data.prevStakeLimit = uint96(_newPrevStakeLimit);
        _data.prevStakeBlockNumber = uint32(block.number);

        return _data;
    }

    /**
     * @notice set stake limit pause state (on or off)
     * @dev input `_data` param is mutated and the func returns effectively the same pointer
     * @param _data stake limit state struct
     * @param _isPaused pause state flag
     */
    function setStakeLimitPauseState(
        StakeLimitTypes.Data memory _data,
        bool _isPaused
    ) internal view returns (StakeLimitTypes.Data memory) {
        _data.prevStakeBlockNumber = uint32(_isPaused ? 0 : block.number);

        return _data;
    }

    /**
     * @notice find a minimum of two numbers with a constant gas consumption
     * @dev doesn't use branching logic inside
     * @param _lhs left hand side value
     * @param _rhs right hand side value
     */
    function _constGasMin(uint256 _lhs, uint256 _rhs) internal pure returns (uint256 min) {
        uint256 lhsIsLess;
        assembly {
            lhsIsLess := lt(_lhs, _rhs) // lhsIsLess = (_lhs < _rhs) ? 1 : 0
        }
        min = (_lhs * lhsIsLess) + (_rhs * (1 - lhsIsLess));
    }
}
