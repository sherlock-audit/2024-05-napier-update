// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SwapBaseTest} from "../shared/Swap.t.sol";

import {Quoter} from "src/Quoter.sol";

contract QuoteRemoveLiquidityOneETHTest is SwapBaseTest {
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
        deal(alice, 5_000 ether);
        // Get some LP tokens for performing `removeLiquidityOneETH`
        metapoolRouter.addLiquidityOneETHKeepYt{value: 4_000 ether}({
            metapool: address(twocrypto),
            minLiquidity: 1,
            recipient: alice,
            deadline: block.timestamp
        });
        approve(twocrypto, address(metapoolRouter), type(uint256).max);
    }

    function test_Quote() public {
        vm.warp(block.timestamp + 99 days);

        _test_QuoteRemoveLiquidityOneETH(
            ReserveFuzzInput({
                ethToNapierPool: 0,
                ethToTriLSTPT: [uint256(0), 0, 0],
                ethToPairPt: 0,
                ethToMetapool: [uint256(0), 0, 0],
                timestamp: block.timestamp
            }),
            U256Input({value: 10 ether}) // 10 liquidity tokens
        );
    }

    function testFuzz_Quote(ReserveFuzzInput memory input, U256Input memory v)
        public
        boundReserveFuzzInput(input)
        setUpReserves(input)
    {
        v.value = bound(v.value, 1e10 wei, twocrypto.balanceOf(alice));
        vm.warp(input.timestamp);

        _test_QuoteRemoveLiquidityOneETH(input, v);
    }

    /// @notice Test 'quoteRemoveLiquidityOneETH' function
    function _test_QuoteRemoveLiquidityOneETH(ReserveFuzzInput memory, U256Input memory v) internal {
        uint256 liquidity = v.value;
        // Prepare
        uint256 snapshot = vm.snapshot();
        bytes memory data = abi.encodeCall(
            metapoolRouter.removeLiquidityOneETH, (address(twocrypto), liquidity, 0, bob, block.timestamp)
        );
        (bool s, bytes memory ret) = address(metapoolRouter).call(data);
        vm.assume(s); // Skip if the tx fails

        uint256 ethOut = abi.decode(ret, (uint256)); // Get the actual value
        vm.revertTo(snapshot); // Revert to the state before the swap

        // Execute
        (bool suc, bytes memory retdata) = quoter.staticcall(
            abi.encodeWithSelector(Quoter.quoteRemoveLiquidityOneETH.selector, twocrypto, triLSTPool, liquidity)
        );
        (uint256 estimateEthOut) = abi.decode(retdata, (uint256)); // Get the estimate
        assertEq(suc, true, "quoteRemoveLiquidityOneETH should succeed if the removeLiquidityOneETH succeeds");
        assertApproxEqRel(
            estimateEthOut,
            ethOut,
            0.001e18, // 0.1%
            "Estimate should be equal to the actual value of ethOut"
        );
    }
}
