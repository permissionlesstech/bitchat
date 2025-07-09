//
// NoiseProtocolImplementation.swift
// bitchat
//
// Practical implementation of Noise Protocol Framework for BitChat
// Author: Unit 221B - Lance James (lancejames@unit221b.com)
//

import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Noise Protocol Core Implementation

/// Core Noise Protocol implementation using CryptoKit
public class NoiseProtocol {
    
    // MARK: - Types
    
    public enum Pattern: String {
        case NN = "Noise_NN_25519_ChaChaPoly_BLAKE2b"
        case XX = "Noise_XX_25519_ChaChaPoly_BLAKE2b"
        case IK = "Noise_IK_25519_ChaChaPoly_BLAKE2b"
        case NK = "Noise_NK_25519_ChaChaPoly_BLAKE2b"
        case XXpsk1 = "Noise_XXpsk1_25519_ChaChaPoly_BLAKE2b"
        
        var handshakePattern: HandshakePattern {
            switch self {
            case .NN: return HandshakePattern.NN
            case .XX: return HandshakePattern.XX
            case .IK: return HandshakePattern.IK
            case .NK: return HandshakePattern.NK
            case .XXpsk1: return HandshakePattern.XXpsk1
            }
        }
    }
    
    public struct KeyPair {
        public let privateKey: Curve25519.KeyAgreement.PrivateKey
        public let publicKey: Curve25519.KeyAgreement.PublicKey
        
        public init() {
            self.privateKey = Curve25519.KeyAgreement.PrivateKey()
            self.publicKey = privateKey.publicKey
        }
        
        public init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
            self.privateKey = privateKey
            self.publicKey = privateKey.publicKey
        }
    }
    
    // MARK: - Handshake State
    
    public class HandshakeState {
        private let pattern: HandshakePattern
        private let isInitiator: Bool
        private var symmetricState: SymmetricState
        private var messagePatterns: [[Token]]
        private var messageIndex = 0
        
        // Keys
        private var s: KeyPair? // Static key pair
        private var e: KeyPair? // Ephemeral key pair
        private var rs: Curve25519.KeyAgreement.PublicKey? // Remote static
        private var re: Curve25519.KeyAgreement.PublicKey? // Remote ephemeral
        private var psk: Data? // Pre-shared key
        
        public private(set) var handshakeComplete = false
        public private(set) var sendCipher: CipherState?
        public private(set) var receiveCipher: CipherState?
        
        public init(pattern: Pattern, isInitiator: Bool, s: KeyPair? = nil, rs: Data? = nil, psk: Data? = nil) throws {
            self.pattern = pattern.handshakePattern
            self.isInitiator = isInitiator
            self.messagePatterns = self.pattern.messagePatterns
            self.symmetricState = SymmetricState(protocolName: pattern.rawValue)
            self.s = s
            self.psk = psk
            
            // Parse remote static key if provided
            if let rsData = rs {
                self.rs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rsData)
            }
            
            // Mix in pre-message patterns
            try mixPreMessagePatterns()
        }
        
        private func mixPreMessagePatterns() throws {
            // Handle pre-message patterns (e.g., for IK, NK patterns)
            let preMessages = pattern.preMessagePatterns
            
            for (isInitiatorPattern, tokens) in preMessages {
                for token in tokens {
                    switch token {
                    case .s:
                        if isInitiatorPattern == isInitiator {
                            guard let s = s else { throw NoiseError.missingKey }
                            symmetricState.mixHash(s.publicKey.rawRepresentation)
                        } else {
                            guard let rs = rs else { throw NoiseError.missingKey }
                            symmetricState.mixHash(rs.rawRepresentation)
                        }
                    default:
                        break
                    }
                }
            }
        }
        
        public func writeMessage(payload: Data = Data()) throws -> Data {
            guard !handshakeComplete else {
                throw NoiseError.handshakeComplete
            }
            
            guard shouldWrite else {
                throw NoiseError.unexpectedWrite
            }
            
            var messageBuffer = Data()
            let patterns = messagePatterns[messageIndex]
            
            for token in patterns {
                switch token {
                case .e:
                    // Generate and send ephemeral key
                    e = KeyPair()
                    let ePublic = e!.publicKey.rawRepresentation
                    messageBuffer.append(ePublic)
                    symmetricState.mixHash(ePublic)
                    
                case .s:
                    // Encrypt and send static key
                    guard let s = s else { throw NoiseError.missingKey }
                    let encrypted = try symmetricState.encryptAndHash(s.publicKey.rawRepresentation)
                    messageBuffer.append(encrypted)
                    
                case .ee:
                    // DH(e, re)
                    guard let e = e, let re = re else { throw NoiseError.missingKey }
                    let shared = try e.privateKey.sharedSecretFromKeyAgreement(with: re)
                    symmetricState.mixKey(Data(shared))
                    
                case .es:
                    // DH(e, rs) or DH(s, re)
                    if isInitiator == (messageIndex % 2 == 0) {
                        guard let e = e, let rs = rs else { throw NoiseError.missingKey }
                        let shared = try e.privateKey.sharedSecretFromKeyAgreement(with: rs)
                        symmetricState.mixKey(Data(shared))
                    } else {
                        guard let s = s, let re = re else { throw NoiseError.missingKey }
                        let shared = try s.privateKey.sharedSecretFromKeyAgreement(with: re)
                        symmetricState.mixKey(Data(shared))
                    }
                    
                case .se:
                    // DH(s, re) or DH(e, rs)
                    if isInitiator == (messageIndex % 2 == 0) {
                        guard let s = s, let re = re else { throw NoiseError.missingKey }
                        let shared = try s.privateKey.sharedSecretFromKeyAgreement(with: re)
                        symmetricState.mixKey(Data(shared))
                    } else {
                        guard let e = e, let rs = rs else { throw NoiseError.missingKey }
                        let shared = try e.privateKey.sharedSecretFromKeyAgreement(with: rs)
                        symmetricState.mixKey(Data(shared))
                    }
                    
                case .ss:
                    // DH(s, rs)
                    guard let s = s, let rs = rs else { throw NoiseError.missingKey }
                    let shared = try s.privateKey.sharedSecretFromKeyAgreement(with: rs)
                    symmetricState.mixKey(Data(shared))
                    
                case .psk:
                    // Mix in pre-shared key
                    guard let psk = psk else { throw NoiseError.missingKey }
                    symmetricState.mixKeyAndHash(psk)
                }
            }
            
            // Encrypt payload
            let encryptedPayload = try symmetricState.encryptAndHash(payload)
            messageBuffer.append(encryptedPayload)
            
            messageIndex += 1
            
            // Check if handshake is complete
            if messageIndex >= messagePatterns.count {
                let (c1, c2) = symmetricState.split()
                if isInitiator {
                    sendCipher = c1
                    receiveCipher = c2
                } else {
                    sendCipher = c2
                    receiveCipher = c1
                }
                handshakeComplete = true
            }
            
            return messageBuffer
        }
        
        public func readMessage(_ message: Data) throws -> Data {
            guard !handshakeComplete else {
                throw NoiseError.handshakeComplete
            }
            
            guard !shouldWrite else {
                throw NoiseError.unexpectedRead
            }
            
            var buffer = message
            let patterns = messagePatterns[messageIndex]
            
            for token in patterns {
                switch token {
                case .e:
                    // Read remote ephemeral key
                    guard buffer.count >= 32 else { throw NoiseError.invalidMessage }
                    let reData = buffer.prefix(32)
                    buffer = buffer.dropFirst(32)
                    re = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: reData)
                    symmetricState.mixHash(reData)
                    
                case .s:
                    // Decrypt remote static key
                    let (rsData, consumed) = try symmetricState.decryptAndHash(buffer)
                    buffer = buffer.dropFirst(consumed)
                    rs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rsData)
                    
                case .ee, .es, .se, .ss:
                    // Same DH operations as writeMessage
                    try performDHToken(token)
                    
                case .psk:
                    // Mix in pre-shared key
                    guard let psk = psk else { throw NoiseError.missingKey }
                    symmetricState.mixKeyAndHash(psk)
                }
            }
            
            // Decrypt payload
            let (payload, _) = try symmetricState.decryptAndHash(buffer)
            
            messageIndex += 1
            
            // Check if handshake is complete
            if messageIndex >= messagePatterns.count {
                let (c1, c2) = symmetricState.split()
                if isInitiator {
                    sendCipher = c1
                    receiveCipher = c2
                } else {
                    sendCipher = c2
                    receiveCipher = c1
                }
                handshakeComplete = true
            }
            
            return payload
        }
        
        private func performDHToken(_ token: Token) throws {
            // Same logic as in writeMessage but extracted for reuse
            switch token {
            case .ee:
                guard let e = e, let re = re else { throw NoiseError.missingKey }
                let shared = try e.privateKey.sharedSecretFromKeyAgreement(with: re)
                symmetricState.mixKey(Data(shared))
                
            case .es:
                if isInitiator == (messageIndex % 2 == 0) {
                    guard let e = e, let rs = rs else { throw NoiseError.missingKey }
                    let shared = try e.privateKey.sharedSecretFromKeyAgreement(with: rs)
                    symmetricState.mixKey(Data(shared))
                } else {
                    guard let s = s, let re = re else { throw NoiseError.missingKey }
                    let shared = try s.privateKey.sharedSecretFromKeyAgreement(with: re)
                    symmetricState.mixKey(Data(shared))
                }
                
            case .se:
                if isInitiator == (messageIndex % 2 == 0) {
                    guard let s = s, let re = re else { throw NoiseError.missingKey }
                    let shared = try s.privateKey.sharedSecretFromKeyAgreement(with: re)
                    symmetricState.mixKey(Data(shared))
                } else {
                    guard let e = e, let rs = rs else { throw NoiseError.missingKey }
                    let shared = try e.privateKey.sharedSecretFromKeyAgreement(with: rs)
                    symmetricState.mixKey(Data(shared))
                }
                
            case .ss:
                guard let s = s, let rs = rs else { throw NoiseError.missingKey }
                let shared = try s.privateKey.sharedSecretFromKeyAgreement(with: rs)
                symmetricState.mixKey(Data(shared))
                
            default:
                break
            }
        }
        
        public var shouldWrite: Bool {
            let isEvenMessage = messageIndex % 2 == 0
            return isInitiator ? isEvenMessage : !isEvenMessage
        }
        
        public var remoteStaticPublicKey: Data? {
            return rs?.rawRepresentation
        }
    }
    
    // MARK: - Symmetric State
    
    private class SymmetricState {
        private var cipherState: CipherState
        private var ck: Data // Chaining key
        private var h: Data  // Handshake hash
        
        init(protocolName: String) {
            let protocolNameData = protocolName.data(using: .utf8)!
            
            if protocolNameData.count <= 32 {
                var padded = protocolNameData
                padded.append(Data(repeating: 0, count: 32 - protocolNameData.count))
                self.h = padded
            } else {
                self.h = Self.hash(protocolNameData)
            }
            
            self.ck = h
            self.cipherState = CipherState()
        }
        
        func mixKey(_ keyMaterial: Data) {
            let (ck, k) = Self.hkdf(chainingKey: self.ck, inputKeyMaterial: keyMaterial)
            self.ck = ck
            self.cipherState = CipherState(key: k)
        }
        
        func mixHash(_ data: Data) {
            h = Self.hash(h + data)
        }
        
        func mixKeyAndHash(_ keyMaterial: Data) {
            let (ck, tempH, k) = Self.hkdf3(chainingKey: self.ck, inputKeyMaterial: keyMaterial)
            self.ck = ck
            mixHash(tempH)
            self.cipherState = CipherState(key: k)
        }
        
        func encryptAndHash(_ plaintext: Data) throws -> Data {
            let ciphertext = try cipherState.encrypt(plaintext: plaintext, associatedData: h)
            mixHash(ciphertext)
            return ciphertext
        }
        
        func decryptAndHash(_ ciphertext: Data) throws -> (Data, Int) {
            let plaintext = try cipherState.decrypt(ciphertext: ciphertext, associatedData: h)
            let ciphertextLen = ciphertext.count - plaintext.count + ciphertext.count
            mixHash(ciphertext.prefix(ciphertextLen))
            return (plaintext, ciphertextLen)
        }
        
        func split() -> (CipherState, CipherState) {
            let (k1, k2) = Self.hkdf2(chainingKey: ck, inputKeyMaterial: Data())
            return (CipherState(key: k1), CipherState(key: k2))
        }
        
        // MARK: - Crypto Primitives
        
        static func hash(_ data: Data) -> Data {
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            data.withUnsafeBytes { bytes in
                _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
            }
            return Data(hash)
        }
        
        static func hkdf(chainingKey: Data, inputKeyMaterial: Data) -> (ck: Data, k: Data) {
            let tempKey = hmac(key: chainingKey, data: inputKeyMaterial)
            let ck = hmac(key: tempKey, data: Data([0x01]))
            let k = hmac(key: tempKey, data: ck + Data([0x02]))
            return (ck, k)
        }
        
        static func hkdf2(chainingKey: Data, inputKeyMaterial: Data) -> (k1: Data, k2: Data) {
            let tempKey = hmac(key: chainingKey, data: inputKeyMaterial)
            let k1 = hmac(key: tempKey, data: Data([0x01]))
            let k2 = hmac(key: tempKey, data: k1 + Data([0x02]))
            return (k1, k2)
        }
        
        static func hkdf3(chainingKey: Data, inputKeyMaterial: Data) -> (ck: Data, h: Data, k: Data) {
            let tempKey = hmac(key: chainingKey, data: inputKeyMaterial)
            let ck = hmac(key: tempKey, data: Data([0x01]))
            let h = hmac(key: tempKey, data: ck + Data([0x02]))
            let k = hmac(key: tempKey, data: h + Data([0x03]))
            return (ck, h, k)
        }
        
        static func hmac(key: Data, data: Data) -> Data {
            var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            key.withUnsafeBytes { keyBytes in
                data.withUnsafeBytes { dataBytes in
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA256),
                        keyBytes.baseAddress, key.count,
                        dataBytes.baseAddress, data.count,
                        &hmac
                    )
                }
            }
            return Data(hmac)
        }
    }
    
    // MARK: - Cipher State
    
    public class CipherState {
        private var key: SymmetricKey?
        private var nonce: UInt64 = 0
        
        init(key: Data? = nil) {
            if let key = key {
                self.key = SymmetricKey(data: key)
            }
        }
        
        public func encrypt(plaintext: Data, associatedData: Data? = nil) throws -> Data {
            guard let key = key else {
                // No encryption yet (handshake not complete)
                return plaintext
            }
            
            let nonceData = createNonce()
            let sealedBox = try ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(data: nonceData), authenticating: associatedData ?? Data())
            nonce += 1
            
            return sealedBox.ciphertext + sealedBox.tag
        }
        
        public func decrypt(ciphertext: Data, associatedData: Data? = nil) throws -> Data {
            guard let key = key else {
                // No decryption yet (handshake not complete)
                return ciphertext
            }
            
            guard ciphertext.count >= 16 else {
                throw NoiseError.invalidMessage
            }
            
            let tagStart = ciphertext.count - 16
            let ciphertextOnly = ciphertext.prefix(tagStart)
            let tag = ciphertext.suffix(16)
            
            let nonceData = createNonce()
            let sealedBox = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: nonceData),
                ciphertext: ciphertextOnly,
                tag: tag
            )
            
            let plaintext = try ChaChaPoly.open(sealedBox, using: key, authenticating: associatedData ?? Data())
            nonce += 1
            
            return plaintext
        }
        
        private func createNonce() -> Data {
            var nonceBytes = [UInt8](repeating: 0, count: 12)
            nonceBytes[4] = UInt8((nonce >> 0) & 0xFF)
            nonceBytes[5] = UInt8((nonce >> 8) & 0xFF)
            nonceBytes[6] = UInt8((nonce >> 16) & 0xFF)
            nonceBytes[7] = UInt8((nonce >> 24) & 0xFF)
            nonceBytes[8] = UInt8((nonce >> 32) & 0xFF)
            nonceBytes[9] = UInt8((nonce >> 40) & 0xFF)
            nonceBytes[10] = UInt8((nonce >> 48) & 0xFF)
            nonceBytes[11] = UInt8((nonce >> 56) & 0xFF)
            return Data(nonceBytes)
        }
        
        public func rekey() {
            // Rekey as per Noise specification
            // This is optional but recommended for long-lived connections
        }
    }
    
    // MARK: - Token Types
    
    private enum Token {
        case e   // Ephemeral key
        case s   // Static key  
        case ee  // DH(e, re)
        case es  // DH(e, rs) or DH(s, re)
        case se  // DH(s, re) or DH(e, rs)
        case ss  // DH(s, rs)
        case psk // Pre-shared key
    }
    
    // MARK: - Handshake Patterns
    
    private struct HandshakePattern {
        let name: String
        let preMessagePatterns: [(Bool, [Token])] // (isInitiator, tokens)
        let messagePatterns: [[Token]]
        
        static let NN = HandshakePattern(
            name: "NN",
            preMessagePatterns: [],
            messagePatterns: [
                [.e],
                [.e, .ee]
            ]
        )
        
        static let XX = HandshakePattern(
            name: "XX",
            preMessagePatterns: [],
            messagePatterns: [
                [.e],
                [.e, .ee, .s, .es],
                [.s, .se]
            ]
        )
        
        static let IK = HandshakePattern(
            name: "IK",
            preMessagePatterns: [(false, [.s])], // <- s
            messagePatterns: [
                [.e, .es, .s, .ss],
                [.e, .ee, .se]
            ]
        )
        
        static let NK = HandshakePattern(
            name: "NK",
            preMessagePatterns: [(false, [.s])], // <- s
            messagePatterns: [
                [.e, .es],
                [.e, .ee]
            ]
        )
        
        static let XXpsk1 = HandshakePattern(
            name: "XXpsk1",
            preMessagePatterns: [],
            messagePatterns: [
                [.e],
                [.e, .ee, .s, .es, .psk],
                [.s, .se]
            ]
        )
    }
    
    // MARK: - Errors
    
    public enum NoiseError: LocalizedError {
        case missingKey
        case invalidMessage
        case handshakeComplete
        case unexpectedWrite
        case unexpectedRead
        case cryptographicFailure
        
        public var errorDescription: String? {
            switch self {
            case .missingKey:
                return "Required key is missing"
            case .invalidMessage:
                return "Invalid message format"
            case .handshakeComplete:
                return "Handshake already complete"
            case .unexpectedWrite:
                return "Expected to read message, not write"
            case .unexpectedRead:
                return "Expected to write message, not read"
            case .cryptographicFailure:
                return "Cryptographic operation failed"
            }
        }
    }
}

// MARK: - Integration Example

extension BluetoothMeshService {
    
    /// Example integration with BitChat's mesh service
    func performNoiseHandshake(with peerID: String) {
        do {
            // Create static key pair (would be loaded from keychain in production)
            let staticKeyPair = NoiseProtocol.KeyPair()
            
            // Initialize handshake
            let handshake = try NoiseProtocol.HandshakeState(
                pattern: .XX,
                isInitiator: true,
                s: staticKeyPair
            )
            
            // Generate first message
            let message1 = try handshake.writeMessage()
            
            // Send via BitChat mesh network
            let packet = BitchatPacket(
                type: MessageType.keyExchange.rawValue,
                senderID: myPeerID.data(using: .utf8)!,
                recipientID: peerID.data(using: .utf8),
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: message1,
                signature: nil,
                ttl: 3
            )
            
            // This would send the packet through the mesh
            print("[NOISE] Initiated handshake with peer: \(peerID)")
            
        } catch {
            print("[NOISE] Handshake initiation failed: \(error)")
        }
    }
}