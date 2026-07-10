//
// NoiseSecurityValidator.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

struct NoiseSecurityValidator {
    
    /// Validate message size
    static func validateMessageSize(_ data: Data) -> Bool {
        return data.count <= NoiseSecurityConstants.maxMessageSize
    }

    static func validateCiphertextSize(_ data: Data) -> Bool {
        data.count <= NoiseSecurityConstants.maxMessageSize
            + NoiseSecurityConstants.transportCiphertextOverhead
    }

    static func validatePrivateFileMessageSize(_ data: Data) -> Bool {
        data.count <= NoiseSecurityConstants.maxPrivateFilePlaintextSize
    }

    static func validatePrivateFileCiphertextSize(_ data: Data) -> Bool {
        data.count <= NoiseSecurityConstants.maxPrivateFileCiphertextSize
    }
    
    /// Validate handshake message size
    static func validateHandshakeMessageSize(_ data: Data) -> Bool {
        return data.count <= NoiseSecurityConstants.maxHandshakeMessageSize
    }
}
