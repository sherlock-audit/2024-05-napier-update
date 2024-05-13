// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../shared/BaseTestTranche.t.sol";

import {AAVEFixture} from "./Fixture.sol";
import {AaveV3Adapter} from "src/adapters/aaveV3/AaveV3Adapter.sol";

contract TestAaveTranche is BaseTestTranche, AAVEFixture {
    using stdStorage for StdStorage;

    function setUp() public virtual override(CompleteFixture, AAVEFixture) {
        AAVEFixture.setUp();
    }

    //////////////////////////////////////////////////////////////////
    /// OVERRIDE
    //////////////////////////////////////////////////////////////////

    /// @notice Test first issuance of PT+YT
    function testIssue_Ok() public override {
        // setup
        uint256 amount = 100 * ONE_SCALE;
        uint256 cscale = adapter.scale();
        uint256 fee = _getIssuanceFee(amount);
        uint256 shares = _convertToShares(amount - fee, cscale);
        // execution
        uint256 issued = tranche.issue(user, amount);
        // assert
        assertEq(tranche.balanceOf(user), issued, "user balance of pt");
        assertEq(yt.balanceOf(user), issued, "yt balance of pt");
        assertEq(tranche.totalSupply(), issued, "total supply");
        assertEq(balanceOfFeeRecipient(), fee, "accumulated fee");
        assertApproxEqRel(
            (amount * (MAX_BPS - _issuanceFee)) / MAX_BPS,
            issued,
            0.000_000_000_1 * 1e18,
            "issued amount should be reduced by fee"
        );
        assertApproxEqRel(target.balanceOf(address(tranche)), shares, 0.000_000_000_1 * 1e18, "target balance of pt");
        assertEq(target.balanceOf(address(adapter)), 0, "zero target balance");
        uint256 cmaxscale = Math.max(cscale, tranche.getGlobalScales().maxscale);
        assertEq(tranche.lscales(user), cmaxscale, "lscale should be updated to max scale");
        assertEq(tranche.unclaimedYields(user), 0, "unclaimed yield should be zero");
    }

    /// @notice Test issuance of PT+YT on top of existing PT+YT
    /// @dev when scale has increased since last issuance, accrued yield should be recorded
    function testIssue_WhenUnclaimedYieldNonZero() public override {
        // setup
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued1 = tranche.issue(address(this), amount);
        // pre-state
        uint256 preTargetBal = target.balanceOf(address(tranche));
        uint256 preFee = balanceOfFeeRecipient();
        uint256 preLscale = tranche.lscales(address(this));
        // execution
        _simulateScaleIncrease();
        uint256 issued2 = tranche.issue(address(this), amount);
        // post-state
        uint256 yield = _calculateYieldRoundDown(issued1, preLscale, tranche.getGlobalScales().maxscale);
        uint256 shares = _convertToShares(amount - _getIssuanceFee(amount), adapter.scale());
        // assert
        assertApproxEqAbs(issued2, issued1, _DELTA_, "issued amount should be approx equal to previous issuance");
        assertEq(tranche.balanceOf(address(this)), issued1 + issued2, "balance");
        assertEq(yt.balanceOf(address(this)), issued1 + issued2, "yt balance");
        assertEq(tranche.totalSupply(), issued1 + issued2, "total supply");
        assertApproxEqAbs(target.balanceOf(address(tranche)), preTargetBal + shares, _DELTA_ + 1, "target balance");
        assertApproxEqAbs(balanceOfFeeRecipient(), preFee + _getIssuanceFee(amount), _DELTA_ + 1, "issuance fee");
        assertEq(tranche.unclaimedYields(address(this)), yield, "unclaimed yield should be recorded");
    }

    /// @notice Round trip test
    ///     Issue PT+YT and then redeem all PT+YT
    ///     - `underlyingWithdrawn` should be equal to `uDeposit` subtracted by fee
    function testRT_Issue_RedeemWithYT_Immediately(uint256 uDeposit) public override {
        uDeposit = bound(uDeposit, MIN_UNDERLYING_DEPOSIT, initialBalance);
        uint256 prevBalance = underlying.balanceOf(address(this));
        _testRT_Issue_RedeemWithYT(uDeposit, noop); // scale does not change
        assertApproxEqRel(
            underlying.balanceOf(address(this)) + _getIssuanceFee(uDeposit),
            prevBalance,
            0.000_000_000_1 * 1e18,
            "underlying withdrawn should be equal to uDeposit subtracted by fee"
        );
    }

    /// @notice Round trip test with scale increase
    ///     Issue PT+YT and then redeem all PT+YT
    /// @param uDeposit amount of underlying to deposit
    function testRT_Issue_RedeemWithYT_ScaleIncrease(uint256 uDeposit) public override {
        uDeposit = bound(uDeposit, MIN_UNDERLYING_DEPOSIT, initialBalance); // 100 is the minimum deposit to make sure accrued yield is not 0
        uint256 prevBalance = underlying.balanceOf(address(this));
        _testRT_Issue_RedeemWithYT(uDeposit, _simulateScaleIncrease);
        assertGt(
            underlying.balanceOf(address(this)) + _getIssuanceFee(uDeposit),
            prevBalance,
            "underlying withdrawn should be greater than uDeposit subtracted by fee"
        );
    }

    /// @notice Round trip test with scale decrease
    ///     Issue PT+YT and then redeem all PT+YT
    /// @param uDeposit amount of underlying to deposit
    function testRT_Issue_RedeemWithYT_ScaleDecrease(uint256 uDeposit) public override {
        uDeposit = bound(uDeposit, MIN_UNDERLYING_DEPOSIT, initialBalance);
        uint256 prevBalance = underlying.balanceOf(address(this));
        _testRT_Issue_RedeemWithYT(uDeposit, _simulateScaleDecrease);
        assertLt(
            underlying.balanceOf(address(this)) + _getIssuanceFee(uDeposit),
            prevBalance,
            "underlying withdrawn should be less than uDeposit subtracted by fee"
        );
    }

    // MUST return as close to and no more than the exact amount of underliyng that
    // would be obtained in a redeem call in the same transaction.
    // I.e. redeem should return the same or more underlyingAmount as previewWithdraw
    // if called in the same transaction.
    /// @notice This test checks EIP5096 compliance
    /// @param args PreviewFuncFuzzArgs struct
    /// @param newTimestamp New timestamp to warp to
    function testFuzz_Collect_AfterMaturity(
        CollectFuzzArgs memory args,
        uint32 newTimestamp
    ) public override boundCollectFuzzArgs(args) {
        deal(address(underlying), args.caller, args.uDeposit);
        _issue(args.caller, args.caller, args.uDeposit);
        // Aave may revert with error code 50 `BORROW_CAP_EXCEEDED` if the timestamp is too large.
        // so we bound the timestamp to be less than 300 days after maturity.
        // https://github.com/aave/aave-v3-core/blob/6070e82d962d9b12835c88e68210d0e63f08d035/contracts/protocol/libraries/helpers/Errors.sol#L58C72-L58C80
        // https://github.com/aave/aave-v3-core/blob/6070e82d962d9b12835c88e68210d0e63f08d035/contracts/protocol/libraries/logic/ValidationLogic.sol#L192C22-L192C31
        newTimestamp = boundU32(newTimestamp, _maturity, _maturity + 300 days);
        vm.warp(newTimestamp);
        _testFuzz_Collect(args);
    }

    /// @notice Test redeeming PT
    ///         - PT should be burned
    ///         - Target should be redeemed for underlying
    /// @param amountToRedeem amount of PT to redeem (less than issued amount)
    function testRedeem_WhenScaleDecrease(uint256 amountToRedeem) public override {
        // setup
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued = _issue(address(this), user, amount);
        vm.warp(_maturity + 7 days);
        amountToRedeem = bound(amountToRedeem, 10, issued); // minimum amount to redeem is 10 to avoid "ZERO_ASSETS" error
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

    /////////////////////////////////////////////////////////////////////
    /// REDEEM WITH YT FUZZ
    /////////////////////////////////////////////////////////////////////

    /// @notice Test redeeming PT with YT
    ///         - PT+YT should be burned
    ///         - Accrued yield should be sent to user
    /// @param amountRedeem amount of PT+YT to redeem
    /// @param newTimestamp new timestamp to warp to
    function testRedeemWithYT_ScaleIncrease(uint256 amountRedeem, uint32 newTimestamp) public override {
        // if newTimestamp < block.timestamp, can't get atoken balance.
        newTimestamp = boundU32(newTimestamp, block.timestamp, _maturity + 300 days);
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued = _issue(address(this), address(this), amount);
        amountRedeem = bound(amountRedeem, 0, issued);
        _testRedeemWithYT(issued, amountRedeem, _simulateScaleIncrease, newTimestamp);
    }

    /// @notice Test redeeming PT with YT
    ///         - PT+YT should be burned
    ///         - There should be no accrued yield
    /// @param amountRedeem amount of PT+YT to redeem
    /// @param newTimestamp new timestamp to warp to
    function testRedeemWithYT_ScaleDecrease(uint256 amountRedeem, uint32 newTimestamp) public override {
        // if newTimestamp < block.timestamp, can't get atoken balance.
        newTimestamp = boundU32(newTimestamp, block.timestamp, _maturity + 300 days);
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued = _issue(address(this), address(this), amount);
        // if amountRedeem <= 1, it reverted by "ZERO_ASSETS"
        amountRedeem = bound(amountRedeem, 2, issued);
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
    ) internal virtual override(StdCheats, AAVEFixture) {
        AAVEFixture.deal(token, to, give, adjust);
    }
}
