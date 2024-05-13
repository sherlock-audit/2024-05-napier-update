// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import {ApproxParams} from "src/interfaces/ApproxParams.sol";
import {TrancheMathHelper} from "src/libs/TrancheMathHelper.sol";

import {FixedPointMathLib} from "@napier/v1-tranche/src/utils/FixedPointMathLib.sol";
import {ITranche} from "@napier/v1-tranche/src/interfaces/ITranche.sol";
import {MAX_BPS} from "@napier/v1-tranche/src/Constants.sol";

import {Base} from "../../Base.t.sol";

contract GetApproxUnderlyingNeededFuzzTest is Base {
    struct ScaleFuzzInput {
        uint256 decimals;
        uint256 cscale;
        uint256 maxscale;
        uint256 issuanceFeeBps;
    }

    uint256 constant MAX_ISSUANCE_FEE_BPS = 500; // 5%

    function setUp() public {
        _deployAdaptersAndPrincipalTokens();
    }

    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_getApproxUnderlyingNeeded(ScaleFuzzInput memory input, uint256 ytDesired) external {
        input.decimals = 18;
        input.maxscale = bound(input.maxscale, 1e6, 1e4 * 1e18);
        input.cscale = bound(input.cscale, input.maxscale / 1_000, input.maxscale);
        input.issuanceFeeBps = bound(input.issuanceFeeBps, 0, MAX_ISSUANCE_FEE_BPS);
        ytDesired = bound(ytDesired, 1e10, 1e8 * 1e18);
        ApproxParams memory approx = ApproxParams({guessMin: 0, guessMax: 0, eps: 0.05 * 1e18, maxIteration: 100});

        ITranche.Series memory series = ITranche.Series({
            underlying: address(0),
            target: address(0),
            yt: address(0),
            adapter: address(0xeee),
            mscale: uint256(0),
            maxscale: input.maxscale,
            issuanceFee: uint64(input.issuanceFeeBps),
            maturity: uint64(0)
        });
        vm.mockCall(address(series.adapter), abi.encodeWithSignature("scale()"), abi.encode(input.cscale));
        vm.mockCall(address(pts[0]), abi.encodeWithSignature("getSeries()"), abi.encode(series));
        vm.mockCall(address(pts[0]), abi.encodeWithSignature("decimals()"), abi.encode(input.decimals));
        uint256 result =
            _issue(input, TrancheMathHelper.getApproxUnderlyingNeededByYt(ITranche(pts[0]), ytDesired, approx));
        assertApproxEqRel(result, ytDesired, 0.05 * 1e18, "should be eq `ytDesired`");
        assertGe(result, ytDesired, "should be gt `ytDesired`");
    }

    // Forked from Tranche.sol
    function _issue(ScaleFuzzInput memory input, uint256 underlyingAmount) public pure returns (uint256 issued) {
        uint256 fee = FixedPointMathLib.mulDivUp(underlyingAmount, input.issuanceFeeBps, MAX_BPS);
        uint256 amount = underlyingAmount - fee;
        uint256 shares = FixedPointMathLib.divWadDown(amount, input.cscale);
        issued = FixedPointMathLib.mulWadDown(shares, input.maxscale);
    }
}
