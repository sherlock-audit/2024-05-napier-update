// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import "forge-std/Test.sol";

// Copy-paste the following code snippet from src/MetapoolRouter.sol

uint256 constant _IS_APPROVED_SLOT_SEED = 0xa8fe4407;

/// @dev Get the approval status of the spender for the token. Return 1 if approved, 0 otherwise.
function _isApproved(address token, address spender) view returns (uint256 approved) {
    /// @solidity memory-safe-assembly
    assembly {
        mstore(0x20, spender)
        mstore(0x0c, _IS_APPROVED_SLOT_SEED)
        mstore(0x00, token)
        approved := sload(keccak256(0x0c, 0x34))
    }
}

/// @dev Set the approval status to 1 for the spender for the token.
function _setApproval(address token, address spender) {
    /// @solidity memory-safe-assembly
    assembly {
        // Compute the approval slot and store the amount.
        mstore(0x20, spender)
        mstore(0x0c, _IS_APPROVED_SLOT_SEED)
        mstore(0x00, token)
        sstore(keccak256(0x0c, 0x34), 1)
    }
}

contract ApprovalTest is Test {
    function test_Seed() public {
        assertEq(_IS_APPROVED_SLOT_SEED, uint256(uint32(bytes4(keccak256("_IS_APPROVED_SLOT_SEED")))));
    }

    function testFuzz_Slot(address token, address spender, bytes32 value) public {
        assumeNotZeroAddress(token);
        assumeNotZeroAddress(spender);
        token = address(uint160(uint256(keccak256(abi.encodePacked(token)))));
        spender = address(uint160(uint256(keccak256(abi.encodePacked(spender)))));

        // keccak256(`token` . 16 zeros . `slot seed` . `spender`) where . is concatenation.
        bytes32 slot = keccak256(abi.encodePacked(token, uint64(0), uint32(_IS_APPROVED_SLOT_SEED), spender));
        vm.store(address(this), slot, value);
        assertEq(_isApproved(token, spender), uint256(value));
    }

    function testFuzz_setApproval(address token, address spender) public {
        assertEq(_isApproved(token, spender), 0);
        _setApproval(token, spender);
        assertEq(_isApproved(token, spender), 1);
    }
}
