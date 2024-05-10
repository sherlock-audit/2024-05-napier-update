// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SwapBaseTest} from "../shared/Swap.t.sol";

import {Errors} from "src/Errors.sol";

contract RemoveLiquidityOneETHTest is SwapBaseTest {
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
        metapoolRouter.addLiquidityOneETHKeepYt{value: 2_000 ether}({
            metapool: address(twocrypto),
            minLiquidity: 1,
            recipient: alice,
            deadline: block.timestamp
        });
        approve(twocrypto, address(metapoolRouter), type(uint256).max);
    }

    function test_RemoveLiquidity_BeforeMaturity() public {
        vm.warp(block.timestamp + 99 days);
        uint256 liquidity = twocrypto.balanceOf(alice) / 100;
        _test_RemoveLiquidity(
            ReserveFuzzInput({
                ethToNapierPool: 0,
                ethToTriLSTPT: [uint256(0), 0, 0],
                ethToPairPt: 0,
                ethToMetapool: [uint256(0), 0, 0],
                timestamp: block.timestamp
            }),
            U256Input({value: liquidity})
        );
    }

    function test_RemoveLiquidity_AfterMaturity() public {
        vm.warp(maturity + 1 days);
        uint256 liquidity = twocrypto.balanceOf(alice) / 100;
        _test_RemoveLiquidity(
            ReserveFuzzInput({
                ethToNapierPool: 0,
                ethToTriLSTPT: [uint256(0), 0, 0],
                ethToPairPt: 0,
                ethToMetapool: [uint256(0), 0, 0],
                timestamp: block.timestamp
            }),
            U256Input({value: liquidity})
        );
    }

    /// @notice Fuzz test case for 'RemoveLiquidityOneETH' function
    function testFuzz_RemoveLiquidity(ReserveFuzzInput memory input, U256Input memory v)
        public
        boundReserveFuzzInput(input)
        setUpReserves(input)
    {
        v.value = bound(v.value, 1e10 wei, twocrypto.balanceOf(alice));
        vm.warp(input.timestamp);

        _test_RemoveLiquidity(input, v);
    }

    /// @notice Test 'RemoveLiquidityOneETH' function
    function _test_RemoveLiquidity(ReserveFuzzInput memory input, U256Input memory v) internal {
        uint256 liquidity = v.value;
        uint256 minEthOut = 100 wei;
        // Execute
        if (block.timestamp >= maturity) {
            vm.expectCall({callee: address(pairPt), data: abi.encodeWithSelector(pairPt.redeem.selector)});
        }
        uint256 _before = gasleft();
        uint256 ethOut = metapoolRouter.removeLiquidityOneETH({
            metapool: address(twocrypto),
            liquidity: liquidity,
            minEthOut: minEthOut,
            recipient: bob,
            deadline: input.timestamp
        });
        console2.log("gas usage: ", _before - gasleft());

        // Assert that no funds are left in the router
        assertNoFundLeftInRouter();
        // Assert that bob received the withdrawn ETH.
        assertEq(bob.balance, ethOut, "bob should receive ETH");
        // Assert that the received ETH amount is greater than or equal to the minimum specified
        assertGe(ethOut, minEthOut, "ETH out should be greater than or equal to minEthOut");
    }

    function test_RevertIf_DeadlinePassed() public {
        vm.expectRevert(Errors.MetapoolRouterTransactionTooOld.selector);
        metapoolRouter.removeLiquidityOneETH(address(twocrypto), 1e18, 100, bob, block.timestamp - 1);
    }

    function test_RevertIf_PoolNotExist() public {
        vm.expectRevert(Errors.MetapoolRouterInvalidMetapool.selector);
        metapoolRouter.removeLiquidityOneETH(address(triLSTPool), 1e18, 10000, bob, block.timestamp);
    }

    function test_RevertIf_SlippageTooHigh() public {
        vm.expectRevert(Errors.MetapoolRouterInsufficientETHOut.selector);
        metapoolRouter.removeLiquidityOneETH(address(twocrypto), 1e18, 100e18, bob, block.timestamp);
    }

    function test_RevertIf_Reentrant() public {}
}
