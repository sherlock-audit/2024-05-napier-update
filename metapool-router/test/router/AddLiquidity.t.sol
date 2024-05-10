// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SwapBaseTest} from "../shared/Swap.t.sol";

import {Errors} from "src/Errors.sol";

contract AddLiquidityTest is SwapBaseTest {
    uint256 constant _IS_APPROVED_SLOT_SEED = 0xa8fe4407;

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

    function test_addLiquidity() public {
        vm.warp(block.timestamp + 99 days);
        uint256 ptAmount = 10 ether;
        _test_AddLiquidity(
            ReserveFuzzInput({
                ethToNapierPool: 0,
                ethToTriLSTPT: [uint256(0), 0, 0],
                ethToPairPt: 0,
                ethToMetapool: [uint256(0), 0, 0],
                timestamp: block.timestamp
            }),
            U256Input({value: ptAmount})
        );
        bytes32 slotA = keccak256(abi.encodePacked(weth, uint64(0), uint32(_IS_APPROVED_SLOT_SEED), pairPt));
        assertEq(vm.load(address(metapoolRouter), slotA), bytes32(uint256(1)), "isApproval slot should be set to 1");
        bytes32 slotB = keccak256(abi.encodePacked(pairPt, uint64(0), uint32(_IS_APPROVED_SLOT_SEED), twocrypto));
        assertEq(vm.load(address(metapoolRouter), slotB), bytes32(uint256(1)), "isApproval slot should be set to 1");
    }

    /// @notice Fuzz test case for 'addLiquidityOneETHKeepYt' function
    function testFuzz_AddLiquidity(ReserveFuzzInput memory input, U256Input memory v)
        public
        boundReserveFuzzInput(input)
        setUpReserves(input)
    {
        v.value = bound(v.value, 1e10 wei, 10000 ether);
        vm.warp(input.timestamp);

        _test_AddLiquidity(input, v);
    }

    /// @notice Test 'addLiquidityOneETHKeepYt' function
    function _test_AddLiquidity(ReserveFuzzInput memory input, U256Input memory v) internal {
        uint256 ethIn = v.value;
        uint256 minLiquidity = ethIn / 10;
        uint256 supply = pairYt.totalSupply();
        // Execute
        uint256 _before = gasleft();
        uint256 liquidity = metapoolRouter.addLiquidityOneETHKeepYt{value: ethIn}({
            metapool: address(twocrypto),
            minLiquidity: minLiquidity,
            recipient: bob,
            deadline: input.timestamp
        });
        console2.log("gas usage: ", _before - gasleft());

        // Assert that no funds are left in the router
        assertNoFundLeftInRouter();
        // Assert that bob received the expected LP tokens and YTs
        assertEq(twocrypto.balanceOf(bob), liquidity, "bob should receive LP tokens");
        assertEq(pairYt.balanceOf(bob), pairYt.totalSupply() - supply, "bob should receive YTs");
        // Assert that the received ETH amount is greater than or equal to the minimum specified
        assertGe(liquidity, minLiquidity, "liquidity should be greater than or equal to minLiqudity");
    }

    function test_RevertIf_DeadlinePassed() public {
        vm.expectRevert(Errors.MetapoolRouterTransactionTooOld.selector);
        metapoolRouter.addLiquidityOneETHKeepYt{value: 100 ether}(address(twocrypto), 1e18, bob, block.timestamp - 1);
    }

    function test_RevertIf_PoolNotExist() public {
        vm.expectRevert(Errors.MetapoolRouterInvalidMetapool.selector);
        metapoolRouter.addLiquidityOneETHKeepYt{value: 100 ether}(address(triLSTPool), 1e18, bob, block.timestamp);
    }

    function test_RevertIf_SlippageTooHigh() public {
        vm.expectRevert(); // Twocrypto revert without error message
        metapoolRouter.addLiquidityOneETHKeepYt{value: 100 ether}(address(twocrypto), 1000e18, bob, block.timestamp);
    }

    function test_RevertIf_Reentrant() public {}
}
