// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {BaseTestTranche} from "../../shared/BaseTestTranche.t.sol";

import {CompleteFixture, RETHFixture} from "./Fixture.sol";
import {RETHAdapter} from "src/adapters/rocketPool/RETHAdapter.sol";
import {BaseAdapter} from "src/BaseAdapter.sol";
import {RocketPoolHelper} from "../../utils/RocketPoolHelper.sol";
import "src/Constants.sol" as Constants;

contract TestRETHTranche is BaseTestTranche, RETHFixture {
    using Cast for *;

    function setUp() public virtual override(CompleteFixture, RETHFixture) {
        RETHFixture.setUp();
    }

    //////////////////////////////////////////////////////////////////
    /// OVERRIDE
    //////////////////////////////////////////////////////////////////

    function testRedeem_WhenScaleIncrease(uint256 amountToRedeem) public override {
        // setup
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued = _issue(address(this), user, amount);
        vm.warp(_maturity + 7 days);
        amountToRedeem = bound(amountToRedeem, MIN_UNDERLYING_DEPOSIT, issued);
        // scale increases after issue
        _simulateScaleIncrease();
        // execution
        _testRedeem(amountToRedeem, user, user, user);
    }

    function testRedeem_WhenScaleDecrease(uint256 amountToRedeem) public override {
        // setup
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued = _issue(address(this), user, amount);
        vm.warp(_maturity + 7 days);
        amountToRedeem = bound(amountToRedeem, MIN_UNDERLYING_DEPOSIT, issued);
        // scale increases after issue
        _simulateScaleDecrease();
        // execution
        _testRedeem(amountToRedeem, user, user, user);
    }

    function _testRedeem(uint256 principalAmount, address to, address from, address caller) internal override {
        // pre-execution state
        uint256 totSupplyBefore = tranche.totalSupply();
        uint256 balBefore = tranche.balanceOf(from);
        uint256 yBal = yt.balanceOf(from);
        // after redeeming all of wrapped token, totalsupply of Aave3Adater become 0, adapter.scale() become 1e18
        // before that, save the value of adapter.scale()
        uint256 scale = adapter.scale();
        uint256 expectedWithdrawn = tranche.convertToUnderlying(principalAmount);
        // execution
        _approve(address(tranche), from, caller, type(uint256).max);
        uint256 underlyingWithdrawn = _redeem({from: caller, to: to, principalAmount: principalAmount, caller: caller});
        // assert
        assertApproxLeAbs(expectedWithdrawn, underlyingWithdrawn, _DELTA_, "underlying withdrawn");
        assertEq(tranche.balanceOf(from), balBefore - principalAmount, "balance");
        assertEq(tranche.totalSupply(), totSupplyBefore - principalAmount, "total supply");
        assertEq(yt.balanceOf(from), yBal, "yt balance shouldn't change");
        assertApproxEqAbs(underlying.balanceOf(to), underlyingWithdrawn, 2, "balance == underlying withdrawn"); // diff should be 0 in theory.
        assertEq(target.balanceOf(address(adapter)), 0, "no funds left in adapter");
        assertApproxEqRel(
            underlyingWithdrawn,
            _convertToUnderlying(((principalAmount * WAD) / tranche.getGlobalScales().maxscale), scale),
            0.000_000_1 * 1e18,
            "underlying withdrawn"
        );
    }

    function testRedeemWithYT_ScaleDecrease(uint256 amountRedeem, uint32 newTimestamp) public override {
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued = _issue(address(this), address(this), amount);
        amountRedeem = bound(amountRedeem, 1_000, issued);
        newTimestamp = boundU32(newTimestamp, block.timestamp, _maturity + 365 days);
        // assert
        _testRedeemWithYT(issued, amountRedeem, _simulateScaleDecrease, newTimestamp);
    }

    //////////////////////////////////////////////////////////////////
    /// Tests for RETH Tranchen specific cases
    //////////////////////////////////////////////////////////////////

    function mintReth(uint256 stakeAmount) public {
        vm.prank(rebalancer);
        adapter.into().mintReth(stakeAmount);
    }

    /// @notice Adapter have to burn rETH when redeeming PT+YT to refill the buffer
    function testRedeemWithYT_ScaleIncrease_WhenNotEnoughBuffer(
        uint256 amountRedeem,
        uint32 newTimestamp
    ) public virtual {
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued = _issue(address(this), address(this), amount);
        mintReth({stakeAmount: (amount * 90) / 100}); // mint rETH
        amountRedeem = bound(amountRedeem, 0, issued);
        newTimestamp = boundU32(newTimestamp, block.timestamp, _maturity + 365 days);

        // assert
        _testRedeemWithYT(issued, amountRedeem, _simulateScaleIncrease, newTimestamp);
    }

    /// @notice Adapter have to burn rETH when redeeming PT+YT to refill the buffer
    function testRedeemWithYT_ScaleDecrease_WhenNotEnoughBuffer(uint256 amountRedeem, uint32 newTimestamp) public {
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued = _issue(address(this), address(this), amount);
        mintReth({stakeAmount: (amount * 90) / 100}); // mint rETH
        amountRedeem = bound(amountRedeem, 1_000, issued);
        newTimestamp = boundU32(newTimestamp, block.timestamp, _maturity + 365 days);

        // assert
        _testRedeemWithYT(issued, amountRedeem, _simulateScaleDecrease, newTimestamp);
    }

    /////////////////////////////////////////////////////////////////
    /// MODIFIERS
    /////////////////////////////////////////////////////////////////
    // The modifiers below are used to bound the fuzz args.
    // NOTE: address type is bounded to `user` or `address(this)` instead of random addresses.
    // because it will run out of rpc resources and very slow if we use random addresses.

    /// @dev Bound fuzz args for `testUpdateUnclaimedYield`.
    modifier boundUpdateUnclaimedYieldFuzzArgs(UpdateUnclaimedYieldFuzzArgs memory args) override {
        vm.assume(args.accounts[0] != address(0) && args.accounts[1] != address(0));
        args.accounts[0] = address(this);
        args.accounts[1] = user;
        args.cscale = bound(args.cscale, (ONE_TARGET * 8) / 10, ONE_TARGET * 2);
        args.uDeposits[0] = bound(args.uDeposits[0], MIN_UNDERLYING_DEPOSIT, FUZZ_UNDERLYING_DEPOSIT_CAP);
        args.uDeposits[1] = bound(args.uDeposits[1], MIN_UNDERLYING_DEPOSIT, FUZZ_UNDERLYING_DEPOSIT_CAP);
        args.unclaimedYields[0] = bound(args.unclaimedYields[0], 0, FUZZ_UNDERLYING_DEPOSIT_CAP);
        args.unclaimedYields[1] = bound(args.unclaimedYields[1], 0, FUZZ_UNDERLYING_DEPOSIT_CAP);
        args.yAmountTransfer = bound(args.yAmountTransfer, 0, args.uDeposits[0]);
        _;
    }

    /// @dev Bound fuzz args for `testCollect`.
    modifier boundCollectFuzzArgs(CollectFuzzArgs memory args) override {
        vm.assume(args.caller != address(0));
        args.caller = address(this);
        args.cscale = bound(args.cscale, (ONE_TARGET * 8) / 10, ONE_TARGET * 2);
        args.uDeposit = bound(args.uDeposit, MIN_UNDERLYING_DEPOSIT, FUZZ_UNDERLYING_DEPOSIT_CAP);
        _;
    }

    /// @dev Bound fuzz args for `testPreview**` and `testMax**`.
    modifier boundPreviewFuncFuzzArgs(PreviewFuncFuzzArgs memory args) override {
        vm.assume(args.caller != address(0) && args.owner != address(0));
        args.caller = address(this);
        args.owner = user;
        args.uDeposit = bound(args.uDeposit, MIN_UNDERLYING_DEPOSIT, FUZZ_UNDERLYING_DEPOSIT_CAP);
        _;
    }

    function deal(
        address token,
        address to,
        uint256 give,
        bool adjust
    ) internal virtual override(StdCheats, RETHFixture) {
        RETHFixture.deal(token, to, give, adjust);
    }
}

library Cast {
    function into(BaseAdapter _x) internal pure returns (RETHAdapter x) {
        assembly {
            x := _x
        }
    }
}
