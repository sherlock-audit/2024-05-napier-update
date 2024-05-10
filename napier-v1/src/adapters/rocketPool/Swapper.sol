// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

// interfaces
import {IWETH9} from "../../interfaces/IWETH9.sol";
import {ICurveTwoTokenPool} from "./interfaces/ICurveTwoTokenPool.sol";
// libs
import "../../Constants.sol" as Constants;

/// @title Swapper - A periphery contract for rETH/WETH swaps
contract Swapper {
    ICurveTwoTokenPool immutable pool;

    uint256 constant WETH_INDEX = 0;
    uint256 constant RETH_INDEX = 1;

    error TransactionTooOld();

    constructor(address _pool) {
        pool = ICurveTwoTokenPool(_pool);
        IWETH9(Constants.WETH).approve(address(pool), type(uint256).max);
    }

    /// @notice swap eth for rETH
    /// @dev Caller must approve this contract to spend WETH
    /// @dev Swapper must send back remaining WETH to the caller after the swap
    /// @param amountIn The amount of WETH to swap
    /// @param deadline The deadline for the swap
    /// @param minOut The minimum amount of rETH to receive
    function swap(uint256 amountIn, uint256 deadline, uint256 minOut, bytes calldata /* data */) external {
        if (deadline < block.timestamp) revert TransactionTooOld();

        IWETH9(Constants.WETH).transferFrom(msg.sender, address(this), amountIn);
        pool.exchange(WETH_INDEX, RETH_INDEX, amountIn, minOut, false, msg.sender);

        // Send back remaining WETH
        uint256 remainingWETH = IWETH9(Constants.WETH).balanceOf(address(this));
        if (remainingWETH > 0) IWETH9(Constants.WETH).transfer(msg.sender, remainingWETH);
    }
}
