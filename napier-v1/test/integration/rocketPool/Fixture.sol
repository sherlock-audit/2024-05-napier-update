// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import {CompleteFixture} from "../../Fixtures.sol";

import {ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import {RETHAdapter} from "src/adapters/rocketPool/RETHAdapter.sol";
import {WETH, RETH} from "src/Constants.sol";
import {IRocketDepositPool} from "src/adapters/rocketPool/interfaces/IRocketDepositPool.sol";

import {RocketPoolHelper} from "../../utils/RocketPoolHelper.sol";

import {RETHAdapter} from "src/adapters/rocketPool/RETHAdapter.sol";
import {Swapper} from "src/adapters/rocketPool/Swapper.sol";

abstract contract RETHFixture is CompleteFixture {
    using RocketPoolHelper for StdStorage;
    using stdStorage for StdStorage;

    uint256 constant FORKED_AT = 19_000_000;

    /// @notice Rocket Pool Address storage https://www.codeslaw.app/contracts/ethereum/0x1d8f8f00cfa6758d7be78336684788fb0ee0fa46
    address constant ROCKET_STORAGE = 0x1d8f8f00cfa6758d7bE78336684788Fb0ee0Fa46;

    address constant RETH_ETH_POOL = 0x0f3159811670c117c372428D4E69AC32325e4D0F;

    /// @notice Current maximum deposit pool size is 18_000 ether.
    uint256 MAXIMUM_DEPOSIT_POOL_SIZE = 40_000 ether;

    /// @dev cap that defines maximum amount of rETH that can be deposited to Tranche
    ///      this is used to bound fuzz arguments.
    uint256 FUZZ_UNDERLYING_DEPOSIT_CAP;

    address rebalancer = makeAddr("rebalancer");

    Swapper swapper;

    function setUp() public virtual override {
        _DELTA_ = 100;
        MIN_UNDERLYING_DEPOSIT = 0.01 ether; // Rocket Pool requires a minimum deposit of some ETH
        vm.createSelectFork("mainnet", FORKED_AT);
        _maturity = block.timestamp + 3 * 365 days;
        _issuanceFee = 0; // 10000 bps = 100%, 10 bps = 0.1%

        super.setUp();

        initialBalance = 300 ether;
        // fund tokens
        deal(WETH, address(this), initialBalance, false);
        // approve tranche to spend underlying
        _approve(address(underlying), address(this), address(tranche), type(uint256).max);

        vm.prank(rebalancer);
        RETHAdapter(payable(address(adapter))).setTargetBufferPercentage(0.1 * 1e18); // 10%

        address rocketDepositPool = RocketPoolHelper.getRocketPoolModuleAddress("rocketDepositPool");
        address rocketDAOProtocolSettingsDeposit = RocketPoolHelper.getRocketPoolModuleAddress(
            "rocketDAOProtocolSettingsDeposit"
        );

        vm.label(RETH_ETH_POOL, "RETH/ETH Pool");
        vm.label(ROCKET_STORAGE, "RP_Storage");
        vm.label(rocketDepositPool, "RP_DepositPool");
        vm.label(rocketDAOProtocolSettingsDeposit, "RP_DepositSettings");

        vm.mockCall(
            rocketDAOProtocolSettingsDeposit,
            abi.encodeWithSignature("getMaximumDepositPoolSize()"),
            abi.encode(MAXIMUM_DEPOSIT_POOL_SIZE)
        );
        // note: the maximum deposit pool amount is the maximum pool size minus the current pool balance.
        FUZZ_UNDERLYING_DEPOSIT_CAP = MAXIMUM_DEPOSIT_POOL_SIZE - IRocketDepositPool(rocketDepositPool).getBalance();

        stdstore.target(address(adapter)).sig("tranche()").checked_write(address(tranche));
    }

    function _deployAdapter() internal virtual override {
        swapper = new Swapper(RETH_ETH_POOL);
        adapter = new RETHAdapter(rebalancer, address(swapper), ROCKET_STORAGE);
        underlying = ERC20(WETH);
        target = ERC20(address(adapter));
    }

    //////////////////////////////////////////////////////////////////
    /// HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////////

    /// @dev simulate a scale increase
    /// @dev Need to change rETH total supply enough because rETH charges a fee, which may not be enough to cover the loss of the PT issuers.
    function _simulateScaleIncrease() internal override {
        // Increase bufferEth without changing total supply of erETH
        uint256 balance = underlying.balanceOf(address(adapter));
        require(RETHAdapter(payable(address(adapter))).bufferEth() == balance, "bufferEth should be equal to balance");
        _storeBufferEth((balance * 15) / 10);

        // Change RETH total supply
        // Formula: rethAmount * totalEthBalance / rethSupply = ethAmount
        uint256 supply = RocketPoolHelper.getTotalRETHSupply();
        stdstore.writeTotalRETHSupply(supply - 10 ether); // price goes up
        require(supply - 10 ether == RocketPoolHelper.getTotalRETHSupply(), "failed to overwrite RETH total supply");
    }

    /// @dev simulate a scale decrease
    function _simulateScaleDecrease() internal override {
        uint256 scale = adapter.scale();
        uint256 balance = underlying.balanceOf(address(adapter));
        require(RETHAdapter(payable(address(adapter))).bufferEth() == balance, "bufferEth should be equal to balance");
        _storeBufferEth((balance * 9) / 10);

        // Increase total supply of rETH
        uint256 supply = RocketPoolHelper.getTotalRETHSupply();
        stdstore.writeTotalRETHSupply(supply + 10 ether); // price goes down
        require(supply + 10 ether == RocketPoolHelper.getTotalRETHSupply(), "failed to overwrite RETH total supply");

        uint256 newScale = adapter.scale();
        console2.log("scale :>>", scale);
        console2.log("newScale :>>", newScale);
    }

    function _storeBufferEth(uint256 bufferEth) internal {
        deal(address(underlying), address(adapter), bufferEth, false);

        vm.store(address(adapter), bytes32(uint256(11)), bytes32(bufferEth));
        require(RETHAdapter(payable(address(adapter))).bufferEth() == bufferEth, "bufferEth not set correctly");
    }

    /// @notice used to fund rETH to a fuzz input address.
    /// @dev if token is rETH, then stake ETH to get rETH.
    ///      rETH balance of `to` will be 1 wei greater than or equal to `give`.
    function deal(address token, address to, uint256 give, bool adjust) internal virtual override {
        if (token == WETH && adjust == true) {
            adjust = false;
            console2.log("`deal` called with WETH, ignore `adjust` and set to false");
        }
        super.deal(token, to, give, adjust);
    }
}
