// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import {CompleteFixture} from "@napier/v1-tranche-test/Fixtures.sol";

import {ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts@4.9.3/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable@4.9.3/token/ERC20/IERC20Upgradeable.sol";
import {IRenzoRestakeManager} from "src/adapters/renzo/interfaces/IRenzoRestakeManager.sol";
import {IRateProvider} from "src/adapters/renzo/interfaces/IRateProvider.sol";
import {RenzoAdapter} from "src/adapters/renzo/RenzoAdapter.sol";

import "src/Constants.sol" as Constants;

contract RenzoFixture is CompleteFixture {
    using stdStorage for StdStorage;

    uint256 constant FORKED_AT = 19_675_000;

    uint256 constant FUZZ_UNDERLYING_DEPOSIT_CAP = 1000 ether;

    uint256 constant MAX_STAKE_LIMIT = 10_000 ether;
    uint256 constant STAKE_LIMIT_INCREASE_PER_BLOCK = 0.00015 ether; // About 1 ether recovery per 1 day

    /// @notice LRTDepositPool
    IRenzoRestakeManager constant EZETH_DEPOSITOR = IRenzoRestakeManager(Constants.RENZO_RESTAKE_MANAGER);

    /// @notice ezETH
    IERC20Upgradeable constant EZETH = IERC20Upgradeable(Constants.EZETH);

    IRateProvider constant RATE_PROVIDER = IRateProvider(Constants.RENZO_RATE_PROVIDER);

    /// @notice Zircuit: Restaking Pool
    /// @dev EZETH whale
    address constant whale = 0xF047ab4c75cebf0eB9ed34Ae2c186f3611aEAfa6;

    address rebalancer = makeAddr("rebalancer");

    function setUp() public virtual override {
        _DELTA_ = 10;
        MIN_UNDERLYING_DEPOSIT = 0.1 ether;
        MAX_UNDERLYING_DEPOSIT = 10_000 ether;

        vm.createSelectFork("mainnet", FORKED_AT);

        _maturity = block.timestamp + 8 hours;
        _issuanceFee = 0; // 10000 bps = 100%, 10 bps = 0.1%

        super.setUp();
        vm.label(Constants.EZETH, "EZETH");
        vm.label(Constants.RENZO_RESTAKE_MANAGER, "RenzoRestakeManager");

        initialBalance = 1_000 ether;
        // fund tokens
        deal(Constants.WETH, address(this), initialBalance, false);
        // approve tranche to spend underlying
        _approve(address(underlying), address(this), address(tranche), type(uint256).max);

        vm.prank(rebalancer);
        RenzoAdapter(payable(address(adapter))).setTargetBufferPercentage(0.1 * 1e18); // 10%
        stdstore.target(address(adapter)).sig("tranche()").checked_write(address(tranche));
    }

    function _deployAdapter() internal virtual override {
        // setup proxy contract & initialize RenzoAdapter
        address implementation = address(new RenzoAdapter());
        bytes memory data = abi.encodeWithSignature(
            "initialize(address,address,uint256,uint256)",
            owner,
            rebalancer,
            MAX_STAKE_LIMIT,
            STAKE_LIMIT_INCREASE_PER_BLOCK
        );
        vm.prank(owner);
        address payable proxy = payable(address(new ERC1967Proxy(implementation, data)));
        RenzoAdapter _adapter = RenzoAdapter(proxy);
        assembly {
            sstore(adapter.slot, _adapter)
        }

        underlying = ERC20(Constants.WETH);
        target = ERC20(address(adapter));
    }

    //////////////////////////////////////////////////////////////////
    /// HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////////

    /// @dev simulate a scale increase
    function _simulateScaleIncrease() internal override {
        // Increase 10%
        uint256 amt = EZETH.balanceOf(address(adapter)) / 10;

        vm.prank(whale);
        EZETH.transfer(address(adapter), amt);
    }

    /// @dev simulate a scale decrease
    function _simulateScaleDecrease() internal override {
        // Decrease 10%
        uint256 amt = EZETH.balanceOf(address(adapter)) / 10;

        vm.prank(address(adapter));
        EZETH.transfer(whale, amt);
    }

    function deal(address token, address to, uint256 give, bool adjust) internal virtual override {
        if (token == Constants.WETH && adjust == true) {
            adjust = false;
            console2.log("`deal` called with WETH, ignore `adjust` and set to false");
        }
        super.deal(token, to, give, adjust);
    }

    function mockTVLCall() internal {
        uint256[][] memory mockResult = new uint256[][](2);
        uint256[] memory mockResult2 = new uint256[](2);
        uint256 mockTvls = 13361771304061692359764;
        vm.mockCall(
            address(Constants.RENZO_RESTAKE_MANAGER),
            abi.encodeWithSelector(bytes4(keccak256("calculateTVLs()"))),
            abi.encode(mockResult, mockResult2, mockTvls)
        );
    }
}
