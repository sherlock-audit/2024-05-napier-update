// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import {ApproxParams} from "@napier/v1-pool/src/interfaces/ApproxParams.sol";

interface IMetapoolRouter {
    function swapETHForPt(
        address metapool,
        uint256 ptAmount,
        uint256 maxEthSpent,
        uint256 minPtOut,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 ethSpent);

    function swapPtForETH(address metapool, uint256 ptAmount, uint256 minEthOut, address recipient, uint256 deadline)
        external
        returns (uint256 ethOut);

    function swapETHForYt(
        address metapool,
        uint256 ytAmount,
        uint256 maxEthSpent,
        address recipient,
        uint256 deadline,
        ApproxParams calldata approx
    ) external payable returns (uint256 ethSpent);

    function addLiquidityOneETHKeepYt(address metapool, uint256 minLiquidity, address recipient, uint256 deadline)
        external
        payable
        returns (uint256 liquidity);

    function removeLiquidityOneETH(
        address metapool,
        uint256 liquidity,
        uint256 minEthOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 ethOut);
}
