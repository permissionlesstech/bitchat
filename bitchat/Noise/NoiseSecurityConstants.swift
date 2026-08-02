//
// NoiseSecurityConstants.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

enum NoiseSecurityConstants {
    // Maximum message size to prevent memory exhaustion
    static let maxMessageSize = 65535 // 64KB as per Noise spec

    /// The extracted transport nonce (4 bytes) and Poly1305 tag (16 bytes)
    /// added by `NoiseCipherState` around every transport plaintext.
    static let transportCiphertextOverhead = 20

    /// Private-file payloads are the only intentional extension above the
    /// ordinary 64 KiB Noise ceiling. The payload type is encrypted, so large
    /// ciphertexts are admitted only through a separate rate limit and must
    /// prove after decrypt that they are `NoisePayloadType.fileTransfer`.
    /// This is a bounded authenticated-peer exception, not a complete DoS
    /// guard equivalent to `maxMessageSize`.
    static let maxPrivateFilePlaintextSize = FileTransferLimits.maxFramedFileBytes
    static let maxPrivateFileCiphertextSize =
        maxPrivateFilePlaintextSize + transportCiphertextOverhead
    
    // Maximum handshake message size
    static let maxHandshakeMessageSize = 2048 // 2KB to accommodate XX pattern
    
    // Session timeout - sessions older than this should be renegotiated
    static let sessionTimeout: TimeInterval = 86400 // 24 hours
    
    // Maximum number of messages before rekey (2^64 - 1 is the nonce limit)
    static let maxMessagesPerSession: UInt64 = 1_000_000_000 // 1 billion messages
    
    // Rate limiting
    static let maxHandshakesPerMinute = 10
    static let maxMessagesPerSecond = 100
    static let maxLargeCiphertextsPerSecond = 3
    
    // Global rate limiting (across all peers)
    static let maxGlobalHandshakesPerMinute = 30
    static let maxGlobalMessagesPerSecond = 500
    static let maxGlobalLargeCiphertextsPerSecond = 10
}
