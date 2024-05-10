// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

// interfaces
import {IWETH9} from "../../interfaces/IWETH9.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

// libs
import {IERC20, SafeERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/utils/SafeERC20.sol";
import "../../Constants.sol" as Constants;

/// @title UniETHSwapper - A periphery contract for uniETH/WETH swaps
contract UniETHSwapper {
    ISwapRouter immutable router;

    constructor(address _router) {
        router = ISwapRouter(_router);
        SafeERC20.forceApprove(IERC20(Constants.UNIETH), _router, type(uint256).max);
    }

    /// @notice swap uniETH for WETH
    /// @dev Caller must approve this contract to spend WETH
    /// @dev Swapper must send back remaining WETH to the caller after the swap
    /// @param amountIn The amount of uniETH to swap
    /// @param deadline The deadline for the swap
    /// @param minEthOut The minimum amount of WETH to receive
    function swap(uint256 amountIn, uint256 deadline, uint256 minEthOut, bytes calldata data) external {
        SafeERC20.safeTransferFrom(IERC20(Constants.UNIETH), msg.sender, address(this), amountIn);
        // Uniswap V3 uniETH/ETH 0.05 % fee tier pool: https://app.uniswap.org/explore/tokens/ethereum/0xf1376bcef0f78459c0ed0ba5ddce976f1ddf51f4
        router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: Constants.UNIETH,
                tokenOut: Constants.WETH,
                fee: 500, // 0.05%
                recipient: msg.sender,
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: minEthOut,
                sqrtPriceLimitX96: abi.decode(data, (uint160))
            })
        );
    }
}
