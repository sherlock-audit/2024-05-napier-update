// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SwapBaseTest} from "../shared/Swap.t.sol";

import {Errors} from "src/Errors.sol";

contract SwapPTForETHTest is SwapBaseTest {
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
        approve(pairPt, address(metapoolRouter), type(uint256).max);
        deal(address(pairPt), alice, 1_000 ether);
    }

    function test_Swap() public {
        vm.warp(block.timestamp + 99 days);
        uint256 ptAmount = 10 ether;
        uint256 ethOut = _test_SwapPtForETH(
            ReserveFuzzInput({
                ethToNapierPool: 0,
                ethToTriLSTPT: [uint256(0), 0, 0],
                ethToPairPt: 0,
                ethToMetapool: [uint256(0), 0, 0],
                timestamp: block.timestamp
            }),
            U256Input({value: ptAmount})
        );
        // Sanity check: in most cases the price of PT should be dicounted against underlying assets
        assertGe(ptAmount, ethOut, "PT should be discounted against ETH");
    }

    /// @notice Fuzz test case for 'swapPtForETH' function
    function testFuzz_Swap(ReserveFuzzInput memory input, U256Input memory v)
        public
        boundReserveFuzzInput(input)
        setUpReserves(input)
    {
        v.value = bound(v.value, 1e10 wei, 10 ether);
        vm.warp(input.timestamp);

        _test_SwapPtForETH(input, v);
    }

    /// @notice Test 'swapPtForETH' function
    function _test_SwapPtForETH(ReserveFuzzInput memory input, U256Input memory v) internal returns (uint256 ethOut) {
        uint256 ptAmount = v.value;
        uint256 minEthOut = ptAmount / 10;

        // Execute
        uint256 _before = gasleft();
        ethOut = metapoolRouter.swapPtForETH({
            metapool: address(twocrypto),
            ptAmount: ptAmount,
            minEthOut: minEthOut,
            recipient: bob,
            deadline: input.timestamp
        });
        console2.log("gas usage: ", _before - gasleft());

        // Assert that no funds are left in the router
        assertNoFundLeftInRouter();
        // Assert that bob received the expected ETH amount
        assertEq(bob.balance, ethOut, "bob should receive ETH");
        // Assert that the received ETH amount is greater than or equal to the minimum specified
        assertGe(ethOut, minEthOut, "ethOut should be greater than or equal to minEthOut");
    }

    function test_RevertIf_DeadlinePassed() public {
        vm.expectRevert(Errors.MetapoolRouterTransactionTooOld.selector);
        metapoolRouter.swapPtForETH(address(twocrypto), 100e18, 100e18, bob, block.timestamp - 1);
    }

    function test_RevertIf_PoolNotExist() public {
        vm.expectRevert(Errors.MetapoolRouterInvalidMetapool.selector);
        metapoolRouter.swapPtForETH(address(triLSTPool), 100e18, 100e18, bob, block.timestamp);
    }

    function test_RevertIf_SlippageTooHigh() public {
        vm.expectRevert(Errors.MetapoolRouterInsufficientETHOut.selector);
        metapoolRouter.swapPtForETH(address(twocrypto), 100e18, 1000e18, bob, block.timestamp);
    }

    function test_RevertIf_Reentrant() public {}
}
