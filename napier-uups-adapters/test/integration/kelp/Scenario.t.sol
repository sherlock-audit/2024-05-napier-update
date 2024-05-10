// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {CompleteFixture} from "@napier/v1-tranche-test/Fixtures.sol";
import {ScenarioLSTBaseTest} from "@napier/v1-tranche-test/integration/ScenarioBaseTest.t.sol";

import {RsEtherFixture} from "./Fixture.sol";

contract TestRsEtherScenario is ScenarioLSTBaseTest, RsEtherFixture {
    function setUp() public override(CompleteFixture, RsEtherFixture) {
        RsEtherFixture.setUp();
        _DELTA_ = 10;
    }

    function deal(
        address token,
        address to,
        uint256 give,
        bool adjust
    ) internal virtual override(StdCheats, RsEtherFixture) {
        RsEtherFixture.deal(token, to, give, adjust);
    }
}
