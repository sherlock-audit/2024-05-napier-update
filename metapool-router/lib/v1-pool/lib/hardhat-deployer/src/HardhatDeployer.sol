// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

///@notice This cheat codes interface is named _Vm so you can use the Vm interface in other testing files without errors
interface _Vm {
    function readFile(string calldata path) external view returns (string memory data);
    function parseJsonBytes(string calldata, string calldata) external returns (bytes memory);
    function ffi(string[] calldata) external returns (bytes memory);
    function toString(address value) external pure returns (string memory stringifiedValue);
}

library HardhatDeployer {
    _Vm constant vm = _Vm(address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))));

    function deployContract(string memory path) internal returns (address) {
        return deployContract(path, "");
    }

    /// @notice Deploys a contract with constructor arguments
    /// @param path The path to the Hardhat artifact
    function deployContract(string memory path, bytes memory args) internal returns (address) {
        string memory json = vm.readFile(path);
        bytes memory bytecode = vm.parseJsonBytes(json, ".bytecode");
        bytes memory creationCode = bytes.concat(bytecode, args); // add args to the deployment bytecode
        return deploy(creationCode);
    }

    function getBytecode(string memory path) internal returns (bytes memory) {
        string memory json = vm.readFile(path);
        return vm.parseJsonBytes(json, ".bytecode");
    }

    /// @dev Deploys a contract from creation code
    function deploy(bytes memory creationCode) private returns (address deployedAddress) {
        assembly {
            deployedAddress := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployedAddress != address(0), "HardhatDeployer: Deploy failed");
    }

    struct Library {
        string name;
        string path;
        address libAddress;
    }

    /// @notice Deploys a contract with a public library linked
    /// @dev https://docs.soliditylang.org/en/develop/using-the-compiler.html#library-linking
    /// > Manually linking libraries on the generated bytecode is discouraged because it does not update contract metadata. Since metadata contains a list of libraries specified at the time of compilation and bytecode contains a metadata hash, you will get different binaries, depending on when linking is performed.
    /// @dev Replace the `__$placeholder$__` in the contract source with the `libAddress` and deploy the contract
    /// @param path The path to the Hardhat artifact
    /// @param args The abi encoded constructor arguments
    /// @param lib The library to link
    /// @return The deployed contract address
    function deployContract(string memory path, bytes memory args, Library memory lib) internal returns (address) {
        // Dev: Reading bytecode with `vm.readFile` doesn't work because the bytecode includes the non-hex characters.
        // Dev: Instead, we use the `vm.ffi` function to call a python script that reads the bytecode and replaces the placeholder.
        string[] memory cmds = new string[](5);
        cmds[0] = "python";
        cmds[1] = "./lib/hardhat-deployer/scripts/link_lib.py";
        cmds[2] = path; // e.g. artifacts/contracts/MyContract.sol/MyContract.json
        cmds[3] = getPlaceholder(lib.path, lib.name); // e.g. 4f035b9cc20a1ee444f28f216ff0203ba7
        cmds[4] = vm.toString(lib.libAddress); // e.g. 0x4f035b9cc20a1ee444f28f216ff0203ba7
        bytes memory bytecode = vm.ffi(cmds);
        bytes memory creationCode = bytes.concat(bytecode, args); // add args to the deployment bytecode
        return deploy(creationCode);
    }

    /// @dev The fully qualified library name is the path of its source file and the library name separated by :
    function getPlaceholder(string memory path, string memory name) private pure returns (string memory) {
        return toHexStringNoPrefix(abi.encodePacked(bytes17(keccak256(abi.encodePacked(path, ":", name)))));
    }

    // Taken from Solady: https://github.com/Vectorized/solady/blob/74e5718ebee8baf66989e9f1b95f38ee94952f8d/src/utils/LibString.sol#L214C1-L248C6
    function toHexStringNoPrefix(bytes memory raw) private pure returns (string memory str) {
        /// @solidity memory-safe-assembly
        assembly {
            let length := mload(raw)
            str := add(mload(0x40), 2) // Skip 2 bytes for the optional prefix.
            mstore(str, add(length, length)) // Store the length of the output.

            // Store "0123456789abcdef" in scratch space.
            mstore(0x0f, 0x30313233343536373839616263646566)

            let o := add(str, 0x20)
            let end := add(raw, length)

            for {} iszero(eq(raw, end)) {} {
                raw := add(raw, 1)
                mstore8(add(o, 1), mload(and(mload(raw), 15)))
                mstore8(o, mload(and(shr(4, mload(raw)), 15)))
                o := add(o, 2)
            }
            mstore(o, 0) // Zeroize the slot after the string.
            mstore(0x40, add(o, 0x20)) // Allocate the memory.
        }
    }
}
