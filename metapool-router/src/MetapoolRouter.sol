// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

// Interfaces
import {IERC20, SafeERC20} from "@openzeppelin/contracts@4.9.3/token/ERC20/utils/SafeERC20.sol";
import {CurveTricryptoOptimizedWETH} from "@napier/v1-pool/src/interfaces/external/CurveTricryptoOptimizedWETH.sol";
import {CurveTricryptoFactory} from "@napier/v1-pool/src/interfaces/external/CurveTricryptoFactory.sol";
import {IWETH9} from "@napier/v1-tranche/src/interfaces/IWETH9.sol";
import {INapierPool} from "@napier/v1-pool/src/interfaces/INapierPool.sol";
import {ITranche} from "@napier/v1-tranche/src/interfaces/ITranche.sol";
import {Twocrypto} from "./interfaces/external/Twocrypto.sol";
import {IVault} from "./interfaces/external/balancer/IVault.sol";
import {IFlashLoanRecipient} from "./interfaces/external/balancer/IFlashLoanRecipient.sol";
import {MetapoolFactory} from "./MetapoolFactory.sol";

import {IMetapoolRouter} from "./interfaces/IMetapoolRouter.sol";

// Libraries
import {TransientStorage} from "./TransientStorage.sol";
import {Math} from "@openzeppelin/contracts@4.9.3/utils/math/Math.sol";
import {TrancheMathHelper} from "@napier/v1-pool/src/libs/TrancheMathHelper.sol";
import {ApproxParams} from "@napier/v1-pool/src/interfaces/ApproxParams.sol";
import {Errors} from "./Errors.sol";

// Inherits
import {ReentrancyGuard} from "@openzeppelin/contracts@4.9.3/security/ReentrancyGuard.sol";

/// @title MetapoolRouter - A contract for swapping between PT, YT, and ETH on the 3LST NapierPool, 3LST-PT tricrypto, and Twocrypto metapools
contract MetapoolRouter is ReentrancyGuard, IFlashLoanRecipient, IMetapoolRouter {
    /// @dev Constants for the Twocrypto metapool indexes
    /// coins(0) is the pegged token (PT) and coins(1) is the base pool token (triLST-PT Tricrypto)
    uint128 constant PEGGED_PT_INDEX = 0;
    uint128 constant BASE_POOL_INDEX = 1;

    /// @dev Transient storage slots
    uint256 constant TSLOT_0 = 0; // Authorization flag for `receiveFlashLoan`
    uint256 constant TSLOT_1 = 1; // Temporary storage for `swapETHForYt` function return value
    uint256 constant TSLOT_CB_DATA_METAPOOL = 2; // `FlashLoanData.metapool` slot for `receiveFlashLoan` callback data
    uint256 constant TSLOT_CB_DATA_PT = 3; // `FlashLoanData.pt` slot for `receiveFlashLoan` callback data
    uint256 constant TSLOT_CB_DATA_SENDER = 4; // `FlashLoanData.sender` slot for `receiveFlashLoan` callback data
    uint256 constant TSLOT_CB_DATA_VALUE = 5; // `FlashLoanData.msgValue` slot for `receiveFlashLoan` callback data
    uint256 constant TSLOT_CB_DATA_MAX_ETH_SPENT = 6; // `FlashLoanData.maxEthSpent` slot for `receiveFlashLoan` callback data
    uint256 constant TSLOT_CB_DATA_RECEIPIENT = 7; // `FlashLoanData.recipient` slot for `receiveFlashLoan` callback data

    /// @notice The WETH9 contract
    IWETH9 public immutable WETH9;

    /// @notice The Factory contract for the Principal Token metapools
    MetapoolFactory public immutable metapoolFactory;

    /// @notice The rETH-PT<>stETH-PT<>sfrxETH-PT Curve TricryptoNG pool (triLST-PT Tricrypto)
    CurveTricryptoOptimizedWETH public immutable tricryptoLST;

    /// @notice The triLST-PT<>WETH NapierPool
    INapierPool public immutable triLSTPool;

    /// @notice The Balancer Vault contract for flash loans
    IVault public immutable vault;

    /// @dev The approval slot of (`token`, `spender`) is given by:
    /// ```
    ///     mstore(0x20, spender)
    ///     mstore(0x0c, _IS_APPROVED_SLOT_SEED)
    ///     mstore(0x00, token)
    ///     let allowanceSlot := keccak256(0x0c, 0x34)
    /// ```
    /// @dev Optimized storage slot for approval flags
    /// `mapping (address token => mapping (address spender => uint256 approved)) _isApproved;`
    uint256 private constant _IS_APPROVED_SLOT_SEED = 0xa8fe4407;

    /// @notice If the transaction is too old, revert.
    /// @param deadline Transaction deadline in unix timestamp
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Errors.MetapoolRouterTransactionTooOld();
        _;
    }

    /// @notice If the metapool is not a TwoCrypto with Principal Token, revert.
    modifier checkMetapool(address metapool) {
        if (!metapoolFactory.isPtMetapool(metapool)) revert Errors.MetapoolRouterInvalidMetapool();
        _;
    }

    receive() external payable {
        if (msg.sender != address(WETH9)) revert Errors.NotWETH();
    }

    constructor(MetapoolFactory _metapoolFactory, INapierPool _triLSTPool, IVault _vault) {
        metapoolFactory = _metapoolFactory;
        triLSTPool = _triLSTPool;
        vault = _vault;
        WETH9 = IWETH9(_metapoolFactory.WETH9());
        tricryptoLST = _triLSTPool.tricrypto();

        (bool s, bytes memory data) = CurveTricryptoOptimizedWETH(tricryptoLST).factory().staticcall(
            abi.encodeWithSignature("get_coins(address)", tricryptoLST)
        );
        require(s);
        address[3] memory coins = abi.decode(data, (address[3]));
        // Approve rETH-PT<>stETH-PT<>sfrxETH-PT Curve TricryptoNG pool (triLST-PT Tricrypto) to spend meta tokens
        IERC20(coins[0]).approve(address(tricryptoLST), type(uint256).max);
        IERC20(coins[1]).approve(address(tricryptoLST), type(uint256).max);
        IERC20(coins[2]).approve(address(tricryptoLST), type(uint256).max);
        // Approve triLST-PT<>WETH NapierPool to spend WETH9
        SafeERC20.forceApprove(IWETH9(WETH9), address(triLSTPool), type(uint256).max);
        // Approve triLST-PT<>WETH NapierPool to spend tricryptoLST
        SafeERC20.forceApprove(tricryptoLST, address(triLSTPool), type(uint256).max);
    }

    /// @notice Swap ETH for PT
    /// @notice A caller must send ETH enough greater than the `maxEthSpent`. Remaining ETH will be sent back to the caller.
    /// @dev This function can't swap ETH for the exact amount of PT because of precision loss. So, `minPtOut` must be specified by the caller.
    /// @param metapool The address of the Twocrypto metapool
    /// @param ptAmount The amount of PT tokens to receive
    /// @param maxEthSpent The maximum amount of ETH to spend in the swap
    /// @param minPtOut The minimum amount of PT tokens to receive
    /// @param recipient The address to receive the swapped PT tokens
    /// @param deadline The timestamp after which the transaction will be reverted
    /// @return ethSpent The amount of ETH spent in the swap
    function swapETHForPt(
        address metapool,
        uint256 ptAmount,
        uint256 maxEthSpent,
        uint256 minPtOut, // TODO: really need this?
        address recipient,
        uint256 deadline
    ) external payable nonReentrant checkDeadline(deadline) checkMetapool(metapool) returns (uint256 ethSpent) {
        // Steps:
        // 1. Quote swap PT -> base pool token on triLST-PT Tricrypto (get_dx)
        // 2. Swap ETH -> base pool token on triLST-PT<>WETH NapierPool
        // 3. Swap base pool token -> PT on twocrypto metapool
        // 4. Send remaining ETH to the recipient

        // Calculate the amount of base pool token required for the specified PT amount
        uint256 basePoolTokenAmount = Twocrypto(metapool).get_dx({i: BASE_POOL_INDEX, j: PEGGED_PT_INDEX, dy: ptAmount});

        // Wrap the received ETH into WETH
        if (maxEthSpent > msg.value) revert Errors.MetapoolRouterInsufficientETHReceived();
        _wrapETH(msg.value);

        // Swap the received WETH for the required amount of base pool token on the NapierPool
        /// @dev Txn may revert if the triLSTPool tries to swap more than the received ETH.
        ethSpent = triLSTPool.swapUnderlyingForExactBaseLpToken({baseLpOut: basePoolTokenAmount, recipient: metapool});

        // Swap the received base pool token for PT on the Curve metapool
        Twocrypto(metapool).exchange_received({
            i: BASE_POOL_INDEX,
            j: PEGGED_PT_INDEX,
            dx: basePoolTokenAmount,
            // `get_dx` has a precision loss, so the actual amount of PT received may be less than `ptAmount`.
            min_dy: minPtOut,
            receiver: recipient
        });

        if (ethSpent > maxEthSpent) revert Errors.MetapoolRouterExceededLimitETHIn();

        // Send the remaining WETH back to the sender
        uint256 remainingWeth = msg.value - ethSpent;
        if (remainingWeth > 0) _unwrapWETH(msg.sender, remainingWeth);

        return ethSpent;
    }

    /// @notice Swap PT for ETH on the Curve metapool through the 3LST-PT<>ETH NapierPool
    /// @param metapool The address of the Twocrypto metapool
    /// @param ptAmount The amount of PT to swap
    /// @param minEthOut The minimum amount of ETH to receive
    /// @param recipient The address to receive the ETH
    /// @param deadline The timestamp after which the transaction will be reverted
    function swapPtForETH(address metapool, uint256 ptAmount, uint256 minEthOut, address recipient, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
        checkMetapool(metapool)
        returns (uint256 ethOut)
    {
        // Steps:
        // 1. Exchange PT for the base pool token on twoCrypto metapool
        // 2. Swap ETH -> base pool token on twocrypto metapool
        // 3. Swap the received base pool token -> ETH on triLST-PT<>WETH NapierPool
        // 4. Send remaining ETH to the recipient

        // Swap PT for the base pool token on the Curve metapool
        SafeERC20.safeTransferFrom(IERC20(Twocrypto(metapool).coins(PEGGED_PT_INDEX)), msg.sender, metapool, ptAmount);
        uint256 basePoolTokenAmount =
            Twocrypto(metapool).exchange_received(PEGGED_PT_INDEX, BASE_POOL_INDEX, ptAmount, 0, address(this));

        // Swap the received base pool token for ETH on the 3LST-PT<>ETH NapierPool
        ethOut =
            triLSTPool.swapExactBaseLpTokenForUnderlying({baseLptIn: basePoolTokenAmount, recipient: address(this)});

        // Check slippage
        if (minEthOut > ethOut) revert Errors.MetapoolRouterInsufficientETHOut();

        // Send native ETH to the recipient
        _unwrapWETH(recipient, ethOut);

        return ethOut;
    }

    /// @notice Swap Ethereum (ETH) for Yield Tokens (YT)
    /// @dev This function first issues PT and YT using ETH, then swaps the PT for the base pool token on the Curve metapool,
    ///      and finally swaps the received base pool token for ETH on the NapierPool.
    /// @notice Caller must send enough ETH equal to the `maxEthSpent` and the remaining ETH will be sent back to the caller.
    /// @dev `recipient` will receive at least `ytAmount` YTs and at most `ytAmount * (1 + approx.eps / 1e18)` YTs.
    /// @param metapool The address of the Curve metapool contract
    /// @param ytAmount The amount of YT tokens to receive
    /// @param maxEthSpent The maximum amount of ETH to spend in the swap
    /// @param recipient The address to receive the swapped YT tokens
    /// @param deadline The timestamp after which the transaction will be reverted
    /// @return ethSpent The amount of ETH spent in the swap
    function swapETHForYt(
        address metapool,
        uint256 ytAmount,
        uint256 maxEthSpent,
        address recipient,
        uint256 deadline,
        ApproxParams calldata approx
    ) external payable nonReentrant checkDeadline(deadline) checkMetapool(metapool) returns (uint256 ethSpent) {
        // Steps:
        // 1. Estimate the amount of WETH required to issue the PT and YT
        // 2. Issue PT and YT using the WETH
        // 3. Swap PT -> Base pool token on the Twocrypto metapool
        // 4. Swap Base pool token -> ETH on the NapierPool
        // 5. Refund the remaining WETH to the sender

        ITranche pt = ITranche(Twocrypto(metapool).coins(PEGGED_PT_INDEX));

        if (maxEthSpent > msg.value) revert Errors.MetapoolRouterInsufficientETHReceived();

        // Estimate the amount of WETH required to issue the PT and YT
        // Bisection method is used to find the approximate amount of WETH needed, which ensures the at least `ytAmount` YT tokens are issued.
        uint256 wethDeposit =
            TrancheMathHelper.getApproxUnderlyingNeededByYt({pt: pt, ytDesired: ytAmount, approx: approx});

        // Authorize access to `receiveFlashLoan` at the last step (flag=address(this))
        assembly {
            // Note: This slot should be used only for authorization purpose and should be cleared after use
            tstore(TSLOT_0, address())
        }

        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = WETH9;
        amounts[0] = wethDeposit;
        // Record the flash loan data in the transient storage
        // Note: Based on try-and-error, passing userData directly is more expensive than using transient storage.
        assembly {
            tstore(TSLOT_CB_DATA_METAPOOL, metapool)
            tstore(TSLOT_CB_DATA_PT, shr(96, shl(96, pt)))
            tstore(TSLOT_CB_DATA_SENDER, caller())
            tstore(TSLOT_CB_DATA_VALUE, callvalue())
            tstore(TSLOT_CB_DATA_MAX_ETH_SPENT, maxEthSpent)
            tstore(TSLOT_CB_DATA_RECEIPIENT, recipient)
        }

        _wrapETH(msg.value);
        vault.flashLoan(this, tokens, amounts, ""); // call receiveFlashLoan

        assembly {
            ethSpent := tload(TSLOT_1)
            tstore(TSLOT_1, 0) // clear transitient storage
        }

        return ethSpent;
    }

    /// @notice Receive the flash loan and run operations to swap ETH for YT
    /// @dev Revert if the call is not initiated by the `swapETHForYt` function.
    /// @custom:param userData - Data structure for the flash loan callback data.
    /// @dev Those members are stored in the transient storage slots with prefix `TSLOT_CB_DATA_`.
    /// ```
    /// struct UserData {
    ///     address _metapool;
    ///     address _pt;
    ///     address _sender; // The address of the caller of `swapETHForYt`
    ///     uint256 _msgValue; // The amount of ETH sent with the call to `swapETHForYt`
    ///     uint256 _maxEthSpent;
    ///     address _recipient;
    /// }
    /// ```
    function receiveFlashLoan(
        IERC20[] calldata, /* tokens */
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata /* userData */
    ) external {
        // CHECK
        // Note: Call only through `swapETHForYt` && from the Vault should be allowed.
        // This ensures that the function call is invoked by `swapETHForYt` entry point.
        // Checking `msg.sender == address(vault)` may not be sufficient as the call may be initiated by other contracts and pass arbitrary data.
        assembly {
            let ctx := tload(TSLOT_0)
            tstore(TSLOT_0, 0) // Delete the authorization (flag=address(0))
            if iszero(eq(ctx, address())) {
                mstore(0x00, 0x5c501941) // `MetapoolRouterUnauthorized()`
                revert(0x1c, 0x04)
            }
        }

        address pt = TransientStorage.tloadAddress(TSLOT_CB_DATA_PT);
        address metapool = TransientStorage.tloadAddress(TSLOT_CB_DATA_METAPOOL);

        // Issue PT tokens using the WETH
        if (_isApproved(address(WETH9), pt) == 0) {
            _setApproval(address(WETH9), pt);
            WETH9.approve(pt, type(uint256).max);
        }
        uint256 wethDeposit = amounts[0];
        uint256 pyIssued = ITranche(pt).issue(address(this), wethDeposit);

        // Swap the PT for the base pool token on the Curve metapool
        ITranche(pt).transfer(metapool, pyIssued);
        uint256 basePoolTokenOut =
            Twocrypto(metapool).exchange_received(PEGGED_PT_INDEX, BASE_POOL_INDEX, pyIssued, 0, address(this));

        // Swap the received base pool token for ETH on the NapierPool
        uint256 wethReceived = triLSTPool.swapExactBaseLpTokenForUnderlying(basePoolTokenOut, address(this));

        // Unreasonable situation: Received more WETH than sold
        if (wethReceived > wethDeposit) revert Errors.MetapoolRouterNonSituationSwapETHForYt();

        // Calculate the amount of ETH spent in the swap
        uint256 repayAmount = wethDeposit + feeAmounts[0];
        uint256 spent = repayAmount - wethReceived; // wethDeposit + feeAmounts[0] - wethReceived

        // Revert if the ETH spent exceeds the specified maximum
        if (spent > TransientStorage.tloadU256(TSLOT_CB_DATA_MAX_ETH_SPENT)) {
            revert Errors.MetapoolRouterExceededLimitETHIn();
        }

        uint256 remaining = TransientStorage.tloadU256(TSLOT_CB_DATA_VALUE) - spent;
        if (repayAmount > remaining) revert Errors.MetapoolRouterInsufficientETHRepay(); // Can't repay the flash loan

        // Temporarily store a return value of `swapETHForYt` function across the call context
        assembly {
            tstore(TSLOT_1, spent)
        }

        // Transfer the YT tokens to the recipient
        IERC20(ITranche(pt).yieldToken()).transfer(TransientStorage.tloadAddress(TSLOT_CB_DATA_RECEIPIENT), pyIssued);

        // Repay the flash loan
        WETH9.transfer(msg.sender, repayAmount);

        // Unwrap and send the remaining WETH back to the sender
        _unwrapWETH(TransientStorage.tloadAddress(TSLOT_CB_DATA_SENDER), remaining);
    }

    /// @notice Add liquidity to the Curve metapool using native ETH and receive LP tokens and YT
    /// @dev Revert if timestamp exceeds the maturity date.
    /// @param metapool The address of the Curve metapool contract
    /// @param minLiquidity The minimum amount of LP tokens to receive
    /// @param recipient The address to receive the LP tokens and YT
    /// @param deadline The timestamp after which the transaction will be reverted
    function addLiquidityOneETHKeepYt(address metapool, uint256 minLiquidity, address recipient, uint256 deadline)
        external
        payable
        nonReentrant
        checkDeadline(deadline)
        checkMetapool(metapool)
        returns (uint256 liquidity)
    {
        // Steps:
        // 1. Issue PT and YT using the received ETH
        // 2. Add liquidity to the Curve metapool
        // 3. Send the received LP token and YT to the recipient

        // Wrap the received ETH into WETH
        _wrapETH(msg.value);

        ITranche pt = ITranche(Twocrypto(metapool).coins(PEGGED_PT_INDEX));
        // Issue PT and YT using the received ETH
        if (_isApproved(address(WETH9), address(pt)) == 0) {
            _setApproval(address(WETH9), address(pt));
            WETH9.approve(address(pt), type(uint256).max);
        }
        uint256 pyAmount = pt.issue({to: address(this), underlyingAmount: msg.value});

        // Add liquidity to the Curve metapool
        if (_isApproved(address(pt), metapool) == 0) {
            _setApproval(address(pt), metapool);
            pt.approve(metapool, type(uint256).max);
        }
        liquidity = Twocrypto(metapool).add_liquidity({
            amounts: [pyAmount, 0],
            min_mint_amount: minLiquidity,
            receiver: recipient
        });

        IERC20(pt.yieldToken()).transfer(recipient, pyAmount);
    }

    /// @notice Remove liquidity from the Curve twocrypto (metapool) and receive native ETH
    /// @notice Before the maturity date of PT, the PT is not redeemable, so the PT is swapped for the Base pool Token
    /// @param metapool The address of the Curve metapool contract
    /// @param liquidity The amount of LP tokens to remove from the Curve twocrypto (metapool)
    /// @param minEthOut The minimum amount of ETH to receive
    /// @param recipient The address to receive the ETH
    /// @param deadline The timestamp after which the transaction will be reverted
    function removeLiquidityOneETH(
        address metapool,
        uint256 liquidity,
        uint256 minEthOut,
        address recipient,
        uint256 deadline
    ) external nonReentrant checkDeadline(deadline) checkMetapool(metapool) returns (uint256 ethOut) {
        // Steps:
        // If PT is matured, redemption of PT is allowed:
        // 1. Remove liquidity from the Curve metapool and withdraw one PT
        // 2. Redeem the PT for ETH

        // If PT is not matured: redemption of PT is not allowed yet:
        // 1. Remove liquidity from the Curve metapool and withdraw one base pool token
        // 2. Swap the received base pool token for ETH on the NapierPool

        ITranche pt = ITranche(Twocrypto(metapool).coins(PEGGED_PT_INDEX));

        SafeERC20.safeTransferFrom(Twocrypto(metapool), msg.sender, address(this), liquidity);

        if (block.timestamp >= pt.maturity()) {
            // If PT is matured, we can directly redeem the PT for ETH
            uint256 ptAmount = Twocrypto(metapool).remove_liquidity_one_coin(liquidity, PEGGED_PT_INDEX, 0);
            ethOut = pt.redeem({principalAmount: ptAmount, to: address(this), from: address(this)});
        } else {
            // Otherwise, redemption of PT is not allowed, so we need to swap the base pool token for ETH
            uint256 basePoolTokenAmount = Twocrypto(metapool).remove_liquidity_one_coin(liquidity, BASE_POOL_INDEX, 0);
            ethOut = triLSTPool.swapExactBaseLpTokenForUnderlying(basePoolTokenAmount, address(this));
        }

        if (minEthOut > ethOut) revert Errors.MetapoolRouterInsufficientETHOut();

        _unwrapWETH(recipient, ethOut);
    }

    //// Helper functions ////

    /// @dev Get the approval status of the spender for the token. Return 1 if approved, 0 otherwise.
    function _isApproved(address token, address spender) internal view returns (uint256 approved) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x20, spender)
            mstore(0x0c, _IS_APPROVED_SLOT_SEED)
            mstore(0x00, token)
            approved := sload(keccak256(0x0c, 0x34))
        }
    }

    /// @dev Set the approval status to 1 for the spender for the token.
    function _setApproval(address token, address spender) internal {
        /// @solidity memory-safe-assembly
        assembly {
            // Compute the approval slot and store the amount.
            mstore(0x20, spender)
            mstore(0x0c, _IS_APPROVED_SLOT_SEED)
            mstore(0x00, token)
            sstore(keccak256(0x0c, 0x34), 1)
        }
    }

    function _wrapETH(uint256 value) internal {
        WETH9.deposit{value: value}();
    }

    function _unwrapWETH(address recipient, uint256 value) internal {
        WETH9.withdraw(value);
        _safeTransferETH(recipient, value);
    }

    /// @notice transfer ether safely
    function _safeTransferETH(address to, uint256 value) internal {
        (bool success,) = to.call{value: value}(new bytes(0));
        if (!success) revert Errors.FailedToSendEther();
    }
}
