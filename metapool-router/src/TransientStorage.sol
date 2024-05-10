// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

/// @notice Transient storage utility functions
library TransientStorage {
    function tloadU256(uint256 slot) internal view returns (uint256 value) {
        assembly {
            value := tload(slot)
        }
    }

    /// @notice The return value may contain dirty upper bits
    function tloadAddress(uint256 slot) internal view returns (address value) {
        assembly {
            value := tload(slot)
        }
    }
}
