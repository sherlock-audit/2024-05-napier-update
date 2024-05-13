// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {INapierPool} from "src/interfaces/INapierPool.sol";

library SwapEventsLib {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct SwapEvent {
        int256 netUnderlying;
        uint256 index;
        int256 netPt;
        uint256 swapFee;
        uint256 protocolFee;
    }

    function getLastSwapEvent(INapierPool pool) internal returns (SwapEvent memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length > 0, "No logs recorded");
        for (uint256 i = logs.length - 1; i > 0; i--) {
            bytes32 topic0 = logs[i].topics[0]; // topic0 is the event signature
            if (logs[i].emitter != address(pool)) continue;
            if (topic0 == keccak256("Swap(address,address,int256,uint256,int256,uint256,uint256)")) {
                return abi.decode(logs[i].data, (SwapEvent));
            }
        }
        revert("Swap event not found");
    }

    struct SwapBaseLptEvent {
        int256 netUnderlying;
        int256 netBaseLpt;
        uint256 swapFee;
        uint256 protocolFee;
    }

    function getLastMetaSwapEvent(INapierPool pool) internal returns (SwapBaseLptEvent memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length > 0, "No logs recorded");
        for (uint256 i = logs.length - 1; i > 0; i--) {
            bytes32 topic0 = logs[i].topics[0]; // topic0 is the event signature
            if (logs[i].emitter != address(pool)) continue;
            if (topic0 == keccak256("SwapBaseLpt(address,address,int256,int256,uint256,uint256)")) {
                return abi.decode(logs[i].data, (SwapBaseLptEvent));
            }
        }
        revert("SwapBaseLpt event not found");
    }
}
