// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PicocashVault} from "../src/PicocashVault.sol";
import {PicocashVaultFactory} from "../src/PicocashVaultFactory.sol";
import {PicocashEmergencyVerifier} from "../src/emergency/PicocashEmergencyVerifier.sol";
import {MockTIP20} from "./mocks/MockTIP20.sol";

contract WithdrawalBreakerTest is Test {
    uint64 constant INTERVAL = 1000;
    uint64 constant GRACE = 500;
    uint16 constant LIMIT_BPS = 2000; // 20% of backing per epoch
    uint64 constant EPOCH = 100;
    uint256 constant TIMELOCK = 2 days;
    bytes8 constant KEYSET = 0x00260deaaf7e6868;

    MockTIP20 token;
    PicocashVaultFactory factory;
    PicocashVault vault;
    address operator = makeAddr("operator");
    address thief = makeAddr("thief");
    address holder = makeAddr("holder");
    uint256 n;

    function setUp() public {
        token = new MockTIP20();
        factory = new PicocashVaultFactory();
        vault = PicocashVault(
            factory.deployVault(
                address(token), operator, TIMELOCK, 1000, INTERVAL, 100_000, "b", "https://b", GRACE, LIMIT_BPS, EPOCH
            )
        );
        token.mint(address(vault), 1_000_000); // $1 backing → allowance 200_000 per epoch
        vm.prank(operator);
        vault.publishOutstandingSupply(KEYSET, 1_000_000);
    }

    function _melt(address to, uint256 amount) internal {
        vm.prank(operator);
        vault.ecashMelt(to, amount, bytes32(++n));
    }

    function test_allowanceBoundsAnEpoch_andOverLimitReverts() public {
        _melt(holder, 150_000);
        (,,, uint256 baseline, uint256 allowance, uint256 melted, uint256 tripped) = vault.breakerInfo();
        assertEq(baseline, 1_000_000);
        assertEq(allowance, 200_000);
        assertEq(melted, 150_000);
        assertEq(tripped, 0);
        // the operator cannot take more than the remaining 50_000 this epoch
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PicocashVault.MeltLimitExceeded.selector, 50_000));
        vault.ecashMelt(thief, 50_001, bytes32(uint256(999)));
        assertFalse(vault.emergencyMode());
    }

    function test_consumingTheAllowanceLatches_opensExitImmediately_blocksDeposits() public {
        _melt(thief, 200_000); // exactly the allowance → latch
        (,,,,,, uint256 tripped) = vault.breakerInfo();
        assertEq(tripped, block.number);
        assertTrue(vault.emergencyMode(), "exit opens without any grace period");
        assertFalse(vault.isPublicationOverdue(), "attestation itself is fine - this is the breaker");

        // no more operator payouts, no new deposits
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PicocashVault.BreakerTripped.selector, block.number));
        vault.ecashMelt(thief, 1, bytes32(uint256(998)));
        token.mint(holder, 10);
        vm.startPrank(holder);
        token.approve(address(vault), 10);
        vm.expectRevert(abi.encodeWithSelector(PicocashVault.BreakerTripped.selector, block.number));
        vault.ecashMint(10, bytes32(uint256(1)));
        vm.stopPrank();

        // and it stays latched across epochs: the thief does not get a fresh allowance
        vm.roll(block.number + EPOCH + 1);
        vm.prank(operator);
        vm.expectRevert();
        vault.ecashMelt(thief, 1, bytes32(uint256(997)));
        assertEq(token.balanceOf(thief), 200_000, "theft bounded to one epoch allowance");
    }

    function test_freshEpochRebasesAllowanceOnCurrentBalance() public {
        _melt(holder, 100_000);
        vm.roll(block.number + EPOCH);
        // new epoch: baseline is the current balance (900_000) → allowance 180_000
        _melt(holder, 100_000);
        (,,, uint256 baseline, uint256 allowance, uint256 melted,) = vault.breakerInfo();
        assertEq(baseline, 900_000);
        assertEq(allowance, 180_000);
        assertEq(melted, 100_000);
    }

    function test_resetRequiresTimelock() public {
        _melt(thief, 200_000);
        vm.prank(operator);
        vm.expectRevert(PicocashVault.NoPendingReset.selector);
        vault.applyBreakerReset();
        vm.prank(operator);
        vault.proposeBreakerReset();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PicocashVault.TimelockNotElapsed.selector, block.timestamp + TIMELOCK));
        vault.applyBreakerReset();
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(operator);
        vault.applyBreakerReset();
        assertFalse(vault.emergencyMode());
        _melt(holder, 1); // a fresh epoch from the current balance
        (,,, uint256 baseline,,,) = vault.breakerInfo();
        assertEq(baseline, 800_000);
    }

    function test_limitDecreaseInstant_increaseTimelocked() public {
        vm.prank(operator);
        vault.decreaseMeltLimit(1000);
        assertEq(vault.meltLimitBps(), 1000);
        vm.prank(operator);
        vm.expectRevert(PicocashVault.NotADecrease.selector);
        vault.decreaseMeltLimit(1500);
        vm.prank(operator);
        vault.proposeMeltLimitIncrease(3000);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PicocashVault.TimelockNotElapsed.selector, block.timestamp + TIMELOCK));
        vault.applyMeltLimitIncrease();
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(operator);
        vault.applyMeltLimitIncrease();
        assertEq(vault.meltLimitBps(), 3000);
    }

    function test_configValidation() public {
        vm.expectRevert(PicocashVault.InvalidBreakerConfig.selector);
        factory.deployVault(address(token), operator, TIMELOCK, 1000, INTERVAL, 1, "x", "y", GRACE, 1000, 0);
        vm.expectRevert(PicocashVault.InvalidBreakerConfig.selector);
        factory.deployVault(address(token), operator, TIMELOCK, 1000, INTERVAL, 1, "x", "y", GRACE, 0, 100);
        vm.expectRevert(PicocashVault.InvalidBreakerConfig.selector);
        factory.deployVault(address(token), operator, TIMELOCK, 1000, INTERVAL, 1, "x", "y", GRACE, 10_001, 100);
        // disabled breaker: melts are unbounded (legacy behaviour), breakerInfo reports 0 limit
        PicocashVault v = PicocashVault(
            factory.deployVault(address(token), operator, TIMELOCK, 1000, INTERVAL, 1, "x", "y", GRACE, 0, 0)
        );
        token.mint(address(v), 100);
        vm.prank(operator);
        v.ecashMelt(holder, 100, bytes32(uint256(5)));
        (uint16 bps,,,,,,) = v.breakerInfo();
        assertEq(bps, 0);
    }
}
