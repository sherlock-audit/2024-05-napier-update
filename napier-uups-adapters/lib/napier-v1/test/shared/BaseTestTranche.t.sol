// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {CompleteFixture, AdapterFixture} from "../Fixtures.sol";

import {ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts@4.9.3/utils/math/Math.sol";

import {ITrancheFactory} from "src/interfaces/ITrancheFactory.sol";
import {IBaseAdapter} from "src/interfaces/IBaseAdapter.sol";
import {ITranche, Tranche} from "src/Tranche.sol";
import {TrancheFactory} from "src/TrancheFactory.sol";
import {YieldToken} from "src/YieldToken.sol";
import {MAX_BPS} from "src/Constants.sol";

import {StringHelper} from "../utils/StringHelper.sol";

/// @dev Base test suite for Tranche
abstract contract BaseTestTranche is CompleteFixture {
    using stdStorage for StdStorage;

    function testConstructor_Ok() public virtual {
        assertEq(tranche.getSeries().maturity, _maturity);
        assertEq(tranche.getSeries().issuanceFee, _issuanceFee);
        assertEq(tranche.management(), management);
        assertEq(tranche.getSeries().mscale, 0);
        assertEq(tranche.getGlobalScales().mscale, 0);
        assertGt(tranche.getSeries().maxscale, 0);
        assertGt(tranche.getGlobalScales().maxscale, 0);
    }

    function testPrincipalTokenMetadata() public virtual {
        assertEq(tranche.maturity(), _maturity, "maturity");
        assertEq(tranche.underlying(), address(underlying));
        assertEq(tranche.target(), address(target));
        assertEq(tranche.yieldToken(), address(yt));
    }

    function testERC20Metadata() public {
        assertEq(tranche.decimals(), underlying.decimals(), "decimals");
        assertTrue(StringHelper.isSubstring(tranche.name(), "Napier Principal Token"), "name");
        assertTrue(StringHelper.isSubstring(tranche.name(), target.name()), "name");
        assertTrue(StringHelper.isSubstring(tranche.symbol(), "eP"), "symbol");
        assertTrue(StringHelper.isSubstring(tranche.symbol(), target.symbol()), "symbol");
        console2.log("name: %s", tranche.name());
        console2.log("symbol: %s", tranche.symbol());
    }

    /////////////////////////////////////////////////////////////////////
    /// ISSUE
    /////////////////////////////////////////////////////////////////////

    /// @notice Test first issuance of PT+YT
    function testIssue_Ok() public virtual {
        // setup
        uint256 amount = 100 * ONE_SCALE;
        uint256 cscale = adapter.scale();
        uint256 cmaxscale = Math.max(cscale, tranche.getGlobalScales().maxscale);
        uint256 fee = _getIssuanceFee(amount);
        uint256 shares = _convertToShares(amount - fee, cscale);
        // execution
        uint256 issued = tranche.issue(user, amount);
        // assert
        assertEq(tranche.balanceOf(user), issued, "user balance of pt");
        assertEq(yt.balanceOf(user), issued, "yt balance of pt");
        assertEq(tranche.totalSupply(), issued, "total supply");
        assertEq(balanceOfFeeRecipient(), fee, "issuance fee");
        assertApproxEqAbs(
            (amount * (MAX_BPS - _issuanceFee)) / MAX_BPS,
            issued,
            20,
            "issued amount should be reduced by fee"
        );
        assertApproxEqAbs(target.balanceOf(address(tranche)), shares, _DELTA_, "target balance of pt");
        assertEq(target.balanceOf(address(adapter)), 0, "zero target balance");
        assertEq(tranche.lscales(user), cmaxscale, "lscale should be updated to max scale");
        assertEq(tranche.unclaimedYields(user), 0, "unclaimed yield should be zero");
    }

    /// @notice Test issuance of PT+YT on top of existing PT+YT
    /// @dev when scale has increased since last issuance, accrued yield should be recorded
    function testIssue_WhenUnclaimedYieldNonZero() public virtual {
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
        assertApproxEqAbs(issued2, issued1, _DELTA_, "issued amount should be equal to previous issuance");
        assertEq(tranche.balanceOf(address(this)), issued1 + issued2, "balance");
        assertEq(yt.balanceOf(address(this)), issued1 + issued2, "yt balance");
        assertEq(tranche.totalSupply(), issued1 + issued2, "total supply");
        assertApproxEqAbs(target.balanceOf(address(tranche)), preTargetBal + shares, _DELTA_ + 1, "target balance");
        assertApproxEqAbs(balanceOfFeeRecipient(), preFee + _getIssuanceFee(amount), _DELTA_ + 1, "issuance fee");
        assertEq(tranche.unclaimedYields(address(this)), yield, "unclaimed yield should be recorded");
    }

    /////////////////////////////////////////////////////////////////////
    /// REDEEM WITH YT FUZZ
    /////////////////////////////////////////////////////////////////////

    /// @notice Test redeeming PT with YT
    ///         - PT+YT should be burned
    ///         - Accrued yield should be sent to user
    /// @param amountRedeem amount of PT+YT to redeem
    /// @param newTimestamp new timestamp to warp to
    function testRedeemWithYT_ScaleIncrease(uint256 amountRedeem, uint32 newTimestamp) public virtual {
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued = _issue(address(this), address(this), amount);
        amountRedeem = bound(amountRedeem, 0, issued);
        newTimestamp = boundU32(newTimestamp, block.timestamp, _maturity + 365 days);
        // assert
        _testRedeemWithYT(issued, amountRedeem, _simulateScaleIncrease, newTimestamp);
    }

    /// @notice Test redeeming PT with YT
    ///         - PT+YT should be burned
    ///         - There should be no accrued yield
    /// @param amountRedeem amount of PT+YT to redeem
    /// @param newTimestamp new timestamp to warp to
    function testRedeemWithYT_ScaleDecrease(uint256 amountRedeem, uint32 newTimestamp) public virtual {
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued = _issue(address(this), address(this), amount);
        amountRedeem = bound(amountRedeem, 0, issued);
        newTimestamp = boundU32(newTimestamp, block.timestamp, _maturity + 365 days);
        // assert
        _testRedeemWithYT(issued, amountRedeem, _simulateScaleDecrease, newTimestamp);
    }

    /////////////////////////////////////////////////////////////////////
    /// REDEEM WITH YT
    /////////////////////////////////////////////////////////////////////

    ////////////////////////////////////////////////////////////////////////////////
    // redeemWithYT: when there are a issuance prior to redeemWithYT
    // i.e. lscale is non-zero
    ////////////////////////////////////////////////////////////////////////////////

    /// @param issued amount of PT+YT issued
    /// @param amountRedeem amount of PT+YT to redeem
    /// @param simulateScaleChange function to simulate scale change
    /// @param newTimestamp new timestamp to warp to
    function _testRedeemWithYT(
        uint256 issued,
        uint256 amountRedeem,
        function() internal simulateScaleChange,
        uint256 newTimestamp
    ) internal virtual {
        vm.warp(newTimestamp);
        // scale increases after issue
        uint256 maxscale = tranche.getGlobalScales().maxscale;
        simulateScaleChange();
        uint256 cscale = adapter.scale();
        // execution
        // redeem with YT and send to 0xcafe
        uint256 underlyingWithdrawn = tranche.redeemWithYT(address(this), address(0xcafe), amountRedeem);
        // assert
        // the next assertion will fail if already settled
        assertEq(tranche.lscales(address(this)), Math.max(cscale, maxscale), "lscale");
        assertApproxEqAbs(tranche.balanceOf(address(this)), issued - amountRedeem, _DELTA_, "pt balance");
        assertApproxEqAbs(yt.balanceOf(address(this)), issued - amountRedeem, _DELTA_, "yt balance");
        assertApproxEqAbs(underlying.balanceOf(address(0xcafe)), underlyingWithdrawn, 2, "receiver underlying balance"); // diff should be 0 in theory.
        assertEq(target.balanceOf(address(adapter)), 0, "target balance");
    }

    function testRedeemWithYT_AfterMaturity_AlreadySettle_LscaleNonZero() public virtual {
        uint256 issued = _issue(address(this), address(this), 100 * ONE_SCALE);
        uint256 amountRedeem = issued / 2;
        vm.warp(_maturity);
        _redeem(user, user, 0, user); // trigger settle
        // noop because _testRedeemWithYT assume settlement has not happened yet.
        // hack: doesn't matter if scale doesn't change after the settlement.
        _testRedeemWithYT(issued, amountRedeem, noop, _maturity);
    }

    ////////////////////////////////////////////////////////////////////////////////
    // redeemWithYT: when there are no issuance prior to redeemWithYT
    ////////////////////////////////////////////////////////////////////////////////

    /// @notice Round trip test
    ///     Issue PT+YT and then redeem all PT+YT
    ///     - `underlyingWithdrawn` should be equal to `uDeposit` subtracted by fee
    function testRT_Issue_RedeemWithYT_Immediately(uint256 uDeposit) public virtual {
        uDeposit = bound(uDeposit, MIN_UNDERLYING_DEPOSIT, initialBalance);
        uint256 prevBalance = underlying.balanceOf(address(this));
        _testRT_Issue_RedeemWithYT(uDeposit, noop); // scale does not change
        assertApproxEqAbs(
            underlying.balanceOf(address(this)) + _getIssuanceFee(uDeposit),
            prevBalance,
            // in theory users can't get back more than uDeposit subtracted by fee.
            // the following should be true:
            // uWithdrawn ~= uDeposit - fee AND uWithdrawn - (uDeposit + fee) < 0
            2 * _DELTA_, // 2x tolerance
            "underlying withdrawn should be equal to uDeposit subtracted by fee"
        );
    }

    /// @notice Round trip test with scale increase
    ///     Issue PT+YT and then redeem all PT+YT
    /// @param uDeposit amount of underlying to deposit
    function testRT_Issue_RedeemWithYT_ScaleIncrease(uint256 uDeposit) public virtual {
        // 100 is the minimum deposit to make sure accrued yield would be rounded down to zero
        uDeposit = bound(uDeposit, MIN_UNDERLYING_DEPOSIT, initialBalance);
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
    function testRT_Issue_RedeemWithYT_ScaleDecrease(uint256 uDeposit) public virtual {
        uDeposit = bound(uDeposit, MIN_UNDERLYING_DEPOSIT, initialBalance);
        uint256 prevBalance = underlying.balanceOf(address(this));
        _testRT_Issue_RedeemWithYT(uDeposit, _simulateScaleDecrease);
        assertLt(
            underlying.balanceOf(address(this)) + _getIssuanceFee(uDeposit),
            prevBalance,
            "underlying withdrawn should be less than uDeposit subtracted by fee"
        );
    }

    /// @notice Round trip test with scale change
    ///     Issue PT+YT and then redeem all PT+YT
    /// @param uDeposit amount of underlying to deposit
    /// @param simulateScaleChange function to simulate scale change
    ///         - scale should increase/decrease/remain the same after issue
    function _testRT_Issue_RedeemWithYT(uint256 uDeposit, function() internal simulateScaleChange) internal virtual {
        uint256 issued = tranche.issue(address(this), uDeposit);
        simulateScaleChange();
        tranche.redeemWithYT(address(this), address(this), issued);
        // all PT+YT should be burned
        assertEq(tranche.balanceOf(address(this)), 0, "pt balance");
        assertEq(yt.balanceOf(address(this)), 0, "yt balance");
    }

    /////////////////////////////////////////////////////////////////////
    /// REDEEM
    /////////////////////////////////////////////////////////////////////

    /// @notice Test redeeming PT
    /// - PT should be burned
    /// - Target should be redeemed for underlying token
    /// @param amountToRedeem amount of PT to redeem (less than issued amount)
    function testRedeem_WhenScaleIncrease(uint256 amountToRedeem) public virtual {
        // setup
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued = _issue(address(this), user, amount);
        vm.warp(_maturity + 7 days);
        amountToRedeem = bound(amountToRedeem, 0, issued);
        // scale increases after issue
        _simulateScaleIncrease();
        // execution
        _testRedeem(amountToRedeem, user, user, user);
    }

    /// @param amountToRedeem amount of PT to redeem (less than issued amount)
    function testRedeem_WhenScaleDecrease(uint256 amountToRedeem) public virtual {
        // setup
        uint256 amount = 100 * ONE_SCALE;
        uint256 issued = _issue(address(this), user, amount);
        vm.warp(_maturity + 7 days);
        amountToRedeem = bound(amountToRedeem, 0, issued);
        // scale increases after issue
        _simulateScaleDecrease();
        // execution
        _testRedeem(amountToRedeem, user, user, user);
    }

    /// @notice Test redeeming PT
    ///         - PT should be burned
    ///         - Target should be redeemed and sent to `to` address
    ///         - YT balance should not change
    ///         - Receiver should receive underlying
    /// @param principalAmount amount of PT to redeem (less than issued amount)
    /// @param to address to send redeemed target
    /// @param from owner of PT to redeem
    /// @param caller address to call redeem function
    function _testRedeem(uint256 principalAmount, address to, address from, address caller) internal virtual {
        // pre-execution state
        uint256 totSupplyBefore = tranche.totalSupply();
        uint256 balBefore = tranche.balanceOf(from);
        uint256 yBal = yt.balanceOf(from);

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
            _convertToUnderlying(((principalAmount * WAD) / tranche.getGlobalScales().maxscale), adapter.scale()),
            0.000_000_1 * 1e18,
            "underlying withdrawn"
        );
    }

    /////////////////////////////////////////////////////////////////////
    /// WITHDRAW
    /////////////////////////////////////////////////////////////////////

    /// @notice Test withdrawing underlying when scale increases
    ///         - PT should be burned
    ///         - Target should be redeemed for underlying token
    function testWithdraw_WhenScaleIncrease() public virtual {
        // setup
        uint256 amount = 100 * ONE_SCALE;
        _issue(address(this), user, amount);
        vm.warp(_maturity + 7 days);
        // scale increases after issue
        _simulateScaleIncrease();
        // execution
        _testWithdraw(amount / 2, user, user, user);
    }

    /// @notice Test withdrawing underlying when scale decreases
    ///         - PT should be burned
    ///         - Target should be redeemed for underlying token
    function testWithdraw_WhenScaleDecrease() public virtual {
        // setup
        uint256 amount = 100 * ONE_SCALE;
        _issue(address(this), user, amount);
        vm.warp(_maturity + 7 days);
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
    /// @param underlyingAmount amount of underlying to withdraw (less than underlying balance)
    /// @param to receiver of underlying withdrawn
    /// @param from owner of PT to redeem
    /// @param caller address to call redeem function
    function _testWithdraw(
        uint256 underlyingAmount,
        address to,
        address from,
        address caller
    ) internal virtual returns (uint256) {
        // pre-execution state
        uint256 totSupplyBefore = tranche.totalSupply();
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
        assertEq(tranche.totalSupply(), totSupplyBefore - ptRedeemed, "total supply");
        assertEq(yt.balanceOf(from), yBal, "yt balance shouldn't change");
        assertEq(target.balanceOf(address(adapter)), 0, "no funds left in adapter");
        assertApproxEqAbs(underlying.balanceOf(to), underlyingAmount, _DELTA_, "balance == underlying withdrawn"); // diff should be 0 in theory.
        assertApproxEqAbs(
            target.balanceOf(address(tranche)),
            tBal - _convertToShares(underlyingAmount, cscale),
            _DELTA_,
            "target balance"
        );
        return ptRedeemed;
    }

    /////////////////////////////////////////////////////////////////////
    /// UPDATE UNCLAIMED YIELD
    /////////////////////////////////////////////////////////////////////

    function testUpdateUnclaimedYield_ReceiverLscaleZero() public virtual {
        _issue(address(this), address(this), 100 * ONE_SCALE);
        // execution
        vm.prank(address(yt));
        tranche.updateUnclaimedYield(address(this), user, 100);
        // assert yt balance of from and to
        assertEq(tranche.lscales(address(this)), tranche.getGlobalScales().maxscale, "lscale should be maxscale");
        assertEq(tranche.lscales(user), tranche.getGlobalScales().maxscale, "lscale should be maxscale");
        assertEq(
            tranche.unclaimedYields(user),
            0,
            "unclaimed yield should be zero because receiver didn't have any yt"
        );
    }

    /////////////////////////////////////////////////////////////////////
    /// UPDATE UNCLAIMED YIELD FUZZ
    /////////////////////////////////////////////////////////////////////

    /// @notice Fuzz Args for updateUnclaimedYield test
    struct UpdateUnclaimedYieldFuzzArgs {
        uint256 cscale; // current scale of adapter
        address[2] accounts; // 0: from, 1: to
        uint256[2] uDeposits; // underlying deposits of from and to
        uint256[2] unclaimedYields; // unclaimed yields of from and to
        uint256 yAmountTransfer; // yt amount to transfer from `from` to `to`
    }

    modifier boundUpdateUnclaimedYieldFuzzArgs(UpdateUnclaimedYieldFuzzArgs memory args) virtual {
        vm.assume(args.accounts[0] != address(0) && args.accounts[1] != address(0));
        vm.assume(accountsExcludedFromFuzzing[args.accounts[0]] == false);
        vm.assume(accountsExcludedFromFuzzing[args.accounts[1]] == false);
        args.cscale = bound(args.cscale, 1, RAY);
        args.uDeposits[0] = bound(args.uDeposits[0], 0, MAX_UNDERLYING_DEPOSIT);
        args.uDeposits[1] = bound(args.uDeposits[1], 0, MAX_UNDERLYING_DEPOSIT);
        args.unclaimedYields[0] = bound(args.unclaimedYields[0], 0, MAX_UNDERLYING_DEPOSIT);
        args.unclaimedYields[1] = bound(args.unclaimedYields[1], 0, MAX_UNDERLYING_DEPOSIT);
        args.yAmountTransfer = bound(args.yAmountTransfer, 0, args.uDeposits[0]);
        _;
    }

    /// @notice Helper function to test `updateUnclaimedYield` function
    /// @dev This test is not applicable for the zero address case.
    ///      Timestamp can be before or after maturity
    ///      This test checks the following:
    ///        - `lscale`s of `sender` and `to` should be updated to the current maxscale
    ///        - YT balances of `sender` and `to`should not change in any case
    ///        - Accrued interest should be transferred to `from`
    function _testFuzz_UpdateUnclaimedYield(UpdateUnclaimedYieldFuzzArgs memory args) public virtual {
        // pre-execution state
        uint256[2] memory yBalances = [yt.balanceOf(args.accounts[0]), yt.balanceOf(args.accounts[1])];
        // setup
        vm.mockCall(address(adapter), abi.encodeWithSelector(IBaseAdapter.scale.selector), abi.encode(args.cscale));
        // execution
        vm.prank(address(yt));
        tranche.updateUnclaimedYield(args.accounts[0], args.accounts[1], args.yAmountTransfer);
        vm.clearMockedCalls();
        // assert yt balance of from and to
        assertEq(yt.balanceOf(args.accounts[0]), yBalances[0], "yt of from should not be burned");
        assertEq(yt.balanceOf(args.accounts[1]), yBalances[1], "yt of to should not be burned");
    }

    /// @notice Test `updateUnclaimedYield` function when `from` and `to` are the same
    /// @dev This test is not applicable for the zero address case.
    ///     Timestamp can be before or after maturity
    /// @param args UpdateUnclaimedYieldFuzzArgs
    /// @param newTimestamp new timestamp to warp to
    function testFuzz_UpdateUnclaimedYield_FromIsTo(
        UpdateUnclaimedYieldFuzzArgs memory args,
        uint32 newTimestamp
    ) public virtual boundUpdateUnclaimedYieldFuzzArgs(args) {
        args.accounts[1] = args.accounts[0];
        args.uDeposits[1] = args.uDeposits[0];
        args.unclaimedYields[1] = args.unclaimedYields[0];
        // setup
        deal(address(underlying), args.accounts[0], args.uDeposits[0], true);
        _setUpPreCollect(args.accounts[0], args.uDeposits[0], args.unclaimedYields[0]);
        vm.warp(newTimestamp);
        // execution
        _testFuzz_UpdateUnclaimedYield(args);
        assertEq(
            tranche.lscales(args.accounts[1]),
            tranche.lscales(args.accounts[0]),
            "lscale of from and receiver should be equal"
        );
    }

    /// @notice Test `updateUnclaimedYield` function when `from` is not `to`, non-zero YT-transfer and `lscale` is zero
    function testFuzz_UpdateUnclaimedYield_FromIsNotTo_NonZeroTransfer_LscaleZero(
        UpdateUnclaimedYieldFuzzArgs memory args,
        uint32 newTimestamp
    ) public virtual boundUpdateUnclaimedYieldFuzzArgs(args) {
        vm.assume(args.accounts[0] != args.accounts[1]);
        // non-zero transfer
        args.uDeposits[0] = bound(args.uDeposits[0], 1, MAX_UNDERLYING_DEPOSIT);
        args.yAmountTransfer = bound(args.yAmountTransfer, 1, args.uDeposits[0]);
        // setup
        deal(address(underlying), args.accounts[0], args.uDeposits[0], true);
        deal(address(underlying), args.accounts[1], args.uDeposits[1], true);
        _setUpPreCollect(args.accounts[0], args.uDeposits[0], args.unclaimedYields[0]);
        _setUpPreCollect(args.accounts[1], args.uDeposits[1], args.unclaimedYields[1]);
        vm.warp(newTimestamp);
        // NOTE: we need to overwrite `lscale` of `from` to zero to test the case
        _overwriteWithOneKey(address(tranche), "lscales(address)", args.accounts[0], 0);
        // execution
        vm.expectRevert(ITranche.NoAccruedYield.selector);
        this._testFuzz_UpdateUnclaimedYield(args);
    }

    /// @notice Test `updateUnclaimedYield` function when `from` is not `to`, non-zero YT-transfer and `lscale` is non-zero
    function testFuzz_UpdateUnclaimedYield_FromIsNotTo_NonZeroTransfer_LscaleNonZero(
        UpdateUnclaimedYieldFuzzArgs memory args,
        uint32 newTimestamp
    ) public virtual boundUpdateUnclaimedYieldFuzzArgs(args) {
        vm.assume(args.accounts[0] != args.accounts[1]);
        // non-zero transfer
        vm.assume(args.yAmountTransfer > 0);
        // setup
        deal(address(underlying), args.accounts[0], args.uDeposits[0], true);
        deal(address(underlying), args.accounts[1], args.uDeposits[1], true);
        _setUpPreCollect(args.accounts[0], args.uDeposits[0], args.unclaimedYields[0]);
        _setUpPreCollect(args.accounts[1], args.uDeposits[1], args.unclaimedYields[1]);
        vm.warp(newTimestamp);
        // pre-execution state
        uint256 lscale = tranche.lscales(args.accounts[0]);
        uint256 yBal = yt.balanceOf(args.accounts[0]);
        vm.assume(lscale > 0);
        // execution
        _testFuzz_UpdateUnclaimedYield(args);
        uint256 cmaxscale = tranche.getGlobalScales().maxscale;
        assertEq(
            tranche.unclaimedYields(args.accounts[0]),
            args.unclaimedYields[0] + _calculateYieldRoundDown(yBal, lscale, cmaxscale),
            "from's unclaimed yield should increase"
        ); // prettier-ignore
        assertEq(tranche.lscales(args.accounts[0]), cmaxscale, "from's scale is equal to maxscale");
    }

    /// @notice Test `UpdateUnclaimedYield` when from != to and zero transfer
    function testFuzz_UpdateUnclaimedYield_FromIsNotTo_ZeroTransfer(
        UpdateUnclaimedYieldFuzzArgs memory args,
        uint32 newTimestamp
    ) public virtual boundUpdateUnclaimedYieldFuzzArgs(args) {
        vm.assume(args.accounts[0] != args.accounts[1]);
        // setup zero transfer
        args.yAmountTransfer = 0;
        // setup
        deal(address(underlying), args.accounts[0], args.uDeposits[0], true);
        deal(address(underlying), args.accounts[1], args.uDeposits[1], true);
        _setUpPreCollect(args.accounts[0], args.uDeposits[0], args.unclaimedYields[0]);
        _setUpPreCollect(args.accounts[1], args.uDeposits[1], args.unclaimedYields[1]);
        vm.warp(newTimestamp);
        // execution/assertion
        _testFuzz_UpdateUnclaimedYield(args);
        assertEq(
            tranche.unclaimedYields(args.accounts[0]), args.unclaimedYields[0], "from's unclaimed yield does not change"
        ); // prettier-ignore
        assertEq(
            tranche.unclaimedYields(args.accounts[1]),
            args.unclaimedYields[1],
            "reciever's unclaimed yield does not change"
        ); // prettier-ignore
    }

    /////////////////////////////////////////////////////////////////////
    /// COLLECT
    /////////////////////////////////////////////////////////////////////

    /// @notice Test arguments for unit tests of `collect`
    struct PreCollectStates {
        address caller; // the caller of collect
        uint256 uBal; // underlying balance of the `caller` before collect
        uint256 yBal; // YT balance of the `caller` before collect
        uint256 unclaimedYield; // unclaimed yield of the `caller` before collect
        uint256 lscale; // scale of the `caller` before collect
        uint256 cscale; // scale of the tranche at the time of collect
    }

    /// @notice This test should be called by other tests to test common post-execution states.
    /// @dev This test covers several scenarios of collect
    /// @param caller The caller of collect and receiver of accrued yield
    /// @param uDeposit The amount of underlying to deposit to the tranche
    /// @param simulateScaleChange A function to simulate scale change right before collect
    /// @param newTimestamp The timestamp to warp to before collect
    function _testCollect_Ok(
        address caller,
        uint256 uDeposit,
        uint256 unclaimedYield,
        function() internal simulateScaleChange,
        uint256 newTimestamp
    ) internal virtual returns (uint256, PreCollectStates memory) {
        // set up unclaimed yield
        _setUpPreCollect(caller, uDeposit, unclaimedYield);
        vm.warp(newTimestamp);
        simulateScaleChange(); // simulate scale change
        // pre-execution state
        PreCollectStates memory prestates = PreCollectStates({
            caller: caller,
            uBal: underlying.balanceOf(caller),
            yBal: yt.balanceOf(caller),
            unclaimedYield: unclaimedYield,
            lscale: tranche.lscales(caller),
            // NOTE: cscale must be the scale at the time of next collect, otherwise the test will fail
            cscale: adapter.scale()
        });
        // execution
        (uint256 collected, uint256 collectedInUnderlying) = _collect(caller);
        // assert common post-execution states
        assertEq(tranche.unclaimedYields(caller), 0, "unclaimed yield of caller should be reset");
        assertApproxEqAbs(
            underlying.balanceOf(caller),
            prestates.uBal + collectedInUnderlying,
            _DELTA_, // rounding error
            "caller's underlying balance should increase by accrued interest"
        );
        return (collected, prestates);
    }

    /// @notice This test covers the most likely scenarios:
    ///     - Scale at collect time, `s_collect`, is higher than the scale at issuance, `s_issue`.
    /// @dev collect should accrue yield and unclaimed yield.
    function _testCollect_ScaleIncrease(uint256 timestamp) internal virtual returns (PreCollectStates memory) {
        address caller = address(this);
        uint256 amount = 100 * ONE_SCALE;
        uint256 unclaimedYield = ONE_TARGET; // 1 target token

        (uint256 collected, PreCollectStates memory prestates) = _testCollect_Ok(
            caller,
            amount,
            unclaimedYield,
            _simulateScaleIncrease, // scale increase
            timestamp
        );
        uint256 expectedYield = _calculateYieldRoundDown({
            amount: prestates.yBal,
            prevScale: prestates.lscale,
            currScale: tranche.getGlobalScales().maxscale
        });
        assertApproxEqAbs(collected, expectedYield + prestates.unclaimedYield, _DELTA_, "collected");
        return prestates;
    }

    /// @notice Does not change YT balance of the caller (issuer) before maturity
    function testCollect_BeforeMaturity_ScaleIncrease() public virtual {
        PreCollectStates memory prestates = _testCollect_ScaleIncrease(_maturity - 1);
        assertEq(
            yt.balanceOf(prestates.caller),
            prestates.yBal,
            "yt balance of caller should not change before maturity"
        );
    }

    /// @notice After maturity, `yt` balance of `caller` should be burned on collect
    function testCollect_AfterMaturity_ScaleIncrease() public virtual {
        _testCollect_ScaleIncrease(_maturity);
        assertEq(yt.balanceOf(address(this)), 0, "yt balance of caller should be burned after maturity");
    }

    /// @notice This test covers possible scenarios:
    ///     - Scale at collect time, `s_collect`, is lower than the scale at issuance, `s_issue`.
    /// @dev collect should not accrue yield other than unclaimed yield.
    function _testCollect_ScaleDecrease(uint256 timestamp) internal virtual returns (PreCollectStates memory) {
        address caller = address(this);
        uint256 amount = 100 * ONE_SCALE;
        uint256 unclaimedYield = ONE_TARGET; // 1 target token

        (uint256 collected, PreCollectStates memory prestates) = _testCollect_Ok(
            caller,
            amount,
            unclaimedYield,
            _simulateScaleDecrease, // scale decrease
            _bound(timestamp, block.timestamp, _maturity + 100 days)
        );
        assertApproxEqAbs(collected, unclaimedYield, _DELTA_, "nothing but unclaimed yield should be accrued");
        return prestates;
    }

    /// @notice Does not change YT balance of the caller (issuer) before maturity
    function testCollect_BeforeMaturity_ScaleDecrease() public virtual {
        PreCollectStates memory prestates = _testCollect_ScaleDecrease(_maturity - 1);
        assertEq(
            yt.balanceOf(prestates.caller),
            prestates.yBal,
            "yt balance of caller should not change before maturity"
        );
    }

    /// @notice After maturity, `yt` balance of `caller` should be burned on collect
    function testCollect_AfterMaturity_ScaleDecrease() public virtual {
        _testCollect_ScaleDecrease(_maturity);
        assertEq(yt.balanceOf(address(this)), 0, "yt balance of caller should be burned after maturity");
    }

    function testCollect_RevertIfLscaleIsZero() external {
        vm.expectRevert(ITranche.NoAccruedYield.selector);
        tranche.collect();
    }

    /////////////////////////////////////////////////////////////////////
    /// COLLECT FUZZ
    /////////////////////////////////////////////////////////////////////

    /// @notice Fuzz args for collect function
    /// @dev This struct is used to pass arguments to boundCollectFuzzArgs modifier
    struct CollectFuzzArgs {
        uint256 cscale; // current scale
        address caller; // caller of collect function
        uint256 uDeposit; // underlying amount to deposit to tranche
    }

    modifier boundCollectFuzzArgs(CollectFuzzArgs memory args) virtual {
        vm.assume(args.caller != address(0));
        vm.assume(accountsExcludedFromFuzzing[args.caller] == false);
        args.cscale = bound(args.cscale, 1, RAY);
        args.uDeposit = bound(args.uDeposit, 0, MAX_UNDERLYING_DEPOSIT);
        _;
    }

    /// @notice This test covers most common several assert cases: collect before maturity
    /// @param args CollectFuzzArgs
    /// @param newTimestamp New timestamp to warp to
    function testFuzz_Collect_BeforeMaturity(
        CollectFuzzArgs memory args,
        uint32 newTimestamp
    ) public virtual boundCollectFuzzArgs(args) {
        deal(address(underlying), args.caller, args.uDeposit, true);
        _issue(args.caller, args.caller, args.uDeposit);
        newTimestamp = boundU32(newTimestamp, block.timestamp, _maturity - 1);
        vm.warp(newTimestamp);
        _testFuzz_Collect(args);
    }

    /// @notice This test covers most common several assert cases: collect after maturity
    /// @param args CollectFuzzArgs
    /// @param newTimestamp New timestamp to warp to
    function testFuzz_Collect_AfterMaturity(
        CollectFuzzArgs memory args,
        uint32 newTimestamp
    ) public virtual boundCollectFuzzArgs(args) {
        deal(address(underlying), args.caller, args.uDeposit, true);
        _issue(args.caller, args.caller, args.uDeposit);
        newTimestamp = boundU32(newTimestamp, _maturity, _maturity + 100 days);
        vm.warp(newTimestamp);
        _testFuzz_Collect(args);
    }

    /// @notice Internal test helper function for `collect` function
    /// @dev This test is not applicable for the zero address case.
    ///      Timestamp can be before or after maturity
    ///      This test checks the following:
    ///        - `lscale` of `caller` should be updated to the current `maxscale`
    ///        - YT balance of `caller` should be burned if maturity is reached
    ///        - `unclaimedYield` of `caller` should be reset
    ///        - Accrued interest should be transferred to `caller` and it should be equal to the sum of: (1) unclaimed yield, (2) accrued interest, (3) principal portion
    ///             This test doesn't check the exact amount of (1), (2), (3). Just check whether the sum of them is equal to the returned value of `collect` function.
    /// @dev Note: `vm.mockCall` is used to simulate scale but actual conversion rate used in `prefundedRedeem` could not be simulated.
    /// @param args CollectFuzzArgs struct
    function _testFuzz_Collect(CollectFuzzArgs memory args) public virtual {
        // pre-execution state
        uint256 tBalance = target.balanceOf(address(tranche));
        uint256 yBalance = yt.balanceOf(args.caller);
        // setup
        vm.mockCall(address(adapter), abi.encodeWithSelector(IBaseAdapter.scale.selector), abi.encode(args.cscale));
        // execution
        uint256 uBal = underlying.balanceOf(args.caller);
        (uint256 collected, uint256 collectedInUnderlying) = _collect(args.caller);
        vm.clearMockedCalls();
        // assert
        uint256 expectedYBal = _isMatured() ? 0 : yBalance;
        assertEq(yt.balanceOf(args.caller), expectedYBal, "yt balance of caller");
        assertEq(tranche.lscales(args.caller), tranche.getGlobalScales().maxscale, "from's scale is equal to maxscale");
        assertEq(tranche.unclaimedYields(args.caller), 0, "unclaimed yield of caller should be reset");
        assertEq(
            underlying.balanceOf(args.caller),
            uBal + collectedInUnderlying,
            "caller's underlying balance should increase by accrued interest"
        );
        if (collected == 0) {
            assertEq(target.balanceOf(address(tranche)), tBalance, "tranche's target balance should not change");
        }
    }

    /////////////////////////////////////////////////////////////////////
    /// VIEW FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    /////////////////////////////////////////////////////////////////////
    /// CONVERT TO UNDERLYING / CONVERT TO PRINCIPAL
    /////////////////////////////////////////////////////////////////////

    // MUST NOT show any variations depending on the caller.
    /// @notice This test checks EIP5096 compliance
    /// @dev skip when forking
    /// @param callers Array of two addresses
    /// @param principal Principal amount to convert
    function testConvertToUnderlying_IndependentOnCaller(
        address[2] calldata callers,
        uint128 principal
    ) public virtual skipWhenForking {
        vm.assume(callers[0] != address(0) && callers[1] != address(0));
        vm.prank(callers[0]);
        uint256 res1 = tranche.convertToUnderlying(principal); // "MAY revert due to integer overflow caused by an unreasonably large input."
        vm.prank(callers[1]);
        uint256 res2 = tranche.convertToUnderlying(principal); // "MAY revert due to integer overflow caused by an unreasonably large input."
        assertEq(res1, res2, "prop/caller-dependency");
    }

    // MUST NOT show any variations depending on the caller.
    /// @notice This test checks EIP5096 compliance
    /// @dev skip when forking
    /// @param callers Array of two addresses
    /// @param underlyingAmount Underlying amount to convert
    function testConvertToPrincipal_IndependentOnCaller(
        address[2] calldata callers,
        uint128 underlyingAmount
    ) public virtual skipWhenForking {
        vm.assume(callers[0] != address(0) && callers[1] != address(0));
        vm.prank(callers[0]);
        uint256 res1 = tranche.convertToPrincipal(underlyingAmount); // "MAY revert due to integer overflow caused by an unreasonably large input."
        vm.prank(callers[1]);
        uint256 res2 = tranche.convertToPrincipal(underlyingAmount); // "MAY revert due to integer overflow caused by an unreasonably large input."
        assertEq(res1, res2, "prop/caller-dependency");
    }

    /////////////////////////////////////////////////////////////////////
    /// MAX REDEEM / MAX WITHDRAW
    /////////////////////////////////////////////////////////////////////

    /// @notice Fuzz args for testing `max*` and `preview*` function
    struct PreviewFuncFuzzArgs {
        address caller; // caller of issue function
        address owner; // recipient of issued PT+YT
        uint256 uDeposit; // amount of underlying to deposit to issue PT+YT
    }

    modifier boundPreviewFuncFuzzArgs(PreviewFuncFuzzArgs memory args) virtual {
        vm.assume(args.caller != address(0) && args.owner != address(0));
        vm.assume(accountsExcludedFromFuzzing[args.caller] == false);
        vm.assume(accountsExcludedFromFuzzing[args.owner] == false);
        args.uDeposit = bound(args.uDeposit, 0, MAX_UNDERLYING_DEPOSIT);
        _;
    }

    // "MUST NOT revert."
    /// @notice This test checks EIP5096 compliance
    /// @param args PreviewFuncFuzzArgs struct
    /// @param newTimestamp New timestamp to warp to
    function testMaxRedeem_BeforeMaturity(
        PreviewFuncFuzzArgs memory args,
        uint32 newTimestamp
    ) public virtual boundPreviewFuncFuzzArgs(args) {
        deal(address(underlying), args.caller, args.uDeposit, false);
        // ignore overflow/underflow when issuing
        try this._issue(args.caller, args.owner, args.uDeposit) {} catch {
            vm.assume(false);
        }
        newTimestamp = boundU32(newTimestamp, block.timestamp, _maturity - 1);
        vm.warp(newTimestamp);
        assertEq(tranche.maxRedeem(args.owner), 0, "prop/nothing-to-redeem");
    }

    // "MUST NOT revert."
    /// @notice This test checks EIP5096 compliance
    /// @param args PreviewFuncFuzzArgs struct
    /// @param newTimestamp New timestamp to warp to
    function testMaxRedeem_AfterMaturity(
        PreviewFuncFuzzArgs memory args,
        uint32 newTimestamp
    ) public virtual boundPreviewFuncFuzzArgs(args) {
        deal(address(underlying), args.caller, args.uDeposit, false);
        try this._issue(args.caller, args.owner, args.uDeposit) {} catch {
            vm.assume(false);
        }
        newTimestamp = boundU32(newTimestamp, _maturity, _maturity + 150 days);
        vm.warp(newTimestamp);
        assertEq(tranche.maxRedeem(args.owner), tranche.balanceOf(args.owner), "prop/max-redeem");
    }

    // "MUST NOT revert."
    /// @notice This test checks EIP5096 compliance
    /// @param args PreviewFuncFuzzArgs struct
    /// @param newTimestamp New timestamp to warp to
    function testMaxWithdraw_BeforeMaturity(
        PreviewFuncFuzzArgs memory args,
        uint32 newTimestamp
    ) public virtual boundPreviewFuncFuzzArgs(args) {
        deal(address(underlying), args.caller, args.uDeposit, false);
        try this._issue(args.caller, args.owner, args.uDeposit) {} catch {
            vm.assume(false);
        }
        newTimestamp = boundU32(newTimestamp, block.timestamp, _maturity - 1);
        vm.warp(newTimestamp);
        assertEq(tranche.maxWithdraw(args.owner), 0, "prop/nothing-to-redeem");
    }

    // "MUST NOT revert."
    /// @notice This test checks EIP5096 compliance
    /// @param args PreviewFuncFuzzArgs struct
    /// @param newTimestamp New timestamp to warp to
    function testMaxWithdraw_AfterMaturity(
        PreviewFuncFuzzArgs memory args,
        uint32 newTimestamp
    ) public virtual boundPreviewFuncFuzzArgs(args) {
        deal(address(underlying), args.caller, args.uDeposit, false);
        try this._issue(args.caller, args.owner, args.uDeposit) {} catch {
            vm.assume(false);
        }
        newTimestamp = boundU32(newTimestamp, _maturity, _maturity + 150 days);
        vm.warp(newTimestamp);
        uint256 expected = tranche.convertToUnderlying(tranche.balanceOf(args.owner));
        assertEq(tranche.maxWithdraw(args.owner), expected, "prop/max-withdraw");
    }

    /////////////////////////////////////////////////////////////////////
    /// PREVIEW REDEEM / PREVIEW WITHDRAW
    /////////////////////////////////////////////////////////////////////

    // "MUST NOT revert."
    /// @notice This test checks EIP5096 compliance
    /// @param args PreviewFuncFuzzArgs struct
    /// @param newTimestamp New timestamp to warp to
    function testPreviewRedeem_BeforeMaturity(
        PreviewFuncFuzzArgs memory args,
        uint32 newTimestamp
    ) public virtual boundPreviewFuncFuzzArgs(args) {
        deal(address(underlying), args.caller, args.uDeposit, false);
        try this._issue(args.caller, args.owner, args.uDeposit) {} catch {
            vm.assume(false);
        }
        uint256 principal = tranche.balanceOf(args.owner);
        newTimestamp = boundU32(newTimestamp, block.timestamp, _maturity - 1);
        vm.warp(newTimestamp);
        assertEq(tranche.previewRedeem(principal), 0, "prop/nothing-to-redeem");
    }

    // MUST return as close to and no more than the exact amount of underliyng that
    // would be obtained in a redeem call in the same transaction.
    // I.e. redeem should return the same or more underlyingAmount as previewRedeem
    // if called in the same transaction.
    /// @notice This test checks EIP5096 compliance
    /// @param args PreviewFuncFuzzArgs struct
    /// @param newTimestamp New timestamp to warp to
    function testPreviewRedeem_AfterMaturity(
        PreviewFuncFuzzArgs memory args,
        uint32 newTimestamp
    ) public virtual boundPreviewFuncFuzzArgs(args) {
        deal(address(underlying), args.caller, args.uDeposit, false);
        try this._issue(args.caller, args.owner, args.uDeposit) {} catch {
            vm.assume(false);
        }
        newTimestamp = boundU32(newTimestamp, _maturity, _maturity + 150 days);
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

    // MUST return as close to and no more than the exact amount of underliyng that
    // would be obtained in a redeem call in the same transaction.
    // I.e. redeem should return the same or more underlyingAmount as previewWithdraw
    // if called in the same transaction.
    /// @notice This test checks EIP5096 compliance
    /// @param args PreviewFuncFuzzArgs struct
    /// @param newTimestamp New timestamp to warp to
    function testPreviewWithdraw_BeforeMaturity(
        PreviewFuncFuzzArgs memory args,
        uint32 newTimestamp
    ) public virtual boundPreviewFuncFuzzArgs(args) {
        deal(address(underlying), args.caller, args.uDeposit, false);
        try this._issue(args.caller, args.owner, args.uDeposit) {} catch {
            vm.assume(false);
        }
        newTimestamp = boundU32(newTimestamp, block.timestamp, _maturity - 1);
        vm.warp(newTimestamp);
        uint256 principal = tranche.balanceOf(args.caller);
        uint256 underlyingAmount = tranche.convertToUnderlying(principal);
        assertEq(tranche.previewWithdraw(underlyingAmount), 0, "prop/nothing-to-redeem");
    }

    // MUST return as close to and no more than the exact amount of underliyng that
    // would be obtained in a withdraw call in the same transaction.
    // I.e. withdraw should return the same or more underlyingAmount as previewWithdraw
    // if called in the same transaction.
    /// @notice This test checks EIP5096 compliance
    /// @param args PreviewFuncFuzzArgs struct
    /// @param newTimestamp New timestamp to warp to
    function testPreviewWithdraw_AfterMaturity(
        PreviewFuncFuzzArgs memory args,
        uint32 newTimestamp
    ) public virtual boundPreviewFuncFuzzArgs(args) {
        deal(address(underlying), args.caller, args.uDeposit, false);
        try this._issue(args.caller, args.owner, args.uDeposit) {} catch {
            vm.assume(false);
        }
        newTimestamp = boundU32(newTimestamp, _maturity, _maturity + 150 days);
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

    /////////////////////////////////////////////////////////////////////
    /// PROTECTED FUNCTIONS
    /////////////////////////////////////////////////////////////////////

    function testSetFeeRecipient_Ok() public virtual {
        vm.prank(management);
        tranche.setFeeRecipient(address(0xcafe));
        assertEq(tranche.feeRecipient(), address(0xcafe), "fee recipient set");
    }

    // skip when not forking
    function testRecoverERC20_Ok() public virtual skipWhenNotForking {
        address uni = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984; // UNISWAP governance token
        deal(uni, address(tranche), 100, false);
        vm.prank(management);
        tranche.recoverERC20(uni, management);
        assertEq(ERC20(uni).balanceOf(management), 100, "recovered");
    }

    /// @notice This function does not do anything.
    function noop() internal pure {}
}
