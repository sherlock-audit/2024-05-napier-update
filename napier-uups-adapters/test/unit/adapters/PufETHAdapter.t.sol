// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {BaseTestLSTAdapter} from "@napier/v1-tranche-test/unit/adapters/BaseTestLSTAdapter.t.sol";

import {ERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts@4.9.3/proxy/ERC1967/ERC1967Proxy.sol";
import {IPufferVault} from "src/adapters/puffer/interfaces/IPufferVault.sol";
import {IPufferDepositor} from "src/adapters/puffer/interfaces/IPufferDepositor.sol";

import "src/Constants.sol" as Constants;

import {PufETHAdapter} from "src/adapters/puffer/PufETHAdapter.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";

library Cast {
    function into(address x) internal pure returns (PufETHAdapter) {
        return PufETHAdapter(payable(address(x)));
    }
}

contract TestPufETHAdapter is BaseTestLSTAdapter {
    using Cast for *;
    using stdStorage for StdStorage;

    uint256 constant FORKED_AT = 19_675_000;
    uint256 constant MAX_STAKE_LIMIT = 10_000 ether;
    uint256 constant STAKE_LIMIT_INCREASE_PER_BLOCK = 0.00015 ether; // About 1 ether recovery per 1 day

    /// @notice pufETH
    IPufferVault constant PUFETH = IPufferVault(Constants.PUFETH);

    /// @notice Puffer Depositor
    IPufferDepositor constant PUF_DEPOSITOR = IPufferDepositor(Constants.PUF_DEPOSITOR);

    function setUp() public override {
        vm.createSelectFork("mainnet", FORKED_AT);
        super.setUp();
        testAdapterHasNoFundLeft();

        vm.label(Constants.PUFETH, "PUFETH");
        vm.label(Constants.PUF_DEPOSITOR, "PUF_DEPOSITOR");
    }

    function _deployAdapter() internal override {
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
        // Note: Workaround because somehow we got an error when compiling the contract
        assembly {
            sstore(adapter.slot, _adapter)
        }

        underlying = ERC20(Constants.WETH);
        target = ERC20(address(adapter));
        LST = ERC20(Constants.PUFETH);
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
        PufETHAdapter(payable(address(adapter))).initialize(owner, rebalancer, 0, 0);
    }

    function testImplementationInitializer_Revert() public {
        bytes32 _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address implementation = address(uint160(uint256(vm.load(address(adapter), _IMPLEMENTATION_SLOT))));
        address attacker = address(0xbabe);
        vm.expectRevert("Initializable: contract is already initialized");
        PufETHAdapter(payable(implementation)).initialize(attacker, rebalancer, 0, 0);
    }

    ////////////////////////////////////////////////////////////////////////
    // Deposit
    ////////////////////////////////////////////////////////////////////////

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
            PUFETH.convertToAssets(balance),
            (wethFundedAmount * 90) / 100,
            10,
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
}
