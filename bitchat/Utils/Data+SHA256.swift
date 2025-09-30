//
//  Data+SHA256.swift
//  bitchat
//
//  Created by Islam on 26/09/2025.
//

import struct Foundation.Data
import struct CryptoKit.SHA256

extension Data {
    /// Returns the hex representation of SHA256 hash
    func sha256Fingerprint() -> String {
        // Implementation matches existing fingerprint generation in NoiseEncryptionService
        sha256Hash().hexEncodedString()
    }
    
    /// Returns the SHA256 hash wrapped in Data
    func sha256Hash() -> Data {
        Data(SHA256.hash(data: self))
    }
}
