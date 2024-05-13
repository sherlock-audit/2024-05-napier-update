// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {NapierHardhatDeployer} from "script/NapierHardhatDeployer.sol";

import {IERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/IERC20.sol";

// external deps
import {CurveTricryptoFactory} from "src/interfaces/external/CurveTricryptoFactory.sol";
import {CurveTricryptoOptimizedWETH} from "src/interfaces/external/CurveTricryptoOptimizedWETH.sol";
import {TrancheFactory} from "@napier/v1-tranche/src/TrancheFactory.sol";
import {YieldToken} from "@napier/v1-tranche/src/YieldToken.sol";
import {Tranche} from "@napier/v1-tranche/src/Tranche.sol";
// internal deps
import {PoolFactory, IPoolFactory} from "src/PoolFactory.sol";
import {NapierPool} from "src/NapierPool.sol";
import {INapierRouter} from "src/interfaces/INapierRouter.sol";
import {ITrancheRouter} from "src/interfaces/ITrancheRouter.sol";

import {WETHMock, IWETH9} from "./mocks/WETHMock.sol";
import {MockERC20} from "@napier/v1-tranche/test/mocks/MockERC20.sol";
import {MockAdapter} from "@napier/v1-tranche/test/mocks/MockAdapter.sol";

import {VyperDeployer} from "../lib/VyperDeployer.sol";
import {CallbackInputType, AddLiquidityInput} from "./shared/CallbackInputType.sol";

abstract contract Base is Test {
    using stdStorage for StdStorage;

    uint256 internal constant MAX_UINT256 = type(uint256).max;
    uint256 internal constant MAX_UINT128 = type(uint128).max;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    ///@notice create a new instance of VyperDeployer
    VyperDeployer vyperDeployer = new VyperDeployer();

    /// @dev The order of the members in the struct must match the order of the arguments in the `deploy_pool` function signature
    struct CurveV2Params {
        uint256 A;
        uint256 gamma;
        uint256 mid_fee;
        uint256 out_fee;
        uint256 fee_gamma;
        uint256 allowed_extra_profit;
        uint256 adjustment_step;
        uint256 ma_time;
        uint256[2] initial_prices;
    }

    //////////////////////////////////////////////////////////////////////////////
    // States
    //////////////////////////////////////////////////////////////////////////////

    uint256 constant N_COINS = 3;

    address owner = makeAddr("owner");
    address feeRecipient = makeAddr("feeRecipient");
    address curveAdmin = makeAddr("curveAdmin");
    address curveFeeReceiver = makeAddr("curveFeeReceiver");
    uint256 maturity = block.timestamp + 365 days;

    IWETH9 weth;
    // Curve v2
    CurveTricryptoFactory curveFactory;
    CurveTricryptoOptimizedWETH tricrypto;
    // Napier Tranche and Adapter
    TrancheFactory trancheFactory;
    IERC20 underlying;
    uint256 uDecimals; // underlying decimals
    uint256 ONE_UNDERLYING; // 10**uDecimals
    IERC20[3] targets;
    Tranche[3] pts;
    YieldToken[3] yts;
    MockAdapter[3] adapters;
    // Napier Pool
    PoolFactory poolFactory;
    NapierPool pool;
    INapierRouter router;
    ITrancheRouter trancheRouter;

    // Napier Tranche Configuration
    uint256 issuanceFee = 100; // 1%

    // Napier Pool Configuration
    IPoolFactory.PoolConfig poolConfig = IPoolFactory.PoolConfig({
        initialAnchor: 1.2 * 1e18,
        scalarRoot: 8 * 1e18,
        lnFeeRateRoot: 0.000995 * 1e18,
        protocolFeePercent: 80,
        feeRecipient: feeRecipient
    });
    // Curve v2 Pool Configuration
    CurveV2Params params = CurveV2Params({
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

    function _deployUnderlying() internal virtual {
        underlying = new MockERC20("Underlying", "UNDERLYING", 6);
        uDecimals = 6;
        ONE_UNDERLYING = 10 ** uDecimals;
    }

    /// @notice deploy mock underlying, three targets, adapters and tranches
    function _deployAdaptersAndPrincipalTokens() internal virtual {
        _deployUnderlying();
        trancheFactory = new TrancheFactory(owner);

        for (uint256 i = 0; i < N_COINS; i++) {
            string memory name = string.concat("target", vm.toString(i));
            targets[i] = new MockERC20(name, name, 18);
            adapters[i] = new MockAdapter(address(underlying), address(targets[i]));
            vm.prank(owner);
            pts[i] = Tranche(trancheFactory.deployTranche(address(adapters[i]), maturity, issuanceFee));
            yts[i] = YieldToken(pts[i].yieldToken());
        }
    }

    function _deployNapierPool() internal virtual {
        if (vm.envOr("OPTIMIZE", false)) {
            poolFactory = PoolFactory(NapierHardhatDeployer.deployNapierPoolFactory(address(curveFactory), owner));
        } else {
            poolFactory = new PoolFactory(address(curveFactory), owner);
        }
        vm.prank(owner);
        pool = NapierPool(poolFactory.deploy(address(tricrypto), address(underlying), poolConfig));
    }

    function _deployCurveV2Pool() internal virtual {
        // Ensure evm version is shanghai because tricrypto-ng requires shanghai
        {
            address math =
                vyperDeployer.deployContract("lib/tricrypto-ng/contracts/main/CurveCryptoMathOptimized3", "shanghai");
            address views =
                vyperDeployer.deployContract("lib/tricrypto-ng/contracts/main/CurveCryptoViews3Optimized", "shanghai");
            address amm_blueprint =
                vyperDeployer.deployBlueprint("lib/tricrypto-ng/contracts/main/CurveTricryptoOptimizedWETH", "shanghai");
            vm.label(math, "math");
            vm.label(views, "views");
            vm.label(amm_blueprint, "amm_blueprint");
            curveFactory = CurveTricryptoFactory(
                vyperDeployer.deployContract(
                    "lib/tricrypto-ng/contracts/main/CurveTricryptoFactory",
                    abi.encode(curveFeeReceiver, curveAdmin),
                    "shanghai"
                )
            );
            // setup tricrypto pool impl
            vm.startPrank(curveAdmin);
            curveFactory.set_pool_implementation(amm_blueprint, 0);
            curveFactory.set_views_implementation(views);
            curveFactory.set_math_implementation(math);
            vm.stopPrank();
        }
        // deploy tricrypto pool with 3 Principal Tokens
        bytes memory data = abi.encodeWithSignature(
            "deploy_pool(string,string,address[3],address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[2])",
            "Curve.fi USDC-PT1-PT2-PT3",
            "PT1PT2PT3",
            [address(pts[0]), address(pts[1]), address(pts[2])],
            weth,
            0, // <-------- 0th implementation index
            // The order of the members in the struct must match the order of the arguments in the function signature
            params
        );
        (bool s, bytes memory ret) = address(curveFactory).call(data);
        if (!s) revert("Base.t.sol:TricryptoFactory::deploy_pool failed");
        tricrypto = CurveTricryptoOptimizedWETH(abi.decode(ret, (address)));
    }

    function _deployWETH() internal virtual {
        weth = new WETHMock();
    }

    function _deployNapierRouter() internal virtual {
        vm.prank(owner);
        if (weth == WETHMock(address(0))) _deployWETH();
        if (vm.envOr("OPTIMIZE", false)) {
            router =
                INapierRouter(payable(NapierHardhatDeployer.deployNapierRouter(address(poolFactory), address(weth))));
        } else {
            // Hack: Fewer dependencies, compiles faster
            router = INapierRouter(deployCode("NapierRouter.sol:NapierRouter", abi.encode(poolFactory, weth)));
        }

        vm.prank(owner);
        poolFactory.authorizeCallbackReceiver(address(router));
    }

    function _deployTrancheRouter() internal virtual {
        vm.prank(owner);
        if (weth == WETHMock(address(0))) _deployWETH();
        if (vm.envOr("OPTIMIZE", false)) {
            trancheRouter = ITrancheRouter(
                payable(NapierHardhatDeployer.deployTrancheRouter(address(trancheFactory), address(weth)))
            );
        } else {
            trancheRouter =
                ITrancheRouter(deployCode("TrancheRouter.sol:TrancheRouter", abi.encode(trancheFactory, weth)));
        }
    }

    function _deployQuoter() internal virtual returns (address quoter) {
        if (vm.envOr("OPTIMIZE", false)) {
            quoter = NapierHardhatDeployer.deployQuoter(address(poolFactory));
        } else {
            // Hack: avoid tons of dependencies
            quoter = deployCode("Quoter.sol:Quoter", abi.encode(poolFactory));
        }
        vm.label(address(quoter), "quoter");
        vm.prank(owner);
        poolFactory.authorizeCallbackReceiver(quoter);
    }

    function _deployMockCallbackReceiverTo(address to) internal {
        // setup mock callback receiver
        deployCodeTo("MockCallbackReceiver.sol", to);
        vm.prank(owner);
        poolFactory.authorizeCallbackReceiver(to);
    }

    function _deployFaultyCallbackReceiverTo(address to) internal {
        // setup mock callback receiver
        deployCodeTo("FaultyCallbackReceiver.sol", to);
        vm.prank(owner);
        poolFactory.authorizeCallbackReceiver(to);
    }

    function _label() internal virtual {
        vm.label(address(poolFactory), "poolFactory");
        vm.label(address(curveFactory), "curveFactory");
        vm.label(address(trancheFactory), "trancheFactory");
        vm.label(address(tricrypto), "tricrypto");
        vm.label(address(underlying), "underlying");
        vm.label(address(pool), "pool");
        vm.label(address(router), "swapRouter");
        vm.label(address(trancheRouter), "trancheRouter");
        for (uint256 i = 0; i < N_COINS; i++) {
            vm.label(address(targets[i]), string.concat("targets[", vm.toString(i), "]"));
            vm.label(address(adapters[i]), string.concat("adapters[", vm.toString(i), "]"));
            vm.label(address(pts[i]), string.concat("pts[", vm.toString(i), "]"));
            vm.label(address(yts[i]), string.concat("yts[", vm.toString(i), "]"));
        }
        vm.label(curveAdmin, "curveAdmin");
        vm.label(feeRecipient, "feeRecipient");
    }

    //////////////////////////////////////////////////////////////////////////////
    // Setup helpers
    //////////////////////////////////////////////////////////////////////////////

    function _authorizeCallback(address receiver) internal {
        vm.prank(owner);
        poolFactory.authorizeCallbackReceiver(receiver);
    }

    /// @dev Helper function to deposit liquidity to NapierPool and Curve Pool
    /// Note: Principal Token is minted in a normal way.
    /// @param recipient Recipient of the liquidity tokens
    /// @param underlyingIn Amount of underlying to deposit to NapierPool
    /// @param uIssues Amount of underlying used to issue Principal Tokens which will be deposited to Curve Pool
    function _issueAndAddLiquidities(address recipient, uint256 underlyingIn, uint256[3] memory uIssues)
        public
        returns (uint256)
    {
        uint256[3] memory ptsIssued;
        address issuer = makeAddr("issuer");
        _deployMockCallbackReceiverTo(issuer); // setup mock callback receiver

        deal(address(underlying), address(issuer), underlyingIn + N_COINS * uIssues[0] + uIssues[1] + uIssues[2], false);
        // issue pts
        for (uint256 i = 0; i < N_COINS; i++) {
            _approve(underlying, issuer, address(pts[i]), type(uint256).max);
            vm.prank(issuer);
            ptsIssued[i] = pts[i].issue(issuer, uIssues[i]);
        }
        // transfer Base LP token to pool
        _approvePts(issuer, address(tricrypto), type(uint256).max);
        vm.prank(issuer);
        uint256 baseLptMinted = tricrypto.add_liquidity(ptsIssued, 0);

        vm.prank(issuer);
        return pool.addLiquidity(
            underlyingIn,
            baseLptMinted,
            recipient,
            abi.encode(CallbackInputType.AddLiquidity, AddLiquidityInput(underlying, tricrypto))
        );
    }

    //////////////////////////////////////////////////////////////////////////////
    // Assertions
    //////////////////////////////////////////////////////////////////////////////

    function assertPoolReserveRatio(
        uint256[2] memory reservesBefore,
        uint256[2] memory reservesAfter,
        uint256 maxPercentDelta
    ) internal {
        assertApproxEqRel(
            reservesAfter[0] * WAD / reservesAfter[1],
            reservesBefore[0] * WAD / reservesBefore[1],
            maxPercentDelta,
            "should be approx equal to reserve ratio after adding/removing liquidity"
        );
    }

    function assertSolvencyReserve() internal {
        assertGe(
            underlying.balanceOf(address(pool)),
            pool.totalUnderlying(), // balance should be greater because of the fee charged on swaps
            "[insolvency] underlying balance should be gt stored reserve value"
        );
        assertGe(
            tricrypto.balanceOf(address(pool)),
            pool.totalBaseLpt(),
            "[insolvency] baseLpt balance should be gt stored reserve value"
        );
    }

    function assertReserveBalanceMatch() internal {
        // fee is not included in reserve. so balance may be greater than reserve
        assertGe(
            underlying.balanceOf(address(pool)),
            pool.totalUnderlying(),
            "underlying balance should be equal to stored reserve value"
        );
        uint256 bBalance = tricrypto.balanceOf(address(pool));
        uint256 bReserve = pool.totalBaseLpt();
        assertGe(bBalance, bReserve, "baseLpt balance should be greater than stored reserve value");
        assertApproxEqAbs(bBalance, bReserve, 10, "baseLpt balance should be equal to stored reserve value");
    }

    /// @dev NapierRouter should not have any fund left
    function assertNoFundLeftInPoolSwapRouter() internal {
        assertEq(underlying.balanceOf(address(router)), 0, "[prop] router should not have any underlying");
        assertEq(tricrypto.balanceOf(address(router)), 0, "[prop] router should not have any baseLpt");
        assertEq(pts[0].balanceOf(address(router)), 0, "[prop] router should not have any pt[0]");
        assertEq(pts[1].balanceOf(address(router)), 0, "[prop] router should not have any pt[1]");
        assertEq(pts[2].balanceOf(address(router)), 0, "[prop] router should not have any pt[2]");
        assertEq(yts[0].balanceOf(address(router)), 0, "[prop] router should not have any yt[0]");
        assertEq(yts[1].balanceOf(address(router)), 0, "[prop] router should not have any yt[1]");
        assertEq(yts[2].balanceOf(address(router)), 0, "[prop] router should not have any yt[2]");
        assertEq(pool.balanceOf(address(router)), 0, "[prop] router should not have any lp token");
        assertEq(address(router).balance, 0, "[prop] router should not have any ether");
        assertEq(weth.balanceOf(address(router)), 0, "[prop] router should not have any weth");
    }

    /// @dev TrancheRouter should not have any fund left
    function assertNoFundLeftInTrancheRouter() internal {
        assertEq(underlying.balanceOf(address(trancheRouter)), 0, "[prop] trancheRouter should not have any underlying");
        assertEq(tricrypto.balanceOf(address(trancheRouter)), 0, "[prop] trancheRouter should not have any baseLpt");
        assertEq(pts[0].balanceOf(address(trancheRouter)), 0, "[prop] trancheRouter should not have any pt[0]");
        assertEq(pts[1].balanceOf(address(trancheRouter)), 0, "[prop] trancheRouter should not have any pt[1]");
        assertEq(pts[2].balanceOf(address(trancheRouter)), 0, "[prop] trancheRouter should not have any pt[2]");
        assertEq(yts[0].balanceOf(address(trancheRouter)), 0, "[prop] trancheRouter should not have any yt[0]");
        assertEq(yts[1].balanceOf(address(trancheRouter)), 0, "[prop] trancheRouter should not have any yt[1]");
        assertEq(yts[2].balanceOf(address(trancheRouter)), 0, "[prop] trancheRouter should not have any yt[2]");
        assertEq(pool.balanceOf(address(trancheRouter)), 0, "[prop] trancheRouter should not have any lp token");
        assertEq(address(trancheRouter).balance, 0, "[prop] trancheRouter should not have any ether");
        assertEq(weth.balanceOf(address(trancheRouter)), 0, "[prop] trancheRouter should not have any weth");
    }

    //////////////////////////////////////////////////////////////////////////////
    // Helpers
    //////////////////////////////////////////////////////////////////////////////

    function _approve(IERC20 token, address _owner, address spender, uint256 value) internal {
        vm.startPrank(_owner);
        // We use a low-level call to ignore reverts because the asset can have the missing return value bug.
        (bool success,) = address(token).call(abi.encodeCall(IERC20.approve, (spender, 0)));
        (success,) = address(token).call(abi.encodeCall(IERC20.approve, (spender, value)));
        vm.stopPrank();
    }

    function _approvePts(address _owner, address spender, uint256 value) internal {
        vm.startPrank(_owner);
        for (uint256 i = 0; i < pts.length; i++) {
            pts[i].approve(spender, value);
        }
        vm.stopPrank();
    }

    function _overwriteWithOneKey(address account, string memory sig, address key, uint256 value) internal {
        stdstore.target(account).sig(sig).with_key(key).checked_write(value);
    }

    function fund(address token, address account, uint256 amount, bool adjust) internal {
        uint256 balance = IERC20(token).balanceOf(account);
        deal(token, account, balance + amount, adjust);
    }

    function dealPts(address to, uint256 amount, bool adjust) internal {
        for (uint256 i = 0; i < pts.length; i++) {
            deal(address(pts[i]), to, amount, adjust);
        }
    }

    function fundPts(address to, uint256 amount, bool adjust) internal {
        for (uint256 i = 0; i < pts.length; i++) {
            uint256 balance = pts[i].balanceOf(to);
            deal(address(pts[i]), to, balance + amount, adjust);
        }
    }

    /// @dev bound array in-place
    function bound(uint256[3] memory x, uint256 min, uint256 max) internal view virtual returns (uint256[3] memory) {
        for (uint256 i = 0; i < 3; i++) {
            x[i] = bound(x[i], min, max);
        }
        return x;
    }

    function boundIndex(uint256 index) internal view returns (uint256) {
        return bound(index, 0, N_COINS - 1);
    }

    modifier anytime() {
        _;
    }

    modifier whenMaturityPassed() {
        vm.warp(maturity + 1);
        _;
    }

    modifier whenMaturityNotPassed() {
        vm.warp(maturity - 1);
        _;
    }
}
