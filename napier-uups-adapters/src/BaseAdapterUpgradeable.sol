// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

// interfaces
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable@4.9.3/token/ERC20/IERC20Upgradeable.sol";
import {IBaseAdapter} from "@napier/v1-tranche/interfaces/IBaseAdapter.sol";

// libs
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable@4.9.3/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable@4.9.3/access/Ownable2StepUpgradeable.sol";

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable@4.9.3/proxy/utils/UUPSUpgradeable.sol";

/// @notice abstract contract for adapters
/// @dev DO NOT ADD ANY STATE VARIABLES HERE. Derived contracts should expose `underlying`, `target` and `scale` functions.
/// @dev adapters are used to deposit underlying tokens into a yield source and redeem them.
/// adapters are also used to fetch the current scale of the yield-bearing asset.
abstract contract BaseAdapterUpgradeable is Ownable2StepUpgradeable, UUPSUpgradeable, IBaseAdapter {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    function __BaseAdapter_init(address _owner) internal onlyInitializing {
        __Ownable2Step_init();
        __UUPSUpgradeable_init();

        _transferOwnership(_owner);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
