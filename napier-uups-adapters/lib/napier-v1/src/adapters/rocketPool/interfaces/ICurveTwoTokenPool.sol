// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

interface ICurveTwoTokenPool {
    /// @notice exchange `dx` amount of token `i` for token `j`.
    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 minDy,
        bool useEth,
        address receiver
    ) external payable returns (uint256 dy);
}
