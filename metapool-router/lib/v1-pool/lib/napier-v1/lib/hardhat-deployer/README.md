## HardHat Deployer

A foundry libary for deploying contracts compiled with HardHat.

## Dependencies

- Python 3
- Foundry

## Installing

````shell
forge install napierfi/hardhat-deployer
```

Add the following to your forge.toml file:

```toml
[profile.default]
# ...
ffi = true
fs_permissions = [{ access = "read", path = "./artifacts/" }] # or wherever your hardhat artifacts are
````

And then add the following to your hardhat.config.js file:

```js
module.exports = {
  // ...
  // Avoid foundry cache conflict.
  paths: {
    sources: "src", // Use ./src rather than ./contracts as Hardhat expects
    cache: "hh-cache",
  },
};
```

## Usage

```solidity
import {HardHatDeployer} from "hardhat-deployer/HardHatDeployer.sol";
```

Ensure that your contract is compiled with HardHat and that the artifacts are in the artifacts directory before deploying with HardHatDeployer.
