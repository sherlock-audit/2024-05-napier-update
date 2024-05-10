// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {BaseTestTranche} from "../../shared/BaseTestTranche.t.sol";
import {UniETHFixture} from "./Fixture.sol";
import {CompleteFixture} from "./../../Fixtures.sol";

import {UniETHAdapter} from "src/adapters/bedrock/UniETHAdapter.sol";

import "src/Constants.sol" as Constants;

contract TestUniETHTranche is BaseTestTranche, UniETHFixture {
    using stdStorage for StdStorage;

    /// @dev Address of WETH whale
    address charlie = makeAddr("charlie");

    function setUp() public virtual override(CompleteFixture, UniETHFixture) {
        UniETHFixture.setUp();
        MIN_UNDERLYING_DEPOSIT = 1_000;
        MAX_UNDERLYING_DEPOSIT = 10_000 ether;
        _DELTA_ = 100;
    }

    function deal(
        address token,
        address to,
        uint256 give,
        bool adjust
    ) internal virtual override(StdCheats, UniETHFixture) {
        UniETHFixture.deal(token, to, give, adjust);
    }

    /// @notice Mint some uniETH and shares by depositing large amount of underlying.
    /// @dev This is a helper function for setting up the test environment.
    modifier setUpBuffer() {
        stdstore.target(address(adapter)).sig("tranche()").checked_write(address(this));

        deal(address(underlying), charlie, 1_000_000 * ONE_SCALE, false); // 100x of the MAX_UNDERLYING_DEPOSIT
        vm.prank(charlie);
        underlying.transfer(address(adapter), 1_000_000 * ONE_SCALE);
        adapter.prefundedDeposit();

        stdstore.target(address(adapter)).sig("tranche()").checked_write(address(tranche));
        _;
    }

    /////////////////////////////////////////////////////////////////////
    /// REDEEM WITH YT
    /////////////////////////////////////////////////////////////////////

    function testRedeemWithYT_ScaleIncrease(uint256 amountRedeem, uint32 newTimestamp) public override setUpBuffer {
        super.testRedeemWithYT_ScaleIncrease(amountRedeem, newTimestamp);
    }

    /// @dev Override fuzz range for `amountRedeem`
    function testRedeemWithYT_ScaleDecrease(uint256 amountRedeem, uint32 newTimestamp) public override setUpBuffer {
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued = _issue(address(this), address(this), amount);
        amountRedeem = bound(amountRedeem, MIN_UNDERLYING_DEPOSIT, issued);
        newTimestamp = boundU32(newTimestamp, block.timestamp, _maturity + 365 days);
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
        super.testRT_Issue_RedeemWithYT_ScaleIncrease(uDeposit);
    }

    /// @inheritdoc BaseTestTranche
    function testRT_Issue_RedeemWithYT_ScaleDecrease(uint256 uDeposit) public override setUpBuffer {
        super.testRT_Issue_RedeemWithYT_ScaleDecrease(uDeposit);
    }

    /////////////////////////////////////////////////////////////////////
    /// REDEEM
    /////////////////////////////////////////////////////////////////////

    function testRedeem_WhenScaleIncrease(uint256 amountToRedeem) public override setUpBuffer {
        super.testRedeem_WhenScaleIncrease(amountToRedeem);
    }

    /// @dev Override fuzz range for `amountToRedeem`
    function testRedeem_WhenScaleDecrease(uint256 amountToRedeem) public override setUpBuffer {
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

    /////////////////////////////////////////////////////////////////////
    /// WITHDRAW
    /////////////////////////////////////////////////////////////////////

    /// @inheritdoc BaseTestTranche
    function testWithdraw_WhenScaleIncrease() public override setUpBuffer {
        super.testWithdraw_WhenScaleIncrease();
    }

    /// @inheritdoc BaseTestTranche
    function testWithdraw_WhenScaleDecrease() public override setUpBuffer {
        super.testWithdraw_WhenScaleDecrease();
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
    function testCollect_AfterMaturity_ScaleIncrease() public override setUpBuffer {
        super.testCollect_AfterMaturity_ScaleIncrease();
    }

    /// @inheritdoc BaseTestTranche
    function testCollect_AfterMaturity_ScaleDecrease() public override setUpBuffer {
        super.testCollect_AfterMaturity_ScaleDecrease();
    }

    /////////////////////////////////////////////////////////////////////
    /// COLLECT FUZZ
    /////////////////////////////////////////////////////////////////////

    modifier boundCollectFuzzArgs(CollectFuzzArgs memory args) override {
        vm.assume(args.caller != address(0));
        vm.assume(accountsExcludedFromFuzzing[args.caller] == false);
        args.cscale = bound(args.cscale, 1e16, 1e22);
        args.uDeposit = bound(args.uDeposit, MIN_UNDERLYING_DEPOSIT, MAX_UNDERLYING_DEPOSIT);
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
    ) public override setUpBuffer {
        super.testFuzz_Collect_AfterMaturity(args, newTimestamp);
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
    ) public override setUpBuffer {
        super.testPreviewRedeem_AfterMaturity(args, newTimestamp);
    }

    /// forge-config: default.fuzz.runs = 100
    function testPreviewWithdraw_AfterMaturity(
        PreviewFuncFuzzArgs memory args,
        uint32 newTimestamp
    ) public override setUpBuffer {
        super.testPreviewWithdraw_AfterMaturity(args, newTimestamp);
    }
}
