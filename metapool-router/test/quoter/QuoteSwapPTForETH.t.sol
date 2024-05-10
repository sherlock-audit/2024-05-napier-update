// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SwapBaseTest} from "../shared/Swap.t.sol";

import {Quoter} from "src/Quoter.sol";

contract QuoteSwapPTForETHTest is SwapBaseTest {
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

    function test_Quote() public {
        vm.warp(block.timestamp + 99 days);

        _test_QuoteSwapPtForETH(
            ReserveFuzzInput({
                ethToNapierPool: 0,
                ethToTriLSTPT: [uint256(0), 0, 0],
                ethToPairPt: 0,
                ethToMetapool: [uint256(0), 0, 0],
                timestamp: block.timestamp
            }),
            U256Input({value: 10 ether}) // 10 YT
        );
    }

    function testFuzz_Quote(ReserveFuzzInput memory input, U256Input memory v)
        public
        boundReserveFuzzInput(input)
        setUpReserves(input)
    {
        v.value = bound(v.value, 1e10 wei, 1000 ether);
        vm.warp(input.timestamp);

        _test_QuoteSwapPtForETH(input, v);
    }

    /// @notice Test 'quoteSwapPtForETH' function
    function _test_QuoteSwapPtForETH(ReserveFuzzInput memory, U256Input memory v) internal {
        uint256 ptAmount = v.value;

        // Prepare
        uint256 snapshot = vm.snapshot();
        bytes memory data =
            abi.encodeWithSelector(metapoolRouter.swapPtForETH.selector, twocrypto, ptAmount, 0, bob, block.timestamp);
        (bool s, bytes memory ret) = address(metapoolRouter).call(data);
        vm.assume(s); // Skip if the swap fails

        uint256 ethOut = abi.decode(ret, (uint256));

        vm.revertTo(snapshot); // Revert to the state before the swap

        // Execute
        (bool suc, bytes memory retdata) = quoter.staticcall(
            abi.encodeWithSelector(Quoter.quoteSwapPtForETH.selector, twocrypto, triLSTPool, ptAmount)
        );
        (uint256 estimateEthOut) = abi.decode(retdata, (uint256));
        assertEq(suc, true, "quoteSwapPtForETH should succeed if the swap succeeds");
        assertApproxEqRel(
            estimateEthOut,
            ethOut,
            0.0001e18, // 0.01%
            "Estimated amount should be less than or equal to actual ETH received"
        );
    }
}
