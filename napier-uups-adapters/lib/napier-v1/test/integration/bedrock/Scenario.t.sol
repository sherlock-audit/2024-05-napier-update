// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {ScenarioLSTBaseTest} from "../ScenarioBaseTest.t.sol";
import {CompleteFixture} from "../../Fixtures.sol";
import {UniETHFixture} from "./Fixture.sol";

contract TestUniETHScenario is ScenarioLSTBaseTest, UniETHFixture {
    function setUp() public override(CompleteFixture, UniETHFixture) {
        UniETHFixture.setUp();
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
}
