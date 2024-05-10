// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import {CompleteFixture} from "../../Fixtures.sol";

import {ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/IERC20.sol";
import {IeETH} from "src/adapters/etherfi/interfaces/IeETH.sol";
import {ILiquidityPool} from "src/adapters/etherfi/interfaces/ILiquidityPool.sol";
import {IWithdrawRequestNFT} from "src/adapters/etherfi/interfaces/IWithdrawRequestNFT.sol";

import {EEtherAdapter, BaseLSTAdapter} from "src/adapters/etherfi/EETHAdapter.sol";
import "src/Constants.sol" as Constants;

contract EEtherFixture is CompleteFixture {
    using stdStorage for StdStorage;

    address constant ADMIN = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705;

    uint256 constant FORKED_AT = 19_574_000;

    uint256 constant FUZZ_UNDERLYING_DEPOSIT_CAP = 1000 ether;

    /// @notice eETH
    IeETH public constant EETH = IeETH(Constants.EETH);

    /// @dev EtherFi WithdrawRequestNFT
    IWithdrawRequestNFT public constant ETHERFI_WITHDRAW_NFT = IWithdrawRequestNFT(Constants.ETHERFI_WITHDRAW_REQUEST);

    /// @dev EtherFi LiquidityPool
    ILiquidityPool constant LIQUIDITY_POOL = ILiquidityPool(Constants.ETHERFI_LP);

    address rebalancer = makeAddr("rebalancer");

    function setUp() public virtual override {
        _DELTA_ = 10;
        MIN_UNDERLYING_DEPOSIT = 0.01 ether;
        MAX_UNDERLYING_DEPOSIT = 10_000 ether;

        vm.createSelectFork("mainnet", FORKED_AT);

        _maturity = block.timestamp + 3 * 365 days;
        _issuanceFee = 0; // 10000 bps = 100%, 10 bps = 0.1%

        super.setUp();
        vm.label(Constants.ETHERFI_WITHDRAW_REQUEST, "eWERC721");
        vm.label(Constants.EETH, "eETH");

        initialBalance = 1_000 ether;
        // fund tokens
        deal(Constants.WETH, address(this), initialBalance, false);
        // approve tranche to spend underlying
        _approve(address(underlying), address(this), address(tranche), type(uint256).max);

        vm.prank(rebalancer);
        EEtherAdapter(payable(address(adapter))).setTargetBufferPercentage(0.1 * 1e18); // 10%
        EEtherAdapter(payable(address(adapter))).setTranche(address(tranche));
    }

    function _deployAdapter() internal virtual override {
        adapter = new EEtherAdapter(rebalancer, 0, 0);
        underlying = ERC20(Constants.WETH);
        target = ERC20(address(adapter));
    }

    //////////////////////////////////////////////////////////////////
    /// HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////////

    /// @dev simulate a scale increase
    function _simulateScaleIncrease() internal override {
        // Increase 10% of eETH
        uint256 share = EETH.shares(address(adapter)) / 10;

        vm.prank(address(LIQUIDITY_POOL));
        EETH.mintShares(address(adapter), share);
    }

    /// @dev simulate a scale decrease
    function _simulateScaleDecrease() internal override {
        // Loss 10% of eETH
        uint256 share = EETH.shares(address(adapter)) / 10;

        vm.prank(address(LIQUIDITY_POOL));
        EETH.burnShares(address(adapter), share);
    }

    function deal(address token, address to, uint256 give, bool adjust) internal virtual override {
        if (token == Constants.WETH && adjust == true) {
            adjust = false;
            console2.log("`deal` called with WETH, ignore `adjust` and set to false");
        }
        super.deal(token, to, give, adjust);
    }
}
