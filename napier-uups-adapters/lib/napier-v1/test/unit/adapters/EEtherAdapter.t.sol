// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {BaseTestLSTAdapter, Cast} from "./BaseTestLSTAdapter.t.sol";

import {ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import {IeETH} from "src/adapters/etherfi/interfaces/IeETH.sol";
import {ILiquidityPool} from "src/adapters/etherfi/interfaces/ILiquidityPool.sol";
import {IWithdrawRequestNFT} from "src/adapters/etherfi/interfaces/IWithdrawRequestNFT.sol";

import {EEtherAdapter} from "src/adapters/etherfi/EETHAdapter.sol";
import "src/Constants.sol" as Constants;

contract TestEEtherAdapter is BaseTestLSTAdapter {
    using Cast for *;

    address constant ADMIN = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705;

    uint256 constant FORKED_AT = 19_574_000;

    /// @notice eETH
    IeETH constant EETH = IeETH(Constants.EETH);

    /// @dev EtherFi WithdrawRequestNFT
    IWithdrawRequestNFT constant ETHERFI_WITHDRAW_NFT = IWithdrawRequestNFT(Constants.ETHERFI_WITHDRAW_REQUEST);

    /// @dev EtherFi LiquidityPool
    ILiquidityPool constant LIQUIDITY_POOL = ILiquidityPool(Constants.ETHERFI_LP);

    address whale = 0x7a95f1554eA2E36ED297b70E70C8B45a33b53095;

    function setUp() public override {
        vm.createSelectFork("mainnet", FORKED_AT);
        super.setUp();
        testAdapterHasNoFundLeft();

        vm.label(Constants.ETHERFI_WITHDRAW_REQUEST, "eETHWERC721");
        vm.label(Constants.EETH, "eETH");
    }

    function _deployAdapter() internal override {
        vm.prank(owner);
        adapter = new EEtherAdapter(rebalancer, 0, 0);
        underlying = ERC20(Constants.WETH);
        target = ERC20(address(adapter));
        LST = ERC20(Constants.EETH);
    }

    function testScale() public override {
        // when totalSupply is 0, scale should be 1e18
        assertEq(adapter.scale(), 1e18, "scale should be 1e18");
    }

    //////////////////////////////////////////////////////////////////////////////
    // Deposit
    //////////////////////////////////////////////////////////////////////////////

    function testPrefundedDeposit() public override {
        // setup
        // The stake amount is caped at 95% of the available ETH at the time of the stake.
        // Target buffer is 10% of the total value of the adapter.

        // transfer WETH to the adapter contract prior as it would be done by Tranche
        uint256 wethFundedAmount = 65115;
        _fundAdapterUnderlying(wethFundedAmount);

        _changeTranche(user);
        vm.prank(user);
        (uint256 underlyingUsed, uint256 sharesMinted) = adapter.prefundedDeposit();

        uint256 expectedShares = wethFundedAmount; // when totalSupply is 0, 1 share = 1 WETH
        assertEq(wethFundedAmount, underlyingUsed, "user provided WETH amount !~= actual WETH used");
        assertEq(sharesMinted, expectedShares, "actual shares minted !~= expected shares minted");
        assertEq(target.balanceOf(user), sharesMinted, "balanceOfUser !~= shares minted");
        testAdapterHasNoFundLeft();
        assertApproxEqRel(
            adapter.into().bufferPresentPercentage(),
            0.1 * 1e18,
            0.0001 * 1e18, // 0.01% tolerance
            "present buffer percentage should be 10%"
        );
        assertApproxEqAbs(
            adapter.into().bufferEth(),
            wethFundedAmount / 10,
            10,
            "bufferEth should be 10% of WETH funded"
        );
        uint256 balance = LST.balanceOf(address(adapter));
        assertApproxEqAbs(
            balance,
            (wethFundedAmount * 90) / 100,
            10,
            "amount of LST minted should be 90% of WETH funded"
        );
    }

    //////////////////////////////////////////////////////////////////////////////
    // Request withdrawal
    //////////////////////////////////////////////////////////////////////////////

    function testRequestWithdrawal() public override {
        // Setup
        // 1. Mint some eETH and shares.
        // 2. Ensure present buffer percentage is less than the target percentage.
        vm.recordLogs();
        {
            _fundAdapterUnderlying(40 ether);
            _changeTranche(address(this));
            adapter.prefundedDeposit(); // Mint some eETH.
            vm.prank(rebalancer);
            adapter.into().setTargetBufferPercentage(0.6 * 1e18); // 60%
        }
        uint256 totalAssetsPrior = adapter.into().totalAssets();

        // Execution
        vm.prank(rebalancer);
        adapter.into().requestWithdrawal();

        Vm.Log memory eventLog = _getRecordedLogs(keccak256("RequestWithdrawal(uint256,uint256)"));
        (uint256 requestId, ) = abi.decode(eventLog.data, (uint256, uint256));

        IWithdrawRequestNFT.WithdrawRequest memory nftInfo = ETHERFI_WITHDRAW_NFT.getRequest(requestId);

        // Assertions
        assertNotEq(requestId, 0, "requestId should be set");
        assertGt(adapter.into().totalQueueEth(), 0, "withdrawalQueueEth should be greater than 0");
        assertEq(
            adapter.into().totalQueueEth(),
            nftInfo.amountOfEEth,
            "Pending withdrawal should be the same with amountOfEEth"
        );
        assertApproxEqAbs(
            adapter.into().totalAssets(),
            totalAssetsPrior,
            2,
            "totalAssets should decrease by calculation issue taken by Lido"
        );
        testAdapterHasNoFundLeft();
    }

    function testRequestWithdrawalAll() public override {
        _fundAdapterUnderlying(2 ether);
        _changeTranche(address(this));
        adapter.prefundedDeposit(); // Mint some eETH.
        // Execution
        vm.prank(rebalancer);
        vm.recordLogs();
        adapter.into().requestWithdrawalAll();
        Vm.Log memory eventLog = _getRecordedLogs(keccak256("RequestWithdrawal(uint256,uint256)"));
        (uint256 requestId, ) = abi.decode(eventLog.data, (uint256, uint256));
        IWithdrawRequestNFT.WithdrawRequest memory nftInfo = ETHERFI_WITHDRAW_NFT.getRequest(requestId);
        // Assertions
        assertLe(LST.balanceOf(address(adapter)), 3, "adapter should have no eETH");
        assertEq(
            adapter.into().totalQueueEth(),
            nftInfo.amountOfEEth,
            "Pending withdrawal should be the same with amountOfEEth value"
        );
        testAdapterHasNoFundLeft();
    }

    /// @notice Scenario: Request withdrawal more than the maximum unstake amount.
    function testRequestWithdrawalAll_WhenExceedMaxUnstake() public {
        // // Setup
        vm.prank(whale);
        EETH.transfer(address(adapter), 10_000 ether);
        // Execution
        vm.prank(rebalancer);
        vm.recordLogs();
        adapter.into().requestWithdrawalAll();

        Vm.Log memory eventLog = _getRecordedLogs(keccak256("RequestWithdrawal(uint256,uint256)"));
        (uint256 requestId, ) = abi.decode(eventLog.data, (uint256, uint256));
        IWithdrawRequestNFT.WithdrawRequest memory nftInfo = ETHERFI_WITHDRAW_NFT.getRequest(requestId);
        // Assertions
        assertEq(
            adapter.into().totalQueueEth(),
            nftInfo.amountOfEEth,
            "Pending withdrawal should be the same with amountOfEEth value"
        );
        testAdapterHasNoFundLeft();
    }

    //////////////////////////////////////////////////////////////////////////////
    // Claim withdrawal
    //////////////////////////////////////////////////////////////////////////////
    function testClaimWithdrawal() public override {
        // Setup
        vm.recordLogs();
        {
            // 1. Mint some eETH and shares.
            _fundAdapterUnderlying(40 ether);
            _changeTranche(address(this));
            adapter.prefundedDeposit(); // Mint some eETH.

            // 2. Request withdrawal.
            vm.prank(rebalancer);
            adapter.into().setTargetBufferPercentage(0.3 * 1e18); // 30%

            vm.prank(rebalancer);
            adapter.into().requestWithdrawal();
        }

        Vm.Log memory eventLog = _getRecordedLogs(keccak256("RequestWithdrawal(uint256,uint256)"));
        (uint256 requestId, ) = abi.decode(eventLog.data, (uint256, uint256));
        uint256 bufferPrior = adapter.into().bufferEth();

        // 3. Wait until the request is matured.
        vm.prank(ADMIN);
        ETHERFI_WITHDRAW_NFT.finalizeRequests(requestId);
        // Execution
        // eETH share price will increase over time because it distributes rewards based on timestamp.
        vm.prank(rebalancer);
        adapter.into().claimWithdrawal(requestId);

        Vm.Log memory eventLog2 = _getRecordedLogs(keccak256("ClaimWithdrawal(uint256,uint256)"));
        (, uint256 claimed) = abi.decode(eventLog2.data, (uint256, uint256));

        // Assertions
        assertEq(adapter.into().bufferEth(), bufferPrior + claimed, "bufferEth should be increased by claimed amount");
        assertEq(adapter.into().totalQueueEth(), 0, "totalQueueEth should be decreased by queue amount");
        assertGt(
            underlying.balanceOf(address(adapter)) - bufferPrior,
            0,
            "WETH balance should be increased by claimed amount"
        );
        testAdapterHasNoFundLeft();
    }

    function testPrefundedDeposit_Zero() public override {
        _changeTranche(address(this));
        (uint256 underlyingUsed, uint256 sharesMinted) = adapter.prefundedDeposit();
        assertEq(underlyingUsed, 0, "underlyingUsed !~= 0");
        assertEq(sharesMinted, 0, "sharesMinted !~= 0");
    }

    function testPrefundedRedeem_Zero() public override {
        _changeTranche(address(this));
        (uint256 underlyingUsed, uint256 sharesMinted) = adapter.prefundedRedeem(user);
        assertEq(underlyingUsed, 0, "underlyingUsed !~= 0");
        assertEq(sharesMinted, 0, "sharesMinted !~= 0");
    }
}
