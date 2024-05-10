// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

interface IRenzoRestakeManager {
    function depositETH(uint256 referralId) external payable;

    function calculateTVLs() external view returns (uint256[][] memory, uint256[] memory, uint256);

    function renzoOracle() external view returns (address);

    function paused() external view returns (bool);
}
