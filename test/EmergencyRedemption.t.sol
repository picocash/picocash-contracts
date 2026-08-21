// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PicocashVault} from "../src/PicocashVault.sol";
import {PicocashVaultFactory} from "../src/PicocashVaultFactory.sol";
import {PicocashEmergencyVerifier} from "../src/emergency/PicocashEmergencyVerifier.sol";
import {MockTIP20} from "./mocks/MockTIP20.sol";

contract EmergencyRedemptionTest is Test {
    uint64 constant INTERVAL = 100;
    uint64 constant GRACE = 50;
    bytes8 constant KEYSET = 0x00260deaaf7e6868;
    uint256 constant AMOUNT = 8;
    uint256 constant LOCKTIME = 1_800_000_000;

    MockTIP20 token;
    PicocashVaultFactory factory;
    PicocashVault vault;
    address operator = makeAddr("operator");
    address holder = makeAddr("holder");

    string json;
    bytes K;

    function setUp() public {
        token = new MockTIP20();
        factory = new PicocashVaultFactory();
        vault = PicocashVault(
            factory.deployVault(
                address(token), operator, 2 days, 1000, INTERVAL, 100_000, "em", "https://em.test", GRACE
            )
        );
        json = vm.readFile("test/vectors/emergency.json");
        K = vm.parseJsonBytes(json, "[0].K");
        // back the vault with 100 and register the keyset key for the 8 denomination
        token.mint(address(vault), 100);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = AMOUNT;
        bytes[] memory keys = new bytes[](1);
        keys[0] = K;
        vm.prank(operator);
        vault.registerKeyset(KEYSET, amounts, keys);
    }

    function _proof(uint256 idx) internal view returns (PicocashEmergencyVerifier.Proof memory p) {
        string memory b = string.concat("[", vm.toString(idx), "]");
        p.amount = AMOUNT;
        p.keysetId = KEYSET;
        p.secret = vm.parseJsonBytes(json, string.concat(b, ".secret"));
        p.C = vm.parseJsonBytes(json, string.concat(b, ".C"));
        p.e = vm.parseJsonBytes32(json, string.concat(b, ".e"));
        p.s = vm.parseJsonBytes32(json, string.concat(b, ".s"));
        p.r = vm.parseJsonBytes32(json, string.concat(b, ".r"));
        p.p2pk.present = vm.parseJsonBool(json, string.concat(b, ".p2pk.present"));
        if (p.p2pk.present) {
            p.p2pk.nonce = vm.parseJsonString(json, string.concat(b, ".p2pk.nonce"));
            p.p2pk.data = vm.parseJsonString(json, string.concat(b, ".p2pk.data"));
            // tags: [["locktime","…"],["refund","…"]]
            p.p2pk.tags = new string[][](2);
            p.p2pk.tags[0] = vm.parseJsonStringArray(json, string.concat(b, ".p2pk.tags[0]"));
            p.p2pk.tags[1] = vm.parseJsonStringArray(json, string.concat(b, ".p2pk.tags[1]"));
        }
    }

    function _one(PicocashEmergencyVerifier.Proof memory p)
        internal
        pure
        returns (PicocashEmergencyVerifier.Proof[] memory a)
    {
        a = new PicocashEmergencyVerifier.Proof[](1);
        a[0] = p;
    }

    function _sig(string memory field) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](1);
        sigs[0] = vm.parseJsonBytes(json, string.concat("[1].", field));
    }

    function _goDark() internal {
        // operator publishes once, then vanishes: interval + grace elapse
        vm.prank(operator);
        vault.publishOutstandingSupply(KEYSET, 40); // attested outstanding = 40 of the 100 backing
        vm.roll(block.number + INTERVAL + GRACE + 1);
    }

    function test_notInEmergency_beforeGrace() public {
        vm.prank(operator);
        vault.publishOutstandingSupply(KEYSET, 40);
        vm.roll(block.number + INTERVAL + GRACE); // overdue, but grace not exceeded
        assertTrue(vault.isPublicationOverdue());
        assertFalse(vault.emergencyMode());
        vm.expectRevert(PicocashVault.NotInEmergency.selector);
        vault.emergencyRedeem(_one(_proof(0)), holder);
    }

    function test_plainProof_redeemsOnce_andMeltStillWorks() public {
        _goDark();
        assertTrue(vault.emergencyMode());
        (bool mode,, uint256 redeemed, uint256 cap,) = vault.emergencyInfo();
        assertTrue(mode);
        assertEq(cap, 40);
        assertEq(redeemed, 0);

        uint256 g0 = gasleft();
        vault.emergencyRedeem(_one(_proof(0)), holder);
        console2.log("gas emergencyRedeem(1 plain proof):", g0 - gasleft());
        assertEq(token.balanceOf(holder), AMOUNT);
        assertEq(vault.emergencyRedeemed(), AMOUNT);

        // the same token again: already redeemed
        vm.expectRevert();
        vault.emergencyRedeem(_one(_proof(0)), holder);

        // a returning operator can still melt normally, and publishing clears emergency mode
        vm.prank(operator);
        vault.ecashMelt(holder, 1, bytes32(uint256(1)));
        vm.prank(operator);
        vault.publishOutstandingSupply(KEYSET, 31);
        assertFalse(vault.emergencyMode());
    }

    function test_lockedProof_agentBeforeLocktime_humanAfter() public {
        _goDark();
        PicocashEmergencyVerifier.Proof memory p = _proof(1);

        // no witness → locked
        vm.expectRevert(PicocashEmergencyVerifier.P2pkNotSatisfied.selector);
        vault.emergencyRedeem(_one(p), holder);
        // stranger's signature → still locked
        p.signatures = _sig("sigStranger");
        vm.expectRevert(PicocashEmergencyVerifier.P2pkNotSatisfied.selector);
        vault.emergencyRedeem(_one(p), holder);
        // human's (refund) signature before locktime → not yet
        vm.warp(LOCKTIME - 10);
        p.signatures = _sig("sigHuman");
        vm.expectRevert(PicocashEmergencyVerifier.P2pkNotSatisfied.selector);
        vault.emergencyRedeem(_one(p), holder);
        // agent's signature before locktime → pays
        p.signatures = _sig("sigAgent");
        uint256 g0 = gasleft();
        vault.emergencyRedeem(_one(p), holder);
        console2.log("gas emergencyRedeem(1 P2PK proof):", g0 - gasleft());
        assertEq(token.balanceOf(holder), AMOUNT);
    }

    function test_lockedProof_refundAfterLocktime_lockKeyRefused() public {
        _goDark();
        vm.warp(LOCKTIME + 1);
        PicocashEmergencyVerifier.Proof memory p = _proof(1);
        p.signatures = _sig("sigAgent"); // lock key after expiry: refund key rules now
        vm.expectRevert(PicocashEmergencyVerifier.P2pkNotSatisfied.selector);
        vault.emergencyRedeem(_one(p), holder);
        p.signatures = _sig("sigHuman");
        vault.emergencyRedeem(_one(p), holder);
        assertEq(token.balanceOf(holder), AMOUNT);
    }

    function test_lockedProof_conditionsMustMatchSecret() public {
        _goDark();
        PicocashEmergencyVerifier.Proof memory p = _proof(1);
        p.signatures = _sig("sigStranger");
        // lie about the lock key: canonical re-serialisation no longer matches the secret
        p.p2pk.data = "02aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        vm.expectRevert(PicocashEmergencyVerifier.P2pkConditionsMismatch.selector);
        vault.emergencyRedeem(_one(p), holder);
        // omit the conditions entirely
        p = _proof(1);
        p.p2pk.present = false;
        vm.expectRevert(PicocashEmergencyVerifier.P2pkConditionsMissing.selector);
        vault.emergencyRedeem(_one(p), holder);
    }

    function test_capAndUnknownKeyset() public {
        _goDark();
        // cap is the attested 40: shrink it to 4 and a redemption of 8 must fail
        vm.roll(block.number - (INTERVAL + GRACE + 1));
        vm.prank(operator);
        vault.publishOutstandingSupply(KEYSET, 4);
        vm.roll(block.number + INTERVAL + GRACE + 1);
        vm.expectRevert(abi.encodeWithSelector(PicocashVault.EmergencyCapExceeded.selector, 4));
        vault.emergencyRedeem(_one(_proof(0)), holder);

        PicocashEmergencyVerifier.Proof memory p = _proof(0);
        p.keysetId = 0x1111111111111111;
        vm.expectRevert(
            abi.encodeWithSelector(PicocashVault.KeysetKeyUnknown.selector, bytes8(0x1111111111111111), AMOUNT)
        );
        vault.emergencyRedeem(_one(p), holder);
    }

    function test_neverAttested_capIsBalance_andRegistryIsAppendOnly() public {
        // fresh vault that never publishes: emergency after deploy + interval + grace, cap = balance
        PicocashVault v = PicocashVault(
            factory.deployVault(address(token), operator, 2 days, 1000, INTERVAL, 100_000, "x", "https://x", GRACE)
        );
        token.mint(address(v), 20);
        vm.roll(block.number + INTERVAL + GRACE + 1);
        assertTrue(v.emergencyMode());
        assertEq(v.emergencyCap(), 20);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = AMOUNT;
        bytes[] memory keys = new bytes[](1);
        keys[0] = hex"02aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        vm.prank(operator);
        v.registerKeyset(KEYSET, amounts, keys);
        keys[0] = K;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PicocashVault.KeyAlreadyRegistered.selector, KEYSET, AMOUNT));
        v.registerKeyset(KEYSET, amounts, keys);
    }

    function test_graceWithoutInterval_reverts() public {
        vm.expectRevert(PicocashVault.InvalidEmergencyConfig.selector);
        factory.deployVault(address(token), operator, 2 days, 1000, 0, 100_000, "x", "https://x", GRACE);
    }
}
