// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PicocashVault} from "../src/PicocashVault.sol";
import {IPicocashVault} from "../src/interfaces/IPicocashVault.sol";
import {MockTIP20} from "./mocks/MockTIP20.sol";

contract PicocashVaultTest is Test {
    MockTIP20 token;
    PicocashVault vault;
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 constant TIMELOCK = 2 days;

    function setUp() public {
        token = new MockTIP20();
        vault = new PicocashVault(address(token), operator, TIMELOCK, "test mint", "http://mint.test");
        token.mint(alice, 10_000_000); // $10
    }

    // --- deposits ---

    function test_memoTransferDeposit_reachesVault() public {
        // the primary flow: no vault call at all, just a memo transfer to it
        vm.prank(alice);
        token.transferWithMemo(address(vault), 1_000_000, bytes32(uint256(0xabc)));
        assertEq(token.balanceOf(address(vault)), 1_000_000);
    }

    function test_allowanceDeposit_emitsBoundEvent() public {
        vm.startPrank(alice);
        token.approve(address(vault), 1_000_000);
        vm.expectEmit(true, true, false, true);
        emit IPicocashVault.EcashMintDeposit(bytes32(uint256(1)), alice, 1_000_000);
        vault.ecashMint(1_000_000, bytes32(uint256(1)));
        vm.stopPrank();
        assertEq(token.balanceOf(address(vault)), 1_000_000);
    }

    function test_deposit_revertsWhenPaused() public {
        vm.prank(operator);
        vault.setDepositsPaused(true);
        vm.startPrank(alice);
        token.approve(address(vault), 1);
        vm.expectRevert(PicocashVault.DepositsArePaused.selector);
        vault.ecashMint(1, bytes32(0));
        vm.stopPrank();
    }

    // --- withdrawals ---

    function _fund(uint256 amount) internal {
        token.mint(address(vault), amount);
    }

    function test_withdraw_operatorOnly() public {
        _fund(100);
        vm.prank(alice);
        vm.expectRevert(PicocashVault.NotOperator.selector);
        vault.ecashMelt(bob, 100, bytes32(uint256(7)));
    }

    function test_withdraw_paysOncePerMeltId() public {
        _fund(200);
        vm.startPrank(operator);
        vault.ecashMelt(bob, 100, bytes32(uint256(7)));
        assertEq(token.balanceOf(bob), 100);
        vm.expectRevert(abi.encodeWithSelector(PicocashVault.MeltAlreadyPaid.selector, bytes32(uint256(7))));
        vault.ecashMelt(bob, 100, bytes32(uint256(7)));
        vm.stopPrank();
    }

    function test_withdraw_worksWhileDepositsPaused() public {
        // exit is sacred: pausing deposits must not touch redemptions
        _fund(100);
        vm.startPrank(operator);
        vault.setDepositsPaused(true);
        vault.ecashMelt(bob, 100, bytes32(uint256(9)));
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 100);
    }

    function testFuzz_withdraw_neverExceedsBalance(uint96 funded, uint96 requested) public {
        _fund(funded);
        vm.prank(operator);
        if (requested > funded) {
            vm.expectRevert();
            vault.ecashMelt(bob, requested, bytes32(uint256(1)));
        } else {
            vault.ecashMelt(bob, requested, bytes32(uint256(1)));
            assertEq(token.balanceOf(bob), requested);
            assertEq(token.balanceOf(address(vault)), uint256(funded) - requested);
        }
    }

    // --- solvency publication ---

    function test_publishOutstandingSupply_snapshotsBalance() public {
        _fund(555);
        vm.prank(operator);
        vm.expectEmit(true, false, false, true);
        emit IPicocashVault.OutstandingSupplyPublished(bytes8(0x00cb743b02e43088), 500, 555);
        vault.publishOutstandingSupply(bytes8(0x00cb743b02e43088), 500);
    }

    // --- token binding & sweep ---

    function test_constructor_rejectsCodelessToken() public {
        vm.expectRevert(PicocashVault.TokenHasNoCode.selector);
        new PicocashVault(makeAddr("not-a-contract"), operator, TIMELOCK, "x", "http://x");
    }

    function test_sweep_returnsStrandedTokens_neverBacking() public {
        MockTIP20 stranded = new MockTIP20();
        stranded.mint(address(vault), 777);
        _fund(1000); // backing balance

        vm.prank(alice);
        vm.expectRevert(PicocashVault.NotOperator.selector);
        vault.sweep(address(stranded), alice);

        vm.startPrank(operator);
        vm.expectRevert(PicocashVault.CannotSweepBackingToken.selector);
        vault.sweep(address(token), operator);

        vault.sweep(address(stranded), bob);
        vm.stopPrank();
        assertEq(stranded.balanceOf(bob), 777);
        assertEq(token.balanceOf(address(vault)), 1000); // backing untouched
    }

    // --- operator rotation ---

    function test_rotation_timelocked() public {
        vm.prank(operator);
        vault.proposeOperator(bob);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(PicocashVault.TimelockNotElapsed.selector, block.timestamp + TIMELOCK)
        );
        vault.acceptOperator();

        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(alice);
        vm.expectRevert(PicocashVault.NotPendingOperator.selector);
        vault.acceptOperator();

        vm.prank(bob);
        vault.acceptOperator();
        assertEq(vault.operator(), bob);
        assertEq(vault.pendingOperator(), address(0));

        // old operator is fully powerless
        vm.prank(operator);
        vm.expectRevert(PicocashVault.NotOperator.selector);
        vault.setDepositsPaused(true);
    }
}
