// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "../ScenarioBaseTest.t.sol";
import {RETHFixture} from "./Fixture.sol";

import {BaseAdapter} from "src/BaseAdapter.sol";
import {RETHAdapter} from "src/adapters/rocketPool/RETHAdapter.sol";

contract TestRETHScenario is ScenarioBaseTest, RETHFixture {
    using Cast for *;

    function setUp() public override(CompleteFixture, RETHFixture) {
        RETHFixture.setUp();
    }

    function testRedeems_Ok() public override {
        uint256 amount = 100 * ONE_SCALE;
        // (this)-> first user, (user)-> second user, (newOwner)->third user
        // first user issues with 100 * ONE_SCALE and other users issue with 50 * ONE_SCALE
        // first user uses collect() twice (before maturity, after maturity)
        // second user uses collect() once (after maturity he collect yield then redeem PT)
        // third user never use collect()  (after maturity, he redeems PT with YT)
        uint256 issued = _issue({from: address(this), to: address(this), underlyingAmount: amount});
        // user issues 1/2 amount
        deal(address(underlying), user, amount / 2, true);
        _issue({from: user, to: user, underlyingAmount: amount / 2});
        deal(address(underlying), newOwner, amount / 2, true);
        _issue({from: newOwner, to: newOwner, underlyingAmount: amount / 2});

        vm.prank(rebalancer);
        adapter.into().mintReth(amount + amount / 2); // Mint rETH with 150 ETH

        _simulateScaleIncrease(); // scale increase

        // collect yield only
        (uint256 yieldBeforeMaturity, ) = _collect(address(this));
        vm.warp(uint32(_maturity));
        _simulateScaleIncrease(); // scale increase
        (uint256 yieldAfterMaturity, ) = _collect(address(this));
        // redeem all PT
        uint256 redeemed = _redeem({
            from: address(this),
            to: address(this),
            principalAmount: issued,
            caller: address(this)
        });
        uint256 collected = yieldBeforeMaturity + yieldAfterMaturity;
        (uint256 yield, ) = _collect(user);
        uint256 yBal = yt.balanceOf(newOwner); // ~= issued / 2 (sometimes 1 wei less due to rounding error)
        // redeem all PT+YT
        uint256 withdrawn = _redeemWithYT({from: newOwner, to: newOwner, amount: yBal, caller: newOwner});
        assertApproxEqAbs(
            collected, // yield(before maturity) + yield(after maturity)
            2 * yield,
            _DELTA_,
            "total yield amount should not be changed"
        );
        assertApproxEqAbs(
            redeemed + _convertToUnderlying(collected, adapter.scale()),
            withdrawn * 2,
            _DELTA_ * 2,
            "sum of yield + principal portion + redeemed should be equal to 1 PT + 1 YT = 1 Target"
        );
    }

    function testTransferYT_Ok() public override {
        uint256 amount = 100 * ONE_SCALE;

        // this issues
        _issue({from: address(this), to: address(this), underlyingAmount: amount});
        // user issues 1/2 amount
        deal(address(underlying), user, amount / 2, true);
        uint256 issued = _issue({from: user, to: user, underlyingAmount: amount / 2});

        _simulateScaleIncrease();
        vm.prank(user);
        yt.transfer(address(this), issued);
        // uncalimed yield should be proportional to YT balance
        uint256 unclaimed = tranche.unclaimedYields(address(this));
        assertGt(unclaimed, 0, "unclaimed yield should be greater than 0");
        assertApproxEqAbs(
            unclaimed,
            2 * tranche.unclaimedYields(user),
            2,
            "uncalimed yield should be twice as much as user"
        );

        (uint256 collectedUser, ) = _collect(user);
        (uint256 collected, ) = _collect(address(this));
        assertApproxEqAbs(
            collected,
            2 * collectedUser,
            2 * _DELTA_,
            "collected yield by this contract should be twice as much as one collected by user"
        );
        assertGt(collected, 0, "collected should be greater than 0");
        assertEq(tranche.unclaimedYields(address(this)), 0, "unclaimed yield should be 0 after collect");
        assertEq(tranche.unclaimedYields(user), 0, "unclaimed yield should be 0 after collect");
    }

    ////////////////////////////////////////////////////////////////////////////////////
    // Tests for rETH adapter specific behavior
    ////////////////////////////////////////////////////////////////////////////////////

    function testMintReth_WhenRedeemsWithYT_ScaleIncrease() public {
        uint256 amount = 50 * ONE_SCALE;
        // issue 2x amount
        _issue({from: address(this), to: address(this), underlyingAmount: 2 * amount});
        // issue amount
        deal(address(underlying), user, amount, true);
        uint256 issued = _issue({from: user, to: user, underlyingAmount: amount});

        vm.prank(rebalancer);
        adapter.into().mintReth(issued);

        console2.log("adapter.scale() :>>", adapter.scale());
        // scale increase
        _simulateScaleIncrease();
        console2.log("adapter.scale() :>>", adapter.scale());
        // redeem half
        uint256 withdrawn1 = _redeemWithYT({
            from: address(this),
            to: address(this),
            amount: issued,
            caller: address(this)
        });
        // redeem full
        uint256 withdrawn2 = _redeemWithYT({from: user, to: user, amount: issued, caller: user});

        // if scale increases, there are a accrued yield.
        // address(this) should get more yield than user gets because address(this) has more YT.
        assertGe(withdrawn1, withdrawn2, "withdrawn1 >= withdrawn2");
    }

    function testWithdraw_WhenRedeem() public {
        uint256 amount = 100 * ONE_SCALE;
        // this deposits 100 ETH
        // user deposits 50 ETH
        // newOwner deposits 50 ETH
        uint256 issued = _issue({from: address(this), to: address(this), underlyingAmount: amount});

        deal(address(underlying), user, amount / 2, true);
        uint256 issuedByUser = _issue({from: user, to: user, underlyingAmount: amount / 2});

        deal(address(underlying), newOwner, amount / 2, true);
        _issue({from: newOwner, to: newOwner, underlyingAmount: amount / 2});

        vm.prank(rebalancer);
        adapter.into().mintReth(amount);

        _simulateScaleIncrease(); // scale increase

        vm.prank(rebalancer);
        adapter.into().setTargetBufferPercentage(0.7 * 1e18); // 70% of total assets should be WETH

        vm.prank(rebalancer);
        adapter.into().withdraw();

        vm.warp(_maturity);

        uint256 redeemed = _redeem({
            from: address(this),
            to: address(this),
            principalAmount: issued,
            caller: address(this)
        });
        uint256 redeemedByUser = _redeem({from: user, to: user, principalAmount: issuedByUser, caller: user});
        assertApproxEqAbs(redeemed, 2 * redeemedByUser, _DELTA_, "Redeemed amount should be twice as much as user's");
    }

    ////////////////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////////////////

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
