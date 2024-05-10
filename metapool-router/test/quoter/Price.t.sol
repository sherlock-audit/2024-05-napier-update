// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SwapBaseTest} from "../shared/Swap.t.sol";

import {Quoter} from "src/Quoter.sol";

contract QuotePriceTest is SwapBaseTest {
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

        _test_QuotePrice(
            ReserveFuzzInput({
                ethToNapierPool: 0,
                ethToTriLSTPT: [uint256(0), 0, 0],
                ethToPairPt: 0,
                ethToMetapool: [uint256(0), 0, 0],
                timestamp: block.timestamp
            })
        );
    }

    function testFuzz_Quote(ReserveFuzzInput memory input) public boundReserveFuzzInput(input) setUpReserves(input) {
        vm.warp(input.timestamp);

        _test_QuotePrice(input);
    }

    /// @notice Test 'quotePtPrice' function
    function _test_QuotePrice(ReserveFuzzInput memory) internal {
        uint256 ptAmount = 1e8; // small amount
        // Prepare
        uint256 snapshot = vm.snapshot();
        bytes memory data =
            abi.encodeWithSelector(metapoolRouter.swapPtForETH.selector, twocrypto, ptAmount, 0, bob, block.timestamp);
        (bool s, bytes memory ret) = address(metapoolRouter).call(data);
        vm.assume(s); // Skip if the swap fails

        uint256 ethOut = abi.decode(ret, (uint256));

        // Execute
        uint256 price_after = Quoter(quoter).quotePtPrice(address(twocrypto), address(triLSTPool));
        vm.revertTo(snapshot); // Revert to the state before the swap
        uint256 price_before = Quoter(quoter).quotePtPrice(address(twocrypto), address(triLSTPool));

        assertApproxEqRel(
            (price_before + price_after) / 2, // average spot price before and after the swap
            ethOut * 1e18 / ptAmount, // effective price
            0.1e18, // 10% tolerance
            "Effective PT price should be equal to the PT price quoted by the Quoter contract"
        );
    }
}
