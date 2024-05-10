// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import {CompleteFixture} from "../../Fixtures.sol";

import {IERC20, ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import {IStaking} from "src/adapters/bedrock/interfaces/IStaking.sol";

import {UniETHAdapter, BaseLSTAdapter} from "src/adapters/bedrock/UniETHAdapter.sol";
import {UniETHSwapper} from "src/adapters/bedrock/UniETHSwapper.sol";
import "src/Constants.sol" as Constants;

contract UniETHFixture is CompleteFixture {
    using stdStorage for StdStorage;

    uint256 constant FORKED_AT = 19_750_000;

    uint256 constant FUZZ_UNDERLYING_DEPOSIT_CAP = 1000 ether;

    ERC20 constant UNIETH = ERC20(Constants.UNIETH);

    /// @notice Bedrock staking contract
    IStaking constant BEDROCK_STAKING = IStaking(Constants.BEDROCK_STAKING);

    address constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    UniETHSwapper swapper;

    address bedrockRedeem;

    address whale = makeAddr("whale");
    address rebalancer = makeAddr("rebalancer");

    function setUp() public virtual override {
        _DELTA_ = 10;
        MIN_UNDERLYING_DEPOSIT = 0.01 ether;
        MAX_UNDERLYING_DEPOSIT = 10_000 ether;

        vm.createSelectFork("mainnet", FORKED_AT);

        _maturity = block.timestamp + 3 * 365 days;
        _issuanceFee = 0; // 10000 bps = 100%, 10 bps = 0.1%

        super.setUp();
        bedrockRedeem = BEDROCK_STAKING.redeemContract();

        vm.label(Constants.UNIETH, "uniETH");
        vm.label(Constants.BEDROCK_STAKING, "bedrockStaking");
        vm.label(UNIV3_ROUTER, "univ3Router");
        vm.label(bedrockRedeem, "bedrockRedeem");

        initialBalance = 1_000 ether;
        // fund tokens
        deal(Constants.WETH, address(this), initialBalance, false);
        // approve tranche to spend underlying
        _approve(address(underlying), address(this), address(tranche), type(uint256).max);

        vm.prank(rebalancer);
        UniETHAdapter(payable(address(adapter))).setTargetBufferPercentage(0.1 * 1e18); // 10%

        stdstore.target(address(adapter)).sig("tranche()").checked_write(address(tranche));
    }

    function _deployAdapter() internal virtual override {
        swapper = new UniETHSwapper(UNIV3_ROUTER);
        adapter = new UniETHAdapter(owner, rebalancer, 0, 0, address(swapper));
        underlying = ERC20(Constants.WETH);
        target = ERC20(address(adapter));
    }

    //////////////////////////////////////////////////////////////////
    /// HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////////

    /// @dev simulate a scale increase
    function _simulateScaleIncrease() internal override {
        uint256 amount = (underlying.balanceOf(address(adapter)) * 3) / 100;
        deal(whale, amount);
        vm.startPrank(whale);
        uint minted = BEDROCK_STAKING.mint{value: amount}({minToMint: 0, deadline: block.timestamp + 1});
        UNIETH.transfer(address(adapter), minted);
        vm.stopPrank();
    }

    /// @dev simulate a scale decrease
    function _simulateScaleDecrease() internal override {
        uint256 uniEthBalance = IERC20(Constants.UNIETH).balanceOf(address(adapter));
        // Loss 10% of uniETH
        vm.prank(address(adapter));
        IERC20(Constants.UNIETH).transfer(whale, uniEthBalance / 10);
    }

    function deal(address token, address to, uint256 give, bool adjust) internal virtual override {
        if (token == Constants.WETH && adjust == true) {
            adjust = false;
            console2.log("`deal` called with WETH, ignore `adjust` and set to false");
        }
        super.deal(token, to, give, adjust);
    }
}
