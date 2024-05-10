// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SwapBaseTest} from "../shared/Swap.t.sol";

import {Quoter} from "src/Quoter.sol";

contract QuoteSwapETHForPTTest is SwapBaseTest {
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

    function test_Quote() public {
        vm.warp(block.timestamp + 99 days);

        _test_QuoteSwapETHForPt(
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

        _test_QuoteSwapETHForPt(input, v);
    }

    /// @notice Test 'quoteSwapETHForYt' function
    function _test_QuoteSwapETHForPt(ReserveFuzzInput memory, U256Input memory v) internal {
        uint256 ptAmount = v.value;

        // Prepare
        uint256 snapshot = vm.snapshot();
        bytes memory data = abi.encodeWithSelector(
            metapoolRouter.swapETHForPt.selector, twocrypto, ptAmount, type(uint96).max, 0, bob, block.timestamp
        );
        (bool s, bytes memory ret) = address(metapoolRouter).call{value: type(uint96).max}(data);
        vm.assume(s); // Skip if the swap fails

        uint256 ethSpent = abi.decode(ret, (uint256));

        vm.revertTo(snapshot); // Revert to the state before the swap

        // Execute
        (bool suc, bytes memory retdata) =
            quoter.call(abi.encodeWithSelector(Quoter.quoteSwapETHForPt.selector, twocrypto, triLSTPool, ptAmount));
        (uint256 estimateSpent) = abi.decode(retdata, (uint256));
        assertEq(suc, true, "quoteSwapETHForPt should succeed if the swap succeeds");
        assertApproxEqRel(
            estimateSpent,
            ethSpent,
            0.0001e18, // 0.01%
            "Estimated ETH spent should be less than or equal to actual ETH spent"
        );
    }
}
