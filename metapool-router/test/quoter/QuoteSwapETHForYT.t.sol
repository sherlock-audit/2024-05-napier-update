// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SwapBaseTest} from "../shared/Swap.t.sol";

import {MockVault} from "../mocks/MockVault.sol"; // Need import statement, otherwise get error: "No matching artifacts found"
import {ApproxParams} from "@napier/v1-pool/src/interfaces/ApproxParams.sol";
import {IProtocolFeesCollector} from "src/interfaces/external/balancer/IProtocolFeesCollector.sol";

import {Quoter} from "src/Quoter.sol";

function defaultApprox(uint256 eps) pure returns (ApproxParams memory) {
    return ApproxParams({guessMin: 0, guessMax: 0, maxIteration: 100, eps: eps});
}

contract MockProtocolFeesCollector is IProtocolFeesCollector {
    function getFlashLoanFeePercentage() external pure override returns (uint256) {
        return 0.0001e18; // 0.01%
    }
}

contract QuoteSwapETHForYTTest is SwapBaseTest {
    MockProtocolFeesCollector flashLoanFeeReceiver = new MockProtocolFeesCollector();

    function setUp() public override {
        super.setUp();

        bytes memory constructorArgs =
            abi.encode(flashLoanFeeReceiver, flashLoanFeeReceiver.getFlashLoanFeePercentage());
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

    function test_Quote() public {
        vm.warp(block.timestamp + 99 days);

        _test_QuoteSwapETHForYt(
            ReserveFuzzInput({
                ethToNapierPool: 0,
                ethToTriLSTPT: [uint256(0), 0, 0],
                ethToPairPt: 0,
                ethToMetapool: [uint256(0), 0, 0],
                timestamp: block.timestamp
            }),
            U256Input({value: 10 ether}), // 10 YT
            U256Input({value: 0.001e18}) // 0.001 % eps
        );
    }

    function testFuzz_Quote(ReserveFuzzInput memory input, U256Input memory v, U256Input memory eps)
        public
        boundReserveFuzzInput(input)
        setUpReserves(input)
    {
        v.value = bound(v.value, 1e10 wei, 1000 ether);
        eps.value = bound(eps.value, 0.00001e18, 0.01e18); // 0.00001% to 0.01%
        vm.warp(input.timestamp);

        _test_QuoteSwapETHForYt(input, v, eps);
    }

    /// @notice Test 'quoteSwapETHForYt' function
    function _test_QuoteSwapETHForYt(ReserveFuzzInput memory, U256Input memory v, U256Input memory eps) internal {
        uint256 ytAmount = v.value;
        uint256 balance = pairYt.balanceOf(bob);

        // Prepare
        uint256 snapshot = vm.snapshot();
        bytes memory data = abi.encodeWithSelector(
            metapoolRouter.swapETHForYt.selector,
            twocrypto,
            ytAmount,
            (ytAmount * 15) / 10,
            bob,
            block.timestamp,
            defaultApprox({eps: eps.value})
        );
        (bool s, bytes memory ret) = address(metapoolRouter).call{value: type(uint96).max}(data);
        vm.assume(s); // Skip if the swap fails

        uint256 ethSpent = abi.decode(ret, (uint256));
        uint256 actualYtAmount = pairYt.balanceOf(bob) - balance;

        vm.revertTo(snapshot); // Revert to the state before the swap

        // Execute
        (bool suc, bytes memory retdata) = quoter.call(
            abi.encodeWithSignature(
                "quoteSwapETHForYt(address,address,uint256,(uint256,uint256,uint256,uint256))",
                twocrypto,
                triLSTPool,
                ytAmount,
                defaultApprox({eps: eps.value})
            )
        );
        (uint256 estimateSpent, /* uint256 depositGuess */ ) = abi.decode(retdata, (uint256, uint256));
        assertEq(suc, true, "quoteSwapETHForYt should succeed if the swap succeeds");
        assertApproxEqRel(
            estimateSpent,
            ethSpent,
            0.01e18, // 1%
            "Estimated ETH spent should be less than or equal to actual ETH spent"
        );
        assertGe(actualYtAmount, ytAmount, "bob should get at least `ytAmount` YTs");
    }
}
