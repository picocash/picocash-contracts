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
        vault = new PicocashVault(address(token), operator, TIMELOCK, 1000, 100, 100_000, "test mint", "http://mint.test");
        token.mint(alice, 10_000_000); // $10
        // a vault with an interval rule is born overdue; establish the baseline attestation
        vm.prank(operator);
        vault.publishOutstandingSupply(bytes8(0), 0);
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
        new PicocashVault(makeAddr("not-a-contract"), operator, TIMELOCK, 1000, 0, 100_000, "x", "http://x");
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

    // --- publication policy ---

    function test_constructor_requiresAPolicy() public {
        vm.expectRevert(PicocashVault.NoPublicationPolicy.selector);
        new PicocashVault(address(token), operator, TIMELOCK, 0, 0, 100_000, "x", "http://x");
        vm.expectRevert(PicocashVault.InvalidThreshold.selector);
        new PicocashVault(address(token), operator, TIMELOCK, 10_001, 0, 100_000, "x", "http://x");
    }

    function test_overdue_blocksAllowanceDeposits_neverMelts() public {
        _fund(500);
        assertFalse(vault.isPublicationOverdue());

        vm.roll(block.number + 101); // past the 100-block interval
        assertTrue(vault.isPublicationOverdue());

        // deposits gated…
        vm.startPrank(alice);
        token.approve(address(vault), 100);
        vm.expectRevert(PicocashVault.PublicationOverdue.selector);
        vault.ecashMint(100, bytes32(0));
        vm.stopPrank();

        // …but exit is sacred: melts pay out even while overdue
        vm.prank(operator);
        vault.ecashMelt(bob, 100, bytes32(uint256(42)));
        assertEq(token.balanceOf(bob), 100);

        // publishing clears the gate
        vm.prank(operator);
        vault.publishOutstandingSupply(bytes8(0), 400);
        assertFalse(vault.isPublicationOverdue());
        vm.startPrank(alice);
        token.approve(address(vault), 100);
        vault.ecashMint(100, bytes32(0));
        vm.stopPrank();
    }

    function test_thresholdRule_triggersDue() public {
        _fund(1_000_000);
        vm.prank(operator);
        vault.publishOutstandingSupply(bytes8(0), 1_000_000); // baseline: balance 1_000_000

        token.mint(address(vault), 50_000); // +5% drift: under the 10% threshold
        assertFalse(vault.isPublicationDue());

        token.mint(address(vault), 60_000); // +11% total drift: over threshold
        assertTrue(vault.isPublicationDue());
        assertFalse(vault.isPublicationOverdue()); // soft trigger, not a breach — nothing is blocked

        vm.prank(operator);
        vault.publishOutstandingSupply(bytes8(0), 1_110_000); // rebases the drift
        assertFalse(vault.isPublicationDue());
    }

    // --- melt-fee ceiling ---

    function test_maxMeltFee_decreaseInstant_increaseTimelocked() public {
        assertEq(vault.maxMeltFee(), 100_000);

        vm.prank(alice);
        vm.expectRevert(PicocashVault.NotOperator.selector);
        vault.decreaseMaxMeltFee(50_000);

        // lowering the exit tax is instant
        vm.prank(operator);
        vault.decreaseMaxMeltFee(50_000);
        assertEq(vault.maxMeltFee(), 50_000);

        vm.startPrank(operator);
        vm.expectRevert(PicocashVault.NotADecrease.selector);
        vault.decreaseMaxMeltFee(60_000);

        // raising it requires public notice via the rotation timelock
        vm.expectRevert(PicocashVault.NotAnIncrease.selector);
        vault.proposeMaxMeltFeeIncrease(40_000);

        vault.proposeMaxMeltFeeIncrease(80_000);
        vm.expectRevert(
            abi.encodeWithSelector(PicocashVault.TimelockNotElapsed.selector, block.timestamp + TIMELOCK)
        );
        vault.applyMaxMeltFeeIncrease();

        vm.warp(block.timestamp + TIMELOCK);
        vault.applyMaxMeltFeeIncrease();
        assertEq(vault.maxMeltFee(), 80_000);
        assertEq(vault.pendingMaxMeltFee(), 0);

        vm.expectRevert(PicocashVault.NoPendingIncrease.selector);
        vault.applyMaxMeltFeeIncrease();
        vm.stopPrank();

        assertEq(vault.info().maxMeltFee, 80_000);
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
