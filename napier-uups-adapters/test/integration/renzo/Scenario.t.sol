// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {CompleteFixture} from "@napier/v1-tranche-test/Fixtures.sol";
import {ScenarioBaseTest} from "@napier/v1-tranche-test/integration/ScenarioBaseTest.t.sol";

import {RenzoFixture} from "./Fixture.sol";

contract TestRenzoScenario is ScenarioBaseTest, RenzoFixture {
    function setUp() public override(CompleteFixture, RenzoFixture) {
        // mockTVLCall();
        RenzoFixture.setUp();
        _DELTA_ = 1573635;
    }

    function deal(
        address token,
        address to,
        uint256 give,
        bool adjust
    ) internal virtual override(StdCheats, RenzoFixture) {
        RenzoFixture.deal(token, to, give, adjust);
    }

    function testTransferYT_Ok() public virtual override {
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
            791089,
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

    address charlie = makeAddr("charlie");

    function testRedeemsWithYT_ScaleIncrease_Ok() public override {
        deal(address(underlying), charlie, 1_000 * ONE_SCALE, false);
        _issue({from: charlie, to: charlie, underlyingAmount: 1_000 * ONE_SCALE});

        super.testRedeemsWithYT_ScaleIncrease_Ok();
    }

    function testRedeemsWithYT_ScaleDecrease_Ok() public override {
        // note: ensure that LST adapter has enough available eth
        // deposit large amount of eth to LST adapter
        deal(address(underlying), charlie, 1_000 * ONE_SCALE, false);
        _issue({from: charlie, to: charlie, underlyingAmount: 1_000 * ONE_SCALE});

        // See ScenarioBaseTest.testRedeemsWithYT_ScaleDecrease_Ok

        uint256 amount = 2 * ONE_SCALE;
        // this issues
        _issue({from: address(this), to: address(this), underlyingAmount: 2 * amount});
        // user issues 2x amount
        deal(address(underlying), user, amount, true);
        uint256 issued = _issue({from: user, to: user, underlyingAmount: amount});
        // scale decrease
        _simulateScaleDecrease();

        // this redeems half
        uint256 withdrawn1 = _redeemWithYT({
            from: address(this),
            to: address(this),
            amount: issued,
            caller: address(this)
        });
        // user redeems same amount
        // underlying withdrawn should be same
        uint256 withdrawn2 = _redeemWithYT({from: user, to: user, amount: issued, caller: user});
        assertEq(withdrawn2, withdrawn1, "withdrawn1 == withdrawn2");

        // this redeems half again
        assertApproxEqAbs(issued, yt.balanceOf(address(this)), 1593, "small precision loss");

        _redeemWithYT({
            from: address(this),
            to: address(this),
            amount: yt.balanceOf(address(this)),
            caller: address(this)
        });
    }

    function _testCollects_Ok(uint32 newTimestamp) public override {
        // note: ensure that LST adapter has enough available eth
        // deposit large amount of eth to LST adapter
        deal(address(underlying), charlie, 10_000 * ONE_SCALE, false);
        _issue({from: charlie, to: charlie, underlyingAmount: 10_000 * ONE_SCALE});

        super._testCollects_Ok(newTimestamp);
    }

    function testRedeems_Ok() public override {
        // note: ensure that LST adapter has enough available eth
        // deposit large amount of eth to LST adapter
        deal(address(underlying), charlie, 10_000 * ONE_SCALE, false);
        _issue({from: charlie, to: charlie, underlyingAmount: 10_000 * ONE_SCALE});

        super.testRedeems_Ok();
    }
}
