//
// NoiseSecurityValidator.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

public struct NoiseSecurityValidator {
    
    /// Validate message size
    public static func validateMessageSize(_ data: Data) -> Bool {
        return data.count <= NoiseSecurityConstants.maxMessageSize
    }
    
    /// Validate handshake message size
    public static func validateHandshakeMessageSize(_ data: Data) -> Bool {
        return data.count <= NoiseSecurityConstants.maxHandshakeMessageSize
    }
}
