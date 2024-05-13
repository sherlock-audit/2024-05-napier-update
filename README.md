
# Napier Update contest details

- Join [Sherlock Discord](https://discord.gg/MABEWyASkp)
- Submit findings using the issue page in your private contest repo (label issues as med or high)
- [Read for more details](https://docs.sherlock.xyz/audits/watsons)

# Q&A

### Q: On what chains are the smart contracts going to be deployed?
Ethereum
___

### Q: If you are integrating tokens, are you allowing only whitelisted tokens to work with the codebase or any complying with the standard? Are they assumed to have certain properties, e.g. be non-reentrant? Are there any types of <a href="https://github.com/d-xo/weird-erc20" target="_blank" rel="noopener noreferrer">weird tokens</a> you want to integrate?
it should support standard ERC20-Tokens.
Tokens with a transfer fee and tokens with a hook are not supported.
___

### Q: Are the admins of the protocols your contracts integrate with (if any) TRUSTED or RESTRICTED? If these integrations are trusted, should auditors also assume they are always responsive, for example, are oracles trusted to provide non-stale information, or VRF providers to respond within a designated timeframe?
LST and LRT protocols are TRUSTED
Internal roles are TRUSTED
Balancer finance flash loan and admin are TRUSTED
Admin of Curve TriCrypto and TwoCrypto are TRUSTED
___

### Q: Are there any protocol roles? Please list them and provide whether they are TRUSTED or RESTRICTED, or provide a more comprehensive description of what a role can and can't do/impact.
Rebalancer role - TRUSTED (as a whole) : An account that manages tokens and assets on vaults and adapters. 
Rebalancer can 
- Request withdrawal for LST.
- Claim some tokens
- Swap tokens
Owner role - TRUSTED: An account that manages vaults and adapter and assigns a rebalancer. 
___

### Q: For permissioned functions, please list all checks and requirements that will be made before calling the function.
LST Adapters
requestWithdrawal and requestWithdrwalAll
- Restricted access if calling function cause a vault share price may change. 
setRebalancer
- Restricted access. Owner can call this function. Setting zero address is allowed.
withdraw
- Restricted access if calling function cause a vault share price may change. 
Functions related to swap or swapper contract on adapter
- Restricted access
SetTranche
- Admin can set only once Tranche address.
prefundedDeposit/prefundedRedeem
- An authorized Tranche can call this function.
___

### Q: Is the codebase expected to comply with any EIPs? Can there be/are there any deviations from the specification?
Optionally compliant (compliancy issues will not be valid Medium/High)
- ERC4626
___

### Q: Are there any off-chain mechanisms or off-chain procedures for the protocol (keeper bots, arbitrage bots, etc.)?
We monitor token balances on adapters, available buffer on adapters and current buffer percentage. 
And we may run bots to rebalance vaults when users run out of buffer.
___

### Q: Are there any hardcoded values that you intend to change before (some) deployments?
No
___

### Q: If the codebase is to be deployed on an L2, what should be the behavior of the protocol in case of sequencer issues (if applicable)? Should Sherlock assume that the Sequencer won't misbehave, including going offline?
N/A
___

### Q: Should potential issues, like broken assumptions about function behavior, be reported if they could pose risks in future integrations, even if they might not be an issue in the context of the scope? If yes, can you elaborate on properties/invariants that should hold?
No
___

### Q: Please discuss any design choices you made.
Some adapters don't support multiple requests for unstaking LST because some of protocols are not compatible with our code base. We implemented some functions to exit stake positions. Buffer may not fully mitigate the waiting period for unstaking. Kinds of DoS issues may be invalid. 

swapETHForPT function on MetapoolRouter can'g swap exact amount of token because of precision loss but we think it's acceptable. But, if this precision loss may cause a serious loss of funds, it may be a valid finding.

Twocrypto, Tricrypto LP token, WETH, Napier PT and YT comply with ERC20 standard completely.
___

### Q: Please list any known issues/acceptable risks that should not result in a valid finding.
claimWithdraw functions on some adapters are public function though the function may change vault share price, which may cause kinds of front running.

Redeeming vault share can be blocked (DoS) because of waiting period of LST/LRT withdrawal

swapETHForPT function on MetapoolRouter can't swap exact amount of token.

Vault inflation attack



___

### Q: We will report issues where the core protocol functionality is inaccessible for at least 7 days. Would you like to override this value?
No
___

### Q: Please provide links to previous audits (if any).
https://audits.sherlock.xyz/contests/171
___

### Q: Please list any relevant protocol resources.
https://napier-labs.notion.site/Napier-Finance-LST-LRT-integrations-604eefb86a20475c804966a0b8a3bdbb?pvs=4
___



# Audit scope


[metapool-router @ 213d967dc2bd525aaa832c7f87a6ac6dc5eafd1b](https://github.com/napierfi/metapool-router/tree/213d967dc2bd525aaa832c7f87a6ac6dc5eafd1b)
- [metapool-router/src/MetapoolFactory.sol](metapool-router/src/MetapoolFactory.sol)
- [metapool-router/src/MetapoolRouter.sol](metapool-router/src/MetapoolRouter.sol)
- [metapool-router/src/TransientStorage.sol](metapool-router/src/TransientStorage.sol)

[napier-uups-adapters @ f345d328c9d4fe1703853d05d6c10d226f9915a4](https://github.com/napierfi/napier-uups-adapters/tree/f345d328c9d4fe1703853d05d6c10d226f9915a4)
- [napier-uups-adapters/src/BaseAdapterUpgradeable.sol](napier-uups-adapters/src/BaseAdapterUpgradeable.sol)
- [napier-uups-adapters/src/Constants.sol](napier-uups-adapters/src/Constants.sol)
- [napier-uups-adapters/src/Structs.sol](napier-uups-adapters/src/Structs.sol)
- [napier-uups-adapters/src/adapters/BaseLSTAdapterUpgradeable.sol](napier-uups-adapters/src/adapters/BaseLSTAdapterUpgradeable.sol)
- [napier-uups-adapters/src/adapters/BaseLSTVaultUpgradeable.sol](napier-uups-adapters/src/adapters/BaseLSTVaultUpgradeable.sol)
- [napier-uups-adapters/src/adapters/kelp/RsETHAdapter.sol](napier-uups-adapters/src/adapters/kelp/RsETHAdapter.sol)
- [napier-uups-adapters/src/adapters/puffer/PufETHAdapter.sol](napier-uups-adapters/src/adapters/puffer/PufETHAdapter.sol)
- [napier-uups-adapters/src/adapters/renzo/RenzoAdapter.sol](napier-uups-adapters/src/adapters/renzo/RenzoAdapter.sol)
- [napier-uups-adapters/src/adapters/swell/RswETHAdapter.sol](napier-uups-adapters/src/adapters/swell/RswETHAdapter.sol)

[napier-v1 @ 4962a3c4e8747fe7aee99096020dc7c649de091b](https://github.com/napierfi/napier-v1/tree/4962a3c4e8747fe7aee99096020dc7c649de091b)
- [napier-v1/src/adapters/BaseLSTAdapter.sol](napier-v1/src/adapters/BaseLSTAdapter.sol)
- [napier-v1/src/adapters/BaseLSTVault.sol](napier-v1/src/adapters/BaseLSTVault.sol)
- [napier-v1/src/adapters/bedrock/UniETHAdapter.sol](napier-v1/src/adapters/bedrock/UniETHAdapter.sol)
- [napier-v1/src/adapters/bedrock/UniETHSwapper.sol](napier-v1/src/adapters/bedrock/UniETHSwapper.sol)
- [napier-v1/src/adapters/etherfi/EETHAdapter.sol](napier-v1/src/adapters/etherfi/EETHAdapter.sol)




[metapool-router @ 213d967dc2bd525aaa832c7f87a6ac6dc5eafd1b](https://github.com/napierfi/metapool-router/tree/213d967dc2bd525aaa832c7f87a6ac6dc5eafd1b)
- [metapool-router/src/MetapoolFactory.sol](metapool-router/src/MetapoolFactory.sol)
- [metapool-router/src/MetapoolRouter.sol](metapool-router/src/MetapoolRouter.sol)
- [metapool-router/src/TransientStorage.sol](metapool-router/src/TransientStorage.sol)

[napier-uups-adapters @ f345d328c9d4fe1703853d05d6c10d226f9915a4](https://github.com/napierfi/napier-uups-adapters/tree/f345d328c9d4fe1703853d05d6c10d226f9915a4)
- [napier-uups-adapters/src/BaseAdapterUpgradeable.sol](napier-uups-adapters/src/BaseAdapterUpgradeable.sol)
- [napier-uups-adapters/src/Constants.sol](napier-uups-adapters/src/Constants.sol)
- [napier-uups-adapters/src/Structs.sol](napier-uups-adapters/src/Structs.sol)
- [napier-uups-adapters/src/adapters/BaseLSTAdapterUpgradeable.sol](napier-uups-adapters/src/adapters/BaseLSTAdapterUpgradeable.sol)
- [napier-uups-adapters/src/adapters/BaseLSTVaultUpgradeable.sol](napier-uups-adapters/src/adapters/BaseLSTVaultUpgradeable.sol)
- [napier-uups-adapters/src/adapters/kelp/RsETHAdapter.sol](napier-uups-adapters/src/adapters/kelp/RsETHAdapter.sol)
- [napier-uups-adapters/src/adapters/puffer/PufETHAdapter.sol](napier-uups-adapters/src/adapters/puffer/PufETHAdapter.sol)
- [napier-uups-adapters/src/adapters/renzo/RenzoAdapter.sol](napier-uups-adapters/src/adapters/renzo/RenzoAdapter.sol)
- [napier-uups-adapters/src/adapters/swell/RswETHAdapter.sol](napier-uups-adapters/src/adapters/swell/RswETHAdapter.sol)




[metapool-router @ 213d967dc2bd525aaa832c7f87a6ac6dc5eafd1b](https://github.com/napierfi/metapool-router/tree/213d967dc2bd525aaa832c7f87a6ac6dc5eafd1b)
- [metapool-router/src/MetapoolFactory.sol](metapool-router/src/MetapoolFactory.sol)
- [metapool-router/src/MetapoolRouter.sol](metapool-router/src/MetapoolRouter.sol)
- [metapool-router/src/TransientStorage.sol](metapool-router/src/TransientStorage.sol)


