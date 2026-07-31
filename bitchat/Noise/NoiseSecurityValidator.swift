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
    
    /// Validate handshake message size
    static func validateHandshakeMessageSize(_ data: Data) -> Bool {
        return data.count <= NoiseSecurityConstants.maxHandshakeMessageSize
    }
}
