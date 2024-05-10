// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {BaseTestLSTAdapter} from "./BaseTestLSTAdapter.t.sol";

import {ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import {IStaking} from "src/adapters/bedrock/interfaces/IStaking.sol";
import {IRedeem} from "src/adapters/bedrock/interfaces/IRedeem.sol";
import {IBaseAdapter} from "src/interfaces/IBaseAdapter.sol";

import {BaseLSTVault} from "src/adapters/BaseLSTVault.sol";
import {UniETHAdapter} from "src/adapters/bedrock/UniETHAdapter.sol";
import {UniETHSwapper} from "src/adapters/bedrock/UniETHSwapper.sol";
import "src/Constants.sol" as Constants;

library Cast {
    function into(IBaseAdapter x) internal pure returns (UniETHAdapter) {
        return UniETHAdapter(payable(address(x)));
    }
}

contract TestUniETHAdapter is BaseTestLSTAdapter {
    using stdStorage for StdStorage;
    using Cast for *;

    uint256 constant FORKED_AT = 19_750_000;

    ERC20 constant UNIETH = ERC20(Constants.UNIETH);

    /// @notice Bedrock staking contract
    IStaking constant BEDROCK_STAKING = IStaking(Constants.BEDROCK_STAKING);

    address constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    UniETHSwapper swapper;

    address bedrockRedeem;

    function setUp() public override {
        vm.createSelectFork("mainnet", FORKED_AT);
        super.setUp();

        bedrockRedeem = BEDROCK_STAKING.redeemContract();

        testAdapterHasNoFundLeft();

        vm.label(Constants.UNIETH, "uniETH");
        vm.label(Constants.BEDROCK_STAKING, "bedrockStaking");
        vm.label(bedrockRedeem, "bedrockRedeem");
        vm.label(UNIV3_ROUTER, "univ3Router");
    }

    function _deployAdapter() internal override {
        swapper = new UniETHSwapper(UNIV3_ROUTER);
        vm.prank(owner);
        adapter = new UniETHAdapter(owner, rebalancer, 0, 0, address(swapper));
        underlying = ERC20(Constants.WETH);
        target = ERC20(address(adapter));
        LST = ERC20(Constants.UNIETH);
    }

    function testScale() public override {
        // when totalSupply is 0, scale should be 1e18
        assertEq(adapter.scale(), 1e18, "scale should be 1e18");
    }

    //////////////////////////////////////////////////////////////////////////////
    // Deposit
    //////////////////////////////////////////////////////////////////////////////

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
        uint256 balanceInWETH = (BEDROCK_STAKING.exchangeRatio() * balance) / 1e18;
        assertApproxEqAbs(
            balanceInWETH,
            (wethFundedAmount * 90) / 100,
            10,
            "amount of LST minted should be 90% of WETH funded"
        );
    }

    //////////////////////////////////////////////////////////////////////////////
    // Request withdrawal
    //////////////////////////////////////////////////////////////////////////////

    function testRequestWithdrawalWithDeadline_RevertWhenNotRebalancer() public {
        vm.expectRevert(BaseLSTVault.NotRebalancer.selector);
        vm.prank(address(0xabcd));
        adapter.into().requestWithdrawal(1 ether, block.timestamp);
    }

    function testRequestWithdrawalWithDeadline_RevertWhen_TransactionTooOld() public {
        vm.expectRevert(UniETHAdapter.TransactionTooOld.selector);
        vm.prank(rebalancer);
        adapter.into().requestWithdrawal(32 ether, block.timestamp - 1);
    }

    function testRequestWithdrawalWithDeadline() public {
        vm.recordLogs();
        // Setup
        // 1. Mint some uniETH and shares.
        // 2. Ensure present buffer percentage is less than the target percentage.
        _fundAdapterUnderlying(320 ether);
        _changeTranche(address(this));
        adapter.prefundedDeposit(); // Mint some uniETH.

        uint256 totalAssetsPrior = adapter.into().totalAssets();
        (, uint256 lastId) = BEDROCK_STAKING.getDebtQueue();
        uint256 expectedId = lastId + 1;

        // Execution
        uint256 withdrawAmount = 32 ether;
        uint256 deadline = block.timestamp + 1 days;
        vm.prank(rebalancer);
        adapter.into().requestWithdrawal(withdrawAmount, deadline);

        Vm.Log memory eventLog = _getRecordedLogs(keccak256("RequestWithdrawal(uint256,uint256)"));
        (uint256 requestId, uint256 actualQueueAmount) = abi.decode(eventLog.data, (uint256, uint256));

        // Assertions
        assertEq(actualQueueAmount, withdrawAmount, "actualQueueAmount should be eq to withdrawAmount");
        assertEq(expectedId, requestId, "requestId should be set");
        assertNotEq(expectedId, 0, "requestId should not be 0");
        (address owner, uint256 debt) = BEDROCK_STAKING.checkDebt(expectedId);
        assertEq(owner, address(adapter), "adapter should own the debt");
        assertEq(BEDROCK_STAKING.debtOf(address(adapter)), debt, "debt should be set");
        assertEq(adapter.into().totalQueueEth(), debt, "totalQueueEth should be eq to debt");
        assertEq(adapter.into().totalQueueEth(), withdrawAmount, "totalQueueEth should be eq to withdrawAmount");
        assertApproxEqAbs(
            adapter.into().totalAssets(),
            totalAssetsPrior,
            1_000,
            "totalAssets should be approximately the same"
        );
        testAdapterHasNoFundLeft();
    }

    function testRequestWithdrawal() public override {
        vm.recordLogs();
        // Setup
        // 1. Mint some uniETH and shares.
        // 2. Ensure present buffer percentage is less than the target percentage.
        {
            _fundAdapterUnderlying(320 ether);
            _changeTranche(address(this));
            adapter.prefundedDeposit(); // Mint some uniETH.
            vm.prank(rebalancer);
            adapter.into().setTargetBufferPercentage(0.6 * 1e18); // 60%
        }
        uint256 totalAssetsPrior = adapter.into().totalAssets();
        (, uint256 lastId) = BEDROCK_STAKING.getDebtQueue();
        uint256 expectedId = lastId + 1;

        // Execution
        vm.prank(rebalancer);
        adapter.into().requestWithdrawal();

        Vm.Log memory eventLog = _getRecordedLogs(keccak256("RequestWithdrawal(uint256,uint256)"));
        (uint256 requestId, uint256 actualQueueEth) = abi.decode(eventLog.data, (uint256, uint256));

        // Assertions
        assertEq(expectedId, requestId, "requestId should be set");
        assertNotEq(expectedId, 0, "requestId should not be 0");
        (address owner, uint256 debt) = BEDROCK_STAKING.checkDebt(expectedId);
        assertEq(owner, address(adapter), "adapter should own the debt");
        assertEq(BEDROCK_STAKING.debtOf(address(adapter)), debt, "debt should be set");
        assertEq(adapter.into().totalQueueEth(), debt, "totalQueueEth should be eq to debt");
        assertEq(adapter.into().totalQueueEth(), actualQueueEth, "totalQueueEth should be eq to actualQueueEth");
        assertApproxEqAbs(
            adapter.into().totalAssets(),
            totalAssetsPrior,
            1_000,
            "totalAssets should be approximately the same"
        );
        testAdapterHasNoFundLeft();
    }

    function testRequestWithdrawalAll() public override {
        _fundAdapterUnderlying(320 ether);
        _changeTranche(address(this));
        adapter.prefundedDeposit(); // Mint some uniETH.

        uint256 lstBalance = LST.balanceOf(address(adapter));

        // Execution
        vm.prank(rebalancer);
        adapter.into().requestWithdrawalAll();
        uint256 burnedUniEth = lstBalance - LST.balanceOf(address(adapter));
        // Assertions
        assertApproxEqAbs(
            adapter.into().totalQueueEth(),
            (BEDROCK_STAKING.exchangeRatio() * burnedUniEth) / 1e18,
            200,
            "Pending withdrawal should be less than previous LST balance"
        );
        // assertEq(adapter.into().requestId(), expectedId, "requestId should be set");
        testAdapterHasNoFundLeft();
    }

    //////////////////////////////////////////////////////////////////////////////
    // Instant withdrawal
    //////////////////////////////////////////////////////////////////////////////

    function testInstantWithdrawal() public {
        // Setup
        {
            _fundAdapterUnderlying(10 ether);
            _changeTranche(address(this));
            adapter.prefundedDeposit(); // Mint some uniETH.
        }
        uint256 bufferPrior = adapter.into().bufferEth();

        // Execution
        uint256 uniEthToBurn = 0.6e18;
        vm.prank(rebalancer);
        adapter.into().withdraw({uniEthAmount: uniEthToBurn});

        uint256 withdrawn = (uniEthToBurn * BEDROCK_STAKING.exchangeRatio()) / 1e18;

        assertApproxEqAbs(
            adapter.into().bufferEth(),
            bufferPrior + withdrawn,
            100,
            "bufferEth should inrease by withdrawn amount"
        );
    }

    function testInstantWithdrawal_RevertWhen_NotRebalancer() public {
        vm.expectRevert(BaseLSTVault.NotRebalancer.selector);
        vm.prank(address(0xabcd));
        adapter.into().withdraw(1 ether);
    }

    //////////////////////////////////////////////////////////////////////////////
    // Claim withdrawal
    //////////////////////////////////////////////////////////////////////////////

    function prepare_testClaimWithdrawal() internal returns (uint256, uint256) {
        // 1. Mint some uniETH and shares.
        _fundAdapterUnderlying(320 ether);
        _changeTranche(address(this));
        adapter.prefundedDeposit(); // Mint some uniETH.

        // 2. Request withdrawal.
        vm.prank(rebalancer);
        adapter.into().setTargetBufferPercentage(0.3 * 1e18); // 30%

        vm.recordLogs();
        vm.prank(rebalancer);
        adapter.into().requestWithdrawal();

        Vm.Log memory eventLog = _getRecordedLogs(keccak256("RequestWithdrawal(uint256,uint256)"));
        (uint256 requestId, uint256 actualQueueEth) = abi.decode(eventLog.data, (uint256, uint256));
        return (requestId, actualQueueEth);
    }

    function testClaimWithdrawal() public override {
        // Setup
        (uint256 requestId, uint256 actualQueueEth) = prepare_testClaimWithdrawal();

        // Wait until the request is finalized
        // Mock the bedrock to finalize the request
        uint256 claimable = actualQueueEth - 1_000;
        IRedeem(bedrockRedeem).pay{value: 1000 ether}(address(0xbabe)); // Bedrock does this
        IRedeem(bedrockRedeem).pay{value: claimable}(address(adapter));
        vm.mockCall(
            Constants.BEDROCK_STAKING,
            abi.encodeWithSelector(IStaking.checkDebt.selector, requestId),
            abi.encode(address(adapter), 0) // debt = 0
        );

        uint256 bufferPrior = adapter.into().bufferEth();
        uint256 scalePrior = adapter.scale();
        // Execute
        vm.prank(rebalancer);
        adapter.into().claimWithdrawal(requestId);

        // Assertions
        assertEq(adapter.into().queueWithdrawal(requestId), 0, "queueWithdrawal should be reset to 0");
        assertEq(adapter.into().bufferEth(), bufferPrior + claimable, "bufferEth should increase by claimable amount");
        assertEq(adapter.into().totalQueueEth(), 0, "totalQueueEth should be reset to 0");
        assertEq(
            underlying.balanceOf(address(adapter)) - bufferPrior,
            claimable,
            "WETH balance should increase by claimable amount"
        );
        assertApproxEqAbs(adapter.scale(), scalePrior, 1_000, "scale should not change");
        testAdapterHasNoFundLeft();
    }

    function testClaimWithdrawal_RevertWhen_RequestNotFinalized() external {
        (uint256 requestId, ) = prepare_testClaimWithdrawal();
        // Setup
        uint256 donation = 1 ether;
        IRedeem(bedrockRedeem).pay{value: donation}(address(adapter));

        vm.expectRevert(UniETHAdapter.RequestNotFinalized.selector);
        vm.prank(rebalancer);
        adapter.into().claimWithdrawal(requestId);
    }

    //////////////////////////////////////////////////////////////////////////////
    // Swap
    //////////////////////////////////////////////////////////////////////////////

    function testSwap() public {
        // Setup
        _fundAdapterUnderlying(400 ether);
        _changeTranche(address(this));
        adapter.prefundedDeposit(); // Mint some uniETH.

        uint256 bufferPrior = adapter.into().bufferEth();
        uint256 balanceBefore = underlying.balanceOf(address(adapter));

        uint256 amountIn = LST.balanceOf(address(adapter)) % 32 ether;
        vm.prank(rebalancer);
        adapter.into().swapUniETHForETH({
            amount: amountIn,
            deadline: block.timestamp,
            minEthOut: 0.1 ether,
            data: abi.encode(0)
        });

        uint256 ethOut = underlying.balanceOf(address(adapter)) - balanceBefore;
        assertGe(ethOut, 0.1 ether, "adapter should have more than 0.6 ETH");
        assertEq(adapter.into().bufferEth(), bufferPrior + ethOut, "received ether should be added to buffer");
        testAdapterHasNoFundLeft();
    }

    function testSwap_RevertWhenNotRebalancer() public {
        vm.expectRevert(BaseLSTVault.NotRebalancer.selector);
        vm.prank(address(0xabcd));
        adapter.into().swapUniETHForETH({
            amount: 1 ether,
            deadline: block.timestamp,
            minEthOut: 0.6 ether,
            data: abi.encode(0)
        });
    }

    function testSwap_RevertWhenSwapAmountTooLarge() public {
        vm.expectRevert(UniETHAdapter.SwapAmountTooLarge.selector);
        vm.prank(rebalancer);
        adapter.into().swapUniETHForETH({
            amount: 32 ether + 1,
            deadline: block.timestamp,
            minEthOut: 0.6 ether,
            data: abi.encode(0)
        });
    }

    function testSwap_RevertWhenTransactionTooOld() public {
        vm.expectRevert();
        vm.prank(rebalancer);
        adapter.into().swapUniETHForETH({
            amount: 1 ether,
            deadline: block.timestamp - 1,
            minEthOut: 0.6 ether,
            data: abi.encode(0)
        });
    }

    function testSetSwapper() public {
        vm.prank(owner);
        adapter.into().setSwapper(address(0x1234));
        assertEq(address(adapter.into().swapper()), address(0x1234), "swapper should be set to 0x1234");
    }

    function testSetSwapper_RevertWhenNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(user);
        adapter.into().setSwapper(address(0x1234));
    }
}
