// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {BaseTestAdapter} from "./BaseTestAdapter.t.sol";

import {RocketPoolHelper} from "../../utils/RocketPoolHelper.sol";

import {ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import {IRocketTokenRETH} from "src/adapters/rocketPool/interfaces/IRocketTokenRETH.sol";
import {IRocketDepositPool} from "src/adapters/rocketPool/interfaces/IRocketDepositPool.sol";
import {IBaseAdapter} from "src/interfaces/IBaseAdapter.sol";
import {BaseLSTAdapter} from "src/adapters/BaseLSTAdapter.sol";
import "src/Constants.sol" as Constants;

import {BaseLSTVault, RETHAdapter} from "src/adapters/rocketPool/RETHAdapter.sol";
import {Swapper} from "src/adapters/rocketPool/Swapper.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";

library Cast {
    function into(IBaseAdapter x) internal pure returns (RETHAdapter) {
        return RETHAdapter(payable(address(x)));
    }
}

contract TestRETHAdapter is BaseTestAdapter {
    using Cast for *;
    using stdStorage for StdStorage;

    uint256 constant FORKED_AT = 19_000_000;

    /// @notice Rocket Pool Storage https://www.codeslaw.app/contracts/ethereum/0x1d8f8f00cfa6758d7be78336684788fb0ee0fa46
    address constant ROCKET_STORAGE = 0x1d8f8f00cfa6758d7bE78336684788Fb0ee0Fa46;

    IRocketTokenRETH constant RETH = IRocketTokenRETH(Constants.RETH);

    address constant RETH_ETH_POOL = 0x0f3159811670c117c372428D4E69AC32325e4D0F;

    /// @notice Rebalancer of the LST adapter
    address rebalancer = makeAddr("rebalancer");

    /// @notice Current maximum deposit pool size is 18_000 ether.
    uint256 MAXIMUM_DEPOSIT_POOL_SIZE = 40_000 ether;

    /// @notice Maximum deposit amount
    uint256 MAXIMUM_DEPOSIT_AMOUNT;

    /// @notice RocketPool Deposit Pool module
    address rocketDepositPool;

    /// @notice RocketPool DAO Protocol Settings Deposit module
    address rocketDAOProtocolSettingsDeposit;

    /// @notice Swapper contract for swapping WETH to rETH
    Swapper swapper;

    function setUp() public override {
        vm.createSelectFork("mainnet", FORKED_AT);
        super.setUp();
        testAdapterHasNoFundLeft();

        rocketDepositPool = RocketPoolHelper.getRocketPoolModuleAddress("rocketDepositPool");
        rocketDAOProtocolSettingsDeposit = RocketPoolHelper.getRocketPoolModuleAddress(
            "rocketDAOProtocolSettingsDeposit"
        );

        vm.label(ROCKET_STORAGE, "RP_Storage");
        vm.label(rocketDepositPool, "RP_DepositPool");
        vm.label(rocketDAOProtocolSettingsDeposit, "RP_DepositSettings");
        vm.label(RETH_ETH_POOL, "RETH/ETH Pool");

        // note Rocket Pool has a maximum deposit pool size.
        // Currently, the maximum deposit pool size is 18_000 ether and the cap is reached.
        // Here, we mock the maximum deposit pool size for testing.
        // https://github.com/rocket-pool/rocketpool/blob/6a9dbfd85772900bb192aabeb0c9b8d9f6e019d1/contracts/contract/deposit/RocketDepositPool.sol#L96
        // https://github.com/rocket-pool/rocketpool/blob/6a9dbfd85772900bb192aabeb0c9b8d9f6e019d1/contracts/contract/dao/protocol/settings/RocketDAOProtocolSettingsDeposit.sol
        vm.mockCall(
            rocketDAOProtocolSettingsDeposit,
            abi.encodeWithSignature("getMaximumDepositPoolSize()"),
            abi.encode(MAXIMUM_DEPOSIT_POOL_SIZE)
        );
        // note: the maximum deposit pool amount is the maximum pool size minus the current pool balance.
        MAXIMUM_DEPOSIT_AMOUNT = MAXIMUM_DEPOSIT_POOL_SIZE - IRocketDepositPool(rocketDepositPool).getBalance();

        _changeTranche(user);
    }

    function _changeTranche(address newTranche) internal {
        stdstore.target(address(adapter)).sig("tranche()").checked_write(newTranche);
    }

    function _deployAdapter() internal override {
        swapper = new Swapper(RETH_ETH_POOL);
        vm.prank(owner);
        adapter = new RETHAdapter(rebalancer, address(swapper), ROCKET_STORAGE);
        underlying = ERC20(Constants.WETH);
        target = ERC20(address(adapter));
    }

    ////////////////////////////////////////////////////////////////////////
    // Assertions
    ////////////////////////////////////////////////////////////////////////

    function testAdapterHasNoFundLeft() internal override {
        // make sure that the adapter's balance is zero prior to any function call in the tests
        assertEq(
            underlying.balanceOf(address(adapter)),
            adapter.into().bufferEth(),
            "adapter is expected to have `bufferEth` WETH"
        );
        assertEq(address(adapter).balance, 0, "adapter is expected to have no native ETH left, but has some");
        assertEq(target.balanceOf(address(adapter)), 0, "adapter is expected to have no shares, but has some");
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function _fundAdapterTarget(uint256 fundedAmount) internal {
        deal(address(adapter), address(adapter), fundedAmount, true);
    }

    function _fundAdapterUnderlying(uint256 fundedAmount) internal {
        deal(Constants.WETH, address(adapter), fundedAmount, false);
    }

    ////////////////////////////////////////////////////////////////////////
    // Deposit
    ////////////////////////////////////////////////////////////////////////

    function testPrefundedDeposit_Zero() public override {
        vm.prank(adapter.into().tranche());
        (uint256 underlyingUsed, uint256 sharesMinted) = adapter.prefundedDeposit();
        assertEq(underlyingUsed, 0, "underlyingUsed !~= 0");
        assertEq(sharesMinted, 0, "sharesMinted !~= 0");
    }

    function testPrefundedRedeem_Zero() public override {
        vm.prank(adapter.into().tranche());
        (uint256 underlyingUsed, uint256 sharesMinted) = adapter.prefundedRedeem(user);
        assertEq(underlyingUsed, 0, "underlyingUsed !~= 0");
        assertEq(sharesMinted, 0, "sharesMinted !~= 0");
    }

    function testPrefundedDeposit() public override {
        // Setup
        // The stake amount is caped at 95% of the available ETH at the time of the stake.
        // Target buffer is 10% of the total value of the adapter.

        // transfer WETH to the adapter contract prior as it would be done by Tranche
        uint256 wethFundedAmount = 1 ether;
        _fundAdapterUnderlying(wethFundedAmount);

        vm.prank(user);
        (uint256 underlyingUsed, uint256 sharesMinted) = adapter.prefundedDeposit();

        uint256 expectedShares = wethFundedAmount; // when totalSupply is 0, 1 share = 1 WETH
        assertEq(wethFundedAmount, underlyingUsed, "user provided WETH amount !~= actual WETH used");
        assertEq(sharesMinted, expectedShares, "actual shares minted !~= expected shares minted");
        assertEq(target.balanceOf(user), sharesMinted, "balanceOfUser !~= shares minted");
        testAdapterHasNoFundLeft();
        assertEq(adapter.into().bufferPresentPercentage(), 1e18, "present buffer percentage should be 100%");
        assertEq(adapter.into().bufferEth(), wethFundedAmount, "bufferEth should be WETH funded");
    }

    /// @notice Test round trip of deposit and redeem
    /// @dev mint shares and then redeem them immediately must not benefit the user
    /// @param initialDeposit initial deposit amount
    /// @param secondDeposit second deposit amount
    /// @param stakeAmount stake amount to mint rETH
    function testFuzz_RT_DepositRedeem(uint256 initialDeposit, uint256 secondDeposit, uint256 stakeAmount) public {
        // Setup
        initialDeposit = bound(initialDeposit, 0, MAXIMUM_DEPOSIT_AMOUNT);
        secondDeposit = bound(secondDeposit, 1_000, MAXIMUM_DEPOSIT_AMOUNT);
        stakeAmount = bound(stakeAmount, 1_000, MAXIMUM_DEPOSIT_AMOUNT + 1000 ether);
        _changeTranche(address(this));

        // transfer WETH to the adapter contract prior as it would be done by Tranche
        _fundAdapterUnderlying(initialDeposit);
        try adapter.prefundedDeposit() {} catch {
            vm.assume(false); // ignore the case when the initial deposit is too small and the deposit fails
        }

        // Execution
        // Mint some rETH
        vm.prank(rebalancer);
        try adapter.into().mintReth(stakeAmount) {} catch {
            vm.assume(false);
        }

        // 1. deposit WETH
        _fundAdapterUnderlying(secondDeposit + underlying.balanceOf(address(adapter)));
        (bool s, bytes memory ret) = address(adapter).call(abi.encodeCall(adapter.prefundedDeposit, ()));
        // `ZeroShares` error is expected only when the deposit is too small.
        if (!s) assertEq(bytes4(ret), BaseLSTVault.ZeroShares.selector, "unexpected revert");
        vm.assume(s);
        (, uint256 shares) = abi.decode(ret, (uint256, uint256));

        // 2. immediately redeem the minted shares
        adapter.into().transfer(address(adapter), shares);
        (uint256 wethWithdrawn, uint256 sharesRedeemed) = adapter.prefundedRedeem(user);

        assertEq(sharesRedeemed, shares, "Shares redeemed should be equal to shares minted");
        assertLe(wethWithdrawn, secondDeposit, "WETH withdrawn should be less than or equal to WETH deposited");
    }

    //////////////////////////////////////////////////////////////////////////////
    // Mint rETH
    //////////////////////////////////////////////////////////////////////////////

    function testMintReth() public {
        uint256 value = 10 ether;
        // Setup
        _changeTranche(address(this));
        deal(Constants.WETH, address(adapter), value, false);
        adapter.prefundedDeposit();

        // Execution
        uint256 stakeAmount = value / 2; // 50% of the value
        vm.expectCall(rocketDepositPool, stakeAmount, abi.encodeWithSignature("deposit()"));
        vm.prank(rebalancer);
        adapter.into().mintReth(stakeAmount);

        // assertion
        testAdapterHasNoFundLeft();
    }

    function testMintReth_WhenMaximumDepositExceed() public {
        uint256 stakeAmount = 1000 ether;
        uint256 maximumDeposit = 1 ether;
        // Setup
        vm.mockCall(
            rocketDepositPool,
            abi.encodeWithSignature("getMaximumDepositAmount()"),
            abi.encode(maximumDeposit)
        );

        deal(Constants.WETH, address(adapter), stakeAmount * 100, false);
        _changeTranche(address(this));
        adapter.prefundedDeposit();

        // Execution
        // Actual stake amount should be changed to maximum deposit amount instead of the provided stake amount
        vm.expectCall({
            callee: rocketDepositPool,
            msgValue: maximumDeposit, // expect the maximum deposit amount to be sent instead of the provided stake amount
            data: abi.encodeWithSignature("deposit()")
        });
        vm.prank(rebalancer);
        adapter.into().mintReth(stakeAmount);

        testAdapterHasNoFundLeft();
    }

    function testMintReth_RevertIf_InsufficientBuffer() public {
        // Setup
        deal(Constants.WETH, address(adapter), 10 ether, false);
        _changeTranche(address(this));
        adapter.prefundedDeposit();

        deal(Constants.RETH, address(adapter), 1000 ether, false); // Transfer a large amount of rETH to the adapter

        // Execution
        // Now, the adapter has small amount of WETH and large amount of rETH
        vm.expectRevert(BaseLSTVault.InsufficientBuffer.selector);
        vm.prank(rebalancer);
        adapter.into().mintReth(1000);
    }

    function testMintReth_RevertIf_MaxStakeExceeded() public {
        uint256 value = 2 ether;
        // Setup
        deal(Constants.WETH, address(adapter), value, false);
        _changeTranche(address(this));
        adapter.prefundedDeposit();

        // Execution
        vm.expectRevert(RETHAdapter.MaxStakeExceeded.selector);
        vm.prank(rebalancer);
        adapter.into().mintReth(value);
    }

    //////////////////////////////////////////////////////////////////////////////
    // Redeem
    //////////////////////////////////////////////////////////////////////////////

    struct PrefundedRedeemPreState {
        address receiver; // receiver of the redeemed WETH
        uint256 shares; // shares to be requested to redeem
    }

    function _testPrefundedRedeem(
        PrefundedRedeemPreState memory params
    ) public returns (uint256 wethWithdrawn, uint256 sharesRedeemed) {
        vm.prank(adapter.into().tranche());
        (wethWithdrawn, sharesRedeemed) = adapter.prefundedRedeem(params.receiver);

        assertEq(params.shares, sharesRedeemed, "params.receiver provided shares !~= actual shares withdrawn");
        assertEq(underlying.balanceOf(params.receiver), wethWithdrawn, "balanceOf receiver !~= wethWithdrawn");
        testAdapterHasNoFundLeft();
    }

    function testPrefundedRedeem() public override {
        // Setup
        // transfer shares to the adapter contract prior as it would be done by Tranche
        uint256 shares = 1_027;
        uint256 buffer = 30_000;
        _fundAdapterTarget(shares);
        // Transfer some WETH to make sure that the adapter has enough buffer
        _fundAdapterUnderlying(buffer);
        _storeBufferEth(buffer);

        (uint256 wethWithdrawn, ) = _testPrefundedRedeem(PrefundedRedeemPreState({receiver: user, shares: shares}));
        assertEq(adapter.into().bufferEth(), buffer - wethWithdrawn, "bufferEth !~= buffer - wethWithdrawn");
    }

    function testPrefundedRedeem_WhenBurnREth() public {
        uint256 value = 10 ether;
        // Setup
        _changeTranche(address(this));
        deal(Constants.WETH, address(adapter), value, false);
        (, uint256 shares) = adapter.prefundedDeposit();

        uint256 depositFee = RocketPoolHelper.getDepositFee((value * 9) / 10);
        vm.prank(rebalancer);
        adapter.into().mintReth((value * 9) / 10); // Mint rETH using 90% of the value

        // Execution
        uint256 sharesToRedeem = (shares * 20) / 100; // 20% of the value equivalent shares
        adapter.into().transfer(address(adapter), sharesToRedeem);

        vm.expectCall(Constants.RETH, abi.encodeWithSignature("burn(uint256)")); // rETH should be burned
        (uint256 wethWithdrawn, ) = this._testPrefundedRedeem(
            PrefundedRedeemPreState({receiver: user, shares: sharesToRedeem})
        );
        assertEq(adapter.into().bufferEth(), 0, "All the buffer should be used");
        assertApproxEqAbs(
            wethWithdrawn,
            ((value - depositFee) * 20) / 100,
            2,
            "underlying withdrawn should be 20% of the value"
        );
    }

    function testFuzz_PrefundedRedeem(uint256 deposit, uint256 stakeAmount, uint256 sharesToRedeem) public {
        deposit = bound(deposit, 1_000, MAXIMUM_DEPOSIT_AMOUNT);
        stakeAmount = bound(stakeAmount, 0, (deposit * 9) / 10);
        sharesToRedeem = bound(sharesToRedeem, 1_000, deposit); // 1 share = 1 asset because totalSupply is 0
        // Setup
        deal(Constants.WETH, address(adapter), deposit, false);
        _changeTranche(address(this));
        adapter.prefundedDeposit();

        vm.prank(rebalancer);
        adapter.into().mintReth(stakeAmount);

        // Execution
        adapter.into().transfer(address(adapter), sharesToRedeem);

        _testPrefundedRedeem(PrefundedRedeemPreState({receiver: user, shares: sharesToRedeem}));
    }

    function testPrefundedRedeem_WhenBurnREth_RevertWhen_InsufficientCollateral() public {
        // Setup
        uint256 value = 10 ether;
        deal(Constants.WETH, address(adapter), value, false);
        _changeTranche(address(this));
        (, uint256 shares) = adapter.prefundedDeposit();

        adapter.into().transfer(address(adapter), shares);

        vm.prank(rebalancer);
        adapter.into().mintReth((value * 9) / 10); // Mint rETH using 90% of the value

        // rETH has less collateral than the amount of WETH to be redeemed
        vm.mockCall(
            Constants.RETH,
            abi.encodeWithSignature("getTotalCollateral()"),
            abi.encode(0.1 ether) // rETH has 0.1 ether collateral only
        );

        vm.expectRevert(RETHAdapter.InsufficientCollateralInRocketPool.selector);
        adapter.prefundedRedeem(user);
    }

    /// @dev In theory, the adapter can redeem shares as long as rETH has enough collateral to cover the withdrawal.
    // This error is expected only when the adapter withdraws slightly less than the expected amount due to rounding errors.
    function testPrefundedRedeem_WhenBurnREth_RevertWhen_InsufficientBuffer() public {}

    //////////////////////////////////////////////////////////////////////////////
    // Withdraw
    //////////////////////////////////////////////////////////////////////////////

    function testWithdraw() public {
        // Setup
        // 1. Mint some rETH.
        // 2. Ensure present buffer percentage is less than the target percentage.
        {
            _storeBufferEth(10 ether);
            _fundAdapterUnderlying(10 ether);
            vm.prank(rebalancer);
            adapter.into().mintReth(9 ether);
            vm.prank(rebalancer);
            adapter.into().setTargetBufferPercentage(0.6 * 1e18); // 60%
        }

        uint256 totalAssetsPrior = adapter.into().totalAssets();
        // Execution
        vm.prank(rebalancer);
        adapter.into().withdraw();
        // Assertions
        assertApproxEqAbs(
            adapter.into().totalAssets(),
            totalAssetsPrior,
            2,
            "totalAssets should be approximately the equal to the previous totalAssets"
        );
        testAdapterHasNoFundLeft();
    }

    function testWithdraw_RevertWhen_BufferTooLarge() public {
        {
            _fundAdapterUnderlying(10 ether);
            _changeTranche(address(this));
            adapter.prefundedDeposit();
        }
        // Setup
        // Ensure that present buffer percentage > target buffer percentage
        _storeBufferEth(adapter.into().bufferEth() + 100); // bufferEth += 100 wei
        // Assertion
        vm.expectRevert(BaseLSTVault.BufferTooLarge.selector);
        vm.prank(rebalancer);
        adapter.into().withdraw();
    }

    function testWithdrawal_RevertWhen_NotRebalancer() public {
        vm.expectRevert(BaseLSTVault.NotRebalancer.selector);
        vm.prank(address(0xabcd));
        adapter.into().withdraw();
    }

    //////////////////////////////////////////////////////////////////////////////
    // Withdraw all
    //////////////////////////////////////////////////////////////////////////////

    function testWithdrawAll() public {
        deal(Constants.RETH, address(adapter), 10 ether, false);
        // Execution
        vm.prank(rebalancer);
        adapter.into().withdrawAll();
        // Assertions
        assertEq(RETH.balanceOf(address(adapter)), 0, "adapter should have no rETH");
        testAdapterHasNoFundLeft();
    }

    function testWithdrawalAll_RevertWhen_NotRebalancer() public {
        vm.expectRevert(BaseLSTVault.NotRebalancer.selector);
        vm.prank(address(0xabcd));
        adapter.into().withdrawAll();
    }

    function testScale() public override {
        assertEq(adapter.scale(), 1e18, "scale should be 1e18 when total supply is 0");
    }

    //////////////////////////////////////////////////////////////////////////////
    // Swap
    //////////////////////////////////////////////////////////////////////////////

    function testSwap() public {
        _fundAdapterUnderlying(10 ether);
        _storeBufferEth(10 ether);

        uint256 balanceBefore = underlying.balanceOf(address(adapter));

        vm.prank(rebalancer);
        adapter.into().swapEthForReth({
            ethValue: 1 ether,
            deadline: block.timestamp,
            amountOutMin: 0.9 ether,
            data: ""
        });

        testAdapterHasNoFundLeft();
        uint256 spent = balanceBefore - underlying.balanceOf(address(adapter));
        assertEq(spent, 1 ether, "Spent WETH should be 1 ether");
        assertGe(RETH.balanceOf(address(adapter)), 0.9 ether, "adapter should have more than 0.9 rETH");
    }

    function testSwap_RevertWhenNotRebalancer() public {
        vm.expectRevert(BaseLSTVault.NotRebalancer.selector);
        vm.prank(address(0xabcd));
        adapter.into().swapEthForReth(1 ether, block.timestamp, 1 ether, "");
    }

    function testSwap_RevertWhenSwapAmountTooLarge() public {
        _fundAdapterUnderlying(100 ether);
        _storeBufferEth(100 ether);

        vm.expectRevert(RETHAdapter.SwapAmountTooLarge.selector);
        vm.prank(rebalancer);
        adapter.into().swapEthForReth({
            ethValue: 90 ether + 1,
            deadline: block.timestamp,
            amountOutMin: 1 ether,
            data: ""
        });
    }

    function testSwap_RevertWhenTransactionTooOld() public {
        _fundAdapterUnderlying(10 ether);
        _storeBufferEth(10 ether);

        vm.expectRevert(Swapper.TransactionTooOld.selector);
        vm.prank(rebalancer);
        adapter.into().swapEthForReth({
            ethValue: 0.001 ether,
            deadline: block.timestamp - 1,
            amountOutMin: 0,
            data: ""
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

    //////////////////////////////////////////////////////////////////////////////
    // Helpers
    //////////////////////////////////////////////////////////////////////////////

    /// @notice helper function to store `bufferEth` state variable
    /// @param bufferEth `bufferEth` to be stored in the adapter contract
    function _storeBufferEth(uint256 bufferEth) internal {
        // bufferEth is packed in the first 128 bits of slot 11
        vm.store(address(adapter), bytes32(uint256(11)), bytes32(bufferEth));
        require(adapter.into().bufferEth() == bufferEth, "bufferEth not set correctly");
    }
}
