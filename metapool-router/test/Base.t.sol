// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import {Test} from "forge-std/Test.sol";

import {VyperDeployer} from "@napier/v1-pool/lib/VyperDeployer.sol";
import {TricryptoNGPrecompiles} from "./TricryptoNGPrecompiles.sol";

import {IERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/IERC20.sol";
import {IVault} from "src/interfaces/external/balancer/IVault.sol";

// Mocks
import {WETHMock, IWETH9} from "@napier/v1-pool/test/mocks/WETHMock.sol";
import {MockERC20} from "@napier/v1-tranche/test/mocks/MockERC20.sol";
import {MockAdapter} from "@napier/v1-tranche/test/mocks/MockAdapter.sol";
import {MockCallbackReceiver} from "./mocks/MockCallbackReceiver.sol";

// Curve
import {CurveTricryptoFactory} from "@napier/v1-pool/src/interfaces/external/CurveTricryptoFactory.sol";
import {CurveTricryptoOptimizedWETH} from "@napier/v1-pool/src/interfaces/external/CurveTricryptoOptimizedWETH.sol";
import {TwocryptoFactory} from "src/interfaces/external/TwocryptoFactory.sol";
import {Twocrypto} from "src/interfaces/external/Twocrypto.sol";

// Napier
import {ITranche} from "@napier/v1-tranche/src/interfaces/ITranche.sol";
import {IYieldToken} from "@napier/v1-tranche/src/interfaces/IYieldToken.sol";
import {INapierPool} from "@napier/v1-pool/src/interfaces/INapierPool.sol";
import {TrancheFactory} from "@napier/v1-tranche/src/TrancheFactory.sol";
import {PoolFactory, IPoolFactory} from "@napier/v1-pool/src/PoolFactory.sol";

// PtMetapool Router
import {MetapoolFactory} from "src/MetapoolFactory.sol";
import {MetapoolRouter} from "src/MetapoolRouter.sol";

contract Base is Test {
    ///@notice create a new instance of VyperDeployer
    VyperDeployer vyperDeployer = new VyperDeployer();

    // Napier Pool configuration
    IPoolFactory.PoolConfig poolConfig = IPoolFactory.PoolConfig({
        initialAnchor: 1.2 * 1e18,
        scalarRoot: 8 * 1e18,
        lnFeeRateRoot: 0.000995 * 1e18,
        protocolFeePercent: 80,
        feeRecipient: feeRecipient
    });
    // TricryptoNG params
    TricryptoNGPrecompiles.TricryptoNGParams tricryptoParams = TricryptoNGPrecompiles.TricryptoNGParams({
        A: 270_000_000,
        gamma: 0.019 * 1e18,
        mid_fee: 1_000_000, // 0.01%
        out_fee: 20_000_000, // 0.20%
        fee_gamma: 0.22 * 1e18, // 0.22
        allowed_extra_profit: 0.000002 * 1e18,
        adjustment_step: 0.00049 * 1e18,
        ma_time: 3600,
        initial_prices: [uint256(1e18), 1e18]
    });
    // TwocryptoNG params
    MetapoolFactory.TwocryptoParams twocryptoParams = MetapoolFactory.TwocryptoParams({
        A: 400_000,
        gamma: 0.000145 * 1e18,
        mid_fee: 0.26 * 1e8,
        out_fee: 0.45 * 1e8,
        fee_gamma: 0.00023 * 1e18,
        allowed_extra_profit: 0.000002 * 1e18,
        adjustment_step: 0.000146 * 1e18,
        ma_time: 866,
        /// Note: 1 Tricrypto LP token (coin1) consists of sum of 3 coin for each.
        // 1 Tricrypto LP token (coin1) ~ 3 coin0
        initial_price: 3 * 1e18 // price of the coins[1] against the coins[0]
    });

    // Napier ITranche params
    uint256 maturity;
    uint256 issuanceFee = 100; // 1%

    //// States ////

    address owner = makeAddr("owner");
    address feeRecipient = makeAddr("feeRecipient");
    address curveFeeReceiver = makeAddr("curveFeeReceiver");
    address curveAdmin = makeAddr("curveAdmin");

    /// @dev Account used to set up liquidity for tests
    address anny = makeAddr("anny");

    //// Users ////

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    //// Contracts ////

    IVault vault = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8); // Balancer Vault
    IWETH9 weth;

    // TricryptoNG
    CurveTricryptoFactory tricryptoFactory;
    CurveTricryptoOptimizedWETH tricryptoLST; // triLSTPrincipalToken Tricrypto Pool

    // Napier ITranche
    TrancheFactory trancheFactory;
    IERC20[3] lstTargets;
    ITranche[3] lstPts;
    IYieldToken[3] lstYts;
    MockAdapter[3] adapters;

    // Napier Pool
    PoolFactory poolFactory;
    INapierPool triLSTPool; // triLSTPrincipalToken-ETH Napier Pool

    // Twocrypto
    TwocryptoFactory twocryptoFactory;
    Twocrypto twocrypto;

    // PtMetapool
    MetapoolFactory metapoolFactory;
    MetapoolRouter metapoolRouter;
    address quoter;

    // Pair PT and YT
    MockAdapter adapter;
    ITranche pairPt;
    IYieldToken pairYt;

    function setUp() public virtual {
        maturity = block.timestamp + 365 days;

        _deployWETH();
        _deployNapierLST3PT();
        _deployNapierLST3PTPool();
        _deployTwocryptoFactory();
        _deployPairPT();
        _deployPtMetapool();
        _deployQuoter();

        // Setup a special account `anny`
        vm.startPrank(anny);
        for (uint256 i = 0; i < 3; i++) {
            approve(lstPts[i], address(tricryptoLST), type(uint256).max);
            approve(weth, address(lstPts[i]), type(uint256).max);
        }
        approve(weth, address(pairPt), type(uint256).max);
        approve(pairPt, address(twocrypto), type(uint256).max);
        approve(tricryptoLST, address(triLSTPool), type(uint256).max);
        approve(tricryptoLST, address(twocrypto), type(uint256).max);
        vm.stopPrank();

        deal(alice, type(uint96).max);
    }

    function _deployPairPT() internal {
        MockERC20 target = new MockERC20("targetPair", "targetPair", 18);
        adapter = new MockAdapter(address(weth), address(target));
        vm.prank(owner);
        pairPt = ITranche(trancheFactory.deployTranche(address(adapter), maturity, issuanceFee));
        pairYt = IYieldToken(pairPt.yieldToken());
    }

    function _deployPtMetapool() internal {
        metapoolFactory = new MetapoolFactory(owner, address(weth), twocryptoFactory);
        vm.prank(owner);
        twocrypto = Twocrypto(
            metapoolFactory.deployMetapool(
                address(pairPt),
                address(triLSTPool),
                0,
                // Too long string causes Twocrypto to revert in constructor
                "3LSTPT/HogePT",
                "3LSTHOGEPT",
                twocryptoParams
            )
        );
        metapoolRouter = new MetapoolRouter(metapoolFactory, triLSTPool, vault);
    }

    function _deployTwocryptoFactory() internal {
        address math =
            vyperDeployer.deployContract("lib/twocrypto-ng/contracts/main/CurveCryptoMathOptimized2", "paris");
        address views =
            vyperDeployer.deployContract("lib/twocrypto-ng/contracts/main/CurveCryptoViews2Optimized", "paris");
        address amm_blueprint =
            vyperDeployer.deployBlueprint("lib/twocrypto-ng/contracts/main/CurveTwocryptoOptimized", "paris");
        vm.label(math, "2cry_math");
        vm.label(views, "2cry_views");
        vm.label(amm_blueprint, "2cry_amm_blueprint");

        vm.startPrank(curveAdmin, curveAdmin); // `self.deployer` is set to `tx.origin` in the constructor
        twocryptoFactory = TwocryptoFactory(
            vyperDeployer.deployContract("lib/twocrypto-ng/contracts/main/CurveTwocryptoFactory", "paris")
        );
        twocryptoFactory.initialise_ownership(curveFeeReceiver, curveAdmin);
        twocryptoFactory.set_pool_implementation(amm_blueprint, 0);
        twocryptoFactory.set_views_implementation(views);
        twocryptoFactory.set_math_implementation(math);
        vm.stopPrank();
    }

    function _deployNapierLST3PT() internal {
        // deploy mock weth, three lstTargets, adapters and tranches
        trancheFactory = new TrancheFactory(owner);

        for (uint256 i = 0; i < 3; i++) {
            string memory name = string.concat("target", vm.toString(i));
            lstTargets[i] = new MockERC20(name, name, 18);
            adapters[i] = new MockAdapter(address(weth), address(lstTargets[i]));
            vm.prank(owner);
            lstPts[i] = ITranche(trancheFactory.deployTranche(address(adapters[i]), maturity, issuanceFee));
            lstYts[i] = IYieldToken(lstPts[i].yieldToken());
        }
    }

    function _deployNapierLST3PTPool() internal {
        //// Deploy Tricrypto ///
        address math = TricryptoNGPrecompiles.deployMath();
        address views = TricryptoNGPrecompiles.deployViews();
        address amm_blueprint = TricryptoNGPrecompiles.deployAMMBlueprint();
        tricryptoFactory = TricryptoNGPrecompiles.deployFactory(curveFeeReceiver, curveAdmin);

        vm.label(math, "3cry_math");
        vm.label(views, "3cry_views");
        vm.label(amm_blueprint, "3cry_amm_blueprint");
        // setup tricrypto pool impl
        vm.startPrank(curveAdmin);
        tricryptoFactory.set_pool_implementation(amm_blueprint, 0);
        tricryptoFactory.set_views_implementation(views);
        tricryptoFactory.set_math_implementation(math);
        vm.stopPrank();

        tricryptoLST = TricryptoNGPrecompiles.deployTricrypto(
            tricryptoFactory,
            "Tricrypto LST3PT",
            "LST3PT",
            [address(lstPts[0]), address(lstPts[1]), address(lstPts[2])],
            address(weth),
            0,
            tricryptoParams
        );
        //// Deploy Napier Pool ///
        poolFactory = new PoolFactory(address(tricryptoFactory), owner);
        vm.prank(owner);
        triLSTPool = INapierPool(poolFactory.deploy(address(tricryptoLST), address(weth), poolConfig));
    }

    function _deployWETH() internal {
        weth = new WETHMock();
    }

    function _deployQuoter() internal {
        quoter = deployCode("Quoter.sol:Quoter", abi.encode(metapoolFactory, vault));
    }

    function _label() internal virtual {
        vm.label(address(tricryptoLST), "LST3PT");
        vm.label(address(triLSTPool), "LST3PT_ETH");
        vm.label(address(pairPt), "pairPt");
        vm.label(address(pairYt), "pairYt");
        vm.label(address(adapter), "pairAdapter");
        vm.label(address(weth), "WETH");
        vm.label(address(tricryptoFactory), "tricryptoFactory");
        vm.label(address(poolFactory), "poolFactory");
        vm.label(address(trancheFactory), "trancheFactory");
        for (uint256 i = 0; i < 3; i++) {
            vm.label(address(lstPts[i]), string.concat("lstPts[", vm.toString(i), "]"));
            vm.label(address(lstYts[i]), string.concat("lstYts[", vm.toString(i), "]"));
            vm.label(address(lstTargets[i]), string.concat("lstTargets[", vm.toString(i), "]"));
            vm.label(address(adapters[i]), string.concat("adapters[", vm.toString(i), "]"));
        }
        vm.label(address(twocryptoFactory), "twocryptoFactory");
        vm.label(address(twocrypto), "twocrypto");
        vm.label(address(metapoolRouter), "metapoolRouter");
        vm.label(address(metapoolFactory), "metapoolFactory");
    }

    /// @dev  Setup mock callback receiver code to address `to` for testing
    function _deployMockCallbackReceiverTo(address to) internal {
        deployCodeTo("test/mocks/MockCallbackReceiver.sol:MockCallbackReceiver", to);
        address caller = readMsgSender();
        changePrank(owner, owner);
        poolFactory.authorizeCallbackReceiver(to);
        changePrank(caller, caller); // revert to original caller
    }

    function approve(IERC20 token, address spender, uint256 value) internal {
        // We use a low-level call to ignore reverts because the asset can have the missing return value bug.
        (bool success,) = address(token).call(abi.encodeCall(IERC20.approve, (spender, value)));
        success; // silence the warning
    }

    function readMsgSender() internal returns (address msgSender) {
        (, msgSender,) = vm.readCallers();
    }

    function _bound(uint256[3] memory x, uint256 min, uint256 max) internal pure returns (uint256[3] memory) {
        for (uint256 i = 0; i < 3; i++) {
            x[i] = _bound(x[i], min, max);
        }
        return x;
    }

    //// Asserts ////
    function assertNoFundLeftInRouter() internal {
        assertEq(address(metapoolRouter).balance, 0, "Router should have no native ETH left");
        assertEq(weth.balanceOf(address(metapoolRouter)), 0, "Router should have no WETH left");
        assertEq(tricryptoLST.balanceOf(address(metapoolRouter)), 0, "Router should have no LST3PT left");
        assertEq(address(metapoolRouter).balance, 0, "Router should have no native ETH left");
        assertEq(pairPt.balanceOf(address(metapoolRouter)), 0, "Router should have no pair PT left");
        assertEq(pairYt.balanceOf(address(metapoolRouter)), 0, "Router should have no pair YT left");
        assertEq(twocrypto.balanceOf(address(metapoolRouter)), 0, "Router should have no twocrypto PT left");
    }

    function deal(address token, address to, uint256 give, bool adjust) internal override {
        // `deal` against WETH generates WETH without collateral.
        // we donate the exact amount of native ETH
        if (token == address(weth)) {
            vm.deal(address(weth), address(weth).balance + give);
        }
        super.deal(token, to, give, adjust);
    }
}
