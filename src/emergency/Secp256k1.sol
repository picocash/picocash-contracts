// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title Secp256k1 — minimal curve arithmetic for on-chain eCash proof verification (PIP-04 §Emergency redemption)
/// @notice Jacobian coordinates, Shamir double-scalar multiplication, SEC1 decompression via the modexp precompile.
///         Written for auditability over speed; see PIP-04 for gas figures and the optimisation roadmap.
library Secp256k1 {
    uint256 internal constant P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    uint256 internal constant GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;

    struct Point {
        uint256 x;
        uint256 y;
    }

    error InvalidPoint();
    error ModExpFailed();

    /// @dev a^e mod m via the EIP-198 precompile.
    function modExp(uint256 a, uint256 e, uint256 m) internal view returns (uint256 result) {
        bool ok;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x20)
            mstore(add(ptr, 0x20), 0x20)
            mstore(add(ptr, 0x40), 0x20)
            mstore(add(ptr, 0x60), a)
            mstore(add(ptr, 0x80), e)
            mstore(add(ptr, 0xa0), m)
            ok := staticcall(gas(), 0x05, ptr, 0xc0, ptr, 0x20)
            result := mload(ptr)
        }
        if (!ok) revert ModExpFailed();
    }

    function modInv(uint256 a) internal view returns (uint256) {
        return modExp(a, P - 2, P);
    }

    function isOnCurve(Point memory p) internal pure returns (bool) {
        if (p.x >= P || p.y >= P) return false;
        uint256 lhs = mulmod(p.y, p.y, P);
        uint256 rhs = addmod(mulmod(mulmod(p.x, p.x, P), p.x, P), 7, P);
        return lhs == rhs;
    }

    /// @notice Decompress a SEC1 compressed point (0x02/0x03 || x). Reverts if x is not on the curve.
    function decompress(bytes memory sec1) internal view returns (Point memory) {
        if (sec1.length != 33) revert InvalidPoint();
        uint8 prefix = uint8(sec1[0]);
        if (prefix != 0x02 && prefix != 0x03) revert InvalidPoint();
        uint256 x;
        assembly {
            x := mload(add(sec1, 0x21))
        }
        (bool ok, uint256 y) = liftX(x, prefix == 0x03);
        if (!ok) revert InvalidPoint();
        return Point(x, y);
    }

    /// @notice y for a given x (choosing parity), or ok=false if x is not on the curve.
    function liftX(uint256 x, bool odd) internal view returns (bool ok, uint256 y) {
        if (x >= P) return (false, 0);
        uint256 rhs = addmod(mulmod(mulmod(x, x, P), x, P), 7, P);
        y = modExp(rhs, (P + 1) / 4, P); // P ≡ 3 mod 4
        if (mulmod(y, y, P) != rhs) return (false, 0);
        if ((y & 1 == 1) != odd) y = P - y;
        return (true, y);
    }

    /// @notice Lowercase-hex ASCII of the SEC1 uncompressed encoding (04 || x || y) — what hashE consumes.
    function uncompressedHex(Point memory p) internal pure returns (bytes memory out) {
        bytes memory raw = abi.encodePacked(uint8(0x04), p.x, p.y);
        bytes16 alphabet = 0x30313233343536373839616263646566;
        out = new bytes(130);
        for (uint256 i = 0; i < 65; i++) {
            out[2 * i] = alphabet[uint8(raw[i]) >> 4];
            out[2 * i + 1] = alphabet[uint8(raw[i]) & 0x0f];
        }
    }

    // ---- Jacobian arithmetic (Z == 0 is the point at infinity) ----

    function jDouble(uint256 x, uint256 y, uint256 z) internal pure returns (uint256, uint256, uint256) {
        if (y == 0 || z == 0) return (0, 1, 0);
        uint256 yy = mulmod(y, y, P);
        uint256 s = mulmod(4, mulmod(x, yy, P), P);
        uint256 m = mulmod(3, mulmod(x, x, P), P);
        uint256 x3 = addmod(mulmod(m, m, P), P - mulmod(2, s, P), P);
        uint256 y3 = addmod(mulmod(m, addmod(s, P - x3, P), P), P - mulmod(8, mulmod(yy, yy, P), P), P);
        uint256 z3 = mulmod(2, mulmod(y, z, P), P);
        return (x3, y3, z3);
    }

    function jAdd(uint256 x1, uint256 y1, uint256 z1, uint256 x2, uint256 y2, uint256 z2)
        internal
        pure
        returns (uint256, uint256, uint256)
    {
        if (z1 == 0) return (x2, y2, z2);
        if (z2 == 0) return (x1, y1, z1);
        uint256 z1z1 = mulmod(z1, z1, P);
        uint256 z2z2 = mulmod(z2, z2, P);
        uint256 u1 = mulmod(x1, z2z2, P);
        uint256 u2 = mulmod(x2, z1z1, P);
        uint256 s1 = mulmod(y1, mulmod(z2, z2z2, P), P);
        uint256 s2 = mulmod(y2, mulmod(z1, z1z1, P), P);
        if (u1 == u2) {
            if (s1 != s2) return (0, 1, 0);
            return jDouble(x1, y1, z1);
        }
        uint256 h = addmod(u2, P - u1, P);
        uint256 r = addmod(s2, P - s1, P);
        uint256 hh = mulmod(h, h, P);
        uint256 hhh = mulmod(hh, h, P);
        uint256 v = mulmod(u1, hh, P);
        uint256 x3 = addmod(addmod(mulmod(r, r, P), P - hhh, P), P - mulmod(2, v, P), P);
        uint256 y3 = addmod(mulmod(r, addmod(v, P - x3, P), P), P - mulmod(s1, hhh, P), P);
        uint256 z3 = mulmod(h, mulmod(z1, z2, P), P);
        return (x3, y3, z3);
    }

    function toAffine(uint256 x, uint256 y, uint256 z) internal view returns (Point memory) {
        if (z == 0) revert InvalidPoint(); // infinity is never a valid result here
        uint256 zi = modInv(z);
        uint256 zi2 = mulmod(zi, zi, P);
        return Point(mulmod(x, zi2, P), mulmod(y, mulmod(zi2, zi, P), P));
    }

    /// @notice a·A + b·B via Shamir's trick (one doubling chain, three precomputed sums).
    function mulAdd(uint256 a, Point memory A, uint256 b, Point memory B) internal view returns (Point memory) {
        a %= N;
        b %= N;
        (uint256 sx, uint256 sy, uint256 sz) = jAdd(A.x, A.y, 1, B.x, B.y, 1); // A + B
        uint256 rx;
        uint256 ry = 1;
        uint256 rz;
        for (uint256 i = 256; i > 0;) {
            unchecked {
                i--;
            }
            (rx, ry, rz) = jDouble(rx, ry, rz);
            bool ba = (a >> i) & 1 == 1;
            bool bb = (b >> i) & 1 == 1;
            if (ba && bb) (rx, ry, rz) = jAdd(rx, ry, rz, sx, sy, sz);
            else if (ba) (rx, ry, rz) = jAdd(rx, ry, rz, A.x, A.y, 1);
            else if (bb) (rx, ry, rz) = jAdd(rx, ry, rz, B.x, B.y, 1);
        }
        return toAffine(rx, ry, rz);
    }

    function add(Point memory A, Point memory B) internal view returns (Point memory) {
        (uint256 x, uint256 y, uint256 z) = jAdd(A.x, A.y, 1, B.x, B.y, 1);
        return toAffine(x, y, z);
    }

    function generator() internal pure returns (Point memory) {
        return Point(GX, GY);
    }
}
