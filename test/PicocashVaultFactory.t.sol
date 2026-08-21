// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PicocashVault} from "../src/PicocashVault.sol";
import {PicocashVaultFactory} from "../src/PicocashVaultFactory.sol";
import {IPicocashVault} from "../src/interfaces/IPicocashVault.sol";
import {MockTIP20} from "./mocks/MockTIP20.sol";

contract PicocashVaultFactoryTest is Test {
    MockTIP20 token;
    PicocashVaultFactory factory;
    address operator = makeAddr("operator");
    address customer = makeAddr("customer"); // pays gas, keeps nothing

    function setUp() public {
        token = new MockTIP20();
        factory = new PicocashVaultFactory();
    }

    function _deploy() internal returns (PicocashVault) {
        vm.prank(customer);
        return PicocashVault(
            factory.deployVault(
                address(token), operator, 2 days, 1000, 100, 100_000, "acme mint", "https://mint.acme.dev", 50, 0, 0
            )
        );
    }

    function test_deployVault_registersAndConfigures() public {
        PicocashVault vault = _deploy();
        assertTrue(factory.isVault(address(vault)));
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaults(0), address(vault));

        // operator control from birth; deployer keeps nothing
        assertEq(vault.operator(), operator);
        assertEq(vault.token(), address(token));
        assertEq(vault.rotationTimelock(), 2 days);
        vm.prank(customer);
        vm.expectRevert(PicocashVault.NotOperator.selector);
        vault.setDepositsPaused(true);
    }

    function test_isVault_falseForForeignContracts() public {
        _deploy();
        PicocashVault rogue = new PicocashVault(
            address(token), operator, 0, 500, 0, 100_000, "rogue", "http://rogue", factory.emergencyVerifier(), 0, 0, 0
        );
        assertFalse(factory.isVault(address(rogue)));
        assertFalse(factory.isVault(address(token)));
    }

    function test_info_exposesDiscoveryAndSolvency() public {
        PicocashVault vault = _deploy();
        token.mint(address(vault), 1_000_000);

        vm.startPrank(operator);
        vault.setActiveKeyset(bytes8(0x006dc833637af45c));
        vault.publishOutstandingSupply(bytes8(0x006dc833637af45c), 900_000);
        vm.stopPrank();

        IPicocashVault.MintInfo memory info = vault.info();
        assertEq(info.name, "acme mint");
        assertEq(info.mintUrl, "https://mint.acme.dev");
        assertEq(info.token, address(token));
        assertEq(info.operator, operator);
        assertEq(info.activeKeysetId, bytes8(0x006dc833637af45c));
        assertEq(info.depositsPaused, false);
        assertEq(info.balance, 1_000_000);
        assertEq(info.lastOutstanding, 900_000);
        assertEq(info.lastPublishedAt, block.timestamp);
    }

    function test_mintInfo_operatorOnlyUpdates() public {
        PicocashVault vault = _deploy();
        vm.prank(customer);
        vm.expectRevert(PicocashVault.NotOperator.selector);
        vault.setMintInfo("evil", "http://evil");

        vm.prank(operator);
        vault.setMintInfo("acme mint v2", "https://mint2.acme.dev");
        assertEq(vault.info().mintUrl, "https://mint2.acme.dev");
    }

    function test_multipleVaults_enumerate() public {
        _deploy();
        vm.prank(customer);
        factory.deployVault(
            address(token), makeAddr("op2"), 1 days, 0, 500, 100_000, "second", "https://second.dev", 0, 0, 0
        );
        assertEq(factory.vaultCount(), 2);
        assertTrue(factory.isVault(factory.vaults(1)));
    }
}
