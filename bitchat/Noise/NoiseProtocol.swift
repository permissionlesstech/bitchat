//
// NoiseProtocol.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

///
/// # NoiseProtocol
///
/// A complete implementation of the Noise Protocol Framework for end-to-end
/// encryption in BitChat. This file contains the core cryptographic primitives
/// and handshake logic that enable secure communication between peers.
///
/// ## Overview
/// The Noise Protocol Framework is a modern cryptographic framework designed
/// for building secure protocols. BitChat uses Noise to provide:
/// - Mutual authentication between peers
/// - Forward secrecy for all messages
/// - Protection against replay attacks
/// - Minimal round trips for connection establishment
///
/// ## Implementation Details
/// This implementation follows the Noise specification exactly, using:
/// - **Pattern**: XX (most versatile, provides mutual authentication)
/// - **DH**: Curve25519 (X25519 key exchange)
/// - **Cipher**: ChaCha20-Poly1305 (AEAD encryption)
/// - **Hash**: SHA-256 (for key derivation and authentication)
///
/// ## Security Properties
/// The XX handshake pattern provides:
/// 1. **Identity Hiding**: Both parties' identities are encrypted
/// 2. **Forward Secrecy**: Past sessions remain secure if keys are compromised
/// 3. **Key Compromise Impersonation Resistance**: Compromised static key doesn't allow impersonation to that party
/// 4. **Mutual Authentication**: Both parties verify each other's identity
///
/// ## Handshake Flow (XX Pattern)
/// ```
/// Initiator                              Responder
/// ---------                              ---------
/// -> e                                   (ephemeral key)
/// <- e, ee, s, es                       (ephemeral, DH, static encrypted, DH)
/// -> s, se                              (static encrypted, DH)
/// ```
///
/// ## Key Components
/// - **NoiseCipherState**: Manages symmetric encryption with nonce tracking
/// - **NoiseSymmetricState**: Handles key derivation and handshake hashing
/// - **NoiseHandshakeState**: Orchestrates the complete handshake process
///
/// ## Replay Protection
/// Implements sliding window replay protection to prevent message replay attacks:
/// - Tracks nonces within a 1024-message window
/// - Rejects duplicate or too-old nonces
/// - Handles out-of-order message delivery
///
/// ## Usage Example
/// ```swift
/// let handshake = NoiseHandshakeState(
///     pattern: .XX,
///     role: .initiator,
///     localStatic: staticKeyPair
/// )
/// let messageBuffer = handshake.writeMessage(payload: Data())
/// // Send messageBuffer to peer...
/// ```
///
/// ## Security Considerations
/// - Static keys must be generated using secure random sources
/// - Keys should be stored securely (e.g., in Keychain)
/// - Handshake state must not be reused after completion
/// - Transport messages have a nonce limit (2^64-1)
///
/// ## References
/// - Noise Protocol Framework: http://www.noiseprotocol.org/
/// - Noise Specification: http://www.noiseprotocol.org/noise.html
///

import BitLogger
import BitFoundation
import Foundation
import CryptoKit

// Core Noise Protocol implementation
// Based on the Noise Protocol Framework specification

// MARK: - Constants and Types

/// Supported Noise handshake patterns.
/// Each pattern provides different security properties and authentication guarantees.
enum NoisePattern {
    case XX  // Most versatile, mutual authentication
    case IK  // Initiator knows responder's static key
    case NK  // Anonymous initiator
    case X   // One-way: single message to a known static key (no response)
}

enum NoiseRole {
    case initiator
    case responder
}

enum NoiseMessagePattern {
    case e     // Ephemeral key
    case s     // Static key
    case ee    // DH(ephemeral, ephemeral)
    case es    // DH(ephemeral, static)
    case se    // DH(static, ephemeral)
    case ss    // DH(static, static)
}

// MARK: - Noise Protocol Configuration

struct NoiseProtocolName {
    let pattern: String
    let dh: String = "25519"        // Curve25519
    let cipher: String = "ChaChaPoly" // ChaCha20-Poly1305
    let hash: String = "SHA256"      // SHA-256
    
    var fullName: String {
        "Noise_\(pattern)_\(dh)_\(cipher)_\(hash)"
    }
}

// MARK: - Cipher State

/// Manages symmetric encryption state for Noise protocol sessions.
/// Handles ChaCha20-Poly1305 AEAD encryption with automatic nonce management
/// and replay protection using a sliding window algorithm.
/// - Warning: Nonce reuse would be catastrophic for security
final class NoiseCipherState {
    // Constants for replay protection
    private static let NONCE_SIZE_BYTES = 4
    private static let REPLAY_WINDOW_SIZE = 1024
    private static let REPLAY_WINDOW_BYTES = REPLAY_WINDOW_SIZE / 8 // 128 bytes
    private static let HIGH_NONCE_WARNING_THRESHOLD: UInt64 = 1_000_000_000
    
    private var key: SymmetricKey?
    private var nonce: UInt64 = 0
    private var useExtractedNonce: Bool = false
    
    // Sliding window replay protection (only used when useExtractedNonce = true)
    private var highestReceivedNonce: UInt64 = 0
    private var replayWindow: [UInt8] = Array(repeating: 0, count: REPLAY_WINDOW_BYTES)
    
    init() {}
    
    init(key: SymmetricKey, useExtractedNonce: Bool = false) {
        self.key = key
        self.useExtractedNonce = useExtractedNonce
    }
    
    deinit {
        clearSensitiveData()
    }
    
    func initializeKey(_ key: SymmetricKey) {
        self.key = key
        self.nonce = 0
    }
    
    func hasKey() -> Bool {
        return key != nil
    }
    
    // MARK: - Sliding Window Replay Protection
    
    /// Check if nonce is valid for replay protection
    /// BCH-01-010: Use safe arithmetic to prevent integer overflow
    private func isValidNonce(_ receivedNonce: UInt64) -> Bool {
        // Safe overflow check: instead of (receivedNonce + WINDOW_SIZE <= highest)
        // use (highest >= WINDOW_SIZE && receivedNonce <= highest - WINDOW_SIZE)
        let windowSize = UInt64(Self.REPLAY_WINDOW_SIZE)
        if highestReceivedNonce >= windowSize && receivedNonce <= highestReceivedNonce - windowSize {
            return false  // Too old, outside window
        }

        if receivedNonce > highestReceivedNonce {
            return true  // Always accept newer nonces
        }

        let offset = Int(highestReceivedNonce - receivedNonce)
        let byteIndex = offset / 8
        let bitIndex = offset % 8

        return (replayWindow[byteIndex] & (1 << bitIndex)) == 0  // Not yet seen
    }
    
    /// Mark nonce as seen in replay window
    private func markNonceAsSeen(_ receivedNonce: UInt64) {
        if receivedNonce > highestReceivedNonce {
            let shift = Int(receivedNonce - highestReceivedNonce)
            
            if shift >= Self.REPLAY_WINDOW_SIZE {
                // Clear entire window in place - avoid heap allocation
                for i in 0..<Self.REPLAY_WINDOW_BYTES {
                    replayWindow[i] = 0
                }
            } else if shift == 1 {
                // Fast path for in-order packets (~99% of traffic)
                for i in stride(from: Self.REPLAY_WINDOW_BYTES - 1, through: 1, by: -1) {
                    replayWindow[i] = (replayWindow[i] << 1) | (replayWindow[i - 1] >> 7)
                }
                replayWindow[0] <<= 1
            } else {
                // Age every recorded nonce by `shift`. Bit `offset % 8` of byte
                // `offset / 8` marks the nonce `offset` below the highest one
                // (see isValidNonce), so a growing offset moves its bit left
                // within a byte and carries into the low end of the next byte.
                // Shifting the other way files each nonce under the wrong
                // offset: recent replays pass and late packets are refused.
                let byteShift = shift >> 3
                let bitShift = shift & 7
                let invBitShift = 8 - bitShift
                for i in stride(from: Self.REPLAY_WINDOW_BYTES - 1, through: 0, by: -1) {
                    let sourceByteIndex = i - byteShift
                    var newByte: UInt8 = 0
                    
                    if sourceByteIndex >= 0 {
                        newByte = replayWindow[sourceByteIndex] << bitShift
                        if sourceByteIndex > 0 && bitShift != 0 {
                            newByte |= replayWindow[sourceByteIndex - 1] >> invBitShift
                        }
                    }
                    
                    replayWindow[i] = newByte
                }
            }
            
            highestReceivedNonce = receivedNonce
            replayWindow[0] |= 1  // Mark most recent bit as seen
        } else {
            let offset = Int(highestReceivedNonce - receivedNonce)
            // isValidNonce refuses anything a full window behind before this
            // runs; never index past the window if that stops being true.
            guard offset < Self.REPLAY_WINDOW_SIZE else { return }
            let byteIndex = offset / 8
            let bitIndex = offset % 8
            replayWindow[byteIndex] |= (1 << bitIndex)
        }
    }
    
    /// Extract nonce from combined payload <nonce><ciphertext>
    /// Returns tuple of (nonce, ciphertext) or nil if invalid
    private func extractNonceFromCiphertextPayload(_ combinedPayload: Data) throws -> (nonce: UInt64, ciphertext: Data)? {
        guard combinedPayload.count >= Self.NONCE_SIZE_BYTES else {
            return nil
        }

        // Extract 4-byte nonce (big-endian) without extra intermediate Data copies
        let extractedNonce: UInt64 = combinedPayload.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return (UInt64(bytes[0]) << 24)
                | (UInt64(bytes[1]) << 16)
                | (UInt64(bytes[2]) << 8)
                | UInt64(bytes[3])
        }

        // Slice remaining bytes (zero-copy view into combinedPayload)
        let ciphertext = combinedPayload.dropFirst(Self.NONCE_SIZE_BYTES)
        return (nonce: extractedNonce, ciphertext: ciphertext)
    }

    /// Builds the 12-byte Noise ChaChaPoly nonce (4 zero bytes + 8-byte LE counter)
    /// directly on the stack using three UInt32s (exact 12 bytes, zero padding).
    private func makeChaChaNonce(for value: UInt64) throws -> ChaChaPoly.Nonce {
        var nonceWords: (UInt32, UInt32, UInt32) = (
            0,
            UInt32(truncatingIfNeeded: value).littleEndian,
            UInt32(truncatingIfNeeded: value >> 32).littleEndian
        )
        return try withUnsafeBytes(of: &nonceWords) { raw in
            try ChaChaPoly.Nonce(data: raw)
        }
    }

    func encrypt(plaintext: Data, associatedData: Data = Data()) throws -> Data {
        guard let key = self.key else {
            throw NoiseError.uninitializedCipher
        }
        
        // Debug logging for nonce tracking
        let currentNonce = nonce
        
        // Check if nonce exceeds 4-byte limit (UInt32 max value)
        guard nonce <= UInt64(UInt32.max) - 1 else {
            throw NoiseError.nonceExceeded
        }
        
        let chachaNonce = try makeChaChaNonce(for: currentNonce)
        
        let sealedBox = try ChaChaPoly.seal(plaintext, using: key, nonce: chachaNonce, authenticating: associatedData)
        // increment local nonce
        nonce += 1
        
        // Build combined payload in one pre-sized allocation: [<nonce>]<ciphertext><tag>
        let prefixLen = useExtractedNonce ? Self.NONCE_SIZE_BYTES : 0
        var combinedPayload = Data(capacity: prefixLen + sealedBox.ciphertext.count + sealedBox.tag.count)
        if useExtractedNonce {
            var nonceBE = UInt32(currentNonce).bigEndian
            withUnsafeBytes(of: &nonceBE) { combinedPayload.append($0.bindMemory(to: UInt8.self)) }
        }
        combinedPayload.append(sealedBox.ciphertext)
        combinedPayload.append(sealedBox.tag)
        
        // Log high nonce values that might indicate issues
        if currentNonce > Self.HIGH_NONCE_WARNING_THRESHOLD {
            SecureLogger.warning("High nonce value detected: \(currentNonce) - consider rekeying", category: .encryption)
        }
        
        return combinedPayload
    }
    
    func decrypt(ciphertext: Data, associatedData: Data = Data()) throws -> Data {
        guard let key = self.key else {
            throw NoiseError.uninitializedCipher
        }
        
        guard ciphertext.count >= 16 else {
            throw NoiseError.invalidCiphertext
        }
        
        let encryptedData: Data
        let tag: Data
        let decryptionNonce: UInt64
        
        if useExtractedNonce {
            // Extract nonce and ciphertext from combined payload
            guard let (extractedNonce, actualCiphertext) = try extractNonceFromCiphertextPayload(ciphertext) else {
                SecureLogger.debug("Decrypt failed: Could not extract nonce from payload")
                throw NoiseError.invalidCiphertext
            }
            
            // Validate nonce with sliding window replay protection
            guard isValidNonce(extractedNonce) else {
                SecureLogger.debug("Replay attack detected: nonce \(extractedNonce) rejected")
                throw NoiseError.replayDetected
            }
            
            // The 4-byte nonce prefix has been stripped, so the remaining bytes
            // must still hold at least the 16-byte Poly1305 tag. The up-front
            // `ciphertext.count >= 16` guard is not sufficient here (it counts
            // the nonce), and `prefix(count - 16)` would trap on a short payload.
            guard actualCiphertext.count >= 16 else {
                throw NoiseError.invalidCiphertext
            }
            // Split ciphertext and tag (zero-copy Data slices)
            encryptedData = actualCiphertext.prefix(actualCiphertext.count - 16)
            tag = actualCiphertext.suffix(16)
            decryptionNonce = extractedNonce
        } else {
            // Split ciphertext and tag
            encryptedData = ciphertext.prefix(ciphertext.count - 16)
            tag = ciphertext.suffix(16)
            decryptionNonce = nonce
        }
        
        let chachaNonce = try makeChaChaNonce(for: decryptionNonce)
        
        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: chachaNonce,
            ciphertext: encryptedData,
            tag: tag
        )
        
        // Log high nonce values that might indicate issues
        if decryptionNonce > Self.HIGH_NONCE_WARNING_THRESHOLD {
            SecureLogger.warning("High nonce value detected: \(decryptionNonce) - consider rekeying", category: .encryption)
        }
        
        do {
            let plaintext = try ChaChaPoly.open(sealedBox, using: key, authenticating: associatedData)

            // BCH-01-010: Atomic nonce state update
            // Both replay window marking and nonce increment must complete together
            // to prevent state desynchronization. We perform both after successful
            // decryption only, ensuring state consistency on any failure path.
            if useExtractedNonce {
                markNonceAsSeen(decryptionNonce)
            }
            nonce += 1

            return plaintext
        } catch {
            // Decryption failed - nonce state remains unchanged (atomic rollback)
            SecureLogger.debug("Decrypt failed: \(error) for nonce \(decryptionNonce)")
            SecureLogger.error("Decryption failed at nonce \(decryptionNonce)", category: .encryption)
            throw error
        }
    }
    
    /// Securely clear sensitive cryptographic data from memory
    func clearSensitiveData() {
        // Clear the symmetric key
        key = nil
        
        // Reset nonce
        nonce = 0
        highestReceivedNonce = 0
        
        // Clear replay window
        for i in 0..<replayWindow.count {
            replayWindow[i] = 0
        }
    }

    #if DEBUG
    func setNonceForTesting(_ nonce: UInt64) {
        self.nonce = nonce
    }

    func extractNonceFromCiphertextPayloadForTesting(_ combinedPayload: Data) throws -> (nonce: UInt64, ciphertext: Data)? {
        try extractNonceFromCiphertextPayload(combinedPayload)
    }
    #endif
}

// MARK: - Symmetric State

/// Manages the symmetric cryptographic state during Noise handshakes.
/// Responsible for key derivation, protocol name hashing, and maintaining
/// the chaining key that provides key separation between handshake messages.
/// - Note: This class implements the SymmetricState object from the Noise spec
final class NoiseSymmetricState {
    private var cipherState: NoiseCipherState
    private var chainingKey: Data
    private var hash: Data
    
    init(protocolName: String) {
        self.cipherState = NoiseCipherState()
        
        // Initialize with protocol name
        let nameData = protocolName.data(using: .utf8)!
        if nameData.count <= 32 {
            self.hash = nameData + Data(repeating: 0, count: 32 - nameData.count)
        } else {
            self.hash = nameData.sha256Hash()
        }
        self.chainingKey = self.hash
    }
    
    func mixKey(_ inputKeyMaterial: Data) {
        let output = hkdf(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial, numOutputs: 2)
        chainingKey = output[0]
        let tempKey = SymmetricKey(data: output[1])
        cipherState.initializeKey(tempKey)
    }
    
    func mixHash(_ data: Data) {
        var hasher = SHA256()
        hasher.update(data: hash)
        hasher.update(data: data)
        hash = Data(hasher.finalize())
    }
    
    func mixKeyAndHash(_ inputKeyMaterial: Data) {
        let output = hkdf(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial, numOutputs: 3)
        chainingKey = output[0]
        mixHash(output[1])
        let tempKey = SymmetricKey(data: output[2])
        cipherState.initializeKey(tempKey)
    }
    
    func getHandshakeHash() -> Data {
        return hash
    }
    
    func hasCipherKey() -> Bool {
        return cipherState.hasKey()
    }
    
    func encryptAndHash(_ plaintext: Data) throws -> Data {
        if cipherState.hasKey() {
            let ciphertext = try cipherState.encrypt(plaintext: plaintext, associatedData: hash)
            mixHash(ciphertext)
            return ciphertext
        } else {
            mixHash(plaintext)
            return plaintext
        }
    }
    
    func decryptAndHash(_ ciphertext: Data) throws -> Data {
        if cipherState.hasKey() {
            let plaintext = try cipherState.decrypt(ciphertext: ciphertext, associatedData: hash)
            mixHash(ciphertext)
            return plaintext
        } else {
            mixHash(ciphertext)
            return ciphertext
        }
    }
    
    func split(useExtractedNonce: Bool) -> (NoiseCipherState, NoiseCipherState) {
        let output = hkdf(chainingKey: chainingKey, inputKeyMaterial: Data(), numOutputs: 2)
        let tempKey1 = SymmetricKey(data: output[0])
        let tempKey2 = SymmetricKey(data: output[1])

        let c1 = NoiseCipherState(key: tempKey1, useExtractedNonce: useExtractedNonce)
        let c2 = NoiseCipherState(key: tempKey2, useExtractedNonce: useExtractedNonce)

        // BCH-01-010: Clear symmetric state after split per Noise spec
        // The chaining key and hash should not be retained after handshake completes
        clearSensitiveData()

        return (c1, c2)
    }

    /// BCH-01-010: Securely clear sensitive cryptographic state
    /// Called after split() to clear chaining key and hash per Noise spec.
    /// Zeroizes the existing buffers in place with `memset_s` rather than
    /// reassigning fresh `Data` allocations (which would leave key material
    /// intact on the heap).
    func clearSensitiveData() {
        Self.zeroize(&chainingKey)
        Self.zeroize(&hash)
        cipherState.clearSensitiveData()
    }

    private static func zeroize(_ data: inout Data) {
        if !data.isEmpty {
            _ = data.withUnsafeMutableBytes { bytes in
                memset_s(bytes.baseAddress, bytes.count, 0, bytes.count)
            }
        }
        data = Data()
    }

    deinit {
        clearSensitiveData()
    }

    // HKDF implementation
    private func hkdf(chainingKey: Data, inputKeyMaterial: Data, numOutputs: Int) -> [Data] {
        let tempKey = HMAC<SHA256>.authenticationCode(for: inputKeyMaterial, using: SymmetricKey(data: chainingKey))
        let tempKeyData = Data(tempKey)
        
        var outputs: [Data] = []
        var currentOutput = Data()
        
        for i in 1...numOutputs {
            currentOutput = Data(HMAC<SHA256>.authenticationCode(
                for: currentOutput + Data([UInt8(i)]),
                using: SymmetricKey(data: tempKeyData)
            ))
            outputs.append(currentOutput)
        }
        
        return outputs
    }
}

// MARK: - Handshake State

/// Orchestrates the complete Noise handshake process.
/// This is the main interface for establishing encrypted sessions between peers.
/// Manages the handshake state machine, message patterns, and key derivation.
/// - Important: Each handshake instance should only be used once
final class NoiseHandshakeState {
    private let role: NoiseRole
    private let pattern: NoisePattern
    private let keychain: KeychainManagerProtocol
    private var symmetricState: NoiseSymmetricState
    
    // Keys
    private var localStaticPrivate: Curve25519.KeyAgreement.PrivateKey?
    private var localStaticPublic: Curve25519.KeyAgreement.PublicKey?
    private var localEphemeralPrivate: Curve25519.KeyAgreement.PrivateKey?
    private var localEphemeralPublic: Curve25519.KeyAgreement.PublicKey?
    
    private var remoteStaticPublic: Curve25519.KeyAgreement.PublicKey?
    private var remoteEphemeralPublic: Curve25519.KeyAgreement.PublicKey?
    
    // Message patterns
    private var messagePatterns: [[NoiseMessagePattern]] = []
    private var currentPattern = 0
    
    // Test support: predetermined ephemeral keys for test vectors
    private var predeterminedEphemeralKey: Curve25519.KeyAgreement.PrivateKey?
    private var prologueData: Data
    
    init(
        role: NoiseRole,
        pattern: NoisePattern,
        keychain: KeychainManagerProtocol,
        localStaticKey: Curve25519.KeyAgreement.PrivateKey? = nil,
        remoteStaticKey: Curve25519.KeyAgreement.PublicKey? = nil,
        prologue: Data = Data(),
        predeterminedEphemeralKey: Curve25519.KeyAgreement.PrivateKey? = nil
    ) {
        self.role = role
        self.pattern = pattern
        self.keychain = keychain
        self.prologueData = prologue
        self.predeterminedEphemeralKey = predeterminedEphemeralKey
        
        // Initialize static keys
        if let localKey = localStaticKey {
            self.localStaticPrivate = localKey
            self.localStaticPublic = localKey.publicKey
        }
        self.remoteStaticPublic = remoteStaticKey
        
        // Initialize protocol name
        let protocolName = NoiseProtocolName(pattern: pattern.patternName)
        self.symmetricState = NoiseSymmetricState(protocolName: protocolName.fullName)
        
        // Initialize message patterns
        self.messagePatterns = pattern.messagePatterns
        
        // Mix pre-message keys according to pattern
        mixPreMessageKeys()
    }
    
    private func mixPreMessageKeys() {
        // Mix prologue
        symmetricState.mixHash(self.prologueData)
        // For XX pattern, no pre-message keys
        // For IK/NK patterns, we'd mix the responder's static key here
        switch pattern {
        case .XX:
            break // No pre-message keys
        case .IK, .NK, .X:
            if role == .initiator, let remoteStatic = remoteStaticPublic {
                symmetricState.mixHash(remoteStatic.rawRepresentation)
            } else if role == .responder, let localStatic = localStaticPublic {
                symmetricState.mixHash(localStatic.rawRepresentation)
            }
        }
    }
    
    func writeMessage(payload: Data = Data()) throws -> Data {
        guard currentPattern < messagePatterns.count else {
            throw NoiseError.handshakeComplete
        }
        
        var messageBuffer = Data()
        let patterns = messagePatterns[currentPattern]
        
        for pattern in patterns {
            switch pattern {
            case .e:
                // Generate ephemeral key (or use predetermined key for tests)
                if let predetermined = predeterminedEphemeralKey {
                    localEphemeralPrivate = predetermined
                    predeterminedEphemeralKey = nil
                } else {
                    localEphemeralPrivate = Curve25519.KeyAgreement.PrivateKey()
                }
                localEphemeralPublic = localEphemeralPrivate!.publicKey
                messageBuffer.append(localEphemeralPublic!.rawRepresentation)
                symmetricState.mixHash(localEphemeralPublic!.rawRepresentation)
                
            case .s:
                // Send static key (encrypted if cipher is initialized)
                guard let staticPublic = localStaticPublic else {
                    throw NoiseError.missingLocalStaticKey
                }
                let encrypted = try symmetricState.encryptAndHash(staticPublic.rawRepresentation)
                messageBuffer.append(encrypted)
                
            case .ee, .es, .se, .ss:
                try performDHOperation(pattern)
            }
        }
        
        // Encrypt payload
        let encryptedPayload = try symmetricState.encryptAndHash(payload)
        messageBuffer.append(encryptedPayload)
        
        currentPattern += 1
        return messageBuffer
    }
    
    func readMessage(_ message: Data, expectedPayloadLength _: Int = 0) throws -> Data {
        
        guard currentPattern < messagePatterns.count else {
            throw NoiseError.handshakeComplete
        }
        
        var buffer = message
        let patterns = messagePatterns[currentPattern]
        
        for pattern in patterns {
            switch pattern {
            case .e:
                // Read ephemeral key
                guard buffer.count >= 32 else {
                    throw NoiseError.invalidMessage
                }
                let ephemeralData = buffer.prefix(32)
                buffer = buffer.dropFirst(32)
                
                do {
                    remoteEphemeralPublic = try NoiseHandshakeState.validatePublicKey(ephemeralData)
                } catch {
                    SecureLogger.warning("Invalid ephemeral public key received", category: .security)
                    throw NoiseError.invalidMessage
                }
                symmetricState.mixHash(ephemeralData)
                
            case .s:
                // Read static key (may be encrypted)
                let keyLength = symmetricState.hasCipherKey() ? 48 : 32 // 32 + 16 byte tag if encrypted
                guard buffer.count >= keyLength else {
                    throw NoiseError.invalidMessage
                }
                let staticData = buffer.prefix(keyLength)
                buffer = buffer.dropFirst(keyLength)
                do {
                    let decrypted = try symmetricState.decryptAndHash(staticData)
                    remoteStaticPublic = try NoiseHandshakeState.validatePublicKey(decrypted)
                } catch {
                    SecureLogger.error(.authenticationFailed(peerID: "Unknown - handshake"))
                    throw NoiseError.authenticationFailure
                }
                
            case .ee, .es, .se, .ss:
                // Same DH operations as in writeMessage
                try performDHOperation(pattern)
            }
        }
        
        // Decrypt payload
        let payload = try symmetricState.decryptAndHash(buffer)
        currentPattern += 1
        
        return payload
    }
    
    private func performDHOperation(_ pattern: NoiseMessagePattern) throws {
        let keys: (Curve25519.KeyAgreement.PrivateKey?, Curve25519.KeyAgreement.PublicKey?)
        switch (pattern, role) {
        case (.ee, _):
            keys = (localEphemeralPrivate, remoteEphemeralPublic)
        case (.es, .initiator), (.se, .responder):
            keys = (localEphemeralPrivate, remoteStaticPublic)
        case (.es, .responder), (.se, .initiator):
            keys = (localStaticPrivate, remoteEphemeralPublic)
        case (.ss, _):
            keys = (localStaticPrivate, remoteStaticPublic)
        case (.e, _), (.s, _):
            return
        }
        guard let localKey = keys.0, let remoteKey = keys.1 else {
            throw NoiseError.missingKeys
        }
        let shared = try localKey.sharedSecretFromKeyAgreement(with: remoteKey)
        var sharedData = shared.withUnsafeBytes { Data($0) }
        symmetricState.mixKey(sharedData)
        keychain.secureClear(&sharedData)
    }
    
    func isHandshakeComplete() -> Bool {
        return currentPattern >= messagePatterns.count
    }
    
    func getTransportCiphers(useExtractedNonce: Bool) throws -> (send: NoiseCipherState, receive: NoiseCipherState, handshakeHash: Data) {
        guard isHandshakeComplete() else {
            throw NoiseError.handshakeNotComplete
        }

        // BCH-01-010: Capture handshake hash BEFORE split() clears symmetric state
        let finalHandshakeHash = symmetricState.getHandshakeHash()

        let (c1, c2) = symmetricState.split(useExtractedNonce: useExtractedNonce)

        // Initiator uses c1 for sending, c2 for receiving
        // Responder uses c2 for sending, c1 for receiving
        let ciphers = role == .initiator ? (c1, c2) : (c2, c1)
        return (send: ciphers.0, receive: ciphers.1, handshakeHash: finalHandshakeHash)
    }
    
    func getRemoteStaticPublicKey() -> Curve25519.KeyAgreement.PublicKey? {
        return remoteStaticPublic
    }

    #if DEBUG
    func getHandshakeHash() -> Data {
        symmetricState.getHandshakeHash()
    }

    func performDHOperationForTesting(_ pattern: NoiseMessagePattern) throws {
        try performDHOperation(pattern)
    }

    func setCurrentPatternForTesting(_ currentPattern: Int) {
        self.currentPattern = currentPattern
    }

    func setRemoteEphemeralPublicKeyForTesting(_ key: Curve25519.KeyAgreement.PublicKey?) {
        self.remoteEphemeralPublic = key
    }
    #endif
}

// MARK: - Pattern Extensions

extension NoisePattern {
    var patternName: String {
        switch self {
        case .XX: return "XX"
        case .IK: return "IK"
        case .NK: return "NK"
        case .X: return "X"
        }
    }
    
    var messagePatterns: [[NoiseMessagePattern]] {
        switch self {
        case .XX:
            return [
                [.e],           // -> e
                [.e, .ee, .s, .es], // <- e, ee, s, es
                [.s, .se]       // -> s, se
            ]
        case .IK:
            return [
                [.e, .es, .s, .ss], // -> e, es, s, ss
                [.e, .ee, .se]      // <- e, ee, se
            ]
        case .NK:
            return [
                [.e, .es],      // -> e, es
                [.e, .ee]       // <- e, ee
            ]
        case .X:
            return [
                [.e, .es, .s, .ss] // -> e, es, s, ss (single one-way message)
            ]
        }
    }
}

// MARK: - Errors

enum NoiseError: Error {
    case uninitializedCipher
    case invalidCiphertext
    case handshakeComplete
    case handshakeNotComplete
    case missingLocalStaticKey
    case missingKeys
    case invalidMessage
    case authenticationFailure
    case invalidPublicKey
    case replayDetected
    case nonceExceeded
}

// MARK: - Constant-Time Operations

/// BCH-01-010: Constant-time comparison to prevent timing side-channel attacks
/// This function compares two Data objects in constant time, preventing
/// information leakage via timing analysis.
private func constantTimeCompare(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }

    var result: UInt8 = 0
    for i in 0..<a.count {
        result |= a[a.startIndex.advanced(by: i)] ^ b[b.startIndex.advanced(by: i)]
    }
    return result == 0
}

/// BCH-01-010: Constant-time check if all bytes are zero
private func constantTimeIsZero(_ data: Data) -> Bool {
    var result: UInt8 = 0
    for byte in data {
        result |= byte
    }
    return result == 0
}

// MARK: - Key Validation

extension NoiseHandshakeState {
    /// Validate a Curve25519 public key
    /// Checks for weak/invalid keys that could compromise security
    /// BCH-01-010: Uses constant-time operations to prevent timing side-channels
    static func validatePublicKey(_ keyData: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        // Check key length
        guard keyData.count == 32 else {
            throw NoiseError.invalidPublicKey
        }

        // BCH-01-010: Constant-time check for all-zero key (point at infinity)
        if constantTimeIsZero(keyData) {
            throw NoiseError.invalidPublicKey
        }

        // Check for low-order points that could enable small subgroup attacks
        // These are the known bad points for Curve25519
        let lowOrderPoints: [Data] = [
            Data(repeating: 0x00, count: 32), // Already checked above
            Data([0x01] + Data(repeating: 0x00, count: 31)), // Point of order 1
            Data([0x00] + Data(repeating: 0x00, count: 30) + [0x01]), // Another low-order point
            Data([0xe0, 0xeb, 0x7a, 0x7c, 0x3b, 0x41, 0xb8, 0xae, 0x16, 0x56, 0xe3,
                  0xfa, 0xf1, 0x9f, 0xc4, 0x6a, 0xda, 0x09, 0x8d, 0xeb, 0x9c, 0x32,
                  0xb1, 0xfd, 0x86, 0x62, 0x05, 0x16, 0x5f, 0x49, 0xb8, 0x00]), // Low order point
            Data([0x5f, 0x9c, 0x95, 0xbc, 0xa3, 0x50, 0x8c, 0x24, 0xb1, 0xd0, 0xb1,
                  0x55, 0x9c, 0x83, 0xef, 0x5b, 0x04, 0x44, 0x5c, 0xc4, 0x58, 0x1c,
                  0x8e, 0x86, 0xd8, 0x22, 0x4e, 0xdd, 0xd0, 0x9f, 0x11, 0x57]), // Low order point
            Data(repeating: 0xFF, count: 32), // All ones
            Data([0xda, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                  0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                  0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), // Another bad point
            Data([0xdb, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                  0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                  0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])  // Another bad point
        ]

        // BCH-01-010: Constant-time check against known bad points
        // We check all points and accumulate matches to avoid early exit timing leaks
        var foundBadPoint = false
        for badPoint in lowOrderPoints {
            if constantTimeCompare(keyData, badPoint) {
                foundBadPoint = true
            }
        }

        if foundBadPoint {
            SecureLogger.warning("Low-order point detected", category: .security)
            throw NoiseError.invalidPublicKey
        }

        // Try to create the key - CryptoKit will validate curve points internally
        do {
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
            return publicKey
        } catch {
            // If CryptoKit rejects it, it's invalid
            SecureLogger.warning("CryptoKit validation failed", category: .security)
            throw NoiseError.invalidPublicKey
        }
    }
}
