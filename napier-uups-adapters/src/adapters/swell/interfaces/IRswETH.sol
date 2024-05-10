// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable@4.9.3/token/ERC20/IERC20Upgradeable.sol";

interface IRswETH is IERC20Upgradeable {
    function deposit() external payable;

    function rswETHToETHRate() external view returns (uint256);

    function ethToRswETHRate() external view returns (uint256);
}
