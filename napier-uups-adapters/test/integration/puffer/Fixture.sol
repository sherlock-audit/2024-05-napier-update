// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import {CompleteFixture} from "@napier/v1-tranche-test/Fixtures.sol";
import {IStETH} from "@napier/v1-tranche/adapters/lido/interfaces/IStETH.sol";

import {ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts@4.9.3/proxy/ERC1967/ERC1967Proxy.sol";

import {IPufferDepositor} from "src/adapters/puffer/interfaces/IPufferDepositor.sol";
import {IPufferVault} from "src/adapters/puffer/interfaces/IPufferVault.sol";
import {PufETHAdapter} from "src/adapters/puffer/PufETHAdapter.sol";

import "src/Constants.sol" as Constants;

contract PufEtherFixture is CompleteFixture {
    using stdStorage for StdStorage;

    uint256 constant FORKED_AT = 19_675_000;

    uint256 constant FUZZ_UNDERLYING_DEPOSIT_CAP = 1000 ether;

    uint256 constant MAX_STAKE_LIMIT = 10_000 ether;
    uint256 constant STAKE_LIMIT_INCREASE_PER_BLOCK = 0.00015 ether; // About 1 ether recovery per 1 day

    /// @notice stETH
    IStETH public constant STETH = IStETH(Constants.STETH);

    /// @notice pufETH
    IPufferVault constant PUFETH = IPufferVault(Constants.PUFETH);

    /// @notice Puffer Depositor
    IPufferDepositor constant PUF_DEPOSITOR = IPufferDepositor(Constants.PUF_DEPOSITOR);

    /// @notice Blast: Deposit address
    /// @dev StETH whale
    address constant whale = 0x5F6AE08B8AeB7078cf2F96AFb089D7c9f51DA47d;

    address rebalancer = makeAddr("rebalancer");

    function setUp() public virtual override {
        _DELTA_ = 10;
        MIN_UNDERLYING_DEPOSIT = 0.01 ether;
        MAX_UNDERLYING_DEPOSIT = 10_000 ether;

        vm.createSelectFork("mainnet", FORKED_AT);

        _maturity = block.timestamp + 3 * 365 days;
        _issuanceFee = 0; // 10000 bps = 100%, 10 bps = 0.1%

        super.setUp();
        vm.label(Constants.STETH, "STETH");
        vm.label(Constants.PUFETH, "PUFETH");
        vm.label(Constants.PUF_DEPOSITOR, "PUF_DEPOSITOR");

        initialBalance = 1_000 ether;
        // fund tokens
        deal(Constants.WETH, address(this), initialBalance, false);
        // approve tranche to spend underlying
        _approve(address(underlying), address(this), address(tranche), type(uint256).max);

        vm.prank(rebalancer);
        PufETHAdapter(payable(address(adapter))).setTargetBufferPercentage(0.1 * 1e18); // 10%
        stdstore.target(address(adapter)).sig("tranche()").checked_write(address(tranche));
    }

    function _deployAdapter() internal virtual override {
        // setup proxy contract & initialize PufETHAdapter
        address implementation = address(new PufETHAdapter());
        bytes memory data = abi.encodeWithSignature(
            "initialize(address,address,uint256,uint256)",
            owner,
            rebalancer,
            MAX_STAKE_LIMIT,
            STAKE_LIMIT_INCREASE_PER_BLOCK
        );
        vm.prank(owner);
        address payable proxy = payable(address(new ERC1967Proxy(implementation, data)));
        PufETHAdapter _adapter = PufETHAdapter(proxy);
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
        uint256 amt = STETH.balanceOf(address(PUFETH)) / 10;

        // Increase 10% of pufETH
        vm.prank(whale);
        STETH.transfer(address(PUFETH), amt);
    }

    /// @dev simulate a scale decrease
    function _simulateScaleDecrease() internal override {
        uint256 amt = STETH.balanceOf(address(PUFETH)) / 10;

        // Loss 10% of pufETH
        vm.prank(address(PUFETH));
        STETH.transfer(address(0xdead), amt);
    }

    function deal(address token, address to, uint256 give, bool adjust) internal virtual override {
        if (token == Constants.WETH && adjust == true) {
            adjust = false;
            console2.log("`deal` called with WETH, ignore `adjust` and set to false");
        }
        super.deal(token, to, give, adjust);
    }
}
