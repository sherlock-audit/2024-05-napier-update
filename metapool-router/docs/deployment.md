# Deployment

### Ethereum Mainnet

### Sepolia

## Deployments

1. Deploy Napier Tranche `napier-v1` contracts. See [napier-v1 deployment](https://github.com/napierfi/napier-v1/blob/main/docs/deployment.md)
1. Deploy Napier Pool `v1-pool` contracts. See [v1-pool deployment](https://github.com/napierfi/v1-pool/blob/main/docs/deployment.md)
1. Export the addresses of the deployed contracts as environment variables.

### Testnet Deployments with Mock Tokens

This script deploys `MetapoolFactory`, `MetapoolRouter`, `Quoter` and Twocrypto pool.

1. Prepare a private key `PK` and fund it with some ETH.

```bash
RPC_URL=
OWNER=
PT=
TRI_LST_POOL=
```

2. After that, you can dry-run the deployment script to check if everything is fine. After that, add `--verify --broadcast` flags to deploy the contracts and verify them automatically at the same time.

```bash
forge script --rpc-url=$RPC_URL --private-key=$PK -vvv --sig="deployTwocryptoMeta" --tc=ProductionDeploy script/ProductionDeploy.s.sol
```

### Production Deployments

1. Edit `MainnetParameters` in `script/ProductionDeploy.s.sol` to set the correct parameters.

To deploys `MetapoolFactory`, `MetapoolRouter` and `Quoter`, type:

Export the following environment variables.

```bash
OWNER=
TRI_LST_POOL=
```

Type:

```bash
forge script --rpc-url=$RPC_URL --private-key=$PK -vvv --sig="deployTwocryptoMeta" --tc=ProductionDeploy script/ProductionDeploy.s.sol
```

For deterministic deployment, export envs and use `--tc=ProductionDeployCREATE2` option. See below.
For regular deployment, type:
ï
To deploy Twocrypto pool, type:

```bash
OWNER=
TRI_LST_POOL=
METAPOOL_FACTORY=
PT= # coin 0 for twocrypto pool
NAME= # Twocrypto pool name
SYMBOL= # Twocrypto pool symbol
IMPLEMENTATION_ID=0 # Twocrypto pool implementation id
```

```bash
forge script --rpc-url=$RPC_URL --private-key=$PK -vvv --sig="deployTwocryptoMeta" --tc=ProductionDeploy script/ProductionDeploy.s.sol
```

### Determisnitic Deployment

Export envs:

```bash
# add the following envs to .env above

CREATE2_DEPLOYER=0x13b0D85CcB8bf860b6b79AF3029fCA081AE9beF2
STARTS_WITH=000000

WETH=
TWOCRYPTO_FACTORY=
METAPOOL_FACTORY=
VAULT=
```

Fore more options, type `cast create2 --help`.

Now, calculate the salts for the contracts.

- MetapoolFactory

Type the following commands and export the output as `FACTORY_SALT`

```bash
ENCODED_ARGS=$(cast abi-encode "cons(address,address,address)" $OWNER $WETH $TWOCRYPTO_FACTORY)
INIT_CODE_HASH=$(cast keccak $(cast concat-hex $(cat artifacts/src/MetapoolFactory.sol/MetapoolFactory.json | jq -r .bytecode) $ENCODED_ARGS))
cast create2 --deployer=$CREATE2_DEPLOYER --init-code-hash=$INIT_CODE_HASH --starts-with=$STARTS_WITH
```

- MetapoolRouter

Type the following commands and export the output as `ROUTER_SALT`

```bash
ENCODED_ARGS=$(cast abi-encode "cons(address, address, address)" $METAPOOL_FACTORY $TRI_LST_POOL $VAULT)
INIT_CODE_HASH=$(cast keccak $(cast concat-hex $(cat artifacts/src/MetapoolRouter.sol/MetapoolRouter.json | jq -r .bytecode) $ENCODED_ARGS))
cast create2 --deployer=$CREATE2_DEPLOYER --init-code-hash=$INIT_CODE_HASH --starts-with=$STARTS_WITH
```

- Quoter

Type the following commands and export the output as `QUOTER_SALT`

```bash
ENCODED_ARGS=$(cast abi-encode "cons(address,address)" $METAPOOL_FACTORY $VAULT)
INIT_CODE_HASH=$(cast keccak $(cast concat-hex $(cat artifacts/src/Quoter.sol/Quoter.json | jq -r .bytecode) $ENCODED_ARGS))
cast create2 --deployer=$CREATE2_DEPLOYER --init-code-hash=$INIT_CODE_HASH --starts-with=$STARTS_WITH
```

After exporting the salts, make sure that environment variables are set. Run commands above with `--tc=ProductionDeployCREATE2` option.
