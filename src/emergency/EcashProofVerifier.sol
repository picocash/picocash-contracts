// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Secp256k1} from "./Secp256k1.sol";

/// @title EcashProofVerifier — verifies a picocash proof (PIP-00) on-chain using only the mint's PUBLIC key.
/// @notice Prototype for PIP-04 §Emergency redemption. Given a proof (secret, C) with its DLEQ payload (e, s, r)
///         and the keyset public key K for that denomination, checks that the mint's key k (K = k·G) produced C,
///         i.e. C = k·hash_to_curve(secret) — without anyone needing k. Byte-compatible with the off-chain
///         verifier in the picocash crypto package (hash_to_curve per NUT-00, hashE per NUT-12).
library EcashProofVerifier {
    using Secp256k1 for Secp256k1.Point;

    bytes constant DOMAIN_SEPARATOR = "Secp256k1_HashToCurve_Cashu_";

    /// @notice Y = hash_to_curve(secret): first counter whose 0x02 || sha256(sha256(DS||secret) || counter_le32) lifts.
    function hashToCurve(bytes memory secret) internal view returns (Secp256k1.Point memory) {
        bytes32 msgHash = sha256(abi.encodePacked(DOMAIN_SEPARATOR, secret));
        for (uint32 counter = 0; counter < 65536; counter++) {
            bytes32 xh = sha256(abi.encodePacked(msgHash, _le32(counter)));
            (bool ok, uint256 y) = Secp256k1.liftX(uint256(xh), false);
            if (ok) return Secp256k1.Point(uint256(xh), y);
        }
        revert Secp256k1.InvalidPoint();
    }

    function _le32(uint32 v) private pure returns (bytes4) {
        return
            bytes4(uint32((v & 0xff) << 24) | uint32((v & 0xff00) << 8) | uint32((v & 0xff0000) >> 8) | uint32(v >> 24));
    }

    /// @notice e = sha256(hex(R1) || hex(R2) || hex(K) || hex(C_)) over lowercase uncompressed hex (NUT-12).
    function hashE(
        Secp256k1.Point memory R1,
        Secp256k1.Point memory R2,
        Secp256k1.Point memory K,
        Secp256k1.Point memory C_
    ) internal pure returns (bytes32) {
        return sha256(
            abi.encodePacked(R1.uncompressedHex(), R2.uncompressedHex(), K.uncompressedHex(), C_.uncompressedHex())
        );
    }

    /// @notice Verify a proof against keyset public key K. Returns (valid, Y) where Y is the proof's ledger key.
    /// @param secret raw secret bytes (the hex-decoded `secret` field)
    /// @param C SEC1 compressed signature point
    /// @param K SEC1 compressed keyset public key for this denomination
    /// @param e DLEQ challenge, @param s DLEQ response, @param r the blinding factor carried in the proof
    function verifyProof(bytes memory secret, bytes memory C, bytes memory K, uint256 e, uint256 s, uint256 r)
        internal
        view
        returns (bool valid, bytes32 yCompressedX)
    {
        if (e == 0 || e >= Secp256k1.N || s == 0 || s >= Secp256k1.N || r == 0 || r >= Secp256k1.N) {
            return (false, 0);
        }
        Secp256k1.Point memory Kp = Secp256k1.decompress(K);
        Secp256k1.Point memory Cp = Secp256k1.decompress(C);
        Secp256k1.Point memory Y = hashToCurve(secret);
        Secp256k1.Point memory G = Secp256k1.generator();

        // Reconstruct the blinded pair the mint actually signed:
        //   B_ = Y + r·G,  C_ = C + r·K
        Secp256k1.Point memory B_ = Secp256k1.mulAdd(1, Y, r, G);
        Secp256k1.Point memory C_ = Secp256k1.mulAdd(1, Cp, r, Kp);

        // Standard DLEQ check with negation folded into the scalar:
        //   R1 = s·G − e·K,  R2 = s·B_ − e·C_
        uint256 ne = Secp256k1.N - e;
        Secp256k1.Point memory R1 = Secp256k1.mulAdd(s, G, ne, Kp);
        Secp256k1.Point memory R2 = Secp256k1.mulAdd(s, B_, ne, C_);

        valid = uint256(hashE(R1, R2, Kp, C_)) == e;
        yCompressedX = bytes32(Y.x);
    }
}
