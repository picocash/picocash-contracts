// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {EcashProofVerifier} from "../src/emergency/EcashProofVerifier.sol";
import {Secp256k1} from "../src/emergency/Secp256k1.sol";

/// Exercises the library through an external wrapper so gas is measured per call.
contract VerifierHarness {
    function verify(bytes memory secret, bytes memory C, bytes memory K, uint256 e, uint256 s, uint256 r)
        external
        view
        returns (bool, bytes32)
    {
        return EcashProofVerifier.verifyProof(secret, C, K, e, s, r);
    }

    function h2c(bytes memory secret) external view returns (uint256 x, uint256 y) {
        Secp256k1.Point memory p = EcashProofVerifier.hashToCurve(secret);
        return (p.x, p.y);
    }
}

contract EcashProofVerifierTest is Test {
    struct Vector {
        bytes C;
        bytes K;
        bytes Y;
        bytes32 e;
        string name;
        bytes32 r;
        bytes32 s;
        bytes secret;
    }

    VerifierHarness h;
    Vector[] vectors;

    function setUp() public {
        h = new VerifierHarness();
        string memory json = vm.readFile("test/vectors/ecash-proofs.json");
        uint256 n = 3;
        for (uint256 i = 0; i < n; i++) {
            string memory p = string.concat("[", vm.toString(i), "]");
            vectors.push(
                Vector({
                    name: vm.parseJsonString(json, string.concat(p, ".name")),
                    secret: vm.parseJsonBytes(json, string.concat(p, ".secret")),
                    C: vm.parseJsonBytes(json, string.concat(p, ".C")),
                    K: vm.parseJsonBytes(json, string.concat(p, ".K")),
                    e: vm.parseJsonBytes32(json, string.concat(p, ".e")),
                    s: vm.parseJsonBytes32(json, string.concat(p, ".s")),
                    r: vm.parseJsonBytes32(json, string.concat(p, ".r")),
                    Y: vm.parseJsonBytes(json, string.concat(p, ".Y"))
                })
            );
        }
    }

    function test_hashToCurve_matchesReference() public view {
        for (uint256 i = 0; i < vectors.length; i++) {
            (uint256 x,) = h.h2c(vectors[i].secret);
            bytes memory y = vectors[i].Y;
            uint256 yx;
            assembly {
                yx := mload(add(y, 0x21))
            }
            assertEq(x, yx, vectors[i].name);
        }
    }

    function test_verifiesRealMintProofs() public view {
        for (uint256 i = 0; i < vectors.length; i++) {
            Vector memory v = vectors[i];
            uint256 g0 = gasleft();
            (bool ok, bytes32 yx) = h.verify(v.secret, v.C, v.K, uint256(v.e), uint256(v.s), uint256(v.r));
            uint256 used = g0 - gasleft();
            console2.log(string.concat("gas verifyProof(", v.name, "):"), used);
            assertTrue(ok, v.name);
            bytes memory y = vectors[i].Y;
            uint256 expected;
            assembly {
                expected := mload(add(y, 0x21))
            }
            assertEq(uint256(yx), expected, "ledger key");
        }
    }

    function test_rejectsTamperedProofs() public view {
        Vector memory v = vectors[0];
        // wrong secret
        (bool ok,) = h.verify(bytes.concat(v.secret, hex"00"), v.C, v.K, uint256(v.e), uint256(v.s), uint256(v.r));
        assertFalse(ok, "secret");
        // wrong r
        (ok,) = h.verify(v.secret, v.C, v.K, uint256(v.e), uint256(v.s), uint256(v.r) + 1);
        assertFalse(ok, "r");
        // wrong e
        (ok,) = h.verify(v.secret, v.C, v.K, uint256(v.e) + 1, uint256(v.s), uint256(v.r));
        assertFalse(ok, "e");
        // different mint key (vector 1's C under a foreign K) — swap C from another vector
        (ok,) = h.verify(v.secret, vectors[1].C, v.K, uint256(v.e), uint256(v.s), uint256(v.r));
        assertFalse(ok, "C");
        // zero scalars
        (ok,) = h.verify(v.secret, v.C, v.K, 0, uint256(v.s), uint256(v.r));
        assertFalse(ok, "e=0");
    }

    function test_rejectsPointNotOnCurve() public {
        Vector memory v = vectors[0];
        bytes memory badC = v.C;
        badC[5] = bytes1(uint8(badC[5]) ^ 0x01);
        // either reverts (x not liftable) or verifies false (x liftable to a different point)
        try h.verify(v.secret, badC, v.K, uint256(v.e), uint256(v.s), uint256(v.r)) returns (bool ok, bytes32) {
            assertFalse(ok);
        } catch {}
    }
}
