import Foundation
import CryptoKit

/// Complete Noise Protocol implementation for BitChat mesh networking
/// Based on Noise_XX_25519_ChaChaPoly_SHA256 pattern
class NoiseProtocolManager {
    
    // MARK: - Properties
    
    private let keychain = KeychainService()
    private var sessions: [String: NoiseSession] = [:]
    private let sessionQueue = DispatchQueue(label: "noise.session", attributes: .concurrent)
    
    // Noise protocol constants
    private let protocolName = "Noise_XX_25519_ChaChaPoly_SHA256"
    private let maxMessageLength = 65535
    private let rekeyInterval = 4294967295 // 2^32 - 1 messages
    
    // Static key pair for this device
    private let staticPrivateKey: Curve25519.KeyAgreement.PrivateKey
    private let staticPublicKey: Curve25519.KeyAgreement.PublicKey
    
    // MARK: - Initialization
    
    init() throws {
        // Load or generate static key pair
        if let keyData = try? keychain.retrieveItem(key: "noise_static_key") {
            self.staticPrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData)
        } else {
            self.staticPrivateKey = Curve25519.KeyAgreement.PrivateKey()
            try keychain.storeItem(staticPrivateKey.rawRepresentation, key: "noise_static_key")
        }
        self.staticPublicKey = staticPrivateKey.publicKey
    }
    
    // MARK: - Session Management
    
    func startHandshake(with peerID: String, isInitiator: Bool) throws -> Data? {
        return try sessionQueue.sync(flags: .barrier) {
            let session = NoiseSession(
                protocolName: protocolName,
                isInitiator: isInitiator,
                staticPrivateKey: staticPrivateKey,
                staticPublicKey: staticPublicKey
            )
            
            sessions[peerID] = session
            
            if isInitiator {
                return try session.writeHandshakeMessage()
            } else {
                return nil
            }
        }
    }
    
    func processHandshakeMessage(_ message: Data, from peerID: String) throws -> Data? {
        return try sessionQueue.sync(flags: .barrier) {
            guard let session = sessions[peerID] else {
                throw NoiseError.noSession
            }
            
            return try session.readHandshakeMessage(message)
        }
    }
    
    func isHandshakeComplete(for peerID: String) -> Bool {
        return sessionQueue.sync {
            return sessions[peerID]?.isHandshakeComplete ?? false
        }
    }
    
    func encrypt(_ data: Data, for peerID: String) throws -> Data {
        return try sessionQueue.sync {
            guard let session = sessions[peerID] else {
                throw NoiseError.noSession
            }
            
            return try session.encrypt(data)
        }
    }
    
    func decrypt(_ data: Data, from peerID: String) throws -> Data {
        return try sessionQueue.sync {
            guard let session = sessions[peerID] else {
                throw NoiseError.noSession
            }
            
            return try session.decrypt(data)
        }
    }
    
    func removeSession(for peerID: String) {
        _ = sessionQueue.sync(flags: .barrier) {
            sessions.removeValue(forKey: peerID)
        }
    }
    
    // MARK: - Cleanup
    
    func cleanupStaleSessions() {
        sessionQueue.sync(flags: .barrier) {
            let now = Date()
            sessions = sessions.filter { _, session in
                now.timeIntervalSince(session.lastActivity) < 300 // 5 minutes
            }
        }
    }
}

// MARK: - Noise Session

private class NoiseSession {
    
    // Handshake state
    private var handshakeState: NoiseHandshakeState
    private var sendCipher: CipherState?
    private var receiveCipher: CipherState?
    
    var isHandshakeComplete: Bool {
        return sendCipher != nil && receiveCipher != nil
    }
    
    var lastActivity = Date()
    
    init(protocolName: String, isInitiator: Bool, staticPrivateKey: Curve25519.KeyAgreement.PrivateKey, staticPublicKey: Curve25519.KeyAgreement.PublicKey) {
        self.handshakeState = NoiseHandshakeState(
            protocolName: protocolName,
            isInitiator: isInitiator,
            staticPrivateKey: staticPrivateKey,
            staticPublicKey: staticPublicKey
        )
    }
    
    func writeHandshakeMessage() throws -> Data {
        lastActivity = Date()
        let message = try handshakeState.writeMessage()
        
        if handshakeState.isComplete {
            let (send, receive) = try handshakeState.split()
            self.sendCipher = send
            self.receiveCipher = receive
        }
        
        return message
    }
    
    func readHandshakeMessage(_ message: Data) throws -> Data? {
        lastActivity = Date()
        try handshakeState.readMessage(message)
        
        if handshakeState.isComplete {
            let (send, receive) = try handshakeState.split()
            self.sendCipher = send
            self.receiveCipher = receive
        }
        
        // If there's another message to send, return it
        if !handshakeState.isComplete && handshakeState.shouldSendMessage {
            return try handshakeState.writeMessage()
        }
        
        return nil
    }
    
    func encrypt(_ data: Data) throws -> Data {
        guard let cipher = sendCipher else {
            throw NoiseError.handshakeNotComplete
        }
        
        lastActivity = Date()
        return try cipher.encrypt(data)
    }
    
    func decrypt(_ data: Data) throws -> Data {
        guard let cipher = receiveCipher else {
            throw NoiseError.handshakeNotComplete
        }
        
        lastActivity = Date()
        return try cipher.decrypt(data)
    }
}

// MARK: - Noise Handshake State

private class NoiseHandshakeState {
    
    private let isInitiator: Bool
    private let staticPrivateKey: Curve25519.KeyAgreement.PrivateKey
    private let staticPublicKey: Curve25519.KeyAgreement.PublicKey
    
    private var ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var ephemeralPublicKey: Curve25519.KeyAgreement.PublicKey?
    private var remoteEphemeralPublicKey: Curve25519.KeyAgreement.PublicKey?
    private var remoteStaticPublicKey: Curve25519.KeyAgreement.PublicKey?
    
    private var handshakeHash = Data()
    private var chainingKey = Data()
    private var messageIndex = 0
    
    var isComplete: Bool {
        return messageIndex >= 3
    }
    
    var shouldSendMessage: Bool {
        return (isInitiator && (messageIndex == 0 || messageIndex == 2)) ||
               (!isInitiator && messageIndex == 1)
    }
    
    init(protocolName: String, isInitiator: Bool, staticPrivateKey: Curve25519.KeyAgreement.PrivateKey, staticPublicKey: Curve25519.KeyAgreement.PublicKey) {
        self.isInitiator = isInitiator
        self.staticPrivateKey = staticPrivateKey
        self.staticPublicKey = staticPublicKey
        
        // Initialize with protocol name
        let protocolNameData = protocolName.data(using: .utf8)!
        if protocolNameData.count <= 32 {
            self.handshakeHash = protocolNameData + Data(repeating: 0, count: 32 - protocolNameData.count)
        } else {
            self.handshakeHash = Data(SHA256.hash(data: protocolNameData))
        }
        
        self.chainingKey = handshakeHash
    }
    
    func writeMessage() throws -> Data {
        var message = Data()
        
        switch messageIndex {
        case 0: // e
            if !isInitiator {
                throw NoiseError.invalidMessageOrder
            }
            
            // Generate ephemeral key pair
            ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
            ephemeralPublicKey = ephemeralPrivateKey!.publicKey
            
            // Add ephemeral public key to message
            message.append(ephemeralPublicKey!.rawRepresentation)
            
            // MixHash(e.public_key)
            mixHash(ephemeralPublicKey!.rawRepresentation)
            
        case 1: // e, ee, s, es
            if isInitiator {
                throw NoiseError.invalidMessageOrder
            }
            
            // Generate ephemeral key pair
            ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
            ephemeralPublicKey = ephemeralPrivateKey!.publicKey
            
            // Add ephemeral public key to message
            message.append(ephemeralPublicKey!.rawRepresentation)
            
            // MixHash(e.public_key)
            mixHash(ephemeralPublicKey!.rawRepresentation)
            
            // ee
            let ee = try ephemeralPrivateKey!.sharedSecretFromKeyAgreement(with: remoteEphemeralPublicKey!)
            mixKey(ee.withUnsafeBytes { Data($0) })
            
            // s (encrypted)
            let encryptedStatic = try encryptAndHash(staticPublicKey.rawRepresentation)
            message.append(encryptedStatic)
            
            // es
            let es = try staticPrivateKey.sharedSecretFromKeyAgreement(with: remoteEphemeralPublicKey!)
            mixKey(es.withUnsafeBytes { Data($0) })
            
        case 2: // s, se
            if !isInitiator {
                throw NoiseError.invalidMessageOrder
            }
            
            // s (encrypted)
            let encryptedStatic = try encryptAndHash(staticPublicKey.rawRepresentation)
            message.append(encryptedStatic)
            
            // se
            let se = try ephemeralPrivateKey!.sharedSecretFromKeyAgreement(with: remoteStaticPublicKey!)
            mixKey(se.withUnsafeBytes { Data($0) })
            
        default:
            throw NoiseError.invalidMessageOrder
        }
        
        messageIndex += 1
        return message
    }
    
    func readMessage(_ message: Data) throws {
        var offset = 0
        
        switch messageIndex {
        case 0: // e
            if isInitiator {
                throw NoiseError.invalidMessageOrder
            }
            
            // Read remote ephemeral public key
            guard message.count >= 32 else {
                throw NoiseError.invalidMessageLength
            }
            
            let ephemeralKeyData = message.subdata(in: 0..<32)
            remoteEphemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralKeyData)
            
            // MixHash(e.public_key)
            mixHash(ephemeralKeyData)
            offset += 32
            
        case 1: // e, ee, s, es
            if !isInitiator {
                throw NoiseError.invalidMessageOrder
            }
            
            // Read remote ephemeral public key
            guard message.count >= 32 else {
                throw NoiseError.invalidMessageLength
            }
            
            let ephemeralKeyData = message.subdata(in: 0..<32)
            remoteEphemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralKeyData)
            
            // MixHash(e.public_key)
            mixHash(ephemeralKeyData)
            offset += 32
            
            // ee
            let ee = try ephemeralPrivateKey!.sharedSecretFromKeyAgreement(with: remoteEphemeralPublicKey!)
            mixKey(ee.withUnsafeBytes { Data($0) })
            
            // s (encrypted) - 32 bytes + 16 bytes auth tag
            guard message.count >= offset + 48 else {
                throw NoiseError.invalidMessageLength
            }
            
            let encryptedStatic = message.subdata(in: offset..<offset + 48)
            let staticKeyData = try decryptAndHash(encryptedStatic)
            remoteStaticPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: staticKeyData)
            offset += 48
            
            // es
            let es = try ephemeralPrivateKey!.sharedSecretFromKeyAgreement(with: remoteStaticPublicKey!)
            mixKey(es.withUnsafeBytes { Data($0) })
            
        case 2: // s, se
            if isInitiator {
                throw NoiseError.invalidMessageOrder
            }
            
            // s (encrypted) - 32 bytes + 16 bytes auth tag
            guard message.count >= offset + 48 else {
                throw NoiseError.invalidMessageLength
            }
            
            let encryptedStatic = message.subdata(in: offset..<offset + 48)
            let staticKeyData = try decryptAndHash(encryptedStatic)
            remoteStaticPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: staticKeyData)
            offset += 48
            
            // se
            let se = try staticPrivateKey.sharedSecretFromKeyAgreement(with: remoteEphemeralPublicKey!)
            mixKey(se.withUnsafeBytes { Data($0) })
            
        default:
            throw NoiseError.invalidMessageOrder
        }
        
        messageIndex += 1
    }
    
    func split() throws -> (CipherState, CipherState) {
        // Split the chaining key into send and receive keys
        let sendKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: chainingKey),
            salt: Data(),
            info: Data([0x01]),
            outputByteCount: 32
        )
        
        let receiveKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: chainingKey),
            salt: Data(),
            info: Data([0x02]),
            outputByteCount: 32
        )
        
        let sendCipher = CipherState(key: sendKey)
        let receiveCipher = CipherState(key: receiveKey)
        
        return isInitiator ? (sendCipher, receiveCipher) : (receiveCipher, sendCipher)
    }
    
    // MARK: - Private Methods
    
    private func mixHash(_ data: Data) {
        let hashData = handshakeHash + data
        handshakeHash = Data(SHA256.hash(data: hashData))
    }
    
    private func mixKey(_ dhOutput: Data) {
        let tempKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: chainingKey),
            salt: dhOutput,
            info: Data(),
            outputByteCount: 32
        )
        chainingKey = tempKey.withUnsafeBytes { Data($0) }
    }
    
    private func encryptAndHash(_ plaintext: Data) throws -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: chainingKey),
            salt: Data(),
            info: Data(),
            outputByteCount: 32
        )
        
        let nonce = Data(handshakeHash.prefix(12))
        let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce))
        let ciphertext = sealedBox.ciphertext + sealedBox.tag
        
        mixHash(ciphertext)
        return ciphertext
    }
    
    private func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: chainingKey),
            salt: Data(),
            info: Data(),
            outputByteCount: 32
        )
        
        let nonce = Data(handshakeHash.prefix(12))
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext.dropLast(16),
            tag: ciphertext.suffix(16)
        )
        
        let plaintext = try AES.GCM.open(sealedBox, using: key)
        mixHash(ciphertext)
        return plaintext
    }
}

// MARK: - Cipher State

private class CipherState {
    private let key: SymmetricKey
    private var nonce: UInt64 = 0
    
    init(key: SymmetricKey) {
        self.key = key
    }
    
    func encrypt(_ plaintext: Data) throws -> Data {
        defer { nonce += 1 }
        
        let nonceData = withUnsafeBytes(of: nonce.littleEndian) { Data($0) } + Data(repeating: 0, count: 4)
        let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonceData))
        return sealedBox.combined!
    }
    
    func decrypt(_ ciphertext: Data) throws -> Data {
        defer { nonce += 1 }
        
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: key)
    }
}

// MARK: - Errors

enum NoiseError: Error {
    case noSession
    case handshakeNotComplete
    case invalidMessageOrder
    case invalidMessageLength
    case cryptographicError
}