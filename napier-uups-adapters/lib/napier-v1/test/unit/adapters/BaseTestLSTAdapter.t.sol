// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts@4.9.3/interfaces/IERC4626.sol";
import {BaseTestAdapter} from "./BaseTestAdapter.t.sol";
import {BaseAdapter, BaseLSTVault, BaseLSTAdapter} from "src/adapters/BaseLSTAdapter.sol";
import "src/Constants.sol" as Constants;

import "forge-std/Test.sol";

library Cast {
    function into(BaseAdapter x) internal pure returns (BaseLSTAdapter) {
        return BaseLSTAdapter(address(x));
    }
}

abstract contract BaseTestLSTAdapter is BaseTestAdapter {
    using Cast for BaseAdapter;
    using stdStorage for StdStorage;

    /// @notice Rebalancer of the LST adapter
    address rebalancer = makeAddr("rebalancer");

    /// @notice Liquid Staking Token (e.g. stETH, FrxETH)
    /// @dev Set in `_deployAdapter()`
    IERC20 LST;

    //////////////////////////////////////////////////////////////////////////////
    // Deposit
    //////////////////////////////////////////////////////////////////////////////

    function testPrefundedDeposit_RevertWhen_NotTranche() public {
        vm.expectRevert(BaseLSTVault.NotTranche.selector);
        vm.prank(user);
        adapter.prefundedDeposit();
    }

    function testPrefundedRedeems_RevertWhen_NotTranche() public {
        vm.expectRevert(BaseLSTVault.NotTranche.selector);
        vm.prank(user);
        adapter.prefundedRedeem(user);
    }

    function testPrefundedDeposit_WhenBufferIsInsufficient() public virtual {
        /// Setup
        uint256 lstBalance; // frxETH or stETH balance of the adapter contract prior to the deposit
        uint256 bufferPrior = 1 ether;
        uint256 stakeLimitPrior = adapter.into().getCurrentStakeLimit();
        // Make sure that the present buffer percentage is less than 10%
        {
            // Mint some LST and mock the buffer and withdrawal queue
            _fundAdapterUnderlying(40 ether);
            _changeTranche(address(this));
            adapter.prefundedDeposit(); // 90% of the deposit would be converted to LST
            _storeBufferEth(bufferPrior);
            _storeWithdrawalQueueEth(bufferPrior);
            assertApproxEqAbs(
                adapter.into().bufferPresentPercentage(),
                0.053e18, // bufferPercentage ~ (1 + 1) / (40*0.9 + 1 + 1) ~ 0.053 (5.3%)
                0.01 * 1e18, // [0.043, 0.063]
                "present buffer percentage should be about 5%"
            );
            lstBalance = LST.balanceOf(address(adapter));
        }
        // transfer WETH to the adapter contract prior as it would be done by Tranche
        uint256 wethFundedAmount = 1_992_265_115;
        _fundAdapterUnderlying(wethFundedAmount + bufferPrior);

        /// Execution
        _changeTranche(user);
        vm.prank(user);
        (uint256 underlyingUsed, uint256 sharesMinted) = adapter.prefundedDeposit();

        assertEq(wethFundedAmount, underlyingUsed, "user provided WETH amount !~= actual WETH used");
        assertEq(target.balanceOf(user), sharesMinted, "balanceOfUser !~= shares minted");
        testAdapterHasNoFundLeft();
        assertEq(LST.balanceOf(address(adapter)), lstBalance, "LST balance should not change");
        assertEq(adapter.into().bufferEth(), wethFundedAmount + bufferPrior, "buffer should increase by WETH funded");
        assertApproxEqAbs(
            adapter.into().getCurrentStakeLimit(),
            stakeLimitPrior - (40 ether * 90) / 100,
            100,
            "stakeLimit should decrease by 90% of WETH funded"
        );
    }

    struct PrefundedDepositParams {
        uint256 underlyingIn;
    }

    modifier boundPrefundedDepositParams(PrefundedDepositParams memory params) virtual {
        params.underlyingIn = bound(params.underlyingIn, 1_000, 1_000_000 ether);
        _;
    }

    /// @notice Fuzz test for prefundedDeposit
    /// @dev The test checks the adapter should not revert any amount of WETH provided by the user
    /// - Lido and Rocket Pool have a maximum deposit limit.
    function testFuzz_PrefundedDeposit_WhenBufferIsInsufficient(
        PrefundedDepositParams memory params
    ) public virtual boundPrefundedDepositParams(params) {
        // Setup
        uint256 underlyingIn = params.underlyingIn;
        _fundAdapterUnderlying(underlyingIn);
        // Execution
        _changeTranche(user);
        vm.prank(user);
        (uint256 underlyingUsed, uint256 shares) = adapter.prefundedDeposit();
        // Assertion
        assertEq(underlyingUsed, underlyingIn, "underlyingUsed !~= underlyingIn");
        assertEq(target.balanceOf(user), shares, "shares !~= sharesMinted");
        testAdapterHasNoFundLeft();
    }

    /// @notice Scenario:
    /// - Buffer is sufficient
    /// - Hit the maximum stake limit
    function testPrefundedDeposit_WhenBufferSufficient_WhenExceedMaxStake() public {
        {
            // Mint tons of shares to hit the maximum stake limit
            _fundAdapterUnderlying(1_000_000 ether);
            _changeTranche(address(this));
            adapter.prefundedDeposit();
            assertEq(
                adapter.into().getCurrentStakeLimit(),
                0,
                "stakeLimit should be zero when it exceeds the maximum stake limit"
            );
        }
        // Setup
        vm.prank(owner);
        adapter.into().setStakingLimit({_maxStakeLimit: 1 ether, _stakeLimitIncreasePerBlock: 0.01 ether});

        uint256 wethFundedAmount = 10 ether;
        uint256 bufferPrior = adapter.into().bufferEth();
        _fundAdapterUnderlying(wethFundedAmount + underlying.balanceOf(address(adapter)));
        // Execution
        _changeTranche(user);
        vm.prank(user);
        (uint256 underlyingUsed, uint256 shares) = adapter.prefundedDeposit();
        // Assertion
        assertEq(underlyingUsed, wethFundedAmount, "underlyingUsed !~= wethFundedAmount");
        assertEq(target.balanceOf(user), shares, "shares !~= sharesMinted");
        testAdapterHasNoFundLeft();
        assertEq(
            adapter.into().bufferEth(),
            wethFundedAmount + bufferPrior,
            "bufferEth should increase by WETH funded"
        );
    }

    /// @notice Scenario:
    /// - Buffer is sufficient
    /// - There is a large withdrawal queue (e.g. 100 ETH)
    function testPrefundedDeposit_WhenBufferSufficient_WhenExceedAvailableEth() public {
        // Setup
        // transfer WETH to the adapter contract prior as it would be done by Tranche
        uint256 lstBalance;
        uint256 bufferPrior = 1 ether;
        {
            _fundAdapterUnderlying(1 ether);
            _changeTranche(address(this));
            adapter.prefundedDeposit(); // Mint some LST
            _storeBufferEth(bufferPrior);
            _storeWithdrawalQueueEth(100 ether); // large withdrawal queue
            lstBalance = LST.balanceOf(address(adapter));
        }
        uint256 wethFundedAmount = 0.09e18; // 0.09 ETH
        _fundAdapterUnderlying(wethFundedAmount + bufferPrior);

        _changeTranche(user);
        vm.prank(user);
        (uint256 underlyingUsed, uint256 sharesMinted) = adapter.prefundedDeposit();

        assertEq(wethFundedAmount, underlyingUsed, "user provided WETH amount !~= actual WETH used");
        assertEq(target.balanceOf(user), sharesMinted, "actual shares minted !~= expected shares minted");
        assertEq(adapter.into().bufferEth(), 0, "bufferEth should go to zero");
    }

    //////////////////////////////////////////////////////////////////////////////
    // Redeem
    //////////////////////////////////////////////////////////////////////////////

    function testPrefundedRedeem() public virtual override {
        // setup
        // transfer shares to the adapter contract prior as it would be done by Tranche
        uint256 shares = 1_027;
        uint256 buffer = 30_000;
        _fundAdapterTarget(shares);
        // Transfer some WETH to make sure that the adapter has enough buffer
        _storeBufferEth(buffer);

        _changeTranche(address(this));
        (uint256 wethWithdrawn, uint256 sharesRedeemed) = adapter.prefundedRedeem(user);

        assertEq(shares, sharesRedeemed, "user provided shares !~= actual shares withdrawn");
        assertEq(underlying.balanceOf(user), wethWithdrawn, "balanceOfUser !~= wethWithdrawn");
        testAdapterHasNoFundLeft();
        assertEq(adapter.into().bufferEth(), buffer - wethWithdrawn, "bufferEth !~= buffer - wethWithdrawn");
    }

    function testPrefundedRedeem_RevertWhen_InsufficientBuffer() public virtual {
        _fundAdapterUnderlying(1 ether);
        _changeTranche(address(this));
        (, uint256 shares) = adapter.prefundedDeposit();
        adapter.into().transfer(address(adapter), shares);

        _changeTranche(address(this));
        // Cannot redeem more than the buffer
        vm.expectRevert(BaseLSTVault.InsufficientBuffer.selector);
        adapter.prefundedRedeem(user);
    }

    /// forge-config: default.fuzz.runs = 4000
    /// @notice Round-trip test for deposit and redeem.
    /// @dev Redeeming the minted shares immediately must not benefit the user.
    function testFuzz_RT_DepositRedeem(
        uint256 withdrawalQueueEth,
        uint256 initialDeposit,
        uint256 wethDeposit
    ) public virtual {
        // Setup
        withdrawalQueueEth = bound(withdrawalQueueEth, 0, 100_000 ether);
        initialDeposit = bound(initialDeposit, 1_000, 100_000 ether);
        wethDeposit = bound(wethDeposit, 1_000, 100_000 ether);
        _storeWithdrawalQueueEth(withdrawalQueueEth);
        // transfer WETH to the adapter contract prior as it would be done by Tranche
        _fundAdapterUnderlying(initialDeposit);
        _changeTranche(address(this));
        try adapter.prefundedDeposit() {} catch {
            vm.assume(false); // ignore the case when the initial deposit is too small and the deposit fails
        }

        // Execution
        // 1. deposit WETH
        _fundAdapterUnderlying(wethDeposit + underlying.balanceOf(address(adapter)));
        _changeTranche(address(this));
        (bool s, bytes memory ret) = address(adapter).call(abi.encodeCall(adapter.prefundedDeposit, ()));
        // ZeroShares error is expected only when the deposit is too small
        if (!s) assertEq(bytes4(ret), BaseLSTVault.ZeroShares.selector, "unexpected revert");
        vm.assume(s);
        (, uint256 shares) = abi.decode(ret, (uint256, uint256));

        // Ensure that the adapter has enough buffer
        vm.assume(adapter.into().bufferEth() >= adapter.into().previewRedeem(shares));

        // 2. immediately redeem the minted shares
        adapter.into().transfer(address(adapter), shares);
        (uint256 wethWithdrawn, uint256 sharesRedeemed) = adapter.prefundedRedeem(user);

        assertEq(sharesRedeemed, shares, "Shares redeemed should be equal to shares minted");
        assertLe(wethWithdrawn, wethDeposit, "WETH withdrawn should be less than or equal to WETH deposited");
    }

    //////////////////////////////////////////////////////////////////////////////
    // Request withdrawal
    //////////////////////////////////////////////////////////////////////////////

    function testRequestWithdrawal() public virtual;

    function testRequestWithdrawal_RevertWhen_NotRebalancer() public virtual {
        vm.expectRevert(BaseLSTVault.NotRebalancer.selector);
        vm.prank(address(0xabcd));
        adapter.into().requestWithdrawal();
    }

    function testRequestWithdrawal_RevertWhen_BufferTooLarge() public virtual {
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
        adapter.into().requestWithdrawal();
    }

    function testRequestWithdrawalAll() public virtual;

    function testRequestWithdrawalAll_RevertWhen_NotRebalancer() public virtual {
        vm.expectRevert(BaseLSTVault.NotRebalancer.selector);
        vm.prank(address(0xabcd));
        adapter.into().requestWithdrawalAll();
    }

    //////////////////////////////////////////////////////////////////////////////
    // Claim withdrawal
    //////////////////////////////////////////////////////////////////////////////

    function testClaimWithdrawal() public virtual;

    function testClaimWithdrawal_RevertWhen_NoPendingWithdrawal() public virtual {
        // Assertion
        vm.expectRevert(BaseLSTAdapter.NoPendingWithdrawal.selector);
        vm.prank(rebalancer);
        adapter.into().claimWithdrawal(0);
    }

    //////////////////////////////////////////////////////////////////////////////
    // Stake limit functions
    //////////////////////////////////////////////////////////////////////////////

    function testStakingLimit() public {
        assertEq(adapter.into().getCurrentStakeLimit(), 10_000 ether, "maxStakeLimit not set correctly");
        {
            // Stake 900 ether (90 % of deposit)
            _fundAdapterUnderlying(1_000 ether);
            _changeTranche(address(this));
            adapter.prefundedDeposit();
        }
        assertEq(adapter.into().getCurrentStakeLimit(), 9_100 ether, "stakeLimit not updated correctly");

        // Advance 1 block
        vm.roll(block.number + 1);
        assertApproxEqRel(
            adapter.into().getCurrentStakeLimit(),
            9_100.00015 ether,
            0.0001e18,
            "stakeLimit not recovered correctly"
        );

        // Advance handreds of thousands of blocks
        vm.roll(block.number + 10000000000);
        assertEq(
            adapter.into().getCurrentStakeLimit(),
            10_000 ether,
            "stakeLimit does not increase after reaching max"
        );
    }

    function testSetStakingLimit() public {
        vm.prank(owner);
        adapter.into().setStakingLimit({_maxStakeLimit: 1 ether, _stakeLimitIncreasePerBlock: 0.01 ether});

        assertEq(adapter.into().getCurrentStakeLimit(), 1 ether, "maxStakeLimit not set correctly");
        // Advance 10 blocks
        vm.roll(block.number + 10);
        assertEq(adapter.into().getCurrentStakeLimit(), 1 ether, "stakeLimit should not change");
    }

    function testPauseUnPauseStakingLimit() public {
        vm.prank(owner);
        adapter.into().setStakingLimit({_maxStakeLimit: 10_0000 ether, _stakeLimitIncreasePerBlock: 0.01 ether});

        // Initial deposit
        {
            _fundAdapterUnderlying(1 ether);
            _changeTranche(address(this));
            adapter.prefundedDeposit();
        }
        uint256 bufferPrior = adapter.into().bufferEth();
        uint256 stakeLimitPrior = adapter.into().getCurrentStakeLimit();
        // Pause
        vm.prank(owner);
        adapter.into().pauseStaking();
        assertEq(adapter.into().getCurrentStakeLimit(), 0, "stakeLimit should be zero when paused");
        assertEq(adapter.into().isStakingPaused(), true, "staking should be paused");
        // Deposit after pause
        {
            _fundAdapterUnderlying(10 ether + underlying.balanceOf(address(adapter)));
            _changeTranche(address(this));
            adapter.prefundedDeposit();
        }
        // Deposit should not be converted to LST
        assertEq(adapter.into().bufferEth(), 10 ether + bufferPrior, "the deposit should be added to the buffer");
        // Unpause
        vm.prank(owner);
        adapter.into().unpauseStaking();
        assertEq(
            adapter.into().getCurrentStakeLimit(),
            stakeLimitPrior,
            "current limit should be equal to the limit before pause"
        );
        assertEq(adapter.into().isStakingPaused(), false, "staking should be unpaused");
        testAdapterHasNoFundLeft();
    }

    //////////////////////////////////////////////////////////////////////////////
    // Admin functions
    //////////////////////////////////////////////////////////////////////////////

    function testSetStakingLimit_RevertWhen_NotOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        adapter.into().setStakingLimit({_maxStakeLimit: 1 ether, _stakeLimitIncreasePerBlock: 0.01 ether});
    }

    function testPauseUnPause_RevertWhen_NotOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        adapter.into().pauseStaking();

        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        adapter.into().unpauseStaking();
    }

    function testSetTranche_RevertWhen_NotOwner() public {
        vm.prank(owner);
        adapter.into().setTranche(address(0xbabe));
        assertEq(adapter.into().tranche(), address(0xbabe), "Rebalancer not set correctly");
    }

    function testSetTranche_RevertWhen_AlreadySet() public {
        vm.prank(owner);
        adapter.into().setTranche(address(this));

        vm.prank(owner);
        vm.expectRevert(BaseLSTVault.TrancheAlreadySet.selector);
        adapter.into().setTranche(address(this));
    }

    function testSetRebalancer() public {
        vm.prank(owner);
        adapter.into().setRebalancer(user);
        assertEq(adapter.into().rebalancer(), user, "Rebalancer not set correctly");
    }

    function testSetRebalancer_RevertWhen_NotOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        adapter.into().setRebalancer(user);
    }

    function testSetTargetBufferPercentage() public {
        vm.prank(rebalancer);
        adapter.into().setTargetBufferPercentage(0.1 * 1e18);
        assertEq(adapter.into().targetBufferPercentage(), 0.1 * 1e18, "Buffer not set correctly");
    }

    function testSetTargetBufferPercentage_RevertWhen_InvalidPercentage() public {
        vm.startPrank(rebalancer);
        vm.expectRevert(BaseLSTVault.InvalidBufferPercentage.selector);
        adapter.into().setTargetBufferPercentage(1e18 + 1); // 100%+1
        vm.expectRevert(BaseLSTVault.InvalidBufferPercentage.selector);
        adapter.into().setTargetBufferPercentage(0.0001 * 1e18); // 0.01%
        vm.stopPrank();
    }

    function testSetTargetBufferPercentage_RevertWhen_NotRebalancer() public {
        vm.prank(address(0xabcd));
        vm.expectRevert(BaseLSTVault.NotRebalancer.selector);
        adapter.into().setTargetBufferPercentage(0.1 * 1e18);
    }

    function testDisabledEIP4626Methods() public {
        address account = address(0x123);
        vm.expectRevert(BaseLSTVault.NotImplemented.selector);
        adapter.into().deposit(100, account);

        vm.expectRevert(BaseLSTVault.NotImplemented.selector);
        adapter.into().mint(100, account);

        vm.expectRevert(BaseLSTVault.NotImplemented.selector);
        adapter.into().withdraw(100, account, account);

        vm.expectRevert(BaseLSTVault.NotImplemented.selector);
        adapter.into().redeem(100, account, account);
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

    function _changeTranche(address newTranche) internal {
        stdstore.target(address(adapter)).sig("tranche()").checked_write(newTranche);
    }

    /// @notice helper function to store `bufferEth` state variable
    /// @param bufferEth `bufferEth` to be stored in the adapter contract
    function _storeBufferEth(uint256 bufferEth) internal virtual {
        _fundAdapterUnderlying(bufferEth);
        // bufferEth is packed in the first 128 bits of slot 11
        bytes32 value = bytes32((bufferEth << 128) | adapter.into().totalQueueEth());
        vm.store(address(adapter), bytes32(uint256(11)), value);
        require(adapter.into().bufferEth() == bufferEth, "bufferEth not set correctly");
    }

    /// @notice helper function to store `totalQueueEth` state variable
    /// @param queueEth `totalQueueEth` to be stored in the adapter contract
    function _storeWithdrawalQueueEth(uint256 queueEth) internal virtual {
        // queueEth is packed in the last 128 bits of slot 11
        bytes32 value = bytes32((uint256(adapter.into().bufferEth()) << 128) | queueEth);
        vm.store(address(adapter), bytes32(uint256(11)), value);
        require(adapter.into().totalQueueEth() == queueEth, "totalQueueEth not set correctly");
    }

    /// @notice helper function to get the recorded logs for the target event
    /// @param targetEvent target event to get the recorded logs
    function _getRecordedLogs(bytes32 targetEvent) internal returns (Vm.Log memory eventLog) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == targetEvent) {
                eventLog = entries[i];
                break;
            }
        }
        return eventLog;
    }
}
