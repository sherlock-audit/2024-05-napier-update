// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {BaseTestTranche} from "@napier/v1-tranche-test/shared/BaseTestTranche.t.sol";
import {CompleteFixture} from "@napier/v1-tranche-test/Fixtures.sol";

import {RenzoAdapter} from "src/adapters/renzo/RenzoAdapter.sol";

import {RenzoFixture} from "./Fixture.sol";

import "src/Constants.sol" as Constants;

contract TestRenzoTranche is BaseTestTranche, RenzoFixture {
    using stdStorage for StdStorage;

    /// @notice Address for setting up the test environment
    address charlie = makeAddr("charlie");

    function setUp() public virtual override(CompleteFixture, RenzoFixture) {
        RenzoFixture.setUp();
        // mockTVLCall();
        MIN_UNDERLYING_DEPOSIT = 1 ether;
        MAX_UNDERLYING_DEPOSIT = 10_000 ether;
        _DELTA_ = 189363;
    }

    function deal(
        address token,
        address to,
        uint256 give,
        bool adjust
    ) internal virtual override(StdCheats, RenzoFixture) {
        RenzoFixture.deal(token, to, give, adjust);
    }

    /// @notice Mint some stETH and shares by depositing large amount of underlying.
    /// @dev This is a helper function for setting up the test environment.
    modifier setUpBuffer() {
        stdstore.target(address(adapter)).sig("tranche()").checked_write(address(this));

        deal(address(underlying), charlie, 100 * MAX_UNDERLYING_DEPOSIT, false); // 100x of the MAX_UNDERLYING_DEPOSIT
        vm.prank(charlie);
        underlying.transfer(address(adapter), 100 * MAX_UNDERLYING_DEPOSIT);
        adapter.prefundedDeposit();
        stdstore.target(address(adapter)).sig("tranche()").checked_write(address(tranche));
        _;
    }

    /////////////////////////////////////////////////////////////////////
    /// REDEEM WITH YT
    /////////////////////////////////////////////////////////////////////

    /// @notice Test redeeming PT with YT
    ///         - PT+YT should be burned
    ///         - Accrued yield should be sent to user
    /// @param amountRedeem amount of PT+YT to redeem
    /// @param newTimestamp new timestamp to warp to
    function testRedeemWithYT_ScaleIncrease(uint256 amountRedeem, uint32 newTimestamp) public override setUpBuffer {
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued = _issue(address(this), address(this), amount);
        amountRedeem = bound(amountRedeem, MIN_UNDERLYING_DEPOSIT, issued);
        newTimestamp = boundU32(newTimestamp, block.timestamp, _maturity);
        // assert
        _testRedeemWithYT(issued, amountRedeem, _simulateScaleIncrease, newTimestamp);
    }

    /// @notice Test redeeming PT with YT
    ///         - PT+YT should be burned
    ///         - There should be no accrued yield
    /// @param amountRedeem amount of PT+YT to redeem
    /// @param newTimestamp new timestamp to warp to
    function testRedeemWithYT_ScaleDecrease(uint256 amountRedeem, uint32 newTimestamp) public override setUpBuffer {
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued = _issue(address(this), address(this), amount);
        amountRedeem = bound(amountRedeem, MIN_UNDERLYING_DEPOSIT, issued);
        newTimestamp = boundU32(newTimestamp, block.timestamp, _maturity);
        // assert
        _testRedeemWithYT(issued, amountRedeem, _simulateScaleDecrease, newTimestamp);
    }

    function testRedeemWithYT_AfterMaturity_AlreadySettle_LscaleNonZero() public override setUpBuffer {
        super.testRedeemWithYT_AfterMaturity_AlreadySettle_LscaleNonZero();
    }

    /// @inheritdoc BaseTestTranche
    function testRT_Issue_RedeemWithYT_Immediately(uint256 uDeposit) public override setUpBuffer {
        super.testRT_Issue_RedeemWithYT_Immediately(uDeposit);
    }

    function testRT_Issue_RedeemWithYT_ScaleIncrease(uint256 uDeposit) public override setUpBuffer {
        uDeposit = bound(uDeposit, MIN_UNDERLYING_DEPOSIT, initialBalance);
        uint256 prevBalance = underlying.balanceOf(address(this));
        _testRT_Issue_RedeemWithYT(uDeposit, _simulateScaleIncrease);
        assertApproxGeAbs(
            underlying.balanceOf(address(this)) + _getIssuanceFee(uDeposit),
            prevBalance,
            10,
            "underlying withdrawn should be greater than uDeposit subtracted by fee"
        );
    }

    /// @inheritdoc BaseTestTranche
    function testRT_Issue_RedeemWithYT_ScaleDecrease(uint256 uDeposit) public override setUpBuffer {
        super.testRT_Issue_RedeemWithYT_ScaleDecrease(uDeposit);
    }

    /////////////////////////////////////////////////////////////////////
    /// REDEEM
    /////////////////////////////////////////////////////////////////////

    /// @inheritdoc BaseTestTranche
    function testRedeem_WhenScaleIncrease(uint256 amountToRedeem) public override setUpBuffer {
        // setup
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued = _issue(address(this), user, amount);
        vm.warp(_maturity);
        amountToRedeem = bound(amountToRedeem, MIN_UNDERLYING_DEPOSIT, issued);
        // scale increases after issue
        _simulateScaleIncrease();
        // execution
        _testRedeem(amountToRedeem, user, user, user);
    }

    /// @inheritdoc BaseTestTranche
    function testRedeem_WhenScaleDecrease(uint256 amountToRedeem) public override setUpBuffer {
        // setup
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued = _issue(address(this), user, amount);
        vm.warp(_maturity);
        amountToRedeem = bound(amountToRedeem, MIN_UNDERLYING_DEPOSIT, issued);
        // scale increases after issue
        _simulateScaleDecrease();
        // execution
        _testRedeem(amountToRedeem, user, user, user);
    }

    /////////////////////////////////////////////////////////////////////
    /// WITHDRAW
    /////////////////////////////////////////////////////////////////////

    /// @inheritdoc BaseTestTranche
    function testWithdraw_WhenScaleIncrease() public override setUpBuffer {
        // setup
        uint256 amount = 100 * ONE_SCALE;
        _issue(address(this), user, amount);
        vm.warp(_maturity);
        // scale increases after issue
        _simulateScaleIncrease();
        // execution
        _testRedeem(amount / 2, user, user, user);
    }

    /// @inheritdoc BaseTestTranche
    function testWithdraw_WhenScaleDecrease() public override setUpBuffer {
        // setup
        uint256 amount = 100 * ONE_SCALE;
        _issue(address(this), user, amount);
        vm.warp(_maturity);
        // scale increases after issue
        _simulateScaleDecrease();
        // execution
        _testRedeem(amount / 2, user, user, user);
    }

    /// @notice Test withdrawing underlying
    ///         - PT should be burned
    ///         - Target should be redeemed
    ///         - YT balance should not change
    ///         - Receiver should receive underlying
    function _testWithdraw(
        uint256 underlyingAmount,
        address to,
        address from,
        address caller
    ) internal override returns (uint256) {
        // pre-execution state
        uint256 balBefore = tranche.balanceOf(from);
        uint256 yBal = yt.balanceOf(from);
        uint256 tBal = target.balanceOf(address(tranche));

        uint256 cscale = adapter.scale();
        uint256 expectedBurned = tranche.convertToPrincipal(underlyingAmount);
        // execution
        _approve(address(tranche), from, caller, type(uint256).max);
        vm.prank(caller);
        uint256 ptRedeemed = tranche.withdraw(underlyingAmount, to, from);
        // assert
        assertApproxLeAbs(expectedBurned, ptRedeemed, 10, "underlying withdrawn");
        assertEq(tranche.balanceOf(from), balBefore - ptRedeemed, "balance");
        assertEq(yt.balanceOf(from), yBal, "yt balance shouldn't change");
        assertEq(target.balanceOf(address(adapter)), 0, "no funds left in adapter");
        // note: Precision loss occurs here.
        assertApproxEqAbs(underlying.balanceOf(to), underlyingAmount, 100, "balance ~= underlying withdrawn"); // diff should be 0 in theory.
        assertApproxEqAbs(
            target.balanceOf(address(tranche)),
            tBal - _convertToShares(underlyingAmount, cscale),
            _DELTA_,
            "target balance"
        );
        return ptRedeemed;
    }

    /////////////////////////////////////////////////////////////////////
    /// UPDATE UNCLAIMED YIELD FUZZ
    /////////////////////////////////////////////////////////////////////

    modifier boundUpdateUnclaimedYieldFuzzArgs(UpdateUnclaimedYieldFuzzArgs memory args) override {
        vm.assume(args.accounts[0] != address(0) && args.accounts[1] != address(0));
        vm.assume(accountsExcludedFromFuzzing[args.accounts[0]] == false);
        vm.assume(accountsExcludedFromFuzzing[args.accounts[1]] == false);
        args.cscale = bound(args.cscale, 1e10, RAY);
        args.uDeposits[0] = bound(args.uDeposits[0], MIN_UNDERLYING_DEPOSIT, MAX_UNDERLYING_DEPOSIT);
        args.uDeposits[1] = bound(args.uDeposits[1], MIN_UNDERLYING_DEPOSIT, MAX_UNDERLYING_DEPOSIT);
        args.unclaimedYields[0] = bound(args.unclaimedYields[0], 0, MAX_UNDERLYING_DEPOSIT);
        args.unclaimedYields[1] = bound(args.unclaimedYields[1], 0, MAX_UNDERLYING_DEPOSIT);
        args.yAmountTransfer = bound(args.yAmountTransfer, 0, args.uDeposits[0]);
        _;
    }

    /// @notice It'll take a long time to run this fuzz test. Run it with a small number of runs.
    /// forge-config: default.fuzz.runs = 100
    /// forge-config: deep_fuzz.fuzz.runs = 500
    /// @inheritdoc BaseTestTranche
    function testFuzz_UpdateUnclaimedYield_FromIsTo(
        UpdateUnclaimedYieldFuzzArgs memory args,
        uint32 newTimestamp
    ) public override {
        super.testFuzz_UpdateUnclaimedYield_FromIsTo(args, newTimestamp);
    }

    /// forge-config: default.fuzz.runs = 100
    /// forge-config: deep_fuzz.fuzz.runs = 500
    /// @inheritdoc BaseTestTranche
    function testFuzz_UpdateUnclaimedYield_FromIsNotTo_NonZeroTransfer_LscaleZero(
        UpdateUnclaimedYieldFuzzArgs memory args,
        uint32 newTimestamp
    ) public override {
        super.testFuzz_UpdateUnclaimedYield_FromIsNotTo_NonZeroTransfer_LscaleZero(args, newTimestamp);
    }

    /// forge-config: default.fuzz.runs = 100
    /// forge-config: deep_fuzz.fuzz.runs = 500
    /// @inheritdoc BaseTestTranche
    function testFuzz_UpdateUnclaimedYield_FromIsNotTo_NonZeroTransfer_LscaleNonZero(
        UpdateUnclaimedYieldFuzzArgs memory args,
        uint32 newTimestamp
    ) public override {
        super.testFuzz_UpdateUnclaimedYield_FromIsNotTo_NonZeroTransfer_LscaleNonZero(args, newTimestamp);
    }

    /// forge-config: default.fuzz.runs = 100
    /// forge-config: deep_fuzz.fuzz.runs = 500
    /// @inheritdoc BaseTestTranche
    function testFuzz_UpdateUnclaimedYield_FromIsNotTo_ZeroTransfer(
        UpdateUnclaimedYieldFuzzArgs memory args,
        uint32 newTimestamp
    ) public override {
        super.testFuzz_UpdateUnclaimedYield_FromIsNotTo_ZeroTransfer(args, newTimestamp);
    }

    /////////////////////////////////////////////////////////////////////
    /// COLLECT
    /////////////////////////////////////////////////////////////////////

    /// @inheritdoc BaseTestTranche
    function testCollect_BeforeMaturity_ScaleIncrease() public override setUpBuffer {
        super.testCollect_BeforeMaturity_ScaleIncrease();
    }

    /// @inheritdoc BaseTestTranche
    function testCollect_BeforeMaturity_ScaleDecrease() public override setUpBuffer {
        super.testCollect_BeforeMaturity_ScaleDecrease();
    }

    /// @inheritdoc BaseTestTranche
    function testCollect_AfterMaturity_ScaleDecrease() public override setUpBuffer {
        super.testCollect_AfterMaturity_ScaleDecrease();
    }

    /// @inheritdoc BaseTestTranche
    function testCollect_AfterMaturity_ScaleIncrease() public override setUpBuffer {
        super.testCollect_AfterMaturity_ScaleIncrease();
    }

    /////////////////////////////////////////////////////////////////////
    /// COLLECT FUZZ
    /////////////////////////////////////////////////////////////////////

    modifier boundCollectFuzzArgs(CollectFuzzArgs memory args) override {
        vm.assume(args.caller != address(0));
        vm.assume(accountsExcludedFromFuzzing[args.caller] == false);
        args.cscale = bound(args.cscale, 1e16, 1e22);
        // In `collect` function, some Target tokens would be redeemed but it might be too small to get non-zero amount of underlying.
        // As a result, `prefundedRedeem` would revert with `ZeroAssets` error.
        args.uDeposit = bound(args.uDeposit, 1e6, MAX_UNDERLYING_DEPOSIT);
        _;
    }

    /// @dev It'll take a long time to run this fuzz test. Run it with a small number of runs.
    /// forge-config: default.fuzz.runs = 100
    /// forge-config: deep_fuzz.fuzz.runs = 500
    function testFuzz_Collect_BeforeMaturity(
        CollectFuzzArgs memory args,
        uint32 newTimestamp
    ) public override boundCollectFuzzArgs(args) setUpBuffer {
        super.testFuzz_Collect_BeforeMaturity(args, newTimestamp);
    }

    /// @dev It'll take a long time to run this fuzz test. Run it with a small number of runs.
    /// forge-config: default.fuzz.runs = 100
    /// forge-config: deep_fuzz.fuzz.runs = 500
    function testFuzz_Collect_AfterMaturity(
        CollectFuzzArgs memory args,
        uint32 newTimestamp
    ) public override setUpBuffer boundCollectFuzzArgs(args) {
        vm.assume(args.caller != address(0));
        deal(address(underlying), args.caller, args.uDeposit, true);
        _issue(args.caller, args.caller, args.uDeposit);
        newTimestamp = boundU32(newTimestamp, _maturity, _maturity);
        vm.warp(newTimestamp);
        _testFuzz_Collect(args);
    }

    function testMaxWithdraw_AfterMaturity(
        PreviewFuncFuzzArgs memory args,
        uint32 newTimestamp
    ) public override boundPreviewFuncFuzzArgs(args) {
        vm.assume(args.caller != address(0) && args.owner != address(0));
        deal(address(underlying), args.caller, args.uDeposit, false);
        try this._issue(args.caller, args.owner, args.uDeposit) {} catch {
            vm.assume(false);
        }
        newTimestamp = boundU32(newTimestamp, _maturity, _maturity);
        vm.warp(newTimestamp);
        uint256 expected = tranche.convertToUnderlying(tranche.balanceOf(args.owner));
        assertEq(tranche.maxWithdraw(args.owner), expected, "prop/max-withdraw");
    }

    /////////////////////////////////////////////////////////////////////
    /// PREVIEW REDEEM / PREVIEW WITHDRAW
    /////////////////////////////////////////////////////////////////////

    modifier boundPreviewFuncFuzzArgs(PreviewFuncFuzzArgs memory args) override {
        vm.assume(args.caller != address(0) && args.owner != address(0));
        vm.assume(accountsExcludedFromFuzzing[args.caller] == false);
        vm.assume(accountsExcludedFromFuzzing[args.owner] == false);
        args.uDeposit = bound(args.uDeposit, MIN_UNDERLYING_DEPOSIT, MAX_UNDERLYING_DEPOSIT);
        _;
    }

    /// forge-config: default.fuzz.runs = 100
    function testPreviewRedeem_AfterMaturity(
        PreviewFuncFuzzArgs memory args,
        uint32 newTimestamp
    ) public override setUpBuffer boundPreviewFuncFuzzArgs(args) {
        vm.assume(args.caller != address(0) && args.owner != address(0));
        deal(address(underlying), args.caller, args.uDeposit, false);
        try this._issue(args.caller, args.owner, args.uDeposit) {} catch {
            vm.assume(false);
        }
        newTimestamp = boundU32(newTimestamp, _maturity, _maturity);
        vm.warp(newTimestamp);
        // pre-execution state
        uint256 principal = tranche.balanceOf(args.caller);
        uint256 preview = tranche.previewRedeem(principal);
        // execution
        _approve(address(tranche), args.owner, args.caller, principal);
        vm.prank(args.caller);
        uint256 actual = tranche.redeem(principal, args.owner, args.owner);
        // assert
        assertApproxLeAbs(preview, actual, 10, "prop/preview-redeem");
    }

    /// forge-config: default.fuzz.runs = 100
    function testPreviewWithdraw_AfterMaturity(
        PreviewFuncFuzzArgs memory args,
        uint32 newTimestamp
    ) public override setUpBuffer boundPreviewFuncFuzzArgs(args) {
        vm.assume(args.caller != address(0) && args.owner != address(0));
        deal(address(underlying), args.caller, args.uDeposit, false);
        try this._issue(args.caller, args.owner, args.uDeposit) {} catch {
            vm.assume(false);
        }
        newTimestamp = boundU32(newTimestamp, _maturity, _maturity);
        vm.warp(newTimestamp);
        // pre-execution state
        uint256 underlyingAmount = tranche.convertToUnderlying(tranche.balanceOf(args.caller));
        uint256 preview = tranche.previewWithdraw(underlyingAmount);
        // execution
        _approve(address(tranche), args.owner, args.caller, underlyingAmount);
        vm.prank(args.caller);
        uint256 actual = tranche.withdraw(underlyingAmount, args.owner, args.owner);
        // assert
        assertApproxLeAbs(preview, actual, 10, "prop/preview-withdraw");
    }
}
