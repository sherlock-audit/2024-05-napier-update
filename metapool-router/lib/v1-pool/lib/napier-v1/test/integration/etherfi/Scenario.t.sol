// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {ScenarioLSTBaseTest} from "../ScenarioBaseTest.t.sol";
import {CompleteFixture} from "../../Fixtures.sol";
import {EEtherFixture} from "./Fixture.sol";

contract TestEEtherScenario is ScenarioLSTBaseTest, EEtherFixture {
    function setUp() public override(CompleteFixture, EEtherFixture) {
        EEtherFixture.setUp();
        _DELTA_ = 10;
    }

    function deal(
        address token,
        address to,
        uint256 give,
        bool adjust
    ) internal virtual override(StdCheats, EEtherFixture) {
        EEtherFixture.deal(token, to, give, adjust);
    }
}
