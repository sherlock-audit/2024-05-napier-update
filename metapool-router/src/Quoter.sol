// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

// Interfaces
import {CurveTricryptoOptimizedWETH} from "@napier/v1-pool/src/interfaces/external/CurveTricryptoOptimizedWETH.sol";
import {INapierPool} from "@napier/v1-pool/src/interfaces/INapierPool.sol";
import {ITranche} from "@napier/v1-tranche/src/interfaces/ITranche.sol";
import {IBaseAdapter} from "@napier/v1-tranche/src/interfaces/IBaseAdapter.sol";
import {Twocrypto} from "./interfaces/external/Twocrypto.sol";
import {IVault} from "./interfaces/external/balancer/IVault.sol";
import {MetapoolFactory} from "./MetapoolFactory.sol";

// Libraries
import {PoolMath} from "@napier/v1-pool/src/libs/PoolMath.sol";
import {TrancheMathHelper} from "@napier/v1-pool/src/libs/TrancheMathHelper.sol";
import {ApproxParams} from "@napier/v1-pool/src/interfaces/ApproxParams.sol";
import "@napier/v1-tranche/src/Constants.sol" as Constants;
import {Errors} from "./Errors.sol";

contract Quoter {
    /// @dev Constants for the Twocrypto metapool indexes
    /// coins(0) is the pegged token (PT) and coins(1) is the base pool token (triLST-PT Tricrypto)
    uint128 constant PEGGED_PT_INDEX = 0;
    uint128 constant BASE_POOL_INDEX = 1;

    /// @notice The Factory contract for the Principal Token metapools
    MetapoolFactory public immutable metapoolFactory;

    IVault public immutable vault;

    /// @notice If the metapool is not a TwoCrypto with Principal Token, revert.
    modifier checkMetapool(address metapool) {
        if (!metapoolFactory.isPtMetapool(metapool)) revert Errors.MetapoolRouterInvalidMetapool();
        _;
    }

    constructor(MetapoolFactory _metapoolFactory, IVault _vault) {
        metapoolFactory = _metapoolFactory;
        vault = _vault;
    }

    /// @notice Quote the amount of WETH needed to get the specified amount of PT
    /// @param metapool The address of the metapool
    /// @param pool The address of the NapierPool (3LST-PT<>ETH)
    /// @param ptAmount The amount of PT to get
    /// @return The amount of WETH spent to get the specified amount of PT
    function quoteSwapETHForPt(address metapool, address pool, uint256 ptAmount)
        external
        view
        checkMetapool(metapool)
        returns (uint256)
    {
        // Calculate the amount of base pool token required for the specified PT amount
        uint256 basePoolTokenAmount = Twocrypto(metapool).get_dx({i: BASE_POOL_INDEX, j: PEGGED_PT_INDEX, dy: ptAmount});

        (uint256 wethSpent,,) =
            PoolMath.swapUnderlyingForExactBaseLpToken(INapierPool(pool).readState(), basePoolTokenAmount);

        return wethSpent;
    }

    /// @notice Quote the amount of WETH received for the specified amount of PT
    /// @return The amount of WETH received for the specified amount of PT
    function quoteSwapPtForETH(address metapool, address pool, uint256 ptAmount)
        external
        view
        checkMetapool(metapool)
        returns (uint256)
    {
        // Estimate amount of base pool token out
        uint256 basePoolTokenAmount = Twocrypto(metapool).get_dy({i: PEGGED_PT_INDEX, j: BASE_POOL_INDEX, dx: ptAmount});

        // Swap the received base pool token for ETH on the 3LST-PT<>ETH NapierPool
        (uint256 wethOut,,) =
            PoolMath.swapExactBaseLpTokenForUnderlying(INapierPool(pool).readState(), basePoolTokenAmount);

        return wethOut;
    }

    function quoteSwapETHForYt(address metapool, address pool, uint256 ytAmount, ApproxParams memory approx)
        public
        view
        checkMetapool(metapool)
        returns (uint256 spent, uint256 wethDepositGuess)
    {
        ITranche pt = ITranche(Twocrypto(metapool).coins(PEGGED_PT_INDEX));

        // Estimate the amount of WETH needed to get the desired amount of YT
        wethDepositGuess =
            TrancheMathHelper.getApproxUnderlyingNeededByYt({pt: pt, ytDesired: ytAmount, approx: approx});

        uint256 ytIssued = _previewIssue(pt, wethDepositGuess);
        uint256 basePoolTokenOut = Twocrypto(metapool).get_dy(PEGGED_PT_INDEX, BASE_POOL_INDEX, ytIssued);

        // Swap the received base pool token for ETH on the NapierPool
        (uint256 wethReceived,,) =
            PoolMath.swapExactBaseLpTokenForUnderlying(INapierPool(pool).readState(), basePoolTokenOut);

        // Unreasonable situation: Received more WETH than sold
        if (wethReceived > wethDepositGuess) revert Errors.MetapoolRouterNonSituationSwapETHForYt();

        // Calculate flash loan fees for borrowing the `wethDepositGuess` amount of WETH
        uint256 feePercentageInWad = vault.getProtocolFeesCollector().getFlashLoanFeePercentage();
        uint256 fees = (wethDepositGuess * feePercentageInWad + Constants.WAD - 1) / Constants.WAD; // round up

        // Calculate the amount of ETH spent in total
        uint256 repayAmount = wethDepositGuess + fees;
        spent = repayAmount - wethReceived;
    }

    function quoteSwapETHForYt(address metapool, address pool, uint256 ytAmount)
        external
        view
        returns (uint256, uint256)
    {
        return quoteSwapETHForYt(metapool, pool, ytAmount, ApproxParams(0, 0, 0, 0));
    }

    /// @notice Quote LP token amount in return for adding liquidity to the metapool
    /// @custom:param pool Placeholder for consistency with other functions
    function quoteAddLiquidityOneETHKeepYt(address metapool, address, /* pool */ uint256 amountIn)
        external
        view
        returns (uint256)
    {
        return quoteAddLiquidityOneETHKeepYt(metapool, amountIn);
    }

    function quoteAddLiquidityOneETHKeepYt(address metapool, uint256 amountIn)
        public
        view
        checkMetapool(metapool)
        returns (uint256)
    {
        ITranche pt = ITranche(Twocrypto(metapool).coins(PEGGED_PT_INDEX));
        uint256 ptAmount = _previewIssue(pt, amountIn);
        return Twocrypto(metapool).calc_token_amount({amounts: [ptAmount, 0], deposit: true});
    }

    /// @notice Quote amount of ETH received for removing liquidity from the metapool
    function quoteRemoveLiquidityOneETH(address metapool, address pool, uint256 liquidity)
        external
        view
        checkMetapool(metapool)
        returns (uint256 ethOut)
    {
        ITranche pt = ITranche(Twocrypto(metapool).coins(PEGGED_PT_INDEX));
        if (block.timestamp >= pt.maturity()) {
            // If PT is matured, we can directly redeem the PT for ETH
            uint256 ptAmount = Twocrypto(metapool).calc_withdraw_one_coin(liquidity, PEGGED_PT_INDEX);
            ethOut = pt.previewRedeem(ptAmount);
        } else {
            uint256 basePoolTokenAmount = Twocrypto(metapool).calc_withdraw_one_coin(liquidity, BASE_POOL_INDEX);
            (ethOut,,) = PoolMath.swapExactBaseLpTokenForUnderlying(INapierPool(pool).readState(), basePoolTokenAmount);
        }
    }

    /// @notice Get PT (coin1) price in Twocrypto in units of 1e18. e.g. 1 PT = 0.9 ETH = 0.9e18
    /// @dev Do not use this function as a oracle.
    function quotePtPrice(address metapool, address pool) public view checkMetapool(metapool) returns (uint256) {
        uint256 timeToMaturity = INapierPool(pool).maturity() - block.timestamp;
        uint256 lnImpliedRate = INapierPool(pool).lastLnImpliedRate();

        // Calculate the price of Base LP token in ETH
        // `_getExchangeRateFromImpliedRate()` returns the "scaled" (internally used) price of underlying token in Base LP token (in 18 decimals).
        uint256 basePoolTokensPerEth = uint256(PoolMath._getExchangeRateFromImpliedRate(lnImpliedRate, timeToMaturity));
        // Note:
        // PT price := [ETH per Base pool token] / [PTs per Base pool tokens]
        // = 1 / [ETH per Base pool token] / [PTs per Base pool tokens]
        uint256 ethPerBasePoolToken = (Constants.WAD * Constants.WAD * 3) / basePoolTokensPerEth;
        uint256 ptsPerBasePoolToken = Twocrypto(metapool).price_oracle();
        return (ethPerBasePoolToken * Constants.WAD) / ptsPerBasePoolToken;
    }

    /// @notice Returns the estimated amount of principal token to be issued for a given amount of underlying token
    /// @param pt The principal token to issue
    /// @param underlyingAmount The amount of underlying token to be deposited
    /// @dev This function is a copy of `Tranche.issue`.
    function _previewIssue(ITranche pt, uint256 underlyingAmount) internal view returns (uint256) {
        ITranche.Series memory series = pt.getSeries();
        uint256 cscale = IBaseAdapter(series.adapter).scale();
        if (cscale > series.maxscale) series.maxscale = cscale; // update maxscale if needed
        // Formula: See `Tranche.issue` in `Tranche.sol` for details.
        uint256 shares = underlyingAmount * Constants.WAD / cscale;
        uint256 fee = (shares * series.issuanceFee + Constants.MAX_BPS - 1) / Constants.MAX_BPS; // round up
        return (shares - fee) * series.maxscale / Constants.WAD;
    }
}
