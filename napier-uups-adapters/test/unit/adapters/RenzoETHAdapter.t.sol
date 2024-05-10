// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {BaseTestLSTAdapter} from "@napier/v1-tranche-test/unit/adapters/BaseTestLSTAdapter.t.sol";
import {BaseLSTVault} from "@napier/v1-tranche/adapters/BaseLSTVault.sol";

import {ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts@4.9.3/proxy/ERC1967/ERC1967Proxy.sol";
import {IRenzoRestakeManager} from "src/adapters/renzo/interfaces/IRenzoRestakeManager.sol";
import {IRateProvider} from "src/adapters/renzo/interfaces/IRateProvider.sol";

import {IBaseAdapter} from "@napier/v1-tranche/interfaces/IBaseAdapter.sol";
import {BaseAdapter} from "@napier/v1-tranche/BaseAdapter.sol";

import "src/Constants.sol" as Constants;

import {RenzoAdapter} from "src/adapters/renzo/RenzoAdapter.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";

library Cast {
    function into(address x) internal pure returns (RenzoAdapter) {
        return RenzoAdapter(payable(address(x)));
    }
}

contract TestRenzoETHAdapter is BaseTestLSTAdapter {
    using Cast for *;
    using stdStorage for StdStorage;

    uint256 constant FORKED_AT = 19_675_000;
    uint256 constant MAX_STAKE_LIMIT = 10_000 ether;
    uint256 constant STAKE_LIMIT_INCREASE_PER_BLOCK = 0.00015 ether; // About 1 ether recovery per 1 day

    /// @notice Renzo Depositor
    IRenzoRestakeManager constant RENZO_RESTAKE_MANAGER = IRenzoRestakeManager(Constants.RENZO_RESTAKE_MANAGER);

    IRateProvider constant RATE_PROVIDER = IRateProvider(Constants.RENZO_RATE_PROVIDER);

    modifier boundPrefundedDepositParams(PrefundedDepositParams memory params) override {
        params.underlyingIn = bound(params.underlyingIn, 1 ether, 1_000_000 ether);
        _;
    }

    function setUp() public override {
        vm.createSelectFork("mainnet", FORKED_AT);
        super.setUp();
        testAdapterHasNoFundLeft();

        vm.label(Constants.EZETH, "EZETH");
        vm.label(Constants.RENZO_RESTAKE_MANAGER, "RenzoRestakeManager");
    }

    function _deployAdapter() internal override {
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
        // Note: Workaround because somehow we got an error when compiling the contract
        assembly {
            sstore(adapter.slot, _adapter)
        }

        underlying = ERC20(Constants.WETH);
        target = ERC20(address(adapter));
        LST = ERC20(Constants.EZETH);
    }

    function testScale() public override {
        // when totalSupply is 0, scale should be 1e18
        assertEq(adapter.scale(), 1e18, "scale should be 1e18 when total supply is 0");
    }

    ////////////////////////////////////////////////////////////////////////
    // Proxy
    ////////////////////////////////////////////////////////////////////////

    function testProxyInitializer_RevertAfter_Initialize_Called() public {
        vm.expectRevert("Initializable: contract is already initialized");
        RenzoAdapter(payable(address(adapter))).initialize(owner, rebalancer, 0, 0);
    }

    function testImplementationInitializer_Revert() public {
        bytes32 _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address implementation = address(uint160(uint256(vm.load(address(adapter), _IMPLEMENTATION_SLOT))));
        address attacker = address(0xbabe);
        vm.expectRevert("Initializable: contract is already initialized");
        RenzoAdapter(payable(implementation)).initialize(attacker, rebalancer, 0, 0);
    }

    ////////////////////////////////////////////////////////////////////////
    // Deposit
    ////////////////////////////////////////////////////////////////////////

    function testPrefundedDeposit() public override {
        // setup
        // The stake amount is caped at 95% of the available ETH at the time of the stake.
        // Target buffer is 10% of the total value of the adapter.

        // transfer WETH to the adapter contract prior as it would be done by Tranche
        uint256 wethFundedAmount = 1 ether;
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
            address(adapter).into().bufferPresentPercentage(),
            0.1 * 1e18,
            0.0001 * 1e18, // 0.01% tolerance
            "present buffer percentage should be 10%"
        );
        assertApproxEqAbs(
            address(adapter).into().bufferEth(),
            wethFundedAmount / 10,
            10,
            "bufferEth should be 10% of WETH funded"
        );
        uint256 balance = LST.balanceOf(address(adapter));
        assertApproxEqAbs(
            (balance * RATE_PROVIDER.getRate()) / 1e18,
            (wethFundedAmount * 90) / 100,
            938037,
            "amount of LST minted should be 90% of WETH funded"
        );
    }

    function testPrefundedDeposit_Zero() public override {
        vm.prank(address(adapter).into().tranche());
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

    function testClaimWithdrawal_RevertWhen_NoPendingWithdrawal() public pure override {}

    function testClaimWithdrawal() public pure override {}

    function testRequestWithdrawal() public pure override {}

    function testRequestWithdrawalAll() public pure override {}

    function testRequestWithdrawalAll_RevertWhen_NotRebalancer() public pure override {}

    function testRequestWithdrawal_RevertWhen_NotRebalancer() public pure override {}

    function testRequestWithdrawal_RevertWhen_BufferTooLarge() public pure override {}

    /// @dev keccak256(abi.encode(uint256(keccak256("napier.adapter.lst")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant LST_ADAPTER_STORAGE_LOCATION = 0xf38a73bc4b2ec3cca65ebfd6e5f091d1a7d7926bf27004d09fdee655c28c5400;

    /// @notice helper function to store `bufferEth` state variable
    /// @param bufferEth `bufferEth` to be stored in the adapter contract
    function _storeBufferEth(uint256 bufferEth) internal override {
        _fundAdapterUnderlying(bufferEth);
        bytes32 value = bytes32((bufferEth << 128) | address(adapter).into().totalQueueEth());
        vm.store(address(adapter), bytes32(uint256(LST_ADAPTER_STORAGE_LOCATION) + 3), value);
        require(address(adapter).into().bufferEth() == bufferEth, "bufferEth not set correctly");
    }

    /// @notice helper function to store `totalQueueEth` state variable
    /// @param queueEth `totalQueueEth` to be stored in the adapter contract
    function _storeWithdrawalQueueEth(uint256 queueEth) internal override {
        bytes32 value = bytes32((uint256(address(adapter).into().bufferEth()) << 128) | queueEth);
        vm.store(address(adapter), bytes32(uint256(LST_ADAPTER_STORAGE_LOCATION) + 3), value);
        require(address(adapter).into().totalQueueEth() == queueEth, "totalQueueEth not set correctly");
    }

    /// forge-config: default.fuzz.runs = 4000
    /// @notice Round-trip test for deposit and redeem.
    /// @dev Redeeming the minted shares immediately must not benefit the user.
    function testFuzz_RT_DepositRedeem(
        uint256 withdrawalQueueEth,
        uint256 initialDeposit,
        uint256 wethDeposit
    ) public override {
        // Setup
        withdrawalQueueEth = bound(withdrawalQueueEth, 1 ether, 100_000 ether);
        initialDeposit = bound(initialDeposit, 10 ether, 100_000 ether);
        wethDeposit = bound(wethDeposit, 100 ether, 100_000 ether);
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
        vm.assume(address(adapter).into().bufferEth() >= address(adapter).into().previewRedeem(shares));

        // 2. immediately redeem the minted shares
        address(adapter).into().transfer(address(adapter), shares);
        (uint256 wethWithdrawn, uint256 sharesRedeemed) = adapter.prefundedRedeem(user);

        assertEq(sharesRedeemed, shares, "Shares redeemed should be equal to shares minted");
        assertLe(wethWithdrawn, wethDeposit, "WETH withdrawn should be less than or equal to WETH deposited");
    }
}
