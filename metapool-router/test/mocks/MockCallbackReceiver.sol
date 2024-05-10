// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @dev Re-export so that `forge-std::deployCodeTo` can find the contract
import {MockCallbackReceiver} from "@napier/v1-pool/test/mocks/MockCallbackReceiver.sol";

library Placeholder {
    function noop() internal {
        new MockCallbackReceiver(); // silence the warning
    }
}
