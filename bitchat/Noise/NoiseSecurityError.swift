//
// NoiseSecurityError.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

enum NoiseSecurityError: Error {
    case sessionExpired
    case sessionExhausted
    case messageTooLarge
    case invalidPeerID
    case rateLimitExceeded
    case handshakeTimeout
}
