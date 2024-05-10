// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SwapBaseTest} from "../shared/Swap.t.sol";

import {Errors} from "src/Errors.sol";
import {ApproxParams} from "@napier/v1-pool/src/interfaces/ApproxParams.sol";
import {IERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/IERC20.sol";

import {MockVault} from "../mocks//MockVault.sol";

function defaultApprox(uint256 eps) pure returns (ApproxParams memory) {
    return ApproxParams({guessMin: 0, guessMax: 0, maxIteration: 100, eps: eps});
}

contract SwapETHForYTTest is SwapBaseTest {
    address flashLoanFeeReceiver = makeAddr("flashLoanFeeReceiver");

    function setUp() public override {
        super.setUp();

        bytes memory constructorArgs = abi.encode(flashLoanFeeReceiver, 0.0001e18); // 0.01%
        deployCodeTo("test/mocks/MockVault.sol:MockVault", constructorArgs, address(vault));

        // Fund some WETH to the vault as liquidity
        deal(address(weth), address(vault), 10_000 ether);

        vm.label(address(vault), "vault");
        _label();

        /// Set up liquidity
        uint256 initialDeposit = 10_000 ether;
        // Issue triLST-PTs and deposit to tricrypto and NapierPool
        vm.startPrank(anny);
        this._triLSTPoolAddLiquidity({wethIn: initialDeposit, spends: [initialDeposit, initialDeposit, initialDeposit]});
        // Issue PT and triLST PTs and deposit to twocrypto
        this._twocryptoMetaAddLiquidity({
            ethToPt: 3 * initialDeposit,
            ethTo3Lst: [initialDeposit, initialDeposit, initialDeposit]
        });

        uint256 price_oracle = twocrypto.price_oracle();
        console2.log("TriLSTPT token price against PT on twocrypto: %e", price_oracle);

        // Default user: alice
        changePrank(alice, alice);
    }

    function test_Swap() public {
        vm.warp(block.timestamp + 99 days);

        _test_SwapETHForYt(
            ReserveFuzzInput({
                ethToNapierPool: 0,
                ethToTriLSTPT: [uint256(0), 0, 0],
                ethToPairPt: 0,
                ethToMetapool: [uint256(0), 0, 0],
                timestamp: block.timestamp
            }),
            U256Input({value: 100 ether}), // 100 YT
            U256Input({value: 0.001e18}) // 0.001 % eps
        );
    }

    function test_Swap_WhenFlashLoanFeeZero() public {
        MockVault(address(vault)).setFlashLoanFeePercentage(0);
        test_Swap();
    }

    // Check we don't have to reset `userData` recorded on transient storage every call because every time router overwrites it
    function test_TransientStorage() public {
        // Prepare
        test_Swap();
        // Execute
        uint256 ytAmount = 8.8 ether;
        uint256 maxEthSpent = (ytAmount * 15) / 10; // 1.5x
        address tsundere = makeAddr("tsundere");

        uint256 _before = gasleft();
        metapoolRouter.swapETHForYt{value: maxEthSpent}(
            address(twocrypto), ytAmount, maxEthSpent, tsundere, block.timestamp, defaultApprox(0.001e18)
        );
        console2.log("gas usage: ", _before - gasleft());

        assertNoFundLeftInRouter();
        assertGe(pairYt.balanceOf(tsundere), ytAmount, "tsundere should get at least `ytAmount` YTs");
    }

    function testFuzz_Swap(ReserveFuzzInput memory input, U256Input memory v, U256Input memory eps)
        public
        boundReserveFuzzInput(input)
        setUpReserves(input)
    {
        v.value = bound(v.value, 1e10 wei, 1000 ether);
        eps.value = bound(eps.value, 0.00001e18, 0.05e18); // 0.00001% to 0.05%
        vm.warp(input.timestamp);

        _test_SwapETHForYt(input, v, eps);
    }

    /// @notice Test 'swapETHForYt' function
    function _test_SwapETHForYt(ReserveFuzzInput memory, U256Input memory v, U256Input memory eps) internal {
        uint256 ytAmount = v.value;
        uint256 balanceBefore = alice.balance;
        uint256 supplyBefore = pairYt.totalSupply();
        // Execute
        uint256 maxEthSpent = (ytAmount * 15) / 10; // 1.5x
        bytes memory data = abi.encodeWithSelector(
            metapoolRouter.swapETHForYt.selector,
            twocrypto,
            ytAmount,
            maxEthSpent,
            bob,
            block.timestamp,
            defaultApprox({eps: eps.value})
        );
        uint256 _before = gasleft();
        (bool s, bytes memory ret) = address(metapoolRouter).call{value: maxEthSpent}(data);
        console2.log("gas usage: ", _before - gasleft());

        if (!s && bytes4(ret) == Errors.MetapoolRouterNonSituationSwapETHForYt.selector) vm.assume(false); // skip
        require(s, "swapETHForYt should succeed");

        uint256 ethSpent = abi.decode(ret, (uint256));
        uint256 supplyIncrease = pairYt.totalSupply() - supplyBefore;

        // Assert that no funds are left in the router
        assertNoFundLeftInRouter();
        assertEq(pairYt.balanceOf(bob), supplyIncrease, "bob should receive the YTs");
        assertGe(pairYt.balanceOf(bob), ytAmount, "bob should get at least `ytAmount` YTs");
        assertApproxEqRel(
            ytAmount, supplyIncrease, eps.value, "bob should receive approximately equal to `ytAmount` YTs"
        );
        // Assert that alice received the remaining ETH
        assertEq(ethSpent, balanceBefore - alice.balance, "alice should consume ETH");
        assertLe(ethSpent, maxEthSpent, "ethSpent should be less than or equal to maxEthSpent");
    }

    function test_RevertIf_DeadlinePassed() public {
        vm.expectRevert(Errors.MetapoolRouterTransactionTooOld.selector);
        metapoolRouter.swapETHForYt(
            address(twocrypto), 100e18, 150e18, bob, block.timestamp - 1, defaultApprox(0.001e18)
        );
    }

    function test_RevertIf_PoolNotExist() public {
        vm.expectRevert(Errors.MetapoolRouterInvalidMetapool.selector);
        metapoolRouter.swapETHForYt(
            address(tricryptoLST), 100e18, 150e18, bob, block.timestamp, defaultApprox(0.001e18)
        );
    }

    function test_RevertIf_SlippageTooHigh() public {
        vm.expectRevert(Errors.MetapoolRouterExceededLimitETHIn.selector);
        metapoolRouter.swapETHForYt{value: 100e18}(
            address(twocrypto), 100e18, 1e18, bob, block.timestamp, defaultApprox(0.001e18)
        );
    }

    function test_RevertIf_Reentrant() public {}

    function test_RevertIf_InsufficientETHRepay() public {
        MockVault(address(vault)).setFlashLoanFeePercentage(0.5e18); // 50%
        vm.expectRevert(Errors.MetapoolRouterInsufficientETHRepay.selector);
        metapoolRouter.swapETHForYt{value: 2e18}(
            address(twocrypto), 1e18, 2e18, bob, block.timestamp, defaultApprox(0.001e18)
        );
    }

    function test_RevertIf_InsufficientETHReceived() public {
        vm.expectRevert(Errors.MetapoolRouterInsufficientETHReceived.selector);
        metapoolRouter.swapETHForYt{value: 1111}(
            address(twocrypto), 1e18, 5e18, bob, block.timestamp, defaultApprox(0.001e18)
        );
    }

    function test_RevertIf_NonSituationSwapETHForYt() public {
        vm.mockCall(
            address(triLSTPool),
            abi.encodeWithSelector(triLSTPool.swapExactBaseLpTokenForUnderlying.selector),
            abi.encode(100e18) // too much WETH received
        );
        vm.expectRevert(Errors.MetapoolRouterNonSituationSwapETHForYt.selector);
        metapoolRouter.swapETHForYt{value: 2e18}(
            address(twocrypto), 1e18, 2e18, bob, block.timestamp, defaultApprox(0.001e18)
        );
    }

    function test_RevertIf_UnauthorizedFlashLoan_When_CallerIsNotVault() public {
        vm.expectRevert(Errors.MetapoolRouterUnauthorized.selector); // caller is not the vault
        metapoolRouter.receiveFlashLoan(new IERC20[](0), new uint256[](100), new uint256[](100), "");
    }

    function test_RevertIf_UnauthorizedFlashLoan_When_InvalidContext() public {
        vm.expectRevert(Errors.MetapoolRouterUnauthorized.selector);
        changePrank(address(vault), address(vault)); // caller is vault but not through `swapETHForYt` function
        metapoolRouter.receiveFlashLoan(new IERC20[](0), new uint256[](100), new uint256[](100), "");
    }

    function test_RevertIf_UnauthorizedFlashLoan_When_InvalidContext_2() public {
        test_Swap();
        // Transient storage should be cleared after the transaction
        test_RevertIf_UnauthorizedFlashLoan_When_InvalidContext();
    }
}
