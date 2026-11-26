//
// Data+SHA256.swift
// BitFoundation
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import struct Foundation.Data
private import struct CryptoKit.SHA256

public extension Data {
    /// Returns the hex representation of SHA256 hash
    func sha256Fingerprint() -> String {
        Self.hexString(from: sha256Digest, byteCount: SHA256.byteCount)
    }

    /// Returns the SHA256 hash wrapped in Data
    func sha256Hash() -> Data {
        Data(sha256Digest)
    }

    func sha256Hex() -> String {
        Self.hexString(from: sha256Digest, byteCount: SHA256.byteCount)
    }

    /// Returns the lowercase hex encoding of the first `byteCount` bytes of SHA256(self)
    /// without allocating an intermediate `Data`.
    func sha256PrefixHex(bytes byteCount: Int) -> String {
        let clamped = Swift.max(0, Swift.min(byteCount, SHA256.byteCount))
        guard clamped > 0 else { return "" }
        return Self.hexString(from: sha256Digest, byteCount: clamped)
    }

    /// Computes both the lowercase hex fingerprint and the raw 32-byte digest in a single SHA256 pass.
    func sha256FingerprintAndHash() -> (fingerprint: String, hash: Data) {
        let digest = sha256Digest
        return (Self.hexString(from: digest, byteCount: SHA256.byteCount), Data(digest))
    }
}

private extension Data {
    var sha256Digest: SHA256.Digest {
        SHA256.hash(data: self)
    }

    static func hexString(from digest: SHA256.Digest, byteCount: Int) -> String {
        digest.withUnsafeBytes { raw in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return ""
            }
            return Self.hexEncodeBytes(src, count: byteCount)
        }
    }
}
