// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Base} from "../Base.t.sol";

import {CallbackInputType, AddLiquidityInput} from "@napier/v1-pool/test/shared/CallbackInputType.sol";

abstract contract SwapBaseTest is Base {
    //// Abstract Test Functions ////

    // function test_RevertIf_DeadlinePassed() public virtual;

    // function test_RevertIf_PoolNotExist() public virtual;

    // function test_RevertIf_SlippageTooHigh() public virtual;

    // function test_RevertIf_Reentrant() public virtual;

    //// Fuzz Utilities ////

    /// @notice Struct for fuzzing input values
    /// @notice ethToNapierPool Amount of ETH to deposit to 3LST-PT<>ETH NapierPool
    /// @notice ethToTriLSTPT Amount of ETH spent to issue 3LST-PTs and held by 3LST-PT<>ETH Napier Pool
    /// @notice ethToPairPt Amount of ETH spent to issue twocrypto.coins(0) PT and held by the twocrypto
    /// @notice ethToMetapool Amount of ETH spent to issue 3LST-PTs and held by the twocrypto metapool
    struct ReserveFuzzInput {
        uint256 ethToNapierPool;
        uint256[3] ethToTriLSTPT;
        uint256 ethToPairPt;
        uint256[3] ethToMetapool;
        uint256 timestamp;
    }

    /// @notice Modifier to bound the input values for random reserves fuzzing
    modifier boundReserveFuzzInput(ReserveFuzzInput memory input) {
        input.ethToNapierPool = _bound(input.ethToNapierPool, 1 ether, 100_000 ether);
        input.ethToTriLSTPT = _bound(input.ethToTriLSTPT, 1 ether, 100_000 ether);
        input.ethToPairPt = _bound(input.ethToPairPt, 1e10 wei, 1_000 ether);
        input.ethToMetapool = _bound(input.ethToMetapool, 1e10 wei, 1_000 ether);
        input.timestamp = _bound(input.timestamp, block.timestamp, maturity - 1); // timestamp [block.timestamp, maturity - 1]
        _;
    }

    /// @notice Modifier to set up reserves for fuzzing
    modifier setUpReserves(ReserveFuzzInput memory input) {
        address sender = readMsgSender();
        changePrank(anny, anny);
        // Issue triLST-PTs and deposit to tricrypto and NapierPool
        try this._triLSTPoolAddLiquidity({wethIn: input.ethToNapierPool, spends: input.ethToTriLSTPT}) {}
        catch {
            vm.assume(false);
        }
        // Issue PT and triLST PTs and deposit to twocrypto
        try this._twocryptoMetaAddLiquidity({ethToPt: input.ethToPairPt, ethTo3Lst: input.ethToMetapool}) {}
        catch {
            vm.assume(false);
        }
        changePrank(sender, sender);
        _;
    }

    /// @dev Change pool state by swapping triLST PTs for underlying assets on tricrypto
    function _pushUpUnderlyingPrice(uint256[3] memory amounts) internal {
        uint256 liquidity = this._tricryptoAddLiquidity(amounts);
        try triLSTPool.swapExactBaseLpTokenForUnderlying(liquidity, anny) {}
        catch {
            vm.assume(false);
        }
    }

    /// @notice Struct for fuzzing input values
    struct U256Input {
        uint256 value;
    }

    //// Helper functions ////

    /// @notice Issue 3LST-PTs with `spends` amount of WETH and then deposit them to tricrypto
    function _tricryptoAddLiquidity(uint256[3] memory spends) public returns (uint256 liquidity) {
        // Issue triLST PTs and deposit to tricrypto
        uint256[3] memory issued;
        deal(address(weth), anny, spends[0] + spends[1] + spends[2]);
        for (uint256 i = 0; i < 3; i++) {
            issued[i] = lstPts[i].issue(anny, spends[i]);
        }
        liquidity = tricryptoLST.add_liquidity(issued, 0, false, anny);
    }

    /// @notice Issue 3LST-PTs with `spends` amount of WETH and then deposit them to tricrypto,
    /// then deposit the resulting LP tokens to NapierPool with `wethIn` amount of WETH.
    /// @param wethIn Amount of WETH to deposit to NapierPool
    /// @param spends Amount of WETH used to issue Principal Tokens
    function _triLSTPoolAddLiquidity(uint256 wethIn, uint256[3] memory spends)
        public
        virtual
        returns (uint256 liquidity)
    {
        uint256[3] memory issued;
        _deployMockCallbackReceiverTo(anny); // set mock callback receiver code

        // Issue triLST PTs and deposit to tricrypto
        deal(address(weth), anny, wethIn + 3 * (spends[0] + spends[1] + spends[2]));
        for (uint256 i = 0; i < 3; i++) {
            issued[i] = lstPts[i].issue(anny, spends[i]);
        }
        uint256 baseLptMinted = tricryptoLST.add_liquidity(issued, 0);
        liquidity = triLSTPool.addLiquidity(
            wethIn,
            baseLptMinted,
            anny,
            abi.encode(CallbackInputType.AddLiquidity, AddLiquidityInput(weth, tricryptoLST))
        );
    }

    /// @notice Issue PT with `ethToPt` amount of WETH and issue 3LST-PTs with `ethTo3Lst` amount of WETH,
    /// then deposit them to twocrypto metapool
    function _twocryptoMetaAddLiquidity(uint256 ethToPt, uint256[3] memory ethTo3Lst)
        public
        virtual
        returns (uint256 liquidity)
    {
        uint256[2] memory meta_amounts;
        deal(address(weth), anny, ethToPt);
        meta_amounts[0] = pairPt.issue(anny, ethToPt);
        meta_amounts[1] = _tricryptoAddLiquidity({spends: ethTo3Lst});
        liquidity = twocrypto.add_liquidity(meta_amounts, 0, anny);
    }
}
