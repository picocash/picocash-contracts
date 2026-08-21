// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Secp256k1} from "./Secp256k1.sol";
import {EcashProofVerifier} from "./EcashProofVerifier.sol";

/// @title PicocashEmergencyVerifier — stateless on-chain check of a redeemable eCash proof (PIP-04 §Emergency redemption)
/// @notice Deployed once by the factory and shared by every vault. Given a proof and the keyset public key for its
///         denomination, proves the mint signed it (DLEQ, PIP-00) and that its spending condition (PIP-08 P2PK)
///         is satisfied now. Pure/view: it holds no state and moves no funds.
contract PicocashEmergencyVerifier {
    using Secp256k1 for Secp256k1.Point;

    /// @dev One proof as presented for emergency redemption. `p2pk` MUST be supplied iff the secret is a P2PK
    ///      secret; it is re-serialised and compared byte-for-byte against `secret`, so it cannot lie.
    struct Proof {
        uint256 amount;
        bytes8 keysetId;
        bytes secret; // raw secret bytes
        bytes C; // SEC1 compressed
        bytes32 e;
        bytes32 s;
        bytes32 r;
        P2pk p2pk;
        bytes[] signatures; // 64-byte BIP-340 signatures over sha256(secret)
    }

    struct P2pk {
        bool present;
        string nonce;
        string data; // 33-byte pubkey, lowercase hex
        string[][] tags;
    }

    error InvalidDleq();
    error P2pkConditionsMissing();
    error P2pkConditionsMismatch();
    error P2pkUnsupported(string what);
    error P2pkNotSatisfied();
    error BadSignatureLength();
    error BadHex();
    error BadNumber();

    bytes private constant P2PK_PREFIX = '["P2PK"';

    /// @notice Verify `p` against keyset public key `K` at time `nowTs`. Reverts if not redeemable; returns the ledger key Y.
    function verifyRedemption(Proof calldata p, bytes calldata K, uint256 nowTs) external view returns (bytes32 y) {
        bool ok;
        (ok, y) = EcashProofVerifier.verifyProof(p.secret, p.C, K, uint256(p.e), uint256(p.s), uint256(p.r));
        if (!ok) revert InvalidDleq();
        if (_hasPrefix(p.secret, P2PK_PREFIX)) {
            if (!p.p2pk.present) revert P2pkConditionsMissing();
            if (keccak256(_canonical(p.p2pk)) != keccak256(p.secret)) revert P2pkConditionsMismatch();
            _checkP2pk(p, nowTs);
        }
    }

    // ---- P2PK evaluation (PIP-08 spend rules, SIG_INPUTS, n_sigs = 1) ----

    function _checkP2pk(Proof calldata p, uint256 nowTs) private view {
        uint256 locktime;
        bytes[] memory refund;
        string[][] calldata tags = p.p2pk.tags;
        for (uint256 i = 0; i < tags.length; i++) {
            if (tags[i].length == 0) continue;
            bytes32 name = keccak256(bytes(tags[i][0]));
            if (name == keccak256("locktime")) {
                locktime = _parseUint(tags[i][1]);
            } else if (name == keccak256("refund")) {
                refund = new bytes[](tags[i].length - 1);
                for (uint256 j = 1; j < tags[i].length; j++) {
                    refund[j - 1] = _hexDecode(tags[i][j]);
                }
            } else if (name == keccak256("pubkeys")) {
                revert P2pkUnsupported("pubkeys");
            } else if (name == keccak256("n_sigs")) {
                if (keccak256(bytes(tags[i][1])) != keccak256("1")) revert P2pkUnsupported("n_sigs");
            } else if (name == keccak256("sigflag")) {
                if (keccak256(bytes(tags[i][1])) != keccak256("SIG_INPUTS")) revert P2pkUnsupported("sigflag");
            }
            // unknown tags are ignored (forward compatibility), exactly as off-chain
        }
        bytes32 msgHash = sha256(p.secret);
        bool expired = locktime != 0 && nowTs >= locktime;
        if (!expired) {
            if (!_anySigBy(p.signatures, _hexDecode(p.p2pk.data), msgHash)) revert P2pkNotSatisfied();
            return;
        }
        if (refund.length == 0) return; // lock expired, no refund key: spendable by anyone
        for (uint256 i = 0; i < refund.length; i++) {
            if (_anySigBy(p.signatures, refund[i], msgHash)) return;
        }
        revert P2pkNotSatisfied();
    }

    function _anySigBy(bytes[] calldata sigs, bytes memory pubkey33, bytes32 msgHash) private view returns (bool) {
        for (uint256 i = 0; i < sigs.length; i++) {
            if (schnorrVerify(sigs[i], pubkey33, msgHash)) return true;
        }
        return false;
    }

    /// @notice BIP-340 verification: sig = (r, s), pubkey x-only (from a 33-byte compressed key), msg = 32 bytes.
    function schnorrVerify(bytes calldata sig, bytes memory pubkey33, bytes32 msgHash) public view returns (bool) {
        if (sig.length != 64) revert BadSignatureLength();
        if (pubkey33.length != 33) return false;
        uint256 rx = uint256(bytes32(sig[0:32]));
        uint256 s = uint256(bytes32(sig[32:64]));
        if (rx >= Secp256k1.P || s >= Secp256k1.N) return false;
        uint256 px;
        assembly {
            px := mload(add(pubkey33, 0x21))
        }
        (bool okP, uint256 py) = Secp256k1.liftX(px, false); // x-only keys are implicitly even-y
        if (!okP) return false;
        // e = int(tagged_hash("BIP0340/challenge", r || P || m)) mod n
        bytes32 tag = sha256("BIP0340/challenge");
        uint256 e = uint256(sha256(abi.encodePacked(tag, tag, bytes32(rx), bytes32(px), msgHash))) % Secp256k1.N;
        // R = s·G − e·P ; valid iff R not infinity, R.y even, R.x == r
        Secp256k1.Point memory R;
        try this._mulAdd(s, Secp256k1.generator(), Secp256k1.N - e, Secp256k1.Point(px, py)) returns (
            Secp256k1.Point memory out
        ) {
            R = out;
        } catch {
            return false; // infinity
        }
        return R.y & 1 == 0 && R.x == rx;
    }

    /// @dev external so a revert in toAffine (infinity) can be caught above.
    function _mulAdd(uint256 a, Secp256k1.Point memory A, uint256 b, Secp256k1.Point memory B)
        external
        view
        returns (Secp256k1.Point memory)
    {
        return Secp256k1.mulAdd(a, A, b, B);
    }

    // ---- canonical P2PK JSON, identical to the producer in @picocash/crypto ----

    function _canonical(P2pk calldata c) private pure returns (bytes memory out) {
        out = abi.encodePacked('["P2PK",{"nonce":"', c.nonce, '","data":"', c.data, '"');
        if (c.tags.length > 0) {
            out = abi.encodePacked(out, ',"tags":[');
            for (uint256 i = 0; i < c.tags.length; i++) {
                out = abi.encodePacked(out, i == 0 ? "[" : ",[");
                for (uint256 j = 0; j < c.tags[i].length; j++) {
                    out = abi.encodePacked(out, j == 0 ? '"' : ',"', c.tags[i][j], '"');
                }
                out = abi.encodePacked(out, "]");
            }
            out = abi.encodePacked(out, "]");
        }
        out = abi.encodePacked(out, "}]");
    }

    function _hasPrefix(bytes calldata data, bytes memory prefix) private pure returns (bool) {
        if (data.length < prefix.length) return false;
        for (uint256 i = 0; i < prefix.length; i++) {
            if (data[i] != prefix[i]) return false;
        }
        return true;
    }

    function _parseUint(string calldata s) private pure returns (uint256 v) {
        bytes calldata b = bytes(s);
        if (b.length == 0 || b.length > 18) revert BadNumber();
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c < 48 || c > 57) revert BadNumber();
            v = v * 10 + (c - 48);
        }
    }

    function _hexDecode(string calldata s) private pure returns (bytes memory out) {
        bytes calldata b = bytes(s);
        if (b.length % 2 != 0) revert BadHex();
        out = new bytes(b.length / 2);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = bytes1(_nibble(uint8(b[2 * i])) * 16 + _nibble(uint8(b[2 * i + 1])));
        }
    }

    function _nibble(uint8 c) private pure returns (uint8) {
        if (c >= 48 && c <= 57) return c - 48;
        if (c >= 97 && c <= 102) return c - 87;
        revert BadHex(); // uppercase is not canonical
    }
}
