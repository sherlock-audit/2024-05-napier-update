// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {ApproxParams} from "./ApproxParams.sol";

/// @title Napier Router Interface
/// @dev Interface for the Router contract
/// @notice Router contract for interacting with Napier Yield Metapool and Base pool.
interface INapierRouter {
    ////////////////////////////////////////////////////////////////
    // PT-Underlying swap functions
    ////////////////////////////////////////////////////////////////

    /// @notice Swap exact amount of Principal Token (PT) for Underlying.
    /// @param pool The address of the pool.
    /// @param index The index of the PT.
    /// @param ptInDesired The amount of PT to swap.
    /// @param underlyingOutMin The minimum amount of underlying asset to receive.
    /// @param recipient The recipient of the swapped underlying asset.
    /// @param deadline The deadline for the swap.
    /// @return The amount of underlying asset received.
    function swapPtForUnderlying(
        address pool,
        uint256 index,
        uint256 ptInDesired,
        uint256 underlyingOutMin,
        address recipient,
        uint256 deadline
    ) external returns (uint256);

    /// @notice Swap underlying asset for exact amount of Principal Token (PT).
    /// @dev This function pulls underlying asset from msg.sender on callback because we don't know the exact amount of underlying asset to pull before the swap.
    /// @param pool The address of the pool.
    /// @param index The index of the PT.
    /// @param ptOutDesired The amount of PT to receive.
    /// @param underlyingInMax The maximum amount of underlying asset to spend.
    /// @param recipient The recipient of the PT token.
    /// @param deadline The deadline for the swap.
    /// @return The amount of PT token received.
    function swapUnderlyingForPt(
        address pool,
        uint256 index,
        uint256 ptOutDesired,
        uint256 underlyingInMax,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256);

    ////////////////////////////////////////////////////////////////
    // YT-Underlying swap functions
    ////////////////////////////////////////////////////////////////

    /// @notice Variant of `swapUnderlyingForYt` with `ApproxParams` as an additional parameter.
    function swapUnderlyingForYt(
        address pool,
        uint256 index,
        uint256 ytOutDesired,
        uint256 underlyingInMax,
        address recipient,
        uint256 deadline,
        ApproxParams calldata approx
    ) external payable returns (uint256);

    /**
     * @notice Swap exact amount of Underlying for YT.
     * @param pool The address of the pool.
     * @param index The index of the YT.
     * @param ytOutDesired The amount of YT to receive.
     * @param underlyingInMax The maximum amount of underlying asset to spend.
     * @param recipient The recipient of the YT.
     * @param deadline The deadline for the swap.
     * @return The amount of YT received.
     */
    function swapUnderlyingForYt(
        address pool,
        uint256 index,
        uint256 ytOutDesired,
        uint256 underlyingInMax,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256);

    /**
     * @notice Swap exact amount of YT for Underlying.
     * @param pool The address of the pool.
     * @param index The index of the YT.
     * @param ytIn The amount of YT to swap.
     * @param underlyingOutMin The minimum amount of underlying asset to receive.
     * @param recipient The recipient of the underlying asset.
     * @param deadline The deadline for the swap.
     * @return The amount of underlying asset received.
     */
    function swapYtForUnderlying(
        address pool,
        uint256 index,
        uint256 ytIn,
        uint256 underlyingOutMin,
        address recipient,
        uint256 deadline
    ) external returns (uint256);

    ////////////////////////////////////////////////////////////////
    // Liquidity-related functions
    ////////////////////////////////////////////////////////////////

    /// @notice Add liquidity to NapierPool and Curve Tricrypto pool.
    /// @param pool The address of the pool.
    /// @param underlyingIn The amount of underlying asset to deposit.
    /// @param ptsIn The amounts of PTs to deposit.
    /// @param liquidityMin The minimum amount of liquidity tokens to receive.
    /// @param recipient The recipient of the liquidity tokens.
    /// @param deadline The deadline for adding liquidity.
    /// @return The amount of liquidity tokens received.
    function addLiquidity(
        address pool,
        uint256 underlyingIn,
        uint256[3] calldata ptsIn,
        uint256 liquidityMin,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256);

    /// @notice Add liquidity to the pool using a single Principal Token.
    /// @dev Swap some amount of PT for underlying asset so that the user can deposit tokens proportionally to the reserves.
    /// @param pool The address of the pool.
    /// @param index The index of the PT.
    /// @param amountIn The amount of PT to deposit.
    /// @param liquidityMin The minimum amount of liquidity tokens to receive.
    /// @param recipient The recipient of the liquidity tokens.
    /// @param deadline The deadline for adding liquidity.
    /// @param baseLpTokenSwap The estimated baseLpt amount to swap with underlying tokens.
    /// @return The amount of liquidity tokens received.
    function addLiquidityOnePt(
        address pool,
        uint256 index,
        uint256 amountIn,
        uint256 liquidityMin,
        address recipient,
        uint256 deadline,
        uint256 baseLpTokenSwap
    ) external returns (uint256);

    /// @notice Add liquidity to the pool using a single underlying asset.
    /// @dev Swap some underlying asset for Base pool token so that the user can deposit tokens proportionally to the reserves.
    /// @param pool The address of the pool.
    /// @param underlyingIn The amount of underlying asset to deposit.
    /// @param liquidityMin The minimum amount of liquidity tokens to receive.
    /// @param recipient The recipient of the liquidity tokens.
    /// @param deadline The deadline for adding liquidity.
    /// @param baseLpTokenSwap The estimated baseLpt amount to get from underlying tokens.
    /// @return The amount of liquidity tokens received.
    function addLiquidityOneUnderlying(
        address pool,
        uint256 underlyingIn,
        uint256 liquidityMin,
        address recipient,
        uint256 deadline,
        uint256 baseLpTokenSwap
    ) external returns (uint256);

    /// @notice Add liquidity to NapierPool with one underlying asset.
    /// @notice Caller must approve the router to spend underlying asset prior to calling this method.
    /// @dev Caller must specify the amount of underlying asset to be spent to issue PT and YT using off-chain calculation.
    /// @param pool The address of the pool.
    /// @param index The index of the issued PT / YT.
    /// @param underlyingIn The amount of underlying asset to deposit.
    /// @param liquidityMin The minimum amount of liquidity tokens to receive.
    /// @param recipient The recipient of the liquidity tokens.
    /// @param deadline The deadline for adding liquidity.
    /// @param underlyingDeposit The estimated underlying amount spent to issue PT and YT.
    /// @return The amount of liquidity tokens received.
    function addLiquidityOneUnderlyingKeepYt(
        address pool,
        uint256 index,
        uint256 underlyingIn,
        uint256 liquidityMin,
        address recipient,
        uint256 deadline,
        uint256 underlyingDeposit
    ) external returns (uint256);

    /// @notice Remove liquidity from NapierPool and Curve Tricrypto pool.
    /// @param pool The address of the pool.
    /// @param liquidity The amount of liquidity tokens to burn.
    /// @param underlyingOutMin The minimum amount of underlying asset to receive.
    /// @param ptsOutMin The minimum amounts of PTs to receive.
    /// @param recipient The recipient of the PTs and underlying asset.
    /// @param deadline The deadline for removing liquidity.
    /// @return The amounts of PTs and underlying asset received.
    function removeLiquidity(
        address pool,
        uint256 liquidity,
        uint256 underlyingOutMin,
        uint256[3] calldata ptsOutMin,
        address recipient,
        uint256 deadline
    ) external returns (uint256, uint256[3] memory);

    /**
     * @notice Remove liquidity from the metapool and receive a single underlying asset.
     * @param pool The address of the pool.
     * @param index The index of PT to be withdrawn when removing liquidity from Base pool. Ignored if maturity has not passed.
     * @param liquidity The amount of liquidity tokens to remove.
     * @param underlyingOutMin The minimum amount of underlying asset to receive.
     * @param recipient The recipient of the underlying asset.
     * @param deadline The deadline for removing liquidity.
     * @return The amount of underlying asset received by `recipient`.
     */
    function removeLiquidityOneUnderlying(
        address pool,
        uint256 index,
        uint256 liquidity,
        uint256 underlyingOutMin,
        address recipient,
        uint256 deadline
    ) external returns (uint256);

    /**
     * @notice Remove liquidity from the metapool and receive a single PT.
     * @param pool The address of the pool.
     * @param index The index of the PT.
     * @param liquidity The amount of liquidity tokens to remove.
     * @param ptOutMin The minimum amount of PT to receive.
     * @param recipient The recipient of the PT.
     * @param deadline The deadline for removing liquidity.
     * @param baseLpTokenSwap The estimated baseLpt amount to swap with underlying tokens.
     * @return The amount of PT received by `recipient`.
     */
    function removeLiquidityOnePt(
        address pool,
        uint256 index,
        uint256 liquidity,
        uint256 ptOutMin,
        address recipient,
        uint256 deadline,
        uint256 baseLpTokenSwap
    ) external returns (uint256);
}
