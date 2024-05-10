// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {Base} from "../shared/Swap.t.sol";

import {Errors} from "src/Errors.sol";

contract DeployTest is Base {
    function test_Deploy() public {
        // Factory
        assertEq(address(metapoolFactory.twocryptoFactory()), address(twocryptoFactory), "twocryptoFactory");
        assertEq(metapoolFactory.owner(), owner, "owner");
        assertEq(address(metapoolFactory.WETH9()), address(weth), "WETH9");
        // Router
        assertEq(address(metapoolRouter.WETH9()), address(weth), "WETH9");
        assertEq(address(metapoolRouter.metapoolFactory()), address(metapoolFactory), "MetapoolFactory");
        assertEq(address(metapoolRouter.tricryptoLST()), address(tricryptoLST), "Tricrypto LST3PT");
        assertEq(address(metapoolRouter.triLSTPool()), address(triLSTPool), "3LST-PT Napier Pool");
        // StableSwapMeta
        assertEq(twocrypto.mid_fee(), twocryptoParams.mid_fee, "mid_fee");
        assertEq(twocrypto.out_fee(), twocryptoParams.out_fee, "out_fee");
        assertEq(twocrypto.coins(0), address(pairPt), "coin[0]");
        assertEq(twocrypto.coins(1), address(tricryptoLST), "coin[1]");
        // State check
        assertEq(metapoolFactory.isPtMetapool(address(twocrypto)), true, "twocrypto should be registered");
    }

    function test_RevertWhen_FailedToDeployMetapool() external {
        vm.mockCallRevert({
            callee: address(twocryptoFactory),
            data: abi.encodeWithSelector(twocryptoFactory.deploy_pool.selector),
            revertData: "0x"
        });
        vm.expectRevert(Errors.MetapoolFactoryFailedToDeployMetapool.selector);
        vm.prank(owner);
        metapoolFactory.deployMetapool(
            address(pairPt), address(triLSTPool), 0, "3LSTPT/HogePT", "3LSTHOGEPT", twocryptoParams
        );
    }

    function test_RevertWhen_NotOwner() external {
        vm.expectRevert("Ownable: caller is not the owner");
        metapoolFactory.deployMetapool(
            address(pairPt), address(triLSTPool), 0, "3LSTPT/HogePT", "3LSTHOGEPT", twocryptoParams
        );
    }

    function test_RevertWhen_WETHMismatch() external {
        vm.startPrank(owner);
        // NapierPool's underlying is not WETH
        vm.mockCall(
            address(triLSTPool),
            abi.encodeWithSignature("getAssets()"),
            abi.encode(address(0xeee), address(tricryptoLST))
        );
        vm.expectRevert(Errors.MetapoolFactoryWETHMismatch.selector);
        metapoolFactory.deployMetapool(
            address(pairPt), address(triLSTPool), 0, "3LSTPT/HogePT", "3LSTHOGEPT", twocryptoParams
        );
        vm.clearMockedCalls();
        // PT's underlying is not WETH
        vm.mockCall(address(pairPt), abi.encodeWithSignature("underlying()"), abi.encode(address(0xeee)));
        vm.expectRevert(Errors.MetapoolFactoryWETHMismatch.selector);
        metapoolFactory.deployMetapool(
            address(pairPt), address(triLSTPool), 0, "3LSTPT/HogePT", "3LSTHOGEPT", twocryptoParams
        );
    }

    function test_RevertWhen_MaturityTooLong() external {
        vm.startPrank(owner);
        vm.mockCall(address(triLSTPool), abi.encodeWithSignature("maturity()"), abi.encode(pairPt.maturity() - 1));
        vm.expectRevert(Errors.MetapoolFactoryMaturityTooLong.selector);
        metapoolFactory.deployMetapool(
            address(pairPt), address(triLSTPool), 0, "3LSTPT/HogePT", "3LSTHOGEPT", twocryptoParams
        );
    }
}
