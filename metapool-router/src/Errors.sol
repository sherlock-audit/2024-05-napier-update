// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

library Errors {
    // Generic
    error FailedToSendEther();
    error NotWETH();

    // Factory
    error MetapoolFactoryFailedToDeployMetapool();
    error MetapoolFactoryMaturityTooLong();
    error MetapoolFactoryWETHMismatch();

    // Router
    error MetapoolRouterUnauthorized();
    error MetapoolRouterInvalidMetapool();
    error MetapoolRouterTransactionTooOld();
    error MetapoolRouterInsufficientETHOut();
    error MetapoolRouterExceededLimitETHIn();
    error MetapoolRouterInsufficientETHRepay();
    error MetapoolRouterCallbackNotLST3PTETHPool();
    error MetapoolRouterInsufficientETHReceived();
    error MetapoolRouterNonSituationSwapETHForYt();
}
