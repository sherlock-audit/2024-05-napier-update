# Deployment

## Relevant Addresses

### Ethereum Mainnet

### Sepolia

| Name                                 | Address                                                                                                                            |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| Create2Deployer                      | 0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2                                                                                         |
| PoolFactory                          | TODO (address and link to etherscan)                                                                                               |
| CurveTricryptoFactory                | [0x898af82d705A1e368b4673a253374081Fc221FF1](https://sepolia.etherscan.io/address/0x898af82d705A1e368b4673a253374081Fc221FF1#code) |
| CurveCryptoOptimizedWETH (Blueprint) | [0xaa212B1097c4395c6755D6Cd94232aC551a6d26A](https://sepolia.etherscan.io/address/0xaa212B1097c4395c6755D6Cd94232aC551a6d26A#code) |
| CurveCryptoViews3Optimized           | [0xfEA521aD542D61a0D8888502224Ee2F33d1aeB31](https://sepolia.etherscan.io/address/0xfEA521aD542D61a0D8888502224Ee2F33d1aeB31#code) |
| CurveTricryptoMathOptimized          | [0xB7E728cC75392C7428D8f3bBfcE46819F5f397D9](https://sepolia.etherscan.io/address/0xB7E728cC75392C7428D8f3bBfcE46819F5f397D9#code) |

## Deployments

1. Prepare a private key `PK` and fund it with some ETH.
2. Export `owner` address of `PoolFactory` contract as `OWNER=$(cast wallet address $PK)`.
3. Export Underlying, WETH and Principal Token addresses as `UNDERLYING`, `WETH`, `PT1`, `PT2` and `PT3`.
4. Ensure that `RPC_URL` is set appropriately.
5. Build the contracts.
6. Deploy the contracts. [Testnet Deployments with mock tokens](#testnet-deployments-with-mock-tokens) or [Production Deployments](#production-deployments)

### Testnet Deployments with Mock Tokens

1. Deploy Curve Tricrypto Factory

If you want to deploy contracts to other testnests than Sepolia, you need to deploy Curve Tricrypto contracts to the network.

> [!NOTE]
> You can skip this step if you want to deploy contracts to Sepolia.

```bash
./script/deploy_curve.sh $PK $OWNER $RPC_URL
```

> Due to a bug in the `foundry` or etherscan, script for deploying will fail. See [issue](https://github.com/foundry-rs/foundry/issues/5251). To fix this, manually deploy CurveTricrypto contracts to the network.

Visit etherscan to get the deployed addresses of Curve Tricrypto and export those addresses.

```bash
export AMM_BLUEPRINT=<CurveCryptoOptimizedWETH>
export TRICRYPTO_FACTORY=<CurveTricryptoFactory>
export VIEWS=<CurveCryptoViews3Optimized>
export MATH=<CurveTricryptoMathOptimized>
```

After that, you can dry-run the deployment script to check if everything is fine. After that, add `--verify --broadcast` flags to deploy the contracts and verify them automatically at the same time.

```bash
WETH=$WETH UNDERLYING=$UNDERLYING PT1=$PT1 PT2=$PT2 PT3=$PT3 forge script --rpc-url=$RPC_URL --private-key=$PK -vvv script/MockDeploy.s.sol:TestDeploy
```

The deployment script supports custom optimizor settings by reading artifacts built by Hardhat. You need to compile the contracts with hardhat first.

```bash
npx hardhat compile
WETH=$WETH UNDERLYING=$UNDERLYING PT1=$PT1 PT2=$PT2 PT3=$PT3 forge script --rpc-url=$RPC_URL --private-key=$PK -vvv script/MockDeploy.s.sol:TestOptimizedDeploy
```

### Production Deployments

1. Deploy Napier Tranche `napier-v1` contracts. See [napier-v1 deployment](../lib/napier-v1/docs/deployment.md)
2. Set parameters for the deployment script. Check the [deployment script](../script/ProductionDeploy.s.sol).
3. Run the deployment script.
4. Verify deployed contracts.

WIP

## Verify Contracts

Export the addresses as environment variables. If contracts are compiled with Hardhat, see [here](#verify-contracts-compiled-with-hardhat)

```bash
export POOL=<pool-address>
export SWAP_ROUTER=<swap-router-address>
export POOL_FACTORY=<factory-address>
export LIB_CREATE2_POOL=<lib-create2-pool-address>
export QUOTER=<quoter-address>
export TRANCHER_FACTORY=<trancher-factory-address>
export TRANCHE_ROUTER=<tranche-router-address>
```

- verify `NapierPool` contract

```bash
forge verify-contract --chain=sepolia $POOL src/NapierPool.sol:NapierPool
```

- verify `NapierRouter` contract

For verification, needed PoolFactory, WETH address for constructor parameters.

```bash
forge verify-contract --chain=sepolia $SWAP_ROUTER src/NapierRouter.sol:NapierRouter --constructor-args=$(cast abi-encode "constructor(address,address)" $POOL_FACTORY $WETH)
```

- verify `PoolFactory` contract

For verification, needed Create2PoolLib library with parameters (LIB_CREATE2_POOL, POOL_FACTORY) and also needed TRICRYPTO_FACTORY, OWNER for constructor parameters.

```bash
forge verify-contract --chain=sepolia --libraries=src/libs/Create2PoolLib.sol:Create2PoolLib:$LIB_CREATE2_POOL $POOL_FACTORY src/PoolFactory.sol:PoolFactory --constructor-args=$(cast abi-encode "cons(address,address)"  $TRICRYPTO_FACTORY $OWNER)
```

- verify `Quoter` contract

Needed PoolFactory address for constructor parameters.

```bash
forge verify-contract --chain=sepolia $QUOTER src/lens/Quoter.sol:Quoter --constructor-args=$(cast abi-encode "cons(address)" $POOL_FACTORY)
```

- verify `TrancheRouter` contract

Needed TrancheFactory, WETH address for constructor parameters.

```bash
forge verify-contract --chain=sepolia $TRANCHE_ROUTER src/TrancheRouter.sol:TrancheRouter --constructor-args=$(cast abi-encode "cons(address,address)" $TRANCHER_FACTORY $WETH)
```

#### Verify contracts compiled with Hardhat

```bash
npx hardhat --network sepolia verify --no-compile $POOL
```

```bash
npx hardhat --network sepolia verify --no-compile $SWAP_ROUTER $POOL_FACTORY $WETH
```

```bash
npx hardhat --network sepolia verify --no-compile $POOL_FACTORY $TRICRYPTO_FACTORY $OWNER
```

```bash
npx hardhat --network sepolia verify --no-compile $QUOTER $POOL_FACTORY
```

```bash
npx hardhat --network sepolia verify --no-compile $TRANCHE_ROUTER $TRANCHE_FACTORY $WETH
```

### Determisnitic Deployment

Ensure that `PoolFactory` is already deployed and compile the contracts with Hardhat.

```bash
npx hardhat compile
```

Export CREATE2 deployer address and set `STARTS_WITH` to your desired sequence.

```bash
CREATE2_DEPLOYER=0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2
STARTS_WITH=000000
```

Fore more options, type `cast create2 --help`.

Now, calculate the salts for the contracts.

- NapierRouter

Type the following commands and export the output as `SWAP_ROUTER_SALT` (bytes32)

```bash
ENCODED_ARGS=$(cast abi-encode "cons(address, address)" $POOL_FACTORY $WETH)
INIT_CODE_HASH=$(cast keccak $(cast concat-hex $(cat artifacts/src/NapierRouter.sol/NapierRouter.json | jq -r .bytecode) $ENCODED_ARGS))
cast create2 --deployer=$CREATE2_DEPLOYER --init-code-hash=$INIT_CODE_HASH --starts-with=$STARTS_WITH
```

- TrancheRouter

Type the following commands and export the output as `TRANCHE_ROUTER_SALT`

```bash
ENCODED_ARGS=$(cast abi-encode "cons(address,address)" $TRANCHE_FACTORY $WETH)
INIT_CODE_HASH=$(cast keccak $(cast concat-hex $(cat artifacts/src/TrancheRouter.sol/TrancheRouter.json | jq -r .bytecode) $ENCODED_ARGS))
cast create2 --deployer=$CREATE2_DEPLOYER --init-code-hash=$INIT_CODE_HASH --starts-with=$STARTS_WITH
```

- Quoter

Type the following commands and export the output as `QUOTER_SALT`

```bash
ENCODED_ARGS=$(cast abi-encode "cons(address)" $POOL_FACTORY)
INIT_CODE_HASH=$(cast keccak $(cast concat-hex $(cat artifacts/src/lens/Quoter.sol/Quoter.json | jq -r .bytecode) $ENCODED_ARGS))
cast create2 --deployer=$CREATE2_DEPLOYER --init-code-hash=$INIT_CODE_HASH --starts-with=$STARTS_WITH
```

After exporting the salts, make sure that environment variables are set. Then, run the deployment script.

```bash
TRANCHE_FACTORY=$TRANCHE_FACTORY POOL_FACTORY=$POOL_FACTORY SWAP_ROUTER_SALT=$SWAP_ROUTER_SALT TRANCHE_ROUTER_SALT=$TRANCHE_ROUTER_SALT QUOTER_SALT=$QUOTER_SALT WETH=$WETH forge script --sig="deployPeripheriesWithSalts()" --rpc-url=$RPC_URL --private-key=$PK -vvv script/ProductionDeploy.s.sol:ProductionDeterministicDeploy
```
