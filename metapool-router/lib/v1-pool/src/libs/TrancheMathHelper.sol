// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

import {ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import {ITranche} from "@napier/v1-tranche/src/interfaces/ITranche.sol";
import {IBaseAdapter} from "@napier/v1-tranche/src/interfaces/IBaseAdapter.sol";
import {ApproxParams} from "..//interfaces/ApproxParams.sol";

import {FixedPointMathLib} from "@napier/v1-tranche/src/utils/FixedPointMathLib.sol";
import {Math} from "@openzeppelin/contracts@4.9.3/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts@4.9.3/utils/math/SafeCast.sol";
import {MAX_BPS} from "@napier/v1-tranche/src/Constants.sol";
import {Errors} from "./Errors.sol";

library TrancheMathHelper {
    using SafeCast for uint256;

    uint256 constant DEFAULT_MAX_ITERATION = 100;
    uint256 constant MAX_ISSUANCE_FEE_BPS = 500; // 5%

    function getApproxUnderlyingNeededByYt(ITranche pt, uint256 ytDesired) internal view returns (uint256) {
        return getApproxUnderlyingNeededByYt(pt, ytDesired, ApproxParams(0, 0, 0, 0));
    }

    /// @notice This section of code aims to calculate the amount of underlying asset (`uDeposit`) required to issue a specific amount of PT and YT (`ytOutDesired`).
    /// The calculations are based on the formula used in the `Tranche.issue` function.
    function getApproxUnderlyingNeededByYt(ITranche pt, uint256 ytDesired, ApproxParams memory approx)
        internal
        view
        returns (uint256)
    {
        // Default approx parameters if not set
        if (approx.guessMax < approx.guessMin) revert Errors.ApproxBinarySearchInputInvalid();
        if (approx.eps == 0) approx.eps = 0.05 * 1e18; // 5%
        if (approx.maxIteration == 0) approx.maxIteration = DEFAULT_MAX_ITERATION;

        ITranche.Series memory series = pt.getSeries();
        uint256 cscale = IBaseAdapter(series.adapter).scale();
        IssueParams memory params = IssueParams({
            decimals: ERC20(address(pt)).decimals(),
            cscale: cscale,
            maxscale: Math.max(series.maxscale, cscale), // Update maxscale if current scale is greater than maxscale
            issuanceFeeBps: series.issuanceFee
        });
        // Variable Definitions:
        // - `uDeposit`: The amount of underlying asset that needs to be deposited to issue PT and YT.
        // - `ytOutDesired`: The desired amount of PT and YT to be issued.
        // - `cscale`: Current scale of the Tranche.
        // - `maxscale`: Maximum scale of the Tranche (denoted as 'S' in the formula).
        // - `issuanceFee`: Issuance fee in basis points. (10000 =100%).
        // `uDeposit` amount of underlying should issue at least `ytOutDesired` amount of PT and YT.
        // Issuance fee is charged in units of underlying token.
        // Formula for `Tranche.issue`:
        // ```
        // fee = uDeposit * issuanceFeeBps
        // shares = (uDeposit - fee) / s
        // pyIssue = shares * S
        // ```
        // Solving for `uDeposit`:
        // ```
        // uDeposit = pyIssue * s / S / (1 - issuanceFeeBps)
        //          => pyIssue * s * MAX_BPS / (S * (MAX_BPS - issuanceFeeBps))
        // ```
        // However, we can't get correct `uDeposit` due to the precision loss, probably indirectly caused by the issuance fee mechanism.

        // Estimate the maximum amount of underlying token
        uint256 uDepositMax = FixedPointMathLib.mulDivUp(
            // cscale is basically a share price which is usually rounded down.
            // So, we need to add 1 to cscale to round up the share price
            ytDesired * (cscale + 1),
            MAX_BPS,
            params.maxscale * (MAX_BPS - MAX_ISSUANCE_FEE_BPS)
        );
        // We use bisection as a workaround.
        return
            _bisectUnderlyingNeeded({params: params, ytDesired: ytDesired, uDepositGuess: uDepositMax, approx: approx});
    }

    /// @notice Variables to be cached
    struct IssueParams {
        uint256 decimals;
        uint256 cscale;
        uint256 maxscale;
        uint256 issuanceFeeBps;
    }

    /// @notice This function uses bisection to find [uDeposit] such that `Tranche::issue` would mint at least `ytDesired` YT.
    /// @param params - Variables to be cached for gas saving
    /// @param ytDesired - A desired amount of YT to issue
    /// @param uDepositGuess - An amount of underlying token that would issue less than `ytDesired` YT.
    function _bisectUnderlyingNeeded(
        IssueParams memory params,
        uint256 ytDesired,
        uint256 uDepositGuess,
        ApproxParams memory approx
    ) internal pure returns (uint256) {
        uint256 stepSize = 10 ** params.decimals; // 1 Underlying token
        uint256 a = FixedPointMathLib.mulDivUp(ytDesired, params.cscale, params.maxscale);
        uint256 b = uDepositGuess + stepSize; // upper bound

        if (approx.guessMin != 0) a = Math.max(approx.guessMin, a);
        if (approx.guessMax != 0) b = Math.min(approx.guessMax, b);

        // Try to find an min amount of underlying token such that the issuing at least `ytDesired`.
        // Bisect the interval [a, b].
        uint256 midpoint;
        for (uint256 i = 0; i != approx.maxIteration;) {
            midpoint = (a + b) / 2;
            uint256 preview = _previewIssue(params, midpoint);
            int256 err_mid = 1e18 - (preview * 1e18 / ytDesired).toInt256(); // v_desired - v_approx
            // Check if the relative error is less than the tolerance
            if (preview >= ytDesired && -(approx.eps).toInt256() < err_mid) {
                return midpoint;
            }
            // a == b ---> midpoint is `b` forever
            // a+1 == b ---> midpoint is `b` forever
            // Exit the loop if midpoin doesn't change
            if (a == b || (a + 1 == b)) break;

            if (err_mid > 0) {
                // bound interval [midpoint, b]
                a = midpoint;
            } else {
                // bound interval [a, midpoint]
                b = midpoint;
            }
            unchecked {
                ++i;
            }
        }
        // If the function hasn't returned by now, it means it didn't find a solution within the tolerance.
        // Try changing the tolerance.
        revert Errors.ApproxFail();
    }

    /// @notice A copy of `Tranche::issue` math
    function _previewIssue(IssueParams memory params, uint256 underlyingAmount) internal pure returns (uint256) {
        uint256 fee = FixedPointMathLib.mulDivUp(underlyingAmount, params.issuanceFeeBps, MAX_BPS);
        uint256 shares = FixedPointMathLib.divWadDown(underlyingAmount - fee, params.cscale);
        return FixedPointMathLib.mulWadDown(shares, params.maxscale);
    }
}
