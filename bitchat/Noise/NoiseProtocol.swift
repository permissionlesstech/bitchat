//
// NoiseProtocol.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit
import os.log

// Core Noise Protocol implementation
// Based on the Noise Protocol Framework specification

// MARK: - Constants and Types

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

class NoiseCipherState {
    private var key: SymmetricKey?
    private var nonce: UInt64 = 0
    
    init() {}
    
    init(key: SymmetricKey) {
        self.key = key
    }
    
    func initializeKey(_ key: SymmetricKey) {
        self.key = key
        self.nonce = 0
    }
    
    func hasKey() -> Bool {
        return key != nil
    }
    
    func encrypt(plaintext: Data, associatedData: Data = Data()) throws -> Data {
        guard let key = self.key else {
            throw NoiseError.uninitializedCipher
        }
        
        // Debug logging for nonce tracking
        let currentNonce = nonce
        
        // Create nonce from counter
        var nonceData = Data(count: 12)
        withUnsafeBytes(of: nonce.littleEndian) { bytes in
            nonceData.replaceSubrange(4..<12, with: bytes)
        }
        
        let sealedBox = try ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(data: nonceData), authenticating: associatedData)
        nonce += 1
        
        // Log high nonce values that might indicate issues
        if currentNonce > 100 {
        }
        
        return sealedBox.ciphertext + sealedBox.tag
    }
    
    func decrypt(ciphertext: Data, associatedData: Data = Data()) throws -> Data {
        guard let key = self.key else {
            throw NoiseError.uninitializedCipher
        }
        
        guard ciphertext.count >= 16 else {
            throw NoiseError.invalidCiphertext
        }
        
        // Debug logging for nonce tracking
        let currentNonce = nonce
        
        // Split ciphertext and tag
        let encryptedData = ciphertext.prefix(ciphertext.count - 16)
        let tag = ciphertext.suffix(16)
        
        // Create nonce from counter
        var nonceData = Data(count: 12)
        withUnsafeBytes(of: nonce.littleEndian) { bytes in
            nonceData.replaceSubrange(4..<12, with: bytes)
        }
        
        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: nonceData),
            ciphertext: encryptedData,
            tag: tag
        )
        
        // Log high nonce values that might indicate issues
        if currentNonce > 100 {
        }
        
        do {
            let plaintext = try ChaChaPoly.open(sealedBox, using: key, authenticating: associatedData)
            nonce += 1
            return plaintext
        } catch {
            // Log authentication failures with nonce info
            throw error
        }
    }
}

// MARK: - Symmetric State

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
        
        let c1 = NoiseCipherState(key: tempKey1)
        let c2 = NoiseCipherState(key: tempKey2)
        
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
        // For XX pattern, no pre-message keys
        // For IK/NK patterns, we'd mix the responder's static key here
        switch pattern {
        case .XX:
            break // No pre-message keys
        case .IK, .NK:
            if role == .initiator, let remoteStatic = remoteStaticPublic {
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
                symmetricState.mixKey(shared.withUnsafeBytes { Data($0) })
                
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
                symmetricState.mixKey(shared.withUnsafeBytes { Data($0) })
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
            SecurityLogger.logSecurityEvent(.invalidKey(reason: "Low-order point detected"), level: .warning)
            throw NoiseError.invalidPublicKey
        }
        
        // Try to create the key - CryptoKit will validate curve points internally
        do {
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
            return publicKey
        } catch {
            // If CryptoKit rejects it, it's invalid
            throw NoiseError.invalidPublicKey
        }
    }
}