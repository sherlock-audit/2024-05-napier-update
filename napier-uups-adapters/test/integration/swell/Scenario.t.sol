// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {CompleteFixture} from "@napier/v1-tranche-test/Fixtures.sol";
import {ScenarioLSTBaseTest} from "@napier/v1-tranche-test/integration/ScenarioBaseTest.t.sol";

import {RswEtherFixture} from "./Fixture.sol";

contract TestRswEtherScenario is ScenarioLSTBaseTest, RswEtherFixture {
    function setUp() public override(CompleteFixture, RswEtherFixture) {
        RswEtherFixture.setUp();
        _DELTA_ = 80;
    }

    function deal(
        address token,
        address to,
        uint256 give,
        bool adjust
    ) internal virtual override(StdCheats, RswEtherFixture) {
        RswEtherFixture.deal(token, to, give, adjust);
    }
}
