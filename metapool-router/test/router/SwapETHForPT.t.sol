// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SwapBaseTest} from "../shared/Swap.t.sol";

import {Errors} from "src/Errors.sol";

contract SwapETHForPTTest is SwapBaseTest {
    function setUp() public override {
        super.setUp();
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

        _test_SwapETHForPt(
            ReserveFuzzInput({
                ethToNapierPool: 0,
                ethToTriLSTPT: [uint256(0), 0, 0],
                ethToPairPt: 0,
                ethToMetapool: [uint256(0), 0, 0],
                timestamp: block.timestamp
            }),
            U256Input({value: 10 ether}) // 10 PT
        );
    }

    function testFuzz_Swap(ReserveFuzzInput memory input, U256Input memory v)
        public
        boundReserveFuzzInput(input)
        setUpReserves(input)
    {
        v.value = bound(v.value, 1e10 wei, 1000 ether);
        vm.warp(input.timestamp);

        _test_SwapETHForPt(input, v);
    }

    /// @notice Test 'swapETHForPt' function
    function _test_SwapETHForPt(ReserveFuzzInput memory, U256Input memory v) internal {
        uint256 ptAmount = v.value;
        uint256 balanceBefore = alice.balance;
        uint256 reserveBefore = pairPt.balanceOf(address(twocrypto));
        // Execute
        uint256 maxEthSpent = (ptAmount * 15) / 10; // 1.5x
        uint256 minOut = (ptAmount * 0.99999e18) / 1e18; // 0.001% slippage
        uint256 _before = gasleft();
        uint256 ethSpent = metapoolRouter.swapETHForPt{value: maxEthSpent}({
            metapool: address(twocrypto),
            ptAmount: ptAmount,
            minPtOut: minOut,
            maxEthSpent: maxEthSpent,
            recipient: bob,
            deadline: block.timestamp
        });
        console2.log("gas usage: ", _before - gasleft());
        uint256 actualPtOut = reserveBefore - pairPt.balanceOf(address(twocrypto));

        // Assert that no funds are left in the router
        assertNoFundLeftInRouter();
        assertEq(pairPt.balanceOf(bob), actualPtOut, "bob should receive the PTs");
        assertGe(actualPtOut, minOut, "actualPtOut should be greater than or equal to min");
        // Assert that alice received the remaining ETH
        assertEq(ethSpent, balanceBefore - alice.balance, "alice should receive the remaining ETH");
        assertLe(ethSpent, maxEthSpent, "ethSpent should be less than or equal to maxEthSpent");
    }

    function test_RevertIf_DeadlinePassed() public {
        vm.expectRevert(Errors.MetapoolRouterTransactionTooOld.selector);
        metapoolRouter.swapETHForPt{value: 100 ether}(
            address(twocrypto), 100e18, 150e18, 100e18, bob, block.timestamp - 1
        );
    }

    function test_RevertIf_PoolNotExist() public {
        vm.expectRevert(Errors.MetapoolRouterInvalidMetapool.selector);
        metapoolRouter.swapETHForPt{value: 100 ether}(
            address(tricryptoLST), 100e18, 150e18, 100e18, bob, block.timestamp
        );
    }

    function test_RevertIf_SlippageTooHigh() public {
        vm.expectRevert(Errors.MetapoolRouterExceededLimitETHIn.selector);
        metapoolRouter.swapETHForPt{value: 1000 ether}(address(twocrypto), 100e18, 10e18, 95e18, bob, block.timestamp);
    }

    function test_RevertIf_InsufficientETHReceived() public {
        vm.expectRevert(Errors.MetapoolRouterInsufficientETHReceived.selector);
        metapoolRouter.swapETHForPt{value: 1 ether}(address(twocrypto), 100e18, 10e18, 95e18, bob, block.timestamp);
    }

    function test_RevertIf_Reentrant() public {}
}
