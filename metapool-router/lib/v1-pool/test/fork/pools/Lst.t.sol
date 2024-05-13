// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import {ForkTest} from "../Fork.t.sol";
import {VyperDeployer} from "../../../lib/VyperDeployer.sol";

import {IERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/IERC20.sol";
import {Tranche} from "@napier/v1-tranche/src/Tranche.sol";
import {YieldToken} from "@napier/v1-tranche/src/YieldToken.sol";
import {IBaseAdapter} from "@napier/v1-tranche/src/interfaces/IBaseAdapter.sol";
import {MockAdapter} from "@napier/v1-tranche/test/mocks/MockAdapter.sol";
import {BaseLSTVault} from "@napier/v1-tranche/src/adapters/BaseLSTVault.sol";
import {IWETH9} from "@napier/v1-tranche/src/interfaces/IWETH9.sol";

import {TrancheFactory} from "@napier/v1-tranche/src/TrancheFactory.sol";
import {RETHAdapter} from "@napier/v1-tranche/src/adapters/rocketPool/RETHAdapter.sol";
import {Swapper} from "@napier/v1-tranche/src/adapters/rocketPool/Swapper.sol";
import {SFrxETHAdapter} from "@napier/v1-tranche/src/adapters/frax/SFrxETHAdapter.sol";
import {StEtherAdapter} from "@napier/v1-tranche/src/adapters/lido/StEtherAdapter.sol";

import "@napier/v1-tranche/src/Constants.sol" as Constants;

library Casts {
    function asMockAdapter(IBaseAdapter x) internal pure returns (MockAdapter) {
        return MockAdapter(address(x));
    }

    function asLstVault(MockAdapter x) internal pure returns (BaseLSTVault) {
        return BaseLSTVault(payable(address(x)));
    }
}

contract LST_ForkTest is ForkTest {
    using Casts for *;

    /// @dev FraxEther redemption queue contract https://etherscan.io/address/0x82bA8da44Cd5261762e629dd5c605b17715727bd
    address constant REDEMPTION_QUEUE = 0x82bA8da44Cd5261762e629dd5c605b17715727bd;

    /// @dev FraxEther minter contract
    address constant FRXETH_MINTER = 0xbAFA44EFE7901E04E39Dad13167D089C559c1138;

    /// @notice Rocket Pool Storage https://www.codeslaw.app/contracts/ethereum/0x1d8f8f00cfa6758d7be78336684788fb0ee0fa46
    address constant ROCKET_STORAGE = 0x1d8f8f00cfa6758d7bE78336684788Fb0ee0Fa46;

    address constant ROCKET_DAO_SETTINGS_DEPOSIT = 0xac2245BE4C2C1E9752499Bcd34861B761d62fC27;

    address constant RETH_ETH_POOL = 0x0f3159811670c117c372428D4E69AC32325e4D0F;

    uint256 constant DEFAULT_MAX_STAKE_LIMIT = 10_000 ether;
    uint256 constant DEFAULT_STAKE_LIMIT_INCREASE_PER_BLOCK = 0.00015 ether; // About 1 ether recovery per 1 day

    /// @notice Vault rebalancer for LST adapter
    address rebalancer = makeAddr("rebalancer");

    /// @notice Swapper contract for rETHAdapter
    Swapper swapper;

    function setUp() public override {
        // Fork Ethereum Mainnet at a specific block number.
        blockNumber = 19_000_000;
        vm.createSelectFork({blockNumber: blockNumber, urlOrAlias: network});

        // note sfrxETH Exchange rate increases as the frax msig mints new frxETH corresponding to the staking yield and drops it into the vault (sfrxETH contract).
        // There is a short time period, “cycles” which the exchange rate increases linearly over.
        // See `sfrxETH` and `xERC4626` contract for more details.
        // https://github.com/FraxFinance/frxETH-public/blob/master/src/sfrxETH.sol
        // https://github.com/corddry/ERC4626/blob/6cf2bee5d784169acb02cc6ac0489ca197a4f149/src/xERC4626.sol
        // Here, we need to set the current timestamp to a time when the last sync happened.
        // Otherwise, the sfrxETH will revert with underflow error on share price calculation (totalAssets function in xERC4626.sol).
        {
            (bool s, bytes memory ret) = Constants.STAKED_FRXETH.staticcall(abi.encodeWithSignature("lastSync()"));
            require(s, "sfrxETH.lastSync() failed");
            uint32 lastSyncAt = abi.decode(ret, (uint32));
            vm.warp(lastSyncAt);
        }

        // note Rocket Pool has a maximum deposit pool size.
        // https://github.com/rocket-pool/rocketpool/blob/6a9dbfd85772900bb192aabeb0c9b8d9f6e019d1/contracts/contract/deposit/RocketDepositPool.sol#L96
        // https://github.com/rocket-pool/rocketpool/blob/6a9dbfd85772900bb192aabeb0c9b8d9f6e019d1/contracts/contract/dao/protocol/settings/RocketDAOProtocolSettingsDeposit.sol
        // Here, we need to change the maximum deposit pool size to a larger value.
        {
            (bool s, bytes memory returndata) =
                ROCKET_DAO_SETTINGS_DEPOSIT.staticcall(abi.encodeWithSignature("getMaximumDepositPoolSize()"));
            require(s, "RocketPoolHelper: failed to get maximum deposit pool size");
            uint256 maxDeposit = abi.decode(returndata, (uint256));
            vm.mockCall(
                ROCKET_DAO_SETTINGS_DEPOSIT,
                abi.encodeWithSignature("getMaximumDepositPoolSize()"),
                abi.encode(maxDeposit + 10000 ether)
            );
        }

        // create a new instance of VyperDeployer
        vyperDeployer = new VyperDeployer();

        maturity = block.timestamp + 365 days;

        weth = IWETH9(Constants.WETH); // WETH Ethereum Mainnet
        _deployAdaptersAndPrincipalTokens();
        _deployCurveV2Pool();
        _deployNapierPool();
        _deployNapierRouter();
        _deployTrancheRouter();

        _label();

        // Set up the initial liquidity to Tricrypto and Napier Pool.
        _issueAndAddLiquidities({
            recipient: address(this),
            underlyingIn: 1000 ether,
            uIssues: [uint256(1000 ether), 1000 ether, 1000 ether]
        });

        _fund();

        vm.startPrank(alice);
    }

    function _label() internal override {
        super._label();
        vm.label(Constants.WETH, "WETH");
        // Frax
        vm.label(FRXETH_MINTER, "frxETHMinter");
        vm.label(REDEMPTION_QUEUE, "frxETHQueue");
        vm.label(Constants.FRXETH, "frxETH");
        vm.label(Constants.STAKED_FRXETH, "sfrxETH");
        // Rocket Pool
        vm.label(Constants.RETH, "rETH");
        vm.label(ROCKET_STORAGE, "RocketStorage");
        vm.label(ROCKET_DAO_SETTINGS_DEPOSIT, "RocketDAOSettingsDeposit");
        vm.label(0x3bDC69C4E5e13E52A65f5583c23EFB9636b469d6, "RocketVault");
        vm.label(0x9e966733e3E9BFA56aF95f762921859417cF6FaA, "MiniPoolQueue");
        // Lido
        vm.label(Constants.STETH, "stETH");
        vm.label(Constants.LIDO_WITHDRAWAL_QUEUE, "stETHQueue");
    }

    function _deployUnderlying() internal override {
        underlying = weth;
        uDecimals = 18;
        ONE_UNDERLYING = 1 ether;
        FUZZ_MAX_UNDERLYING = 100 ether;
    }

    function _deployAdaptersAndPrincipalTokens() internal override {
        _deployUnderlying();
        trancheFactory = new TrancheFactory(owner);
        swapper = new Swapper(RETH_ETH_POOL);
        /// Hack Fix `adapters` type to be `IBaseAdapter[]`
        vm.startPrank(owner);
        adapters = [
            new RETHAdapter(rebalancer, address(swapper), ROCKET_STORAGE).asMockAdapter(),
            new StEtherAdapter(rebalancer, DEFAULT_MAX_STAKE_LIMIT, DEFAULT_STAKE_LIMIT_INCREASE_PER_BLOCK).asMockAdapter(),
            new SFrxETHAdapter(rebalancer, DEFAULT_MAX_STAKE_LIMIT, DEFAULT_STAKE_LIMIT_INCREASE_PER_BLOCK).asMockAdapter()
        ];
        targets = [IERC20(adapters[0].target()), IERC20(adapters[1].target()), IERC20(adapters[2].target())];

        for (uint256 i = 0; i < N_COINS; i++) {
            pts[i] = Tranche(trancheFactory.deployTranche(address(adapters[i]), maturity, issuanceFee));
            yts[i] = YieldToken(pts[i].yieldToken());
            // Set the tranche to the adapter
            adapters[i].asLstVault().setTranche(address(pts[i]));
        }
        vm.stopPrank();
    }

    modifier boundParamsSwap(Params_Swap memory params) override {
        if (useEth) assumePayable(params.recipient); // make sure recipient can be payable
        vm.assume(params.recipient != address(0) && params.recipient != address(pool)); // make sure recipient is not the pool itself
        params.timestamp = _bound(params.timestamp, block.timestamp, maturity - 1);
        params.index = _bound(params.index, 0, 2);
        params.amount = _bound(params.amount, ONE_UNDERLYING / 100, FUZZ_MAX_UNDERLYING); // swap large amount will revert
        _;
    }
}

contract LST_NativeETH_ForkTest is LST_ForkTest {
    constructor() {
        useEth = true;
    }
}
