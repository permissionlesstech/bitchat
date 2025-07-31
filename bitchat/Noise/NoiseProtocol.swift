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

import Foundation
import CryptoKit
import os.log

// Core Noise Protocol implementation
// Based on the Noise Protocol Framework specification

// MARK: - Constants and Types

/// Supported Noise handshake patterns.
/// Each pattern provides different security properties and authentication guarantees.
enum NoisePattern {
    case XX  // Most versatile, mutual authentication
    case IK  // Initiator knows responder's static key
    case NK  // Anonymous initiator
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
class NoiseCipherState {
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
    private func isValidNonce(_ receivedNonce: UInt64) -> Bool {
        if receivedNonce + UInt64(Self.REPLAY_WINDOW_SIZE) <= highestReceivedNonce {
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
                // Clear entire window - shift is too large
                replayWindow = Array(repeating: 0, count: Self.REPLAY_WINDOW_BYTES)
            } else {
                // Shift window right by `shift` bits
                for i in stride(from: Self.REPLAY_WINDOW_BYTES - 1, through: 0, by: -1) {
                    let sourceByteIndex = i - shift / 8
                    var newByte: UInt8 = 0
                    
                    if sourceByteIndex >= 0 {
                        newByte = replayWindow[sourceByteIndex] >> (shift % 8)
                        if sourceByteIndex > 0 && shift % 8 != 0 {
                            newByte |= replayWindow[sourceByteIndex - 1] << (8 - shift % 8)
                        }
                    }
                    
                    replayWindow[i] = newByte
                }
            }
            
            highestReceivedNonce = receivedNonce
            replayWindow[0] |= 1  // Mark most recent bit as seen
        } else {
            let offset = Int(highestReceivedNonce - receivedNonce)
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

        // Extract 4-byte nonce (big-endian)
        let nonceData = combinedPayload.prefix(Self.NONCE_SIZE_BYTES)
        let extractedNonce = nonceData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> UInt64 in
            let byteArray = bytes.bindMemory(to: UInt8.self)
            var result: UInt64 = 0
            for i in 0..<Self.NONCE_SIZE_BYTES {
                result = (result << 8) | UInt64(byteArray[i])
            }
            return result
        }

        // Extract ciphertext (remaining bytes)
        let ciphertext = combinedPayload.dropFirst(Self.NONCE_SIZE_BYTES)

        return (nonce: extractedNonce, ciphertext: Data(ciphertext))
    }

    /// Convert nonce to 4-byte array (big-endian)
    private func nonceToBytes(_ nonce: UInt64) -> Data {
        var bytes = Data(count: Self.NONCE_SIZE_BYTES)
        withUnsafeBytes(of: nonce.bigEndian) { ptr in
            // Copy only the last 4 bytes from the 8-byte UInt64 
            let sourceBytes = ptr.bindMemory(to: UInt8.self)
            bytes.replaceSubrange(0..<Self.NONCE_SIZE_BYTES, with: sourceBytes.suffix(Self.NONCE_SIZE_BYTES))
        }
        return bytes
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
        
        // Create nonce from counter
        var nonceData = Data(count: 12)
        withUnsafeBytes(of: currentNonce.littleEndian) { bytes in
            nonceData.replaceSubrange(4..<12, with: bytes)
        }
        
        let sealedBox = try ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(data: nonceData), authenticating: associatedData)
        // increment local nonce
        nonce += 1
               
        // Create combined payload: <nonce><ciphertext>
        let combinedPayload: Data
        if (useExtractedNonce) {
            let nonceBytes = nonceToBytes(currentNonce)
            combinedPayload = nonceBytes + sealedBox.ciphertext + sealedBox.tag
        } else {
            combinedPayload = sealedBox.ciphertext + sealedBox.tag
        }
        
        // Log high nonce values that might indicate issues
        if currentNonce > Self.HIGH_NONCE_WARNING_THRESHOLD {
            SecureLogger.log("High nonce value detected: \(currentNonce) - consider rekeying", category: SecureLogger.encryption, level: .warning)
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
                SecureLogger.log("Decrypt failed: Could not extract nonce from payload")
                throw NoiseError.invalidCiphertext
            }
            
            // Validate nonce with sliding window replay protection
            guard isValidNonce(extractedNonce) else {
                SecureLogger.log("Replay attack detected: nonce \(extractedNonce) rejected")
                throw NoiseError.replayDetected
            }

            // Split ciphertext and tag
            encryptedData = actualCiphertext.prefix(actualCiphertext.count - 16)
            tag = actualCiphertext.suffix(16)
            decryptionNonce = extractedNonce
        } else {
            // Split ciphertext and tag
            encryptedData = ciphertext.prefix(ciphertext.count - 16)
            tag = ciphertext.suffix(16)
            decryptionNonce = nonce
        }
        
        // Create nonce from counter
        var nonceData = Data(count: 12)
        withUnsafeBytes(of: decryptionNonce.littleEndian) { bytes in
            nonceData.replaceSubrange(4..<12, with: bytes)
        }
        
        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: nonceData),
            ciphertext: encryptedData,
            tag: tag
        )
        
        // Log high nonce values that might indicate issues
        if decryptionNonce > Self.HIGH_NONCE_WARNING_THRESHOLD {
            SecureLogger.log("High nonce value detected: \(decryptionNonce) - consider rekeying", category: SecureLogger.encryption, level: .warning)
        }
        
        do {
            let plaintext = try ChaChaPoly.open(sealedBox, using: key, authenticating: associatedData)
            
            if useExtractedNonce {
                // Mark nonce as seen after successful decryption
                markNonceAsSeen(decryptionNonce)
            }
            nonce += 1
            return plaintext
        } catch {
            SecureLogger.log("Decrypt failed: \(error) for nonce \(decryptionNonce)")
            // Log authentication failures with nonce info
            SecureLogger.log("Decryption failed at nonce \(decryptionNonce)", category: SecureLogger.encryption, level: .error)
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
}

// MARK: - Symmetric State

/// Manages the symmetric cryptographic state during Noise handshakes.
/// Responsible for key derivation, protocol name hashing, and maintaining
/// the chaining key that provides key separation between handshake messages.
/// - Note: This class implements the SymmetricState object from the Noise spec
class NoiseSymmetricState {
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
            self.hash = Data(SHA256.hash(data: nameData))
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
        hash = Data(SHA256.hash(data: hash + data))
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
    
    func split() -> (NoiseCipherState, NoiseCipherState) {
        let output = hkdf(chainingKey: chainingKey, inputKeyMaterial: Data(), numOutputs: 2)
        let tempKey1 = SymmetricKey(data: output[0])
        let tempKey2 = SymmetricKey(data: output[1])
        
        let c1 = NoiseCipherState(key: tempKey1, useExtractedNonce: true)
        let c2 = NoiseCipherState(key: tempKey2, useExtractedNonce: true)
        
        return (c1, c2)
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
class NoiseHandshakeState {
    private let role: NoiseRole
    private let pattern: NoisePattern
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
    
    init(role: NoiseRole, pattern: NoisePattern, localStaticKey: Curve25519.KeyAgreement.PrivateKey? = nil, remoteStaticKey: Curve25519.KeyAgreement.PublicKey? = nil) {
        self.role = role
        self.pattern = pattern
        
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
        // Mix prologue (empty for XX pattern normally)
        symmetricState.mixHash(Data()) // Empty prologue for XX pattern
        // For XX pattern, no pre-message keys
        // For IK/NK patterns, we'd mix the responder's static key here
        switch pattern {
        case .XX:
            break // No pre-message keys
        case .IK, .NK:
            if role == .initiator, let remoteStatic = remoteStaticPublic {
                _ = symmetricState.getHandshakeHash()
                symmetricState.mixHash(remoteStatic.rawRepresentation)
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
                // Generate ephemeral key
                localEphemeralPrivate = Curve25519.KeyAgreement.PrivateKey()
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
                
            case .ee:
                // DH(local ephemeral, remote ephemeral)
                guard let localEphemeral = localEphemeralPrivate,
                      let remoteEphemeral = remoteEphemeralPublic else {
                    throw NoiseError.missingKeys
                }
                let shared = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteEphemeral)
                var sharedData = shared.withUnsafeBytes { Data($0) }
                symmetricState.mixKey(sharedData)
                // Clear sensitive shared secret
                KeychainManager.secureClear(&sharedData)
                
            case .es:
                // DH(ephemeral, static) - direction depends on role
                if role == .initiator {
                    guard let localEphemeral = localEphemeralPrivate,
                          let remoteStatic = remoteStaticPublic else {
                        throw NoiseError.missingKeys
                    }
                    let shared = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteStatic)
                    symmetricState.mixKey(shared.withUnsafeBytes { Data($0) })
                } else {
                    guard let localStatic = localStaticPrivate,
                          let remoteEphemeral = remoteEphemeralPublic else {
                        throw NoiseError.missingKeys
                    }
                    let shared = try localStatic.sharedSecretFromKeyAgreement(with: remoteEphemeral)
                    symmetricState.mixKey(shared.withUnsafeBytes { Data($0) })
                }
                
            case .se:
                // DH(static, ephemeral) - direction depends on role
                if role == .initiator {
                    guard let localStatic = localStaticPrivate,
                          let remoteEphemeral = remoteEphemeralPublic else {
                        throw NoiseError.missingKeys
                    }
                    let shared = try localStatic.sharedSecretFromKeyAgreement(with: remoteEphemeral)
                    symmetricState.mixKey(shared.withUnsafeBytes { Data($0) })
                } else {
                    guard let localEphemeral = localEphemeralPrivate,
                          let remoteStatic = remoteStaticPublic else {
                        throw NoiseError.missingKeys
                    }
                    let shared = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteStatic)
                    symmetricState.mixKey(shared.withUnsafeBytes { Data($0) })
                }
                
            case .ss:
                // DH(static, static)
                guard let localStatic = localStaticPrivate,
                      let remoteStatic = remoteStaticPublic else {
                    throw NoiseError.missingKeys
                }
                let shared = try localStatic.sharedSecretFromKeyAgreement(with: remoteStatic)
                var sharedData = shared.withUnsafeBytes { Data($0) }
                symmetricState.mixKey(sharedData)
                // Clear sensitive shared secret
                KeychainManager.secureClear(&sharedData)
            }
        }
        
        // Encrypt payload
        let encryptedPayload = try symmetricState.encryptAndHash(payload)
        messageBuffer.append(encryptedPayload)
        
        currentPattern += 1
        return messageBuffer
    }
    
    func readMessage(_ message: Data, expectedPayloadLength: Int = 0) throws -> Data {
        
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
                    SecureLogger.log("Invalid ephemeral public key received", category: SecureLogger.security, level: .warning)
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
                    SecureLogger.logSecurityEvent(.authenticationFailed(peerID: "Unknown - handshake"), level: .error)
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
        switch pattern {
        case .ee:
            guard let localEphemeral = localEphemeralPrivate,
                  let remoteEphemeral = remoteEphemeralPublic else {
                throw NoiseError.missingKeys
            }
            let shared = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteEphemeral)
            symmetricState.mixKey(shared.withUnsafeBytes { Data($0) })
            
        case .es:
            if role == .initiator {
                guard let localEphemeral = localEphemeralPrivate,
                      let remoteStatic = remoteStaticPublic else {
                    throw NoiseError.missingKeys
                }
                let shared = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteStatic)
                var sharedData = shared.withUnsafeBytes { Data($0) }
                symmetricState.mixKey(sharedData)
                // Clear sensitive shared secret
                KeychainManager.secureClear(&sharedData)
            } else {
                guard let localStatic = localStaticPrivate,
                      let remoteEphemeral = remoteEphemeralPublic else {
                    throw NoiseError.missingKeys
                }
                let shared = try localStatic.sharedSecretFromKeyAgreement(with: remoteEphemeral)
                var sharedData = shared.withUnsafeBytes { Data($0) }
                symmetricState.mixKey(sharedData)
                // Clear sensitive shared secret
                KeychainManager.secureClear(&sharedData)
            }
            
        case .se:
            if role == .initiator {
                guard let localStatic = localStaticPrivate,
                      let remoteEphemeral = remoteEphemeralPublic else {
                    throw NoiseError.missingKeys
                }
                let shared = try localStatic.sharedSecretFromKeyAgreement(with: remoteEphemeral)
                var sharedData = shared.withUnsafeBytes { Data($0) }
                symmetricState.mixKey(sharedData)
                // Clear sensitive shared secret
                KeychainManager.secureClear(&sharedData)
            } else {
                guard let localEphemeral = localEphemeralPrivate,
                      let remoteStatic = remoteStaticPublic else {
                    throw NoiseError.missingKeys
                }
                let shared = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteStatic)
                var sharedData = shared.withUnsafeBytes { Data($0) }
                symmetricState.mixKey(sharedData)
                // Clear sensitive shared secret
                KeychainManager.secureClear(&sharedData)
            }
            
        case .ss:
            guard let localStatic = localStaticPrivate,
                  let remoteStatic = remoteStaticPublic else {
                throw NoiseError.missingKeys
            }
            let shared = try localStatic.sharedSecretFromKeyAgreement(with: remoteStatic)
            symmetricState.mixKey(shared.withUnsafeBytes { Data($0) })
            
        default:
            break
        }
    }
    
    func isHandshakeComplete() -> Bool {
        return currentPattern >= messagePatterns.count
    }
    
    func getTransportCiphers() throws -> (send: NoiseCipherState, receive: NoiseCipherState) {
        guard isHandshakeComplete() else {
            throw NoiseError.handshakeNotComplete
        }
        
        let (c1, c2) = symmetricState.split()
        
        // Initiator uses c1 for sending, c2 for receiving
        // Responder uses c2 for sending, c1 for receiving
        return role == .initiator ? (c1, c2) : (c2, c1)
    }
    
    func getRemoteStaticPublicKey() -> Curve25519.KeyAgreement.PublicKey? {
        return remoteStaticPublic
    }
    
    func getHandshakeHash() -> Data {
        return symmetricState.getHandshakeHash()
    }
}

// MARK: - Pattern Extensions

extension NoisePattern {
    var patternName: String {
        switch self {
        case .XX: return "XX"
        case .IK: return "IK"
        case .NK: return "NK"
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

// MARK: - Key Validation

extension NoiseHandshakeState {
    /// Validate a Curve25519 public key
    /// Checks for weak/invalid keys that could compromise security
    static func validatePublicKey(_ keyData: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        // Check key length
        guard keyData.count == 32 else {
            throw NoiseError.invalidPublicKey
        }
        
        // Check for all-zero key (point at infinity)
        if keyData.allSatisfy({ $0 == 0 }) {
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
        
        // Check against known bad points
        if lowOrderPoints.contains(keyData) {
            SecureLogger.log("Low-order point detected", category: SecureLogger.security, level: .warning)
            throw NoiseError.invalidPublicKey
        }
        
        // Try to create the key - CryptoKit will validate curve points internally
        do {
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
            return publicKey
        } catch {
            // If CryptoKit rejects it, it's invalid
            SecureLogger.log("CryptoKit validation failed", category: SecureLogger.security, level: .warning)
            throw NoiseError.invalidPublicKey
        }
    }
}
