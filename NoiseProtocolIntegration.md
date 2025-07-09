# Noise Protocol Integration Architecture for BitChat

## Executive Summary

This document outlines the architecture for integrating the Noise Protocol Framework into BitChat's existing encryption infrastructure. The design prioritizes backward compatibility, minimal disruption to the mesh networking functionality, and enhanced security through modern cryptographic protocols.

## Current State Analysis

### Existing Encryption Service
- Uses Curve25519 for key agreement and signing
- Implements per-message forward secrecy with HKDF
- Stores persistent identity keys in iOS Keychain with biometric protection
- Supports ephemeral session keys with key rotation
- Uses AES-GCM for symmetric encryption

### Mesh Networking Requirements
- Bluetooth LE packet size constraints (max ~500 bytes for extended data)
- Multi-hop message relay with TTL
- Store-and-forward capability for offline peers
- Probabilistic flooding for scalability
- Message fragmentation for large payloads

## Noise Protocol Integration Design

### 1. NoiseProtocolService Architecture

```swift
// NoiseProtocolService.swift
import Foundation
import CryptoKit

/// Service managing Noise Protocol handshakes and transport encryption
class NoiseProtocolService {
    
    // MARK: - Noise Pattern Types
    
    enum NoisePattern {
        case xx  // Unknown peers - mutual authentication
        case ik  // Known responder - optimized reconnection
        case nk  // Anonymous initiator - privacy mode
        case xxPSK1  // XX with pre-shared key for extra security
        
        var patternString: String {
            switch self {
            case .xx: return "Noise_XX_25519_ChaChaPoly_BLAKE2b"
            case .ik: return "Noise_IK_25519_ChaChaPoly_BLAKE2b"
            case .nk: return "Noise_NK_25519_ChaChaPoly_BLAKE2b"
            case .xxPSK1: return "Noise_XXpsk1_25519_ChaChaPoly_BLAKE2b"
            }
        }
    }
    
    // MARK: - Handshake State
    
    class HandshakeState {
        let pattern: NoisePattern
        let isInitiator: Bool
        private var state: OpaquePointer?  // Noise-C library state
        private var messagePatterns: [[TokenType]] = []
        private var currentMessageIndex = 0
        
        // Ephemeral keys
        private var ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey?
        private var ephemeralPublicKey: Curve25519.KeyAgreement.PublicKey?
        
        // Remote keys
        private var remoteEphemeralKey: Curve25519.KeyAgreement.PublicKey?
        private var remoteStaticKey: Curve25519.KeyAgreement.PublicKey?
        
        // Cipher state after handshake
        private var sendCipher: CipherState?
        private var receiveCipher: CipherState?
        
        init(pattern: NoisePattern, isInitiator: Bool, localStaticKey: Curve25519.KeyAgreement.PrivateKey?, remoteStaticKey: Curve25519.KeyAgreement.PublicKey? = nil, psk: Data? = nil) throws {
            self.pattern = pattern
            self.isInitiator = isInitiator
            
            // Initialize message patterns based on pattern type
            self.messagePatterns = Self.getMessagePatterns(for: pattern)
            
            // Generate ephemeral keys
            self.ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
            self.ephemeralPublicKey = ephemeralPrivateKey?.publicKey
            
            // Set remote static key if known (for IK, NK patterns)
            self.remoteStaticKey = remoteStaticKey
        }
        
        /// Process next handshake message
        func processMessage(_ data: Data) throws -> (payload: Data?, transportReady: Bool) {
            guard currentMessageIndex < messagePatterns.count else {
                throw NoiseError.handshakeAlreadyComplete
            }
            
            let tokens = messagePatterns[currentMessageIndex]
            var payload = Data()
            
            // Process tokens for this message
            for token in tokens {
                switch token {
                case .e:
                    if shouldWrite() {
                        // Send our ephemeral key
                        payload.append(ephemeralPublicKey!.rawRepresentation)
                    } else {
                        // Receive remote ephemeral key
                        guard data.count >= 32 else { throw NoiseError.invalidMessage }
                        let keyData = data.prefix(32)
                        remoteEphemeralKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
                    }
                    
                case .s:
                    // Handle static key transmission
                    if shouldWrite() {
                        // Encrypt and send our static key
                        // Implementation depends on cipher state
                    } else {
                        // Receive and decrypt remote static key
                    }
                    
                case .ee, .es, .se, .ss:
                    // Perform DH operations
                    try performDH(token)
                    
                case .psk:
                    // Mix pre-shared key into handshake
                    try mixPSK()
                }
            }
            
            currentMessageIndex += 1
            let isComplete = currentMessageIndex >= messagePatterns.count
            
            if isComplete {
                // Derive transport keys
                (sendCipher, receiveCipher) = try deriveTransportKeys()
            }
            
            return (payload, isComplete)
        }
        
        /// Check if we should write the next message
        func shouldWrite() -> Bool {
            let isEvenMessage = currentMessageIndex % 2 == 0
            return isInitiator ? isEvenMessage : !isEvenMessage
        }
        
        private func performDH(_ token: TokenType) throws {
            // Implement DH operations based on token type
            // This would integrate with CryptoKit's Curve25519
        }
        
        private func mixPSK() throws {
            // Mix pre-shared key into handshake state
        }
        
        private func deriveTransportKeys() throws -> (CipherState, CipherState) {
            // Derive send and receive cipher states
            // Using HKDF to derive separate keys for each direction
            let sendKey = SymmetricKey(size: .bits256)
            let receiveKey = SymmetricKey(size: .bits256)
            
            return (
                CipherState(key: sendKey),
                CipherState(key: receiveKey)
            )
        }
        
        private static func getMessagePatterns(for pattern: NoisePattern) -> [[TokenType]] {
            switch pattern {
            case .xx:
                return [
                    [.e],                    // -> e
                    [.e, .ee, .s, .es],     // <- e, ee, s, es
                    [.s, .se]               // -> s, se
                ]
            case .ik:
                return [
                    [.e, .es, .s, .ss],     // -> e, es, s, ss
                    [.e, .ee, .se]          // <- e, ee, se
                ]
            case .nk:
                return [
                    [.e, .es],              // -> e, es
                    [.e, .ee]               // <- e, ee
                ]
            case .xxPSK1:
                return [
                    [.e],                    // -> e
                    [.e, .ee, .s, .es, .psk], // <- e, ee, s, es, psk
                    [.s, .se]               // -> s, se
                ]
            }
        }
    }
    
    // MARK: - Token Types
    
    private enum TokenType {
        case e   // Ephemeral key
        case s   // Static key
        case ee  // DH(ephemeral, ephemeral)
        case es  // DH(ephemeral, static)
        case se  // DH(static, ephemeral)
        case ss  // DH(static, static)
        case psk // Pre-shared key
    }
    
    // MARK: - Cipher State
    
    class CipherState {
        private let key: SymmetricKey
        private var nonce: UInt64 = 0
        
        init(key: SymmetricKey) {
            self.key = key
        }
        
        func encrypt(_ plaintext: Data, associatedData: Data? = nil) throws -> Data {
            let nonce = try AES.GCM.Nonce(data: generateNonce())
            let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce, associatedData: associatedData)
            self.nonce += 1
            return sealedBox.combined ?? Data()
        }
        
        func decrypt(_ ciphertext: Data, associatedData: Data? = nil) throws -> Data {
            let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
            let plaintext = try AES.GCM.open(sealedBox, using: key, associatedData: associatedData)
            self.nonce += 1
            return plaintext
        }
        
        private func generateNonce() -> Data {
            var nonceData = Data(count: 12)
            nonceData.withUnsafeMutableBytes { bytes in
                bytes.storeBytes(of: nonce.littleEndian, as: UInt64.self)
            }
            return nonceData
        }
    }
    
    // MARK: - Session Management
    
    struct NoiseSession {
        let sessionID: String
        let peerID: String
        let pattern: NoisePattern
        let handshakeState: HandshakeState?
        let sendCipher: CipherState?
        let receiveCipher: CipherState?
        let establishedAt: Date
        var lastActivityAt: Date
        let isInitiator: Bool
        
        var isHandshakeComplete: Bool {
            return sendCipher != nil && receiveCipher != nil
        }
    }
    
    // MARK: - Service Properties
    
    private var sessions: [String: NoiseSession] = [:]
    private let sessionQueue = DispatchQueue(label: "bitchat.noise.sessions", attributes: .concurrent)
    private let encryptionService: EncryptionService
    private let keychain = KeychainService()
    
    // Session timeout (24 hours)
    private let sessionTimeout: TimeInterval = 86400
    
    // MARK: - Initialization
    
    init(encryptionService: EncryptionService) {
        self.encryptionService = encryptionService
        startSessionCleanupTimer()
    }
    
    // MARK: - Public Methods
    
    /// Initiate a Noise handshake with a peer
    func initiateHandshake(with peerID: String, pattern: NoisePattern, knownPublicKey: Data? = nil) throws -> Data {
        return try sessionQueue.sync(flags: .barrier) {
            // Check if we already have an active session
            if let existingSession = sessions[peerID], existingSession.isHandshakeComplete {
                throw NoiseError.sessionAlreadyExists
            }
            
            // Get our static keys from EncryptionService
            let localStaticKey = try getLocalStaticKey()
            
            // Parse known public key if provided
            var remoteStaticKey: Curve25519.KeyAgreement.PublicKey?
            if let knownKey = knownPublicKey {
                remoteStaticKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: knownKey)
            }
            
            // Create handshake state
            let handshakeState = try HandshakeState(
                pattern: pattern,
                isInitiator: true,
                localStaticKey: localStaticKey,
                remoteStaticKey: remoteStaticKey
            )
            
            // Generate first handshake message
            let (message, complete) = try handshakeState.processMessage(Data())
            
            // Create session
            let session = NoiseSession(
                sessionID: UUID().uuidString,
                peerID: peerID,
                pattern: pattern,
                handshakeState: complete ? nil : handshakeState,
                sendCipher: nil,
                receiveCipher: nil,
                establishedAt: Date(),
                lastActivityAt: Date(),
                isInitiator: true
            )
            
            sessions[peerID] = session
            
            return message ?? Data()
        }
    }
    
    /// Process incoming handshake message
    func processHandshakeMessage(from peerID: String, message: Data) throws -> (response: Data?, complete: Bool) {
        return try sessionQueue.sync(flags: .barrier) {
            guard let session = sessions[peerID],
                  let handshakeState = session.handshakeState else {
                throw NoiseError.noActiveHandshake
            }
            
            let (payload, complete) = try handshakeState.processMessage(message)
            
            if complete {
                // Update session with transport ciphers
                var updatedSession = session
                updatedSession.sendCipher = handshakeState.sendCipher
                updatedSession.receiveCipher = handshakeState.receiveCipher
                updatedSession.handshakeState = nil
                sessions[peerID] = updatedSession
            }
            
            return (payload, complete)
        }
    }
    
    /// Encrypt message for peer using established Noise transport
    func encryptMessage(_ plaintext: Data, for peerID: String) throws -> Data {
        return try sessionQueue.sync {
            guard let session = sessions[peerID],
                  let sendCipher = session.sendCipher else {
                // Fall back to existing encryption if no Noise session
                return try encryptionService.encrypt(plaintext, for: peerID)
            }
            
            // Update activity timestamp
            sessionQueue.async(flags: .barrier) {
                self.sessions[peerID]?.lastActivityAt = Date()
            }
            
            return try sendCipher.encrypt(plaintext)
        }
    }
    
    /// Decrypt message from peer using established Noise transport
    func decryptMessage(_ ciphertext: Data, from peerID: String) throws -> Data {
        return try sessionQueue.sync {
            guard let session = sessions[peerID],
                  let receiveCipher = session.receiveCipher else {
                // Fall back to existing encryption if no Noise session
                return try encryptionService.decrypt(ciphertext, from: peerID)
            }
            
            // Update activity timestamp
            sessionQueue.async(flags: .barrier) {
                self.sessions[peerID]?.lastActivityAt = Date()
            }
            
            return try receiveCipher.decrypt(ciphertext)
        }
    }
    
    /// Check if peer has active Noise session
    func hasActiveSession(with peerID: String) -> Bool {
        return sessionQueue.sync {
            guard let session = sessions[peerID] else { return false }
            return session.isHandshakeComplete
        }
    }
    
    /// Get appropriate pattern for peer connection
    func getRecommendedPattern(for peerID: String) -> NoisePattern {
        // Check if we know this peer's static key
        if let _ = encryptionService.getPeerIdentityKey(peerID) {
            // Known peer - use IK for optimized reconnection
            return .ik
        } else if UserDefaults.standard.bool(forKey: "AnonymousMode") {
            // Anonymous mode - use NK pattern
            return .nk
        } else {
            // Unknown peer - use XX for mutual authentication
            return .xx
        }
    }
    
    // MARK: - Private Methods
    
    private func getLocalStaticKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        // This would integrate with existing EncryptionService key management
        // For now, generate a new key
        return Curve25519.KeyAgreement.PrivateKey()
    }
    
    private func startSessionCleanupTimer() {
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.cleanupExpiredSessions()
        }
    }
    
    private func cleanupExpiredSessions() {
        sessionQueue.async(flags: .barrier) {
            let now = Date()
            self.sessions = self.sessions.filter { _, session in
                now.timeIntervalSince(session.lastActivityAt) < self.sessionTimeout
            }
        }
    }
}

// MARK: - Error Types

enum NoiseError: LocalizedError {
    case handshakeAlreadyComplete
    case invalidMessage
    case noActiveHandshake
    case sessionAlreadyExists
    case unsupportedPattern
    case cryptographicFailure(String)
    
    var errorDescription: String? {
        switch self {
        case .handshakeAlreadyComplete:
            return "Handshake already completed"
        case .invalidMessage:
            return "Invalid handshake message"
        case .noActiveHandshake:
            return "No active handshake for peer"
        case .sessionAlreadyExists:
            return "Session already exists with peer"
        case .unsupportedPattern:
            return "Unsupported Noise pattern"
        case .cryptographicFailure(let detail):
            return "Cryptographic operation failed: \(detail)"
        }
    }
}
```

### 2. Integration with BluetoothMeshService

```swift
// Extension to BluetoothMeshService for Noise Protocol support
extension BluetoothMeshService {
    
    // MARK: - Noise Protocol Message Types
    
    enum NoiseMessageType: UInt8 {
        case handshakeInitiation = 0x10
        case handshakeResponse = 0x11
        case handshakeComplete = 0x12
        case transportMessage = 0x13
    }
    
    // MARK: - Noise Handshake Management
    
    /// Initiate Noise handshake with peer
    private func initiateNoiseHandshake(with peerID: String) {
        guard let noiseService = self.noiseProtocolService else { return }
        
        do {
            // Determine appropriate pattern
            let pattern = noiseService.getRecommendedPattern(for: peerID)
            
            // Get known public key if available
            let knownKey = encryptionService.getPeerIdentityKey(peerID)
            
            // Initiate handshake
            let handshakeMessage = try noiseService.initiateHandshake(
                with: peerID,
                pattern: pattern,
                knownPublicKey: knownKey
            )
            
            // Wrap in BitchatPacket
            let packet = BitchatPacket(
                type: NoiseMessageType.handshakeInitiation.rawValue,
                senderID: myPeerID.data(using: .utf8)!,
                recipientID: peerID.data(using: .utf8),
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: handshakeMessage,
                signature: nil,
                ttl: 1  // Direct handshake, no relay
            )
            
            // Send via existing mesh network
            sendPacket(packet, to: peerID)
            
        } catch {
            print("[NOISE] Failed to initiate handshake: \(error)")
        }
    }
    
    /// Process incoming Noise protocol messages
    private func processNoiseMessage(_ packet: BitchatPacket) {
        guard let noiseService = self.noiseProtocolService,
              let messageType = NoiseMessageType(rawValue: packet.type) else { return }
        
        let senderID = String(data: packet.senderID, encoding: .utf8) ?? ""
        
        switch messageType {
        case .handshakeInitiation:
            handleHandshakeInitiation(from: senderID, payload: packet.payload)
            
        case .handshakeResponse:
            handleHandshakeResponse(from: senderID, payload: packet.payload)
            
        case .handshakeComplete:
            handleHandshakeComplete(from: senderID)
            
        case .transportMessage:
            handleNoiseTransportMessage(from: senderID, payload: packet.payload)
        }
    }
    
    private func handleHandshakeInitiation(from peerID: String, payload: Data) {
        // Process handshake initiation and send response
        do {
            let (response, complete) = try noiseProtocolService?.processHandshakeMessage(
                from: peerID,
                message: payload
            ) ?? (nil, false)
            
            if let responseData = response {
                let packet = BitchatPacket(
                    type: NoiseMessageType.handshakeResponse.rawValue,
                    senderID: myPeerID.data(using: .utf8)!,
                    recipientID: peerID.data(using: .utf8),
                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                    payload: responseData,
                    signature: nil,
                    ttl: 1
                )
                sendPacket(packet, to: peerID)
            }
            
            if complete {
                notifyHandshakeComplete(peerID)
            }
            
        } catch {
            print("[NOISE] Failed to process handshake initiation: \(error)")
        }
    }
    
    // MARK: - Message Encryption Override
    
    /// Override message encryption to use Noise when available
    private func encryptMessagePayload(_ payload: Data, for peerID: String) throws -> Data {
        // Check if Noise session is available
        if let noiseService = noiseProtocolService,
           noiseService.hasActiveSession(with: peerID) {
            return try noiseService.encryptMessage(payload, for: peerID)
        }
        
        // Fall back to existing encryption
        return try encryptionService.encrypt(payload, for: peerID)
    }
    
    /// Override message decryption to use Noise when available
    private func decryptMessagePayload(_ payload: Data, from peerID: String) throws -> Data {
        // Check if Noise session is available
        if let noiseService = noiseProtocolService,
           noiseService.hasActiveSession(with: peerID) {
            return try noiseService.decryptMessage(payload, from: peerID)
        }
        
        // Fall back to existing encryption
        return try encryptionService.decrypt(payload, from: peerID)
    }
}
```

### 3. Backward Compatibility Layer

```swift
// CompatibilityService.swift
import Foundation

/// Service managing backward compatibility during Noise Protocol migration
class CompatibilityService {
    
    enum ProtocolVersion: UInt8 {
        case legacy = 1      // Current AES-GCM based
        case noiseEnabled = 2 // Noise Protocol support
    }
    
    struct PeerCapabilities {
        let peerID: String
        let protocolVersion: ProtocolVersion
        let supportsNoise: Bool
        let supportedPatterns: [NoiseProtocolService.NoisePattern]
        let lastUpdated: Date
    }
    
    private var peerCapabilities: [String: PeerCapabilities] = [:]
    private let queue = DispatchQueue(label: "bitchat.compatibility", attributes: .concurrent)
    
    /// Check if peer supports Noise Protocol
    func peerSupportsNoise(_ peerID: String) -> Bool {
        return queue.sync {
            peerCapabilities[peerID]?.supportsNoise ?? false
        }
    }
    
    /// Update peer capabilities from announcement
    func updatePeerCapabilities(from announcement: Data, peerID: String) {
        // Parse capability announcement
        guard announcement.count >= 2 else { return }
        
        let version = ProtocolVersion(rawValue: announcement[0]) ?? .legacy
        let supportsNoise = announcement[1] & 0x01 != 0
        
        let capabilities = PeerCapabilities(
            peerID: peerID,
            protocolVersion: version,
            supportsNoise: supportsNoise,
            supportedPatterns: parseNoisePatterns(from: announcement),
            lastUpdated: Date()
        )
        
        queue.async(flags: .barrier) {
            self.peerCapabilities[peerID] = capabilities
        }
    }
    
    /// Create capability announcement
    func createCapabilityAnnouncement() -> Data {
        var announcement = Data()
        
        // Protocol version
        announcement.append(ProtocolVersion.noiseEnabled.rawValue)
        
        // Capability flags
        var flags: UInt8 = 0
        flags |= 0x01  // Supports Noise
        flags |= 0x02  // Supports XX pattern
        flags |= 0x04  // Supports IK pattern
        flags |= 0x08  // Supports NK pattern
        announcement.append(flags)
        
        return announcement
    }
    
    private func parseNoisePatterns(from data: Data) -> [NoiseProtocolService.NoisePattern] {
        guard data.count > 1 else { return [] }
        
        let flags = data[1]
        var patterns: [NoiseProtocolService.NoisePattern] = []
        
        if flags & 0x02 != 0 { patterns.append(.xx) }
        if flags & 0x04 != 0 { patterns.append(.ik) }
        if flags & 0x08 != 0 { patterns.append(.nk) }
        
        return patterns
    }
}
```

### 4. iOS Keychain Integration for Noise Keys

```swift
// NoiseKeychainManager.swift
import Foundation
import Security

/// Manages Noise Protocol keys in iOS Keychain
class NoiseKeychainManager {
    
    private let keychainService = "com.bitchat.noise"
    private let staticKeyTag = "noise.static.key"
    private let pskTag = "noise.psk."
    
    /// Store Noise static key pair
    func storeStaticKeyPair(_ privateKey: Data, publicKey: Data) throws {
        let keyData = [
            "private": privateKey.base64EncodedString(),
            "public": publicKey.base64EncodedString()
        ]
        
        let jsonData = try JSONEncoder().encode(keyData)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: staticKeyTag,
            kSecValueData as String: jsonData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true
        ]
        
        // Delete existing item
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unableToStore
        }
    }
    
    /// Retrieve Noise static key pair
    func retrieveStaticKeyPair() throws -> (privateKey: Data, publicKey: Data)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: staticKeyTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        guard status == errSecSuccess,
              let data = item as? Data,
              let keyData = try? JSONDecoder().decode([String: String].self, from: data),
              let privateKeyString = keyData["private"],
              let publicKeyString = keyData["public"],
              let privateKey = Data(base64Encoded: privateKeyString),
              let publicKey = Data(base64Encoded: publicKeyString) else {
            return nil
        }
        
        return (privateKey, publicKey)
    }
    
    /// Store pre-shared key for peer
    func storePSK(_ psk: Data, for peerID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: pskTag + peerID,
            kSecValueData as String: psk,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true
        ]
        
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unableToStore
        }
    }
    
    /// Retrieve pre-shared key for peer
    func retrievePSK(for peerID: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: pskTag + peerID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        guard status == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        
        return data
    }
}

enum KeychainError: Error {
    case unableToStore
    case unableToRetrieve
    case dataCorrupted
}
```

### 5. Testing Strategy

```swift
// NoiseProtocolTests.swift
import XCTest
@testable import BitChat

class NoiseProtocolTests: XCTestCase {
    
    var aliceService: NoiseProtocolService!
    var bobService: NoiseProtocolService!
    var encryptionService: EncryptionService!
    
    override func setUp() {
        super.setUp()
        encryptionService = try! EncryptionService()
        aliceService = NoiseProtocolService(encryptionService: encryptionService)
        bobService = NoiseProtocolService(encryptionService: encryptionService)
    }
    
    func testXXHandshake() throws {
        // Test mutual authentication pattern
        let aliceFirstMessage = try aliceService.initiateHandshake(
            with: "bob",
            pattern: .xx
        )
        
        let (bobResponse, bobComplete) = try bobService.processHandshakeMessage(
            from: "alice",
            message: aliceFirstMessage
        )
        
        XCTAssertNotNil(bobResponse)
        XCTAssertFalse(bobComplete)
        
        let (aliceFinal, aliceComplete) = try aliceService.processHandshakeMessage(
            from: "bob",
            message: bobResponse!
        )
        
        XCTAssertNotNil(aliceFinal)
        XCTAssertTrue(aliceComplete)
        
        // Both should now have established sessions
        XCTAssertTrue(aliceService.hasActiveSession(with: "bob"))
        XCTAssertTrue(bobService.hasActiveSession(with: "alice"))
    }
    
    func testEncryptedTransport() throws {
        // Establish session first
        try establishXXSession()
        
        let message = "Hello, Noise Protocol!".data(using: .utf8)!
        
        // Alice encrypts for Bob
        let ciphertext = try aliceService.encryptMessage(message, for: "bob")
        
        // Bob decrypts from Alice
        let plaintext = try bobService.decryptMessage(ciphertext, from: "alice")
        
        XCTAssertEqual(plaintext, message)
    }
    
    func testBackwardCompatibility() throws {
        // Test fallback to legacy encryption
        let legacyMessage = "Legacy message".data(using: .utf8)!
        
        // No Noise session established
        let encrypted = try aliceService.encryptMessage(legacyMessage, for: "charlie")
        
        // Should fall back to EncryptionService
        let decrypted = try encryptionService.decrypt(encrypted, from: "alice")
        
        XCTAssertEqual(decrypted, legacyMessage)
    }
    
    func testBLEPacketSizeConstraints() throws {
        // Test that handshake messages fit in BLE packets
        let handshakeMessage = try aliceService.initiateHandshake(
            with: "bob",
            pattern: .xx
        )
        
        // BLE extended data length is ~500 bytes
        XCTAssertLessThan(handshakeMessage.count, 500)
    }
    
    private func establishXXSession() throws {
        let msg1 = try aliceService.initiateHandshake(with: "bob", pattern: .xx)
        let (msg2, _) = try bobService.processHandshakeMessage(from: "alice", message: msg1)
        let (msg3, _) = try aliceService.processHandshakeMessage(from: "bob", message: msg2!)
        let (_, complete) = try bobService.processHandshakeMessage(from: "alice", message: msg3!)
        XCTAssertTrue(complete)
    }
}
```

## Implementation Plan

### Phase 1: Core Noise Protocol Service (Week 1-2)
1. Implement NoiseProtocolService with basic XX pattern
2. Create HandshakeState management
3. Implement CipherState for transport encryption
4. Add session management and cleanup

### Phase 2: Pattern Support (Week 3)
1. Implement IK pattern for known peer reconnection
2. Implement NK pattern for anonymous mode
3. Add PSK support for extra security
4. Create pattern selection logic

### Phase 3: Integration (Week 4-5)
1. Integrate with BluetoothMeshService
2. Add Noise message types to protocol
3. Implement handshake message routing
4. Override encryption/decryption methods

### Phase 4: Backward Compatibility (Week 6)
1. Implement CompatibilityService
2. Add capability announcements
3. Create fallback mechanisms
4. Test mixed protocol scenarios

### Phase 5: iOS Integration (Week 7)
1. Implement NoiseKeychainManager
2. Add biometric protection for Noise keys
3. Integrate with existing key rotation
4. Handle key migration

### Phase 6: Testing & Optimization (Week 8-9)
1. Comprehensive unit tests
2. Integration tests with mesh network
3. Performance optimization for BLE
4. Security audit preparation

### Phase 7: Migration Strategy (Week 10)
1. Gradual rollout plan
2. User notification system
3. Key migration utilities
4. Documentation updates

## Security Considerations

1. **Key Management**
   - Noise static keys stored in iOS Keychain with biometric protection
   - Automatic key rotation every 30 days
   - Secure key derivation using HKDF

2. **Pattern Selection**
   - XX for unknown peers (mutual authentication)
   - IK for known peers (optimized performance)
   - NK for anonymous mode (privacy protection)
   - PSK support for high-security scenarios

3. **Backward Compatibility**
   - Graceful fallback to existing encryption
   - Capability negotiation prevents downgrade attacks
   - Parallel operation during migration period

4. **BLE Constraints**
   - Handshake messages optimized for packet size
   - Efficient binary encoding
   - Minimal overhead for transport messages

## Performance Optimizations

1. **Connection Pooling**
   - Reuse established Noise sessions
   - Automatic session timeout and cleanup
   - Efficient memory management

2. **Handshake Optimization**
   - IK pattern reduces round trips for known peers
   - Cached ephemeral keys for quick reconnection
   - Parallel handshake processing

3. **Message Processing**
   - Zero-copy encryption where possible
   - Efficient nonce generation
   - Optimized for iOS hardware acceleration

## Conclusion

This architecture provides a robust integration of the Noise Protocol Framework into BitChat while maintaining backward compatibility and respecting the constraints of Bluetooth LE mesh networking. The phased implementation approach ensures minimal disruption to existing functionality while providing enhanced security through modern cryptographic protocols.

**Author:** Unit 221B  
**Contact:** Lance James - lancejames@unit221b.com  
**Date:** 2025-01-09