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

    /// Private files are an explicit BitChat extension to the ordinary Noise
    /// message-size ceiling. They remain bounded by the same framed-file cap
    /// used by the binary and fragment decoders. Only the `.privateFile`
    /// typed-payload path is allowed to use this larger budget.
    private static let privateFileOuterPacketOverhead =
        (BinaryProtocol.v1HeaderSize + 2) // v2 adds two length bytes
        + BinaryProtocol.senderIDSize
        + BinaryProtocol.recipientIDSize
    static let maxPrivateFilePlaintextSize = FileTransferLimits.maxFramedFileBytes
        - privateFileOuterPacketOverhead
        - transportCiphertextOverhead
    static let maxPrivateFileCiphertextSize =
        maxPrivateFilePlaintextSize + transportCiphertextOverhead
    
    // Maximum handshake message size
    static let maxHandshakeMessageSize = 2048 // 2KB to accommodate XX pattern

    // Noise XX message 1 contains only the initiator's 32-byte ephemeral key.
    static let xxInitialMessageSize = 32
    
    // Session timeout - sessions older than this should be renegotiated
    static let sessionTimeout: TimeInterval = 86400 // 24 hours
    
    // Maximum number of messages before rekey (2^64 - 1 is the nonce limit)
    static let maxMessagesPerSession: UInt64 = 1_000_000_000 // 1 billion messages
    
    // Rate limiting
    static let maxHandshakesPerMinute = 10
    static let maxMessagesPerSecond = 100
    
    // Global rate limiting (across all peers)
    static let maxGlobalHandshakesPerMinute = 30
    static let maxGlobalMessagesPerSecond = 500
}
