// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

/// @title Uniswap V3 Swap Router
interface ISwapRouter {
    /// Note that fee is in hundredths of basis points (e.g. the fee for a pool at the 0.3% tier is 3000; the fee for a pool at the 0.01% tier is 100).
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps amountIn of one token for as much as possible of another token
    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
}
