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
        // Implementation matches existing fingerprint generation in NoiseEncryptionService
        sha256Hash().hexEncodedString()
    }

    /// Returns the SHA256 hash wrapped in Data
    func sha256Hash() -> Data {
        Data(sha256Digest)
    }

    func sha256Hex() -> String {
        sha256Digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    var sha256Digest: SHA256.Digest {
        SHA256.hash(data: self)
    }
}
