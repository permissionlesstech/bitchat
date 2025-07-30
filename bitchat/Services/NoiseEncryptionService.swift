//
// NoiseEncryptionService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

///
/// # NoiseEncryptionService
///
/// High-level encryption service that manages Noise Protocol sessions for secure
/// peer-to-peer communication in BitChat. Acts as the bridge between the transport
/// layer (BluetoothMeshService) and the cryptographic layer (NoiseProtocol).
///
/// ## Overview
/// This service provides a simplified API for establishing and managing encrypted
/// channels between peers. It handles:
/// - Static identity key management
/// - Session lifecycle (creation, maintenance, teardown)
/// - Message encryption/decryption
/// - Peer authentication and fingerprint tracking
/// - Automatic rekeying for forward secrecy
///
/// ## Architecture
/// The service operates at multiple levels:
/// 1. **Identity Management**: Persistent Curve25519 keys stored in Keychain
/// 2. **Session Management**: Per-peer Noise sessions with state tracking
/// 3. **Message Processing**: Encryption/decryption with proper framing
/// 4. **Security Features**: Rate limiting, fingerprint verification
///
/// ## Key Features
///
/// ### Identity Keys
/// - Static Curve25519 key pair for Noise XX pattern
/// - Ed25519 signing key pair for additional authentication
/// - Keys persisted securely in iOS/macOS Keychain
/// - Fingerprints derived from SHA256 of public keys
///
/// ### Session Management
/// - Lazy session creation (on-demand when sending messages)
/// - Automatic session recovery after disconnections
/// - Configurable rekey intervals for forward secrecy
/// - Graceful handling of simultaneous handshakes
///
/// ### Security Properties
/// - Forward secrecy via ephemeral keys in handshakes
/// - Mutual authentication via static key exchange
/// - Protection against replay attacks
/// - Rate limiting to prevent DoS attacks
///
/// ## Encryption Flow
/// ```
/// 1. Message arrives for encryption
/// 2. Check if session exists for peer
/// 3. If not, initiate Noise handshake
/// 4. Once established, encrypt message
/// 5. Add message type header for protocol handling
/// 6. Return encrypted payload for transmission
/// ```
///
/// ## Integration Points
/// - **BluetoothMeshService**: Calls this service for all private messages
/// - **ChatViewModel**: Monitors encryption status for UI indicators
/// - **NoiseHandshakeCoordinator**: Prevents handshake race conditions
/// - **KeychainManager**: Secure storage for identity keys
///
/// ## Thread Safety
/// - Concurrent read access via reader-writer queue
/// - Session operations protected by per-peer queues
/// - Atomic updates for critical state changes
///
/// ## Error Handling
/// - Graceful fallback for encryption failures
/// - Clear error messages for debugging
/// - Automatic retry with exponential backoff
/// - User notification for critical failures
///
/// ## Performance Considerations
/// - Sessions cached in memory for fast access
/// - Minimal allocations in hot paths
/// - Efficient binary message format
/// - Background queue for CPU-intensive operations
///

import Foundation
import CryptoKit
import os.log

// MARK: - Encryption Status

/// Represents the current encryption status of a peer connection.
/// Used for UI indicators and decision-making about message handling.
enum EncryptionStatus: Equatable {
    case none                // Failed or incompatible
    case noHandshake        // No handshake attempted yet
    case noiseHandshaking   // Currently establishing
    case noiseSecured       // Established but not verified
    case noiseVerified      // Established and verified
    
    var icon: String? {  // Made optional to hide icon when no handshake
        switch self {
        case .none:
            return "lock.slash"  // Failed handshake
        case .noHandshake:
            return nil  // No icon when no handshake attempted
        case .noiseHandshaking:
            return "lock.rotation"
        case .noiseSecured:
            return "lock.fill"  // Changed from "lock" to "lock.fill" for filled lock
        case .noiseVerified:
            return "checkmark.seal.fill"  // Verified badge
        }
    }
    
    var description: String {
        switch self {
        case .none:
            return "Encryption failed"
        case .noHandshake:
            return "Not encrypted"
        case .noiseHandshaking:
            return "Establishing encryption..."
        case .noiseSecured:
            return "Encrypted"
        case .noiseVerified:
            return "Encrypted & Verified"
        }
    }
}

// MARK: - Noise Encryption Service

/// Manages end-to-end encryption for BitChat using the Noise Protocol Framework.
/// Provides a high-level API for establishing secure channels between peers,
/// handling all cryptographic operations transparently.
/// - Important: This service maintains the device's cryptographic identity
class NoiseEncryptionService {
    // Static identity key (persistent across sessions)
    private let staticIdentityKey: Curve25519.KeyAgreement.PrivateKey
    public let staticIdentityPublicKey: Curve25519.KeyAgreement.PublicKey
    
    // Ed25519 signing key (persistent across sessions)
    private let signingKey: Curve25519.Signing.PrivateKey
    public let signingPublicKey: Curve25519.Signing.PublicKey
    
    // Session manager
    private let sessionManager: NoiseSessionManager
    
    // Peer fingerprints (SHA256 hash of static public key)
    private var peerFingerprints: [String: String] = [:] // peerID -> fingerprint
    private var fingerprintToPeerID: [String: String] = [:] // fingerprint -> peerID
    
    // Thread safety
    private let serviceQueue = DispatchQueue(label: "chat.bitchat.noise.service", attributes: .concurrent)
    
    // Security components
    private let rateLimiter = NoiseRateLimiter()
    
    // Session maintenance
    private var rekeyTimer: Timer?
    private let rekeyCheckInterval: TimeInterval = 60.0 // Check every minute
    
    // Callbacks
    var onPeerAuthenticated: ((String, String) -> Void)? // peerID, fingerprint
    var onHandshakeRequired: ((String) -> Void)? // peerID needs handshake
    
    init() {
        // Load or create static identity key (ONLY from keychain)
        let loadedKey: Curve25519.KeyAgreement.PrivateKey
        
        // Try to load from keychain
        if let identityData = KeychainManager.shared.getIdentityKey(forKey: "noiseStaticKey"),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identityData) {
            loadedKey = key
            SecureLogger.logKeyOperation("load", keyType: "noiseStaticKey", success: true)
        }
        // If no identity exists, create new one
        else {
            loadedKey = Curve25519.KeyAgreement.PrivateKey()
            let keyData = loadedKey.rawRepresentation
            
            // Save to keychain
            let saved = KeychainManager.shared.saveIdentityKey(keyData, forKey: "noiseStaticKey")
            SecureLogger.logKeyOperation("create", keyType: "noiseStaticKey", success: saved)
        }
        
        // Now assign the final value
        self.staticIdentityKey = loadedKey
        self.staticIdentityPublicKey = staticIdentityKey.publicKey
        
        // Load or create signing key pair
        let loadedSigningKey: Curve25519.Signing.PrivateKey
        
        // Try to load from keychain
        if let signingData = KeychainManager.shared.getIdentityKey(forKey: "ed25519SigningKey"),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingData) {
            loadedSigningKey = key
            SecureLogger.logKeyOperation("load", keyType: "ed25519SigningKey", success: true)
        }
        // If no signing key exists, create new one
        else {
            loadedSigningKey = Curve25519.Signing.PrivateKey()
            let keyData = loadedSigningKey.rawRepresentation
            
            // Save to keychain
            let saved = KeychainManager.shared.saveIdentityKey(keyData, forKey: "ed25519SigningKey")
            SecureLogger.logKeyOperation("create", keyType: "ed25519SigningKey", success: saved)
        }
        
        // Now assign the signing keys
        self.signingKey = loadedSigningKey
        self.signingPublicKey = signingKey.publicKey
        
        // Initialize session manager
        self.sessionManager = NoiseSessionManager(localStaticKey: staticIdentityKey)
        
        // Set up session callbacks
        sessionManager.onSessionEstablished = { [weak self] peerID, remoteStaticKey in
            self?.handleSessionEstablished(peerID: peerID, remoteStaticKey: remoteStaticKey)
        }
        
        // Start session maintenance timer
        startRekeyTimer()
    }
    
    // MARK: - Public Interface
    
    /// Get our static public key for sharing
    func getStaticPublicKeyData() -> Data {
        return staticIdentityPublicKey.rawRepresentation
    }
    
    /// Get our signing public key for sharing
    func getSigningPublicKeyData() -> Data {
        return signingPublicKey.rawRepresentation
    }
    
    /// Get our identity fingerprint
    func getIdentityFingerprint() -> String {
        let hash = SHA256.hash(data: staticIdentityPublicKey.rawRepresentation)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Get peer's public key data
    func getPeerPublicKeyData(_ peerID: String) -> Data? {
        return sessionManager.getRemoteStaticKey(for: peerID)?.rawRepresentation
    }
    
    /// Clear persistent identity (for panic mode)
    func clearPersistentIdentity() {
        // Clear from keychain
        let deletedStatic = KeychainManager.shared.deleteIdentityKey(forKey: "noiseStaticKey")
        let deletedSigning = KeychainManager.shared.deleteIdentityKey(forKey: "ed25519SigningKey")
        SecureLogger.logKeyOperation("delete", keyType: "identity keys", success: deletedStatic && deletedSigning)
        SecureLogger.log("Panic mode activated - identity cleared", category: SecureLogger.security, level: .warning)
        // Stop rekey timer
        stopRekeyTimer()
    }
    
    /// Sign data with our Ed25519 signing key
    func signData(_ data: Data) -> Data? {
        do {
            let signature = try signingKey.signature(for: data)
            return signature
        } catch {
            SecureLogger.logError(error, context: "Failed to sign data", category: SecureLogger.noise)
            return nil
        }
    }
    
    /// Verify signature with a peer's Ed25519 public key
    func verifySignature(_ signature: Data, for data: Data, publicKey: Data) -> Bool {
        do {
            let signingPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            return signingPublicKey.isValidSignature(signature, for: data)
        } catch {
            SecureLogger.logError(error, context: "Failed to verify signature", category: SecureLogger.noise)
            return false
        }
    }
    
    // MARK: - Handshake Management
    
    /// Initiate a Noise handshake with a peer
    func initiateHandshake(with peerID: String) throws -> Data {
        
        // Validate peer ID
        guard NoiseSecurityValidator.validatePeerID(peerID) else {
            SecureLogger.logSecurityEvent(.authenticationFailed(peerID: peerID), level: .warning)
            throw NoiseSecurityError.invalidPeerID
        }
        
        // Check rate limit
        guard rateLimiter.allowHandshake(from: peerID) else {
            SecureLogger.logSecurityEvent(.authenticationFailed(peerID: "Rate limited: \(peerID)"), level: .warning)
            throw NoiseSecurityError.rateLimitExceeded
        }
        
        SecureLogger.logSecurityEvent(.handshakeStarted(peerID: peerID))
        
        // Return raw handshake data without wrapper
        // The Noise protocol handles its own message format
        let handshakeData = try sessionManager.initiateHandshake(with: peerID)
        return handshakeData
    }
    
    /// Process an incoming handshake message
    func processHandshakeMessage(from peerID: String, message: Data) throws -> Data? {
        
        // Validate peer ID
        guard NoiseSecurityValidator.validatePeerID(peerID) else {
            SecureLogger.logSecurityEvent(.authenticationFailed(peerID: peerID), level: .warning)
            throw NoiseSecurityError.invalidPeerID
        }
        
        // Validate message size
        guard NoiseSecurityValidator.validateHandshakeMessageSize(message) else {
            SecureLogger.logSecurityEvent(.handshakeFailed(peerID: peerID, error: "Message too large"), level: .warning)
            throw NoiseSecurityError.messageTooLarge
        }
        
        // Check rate limit
        guard rateLimiter.allowHandshake(from: peerID) else {
            SecureLogger.logSecurityEvent(.authenticationFailed(peerID: "Rate limited: \(peerID)"), level: .warning)
            throw NoiseSecurityError.rateLimitExceeded
        }
        
        // For handshakes, we process the raw data directly without NoiseMessage wrapper
        // The Noise protocol handles its own message format
        let responsePayload = try sessionManager.handleIncomingHandshake(from: peerID, message: message)
        
        
        // Return raw response without wrapper
        return responsePayload
    }
    
    /// Check if we have an established session with a peer
    func hasEstablishedSession(with peerID: String) -> Bool {
        return sessionManager.getSession(for: peerID)?.isEstablished() ?? false
    }
    
    /// Check if we have a session (established or handshaking) with a peer
    func hasSession(with peerID: String) -> Bool {
        return sessionManager.getSession(for: peerID) != nil
    }
    
    // MARK: - Encryption/Decryption
    
    /// Encrypt data for a specific peer
    func encrypt(_ data: Data, for peerID: String) throws -> Data {
        // Validate message size
        guard NoiseSecurityValidator.validateMessageSize(data) else {
            throw NoiseSecurityError.messageTooLarge
        }
        
        // Check rate limit
        guard rateLimiter.allowMessage(from: peerID) else {
            throw NoiseSecurityError.rateLimitExceeded
        }
        
        // Check if we have an established session
        guard hasEstablishedSession(with: peerID) else {
            // Signal that handshake is needed
            onHandshakeRequired?(peerID)
            throw NoiseEncryptionError.handshakeRequired
        }
        
        return try sessionManager.encrypt(data, for: peerID)
    }
    
    /// Decrypt data from a specific peer
    func decrypt(_ data: Data, from peerID: String) throws -> Data {
        // Validate message size
        guard NoiseSecurityValidator.validateMessageSize(data) else {
            throw NoiseSecurityError.messageTooLarge
        }
        
        // Check rate limit
        guard rateLimiter.allowMessage(from: peerID) else {
            throw NoiseSecurityError.rateLimitExceeded
        }
        
        // Check if we have an established session
        guard hasEstablishedSession(with: peerID) else {
            throw NoiseEncryptionError.sessionNotEstablished
        }
        
        return try sessionManager.decrypt(data, from: peerID)
    }
    
    // MARK: - Peer Management
    
    /// Get fingerprint for a peer
    func getPeerFingerprint(_ peerID: String) -> String? {
        return serviceQueue.sync {
            return peerFingerprints[peerID]
        }
    }
    
    /// Get peer ID for a fingerprint
    func getPeerID(for fingerprint: String) -> String? {
        return serviceQueue.sync {
            return fingerprintToPeerID[fingerprint]
        }
    }
    
    /// Remove a peer session
    func removePeer(_ peerID: String) {
        sessionManager.removeSession(for: peerID)
        
        serviceQueue.sync(flags: .barrier) {
            if let fingerprint = peerFingerprints[peerID] {
                fingerprintToPeerID.removeValue(forKey: fingerprint)
            }
            peerFingerprints.removeValue(forKey: peerID)
        }
        
        SecureLogger.logSecurityEvent(.sessionExpired(peerID: peerID))
    }
    
    /// Migrate session when peer ID changes
    func migratePeerSession(from oldPeerID: String, to newPeerID: String, fingerprint: String) {
        // First update the fingerprint mappings
        serviceQueue.sync(flags: .barrier) {
            // Remove old mapping
            if let oldFingerprint = peerFingerprints[oldPeerID], oldFingerprint == fingerprint {
                peerFingerprints.removeValue(forKey: oldPeerID)
            }
            
            // Add new mapping
            peerFingerprints[newPeerID] = fingerprint
            fingerprintToPeerID[fingerprint] = newPeerID
        }
        
        // Migrate the session in session manager
        sessionManager.migrateSession(from: oldPeerID, to: newPeerID)
    }
    
    // MARK: - Private Helpers
    
    private func handleSessionEstablished(peerID: String, remoteStaticKey: Curve25519.KeyAgreement.PublicKey) {
        // Calculate fingerprint
        let fingerprint = calculateFingerprint(for: remoteStaticKey)
        
        // Store fingerprint mapping
        serviceQueue.sync(flags: .barrier) {
            peerFingerprints[peerID] = fingerprint
            fingerprintToPeerID[fingerprint] = peerID
        }
        
        // Log security event
        SecureLogger.logSecurityEvent(.handshakeCompleted(peerID: peerID))
        
        // Notify about authentication
        onPeerAuthenticated?(peerID, fingerprint)
    }
    
    private func calculateFingerprint(for publicKey: Curve25519.KeyAgreement.PublicKey) -> String {
        let hash = SHA256.hash(data: publicKey.rawRepresentation)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
        
    // MARK: - Session Maintenance
    
    private func startRekeyTimer() {
        rekeyTimer = Timer.scheduledTimer(withTimeInterval: rekeyCheckInterval, repeats: true) { [weak self] _ in
            self?.checkSessionsForRekey()
        }
    }
    
    private func stopRekeyTimer() {
        rekeyTimer?.invalidate()
        rekeyTimer = nil
    }
    
    private func checkSessionsForRekey() {
        let sessionsNeedingRekey = sessionManager.getSessionsNeedingRekey()
        
        for (peerID, needsRekey) in sessionsNeedingRekey where needsRekey {
            
            // Attempt to rekey the session
            do {
                try sessionManager.initiateRekey(for: peerID)
                SecureLogger.log("Key rotation initiated for peer: \(peerID)", category: SecureLogger.security, level: .info)
                
                // Signal that handshake is needed
                onHandshakeRequired?(peerID)
            } catch {
                SecureLogger.logError(error, context: "Failed to initiate rekey for peer: \(peerID)", category: SecureLogger.session)
            }
        }
    }
    
    deinit {
        stopRekeyTimer()
    }
}

// MARK: - Protocol Message Types for Noise

/// Message types for the Noise encryption protocol layer.
/// These types wrap the underlying BitChat protocol messages with encryption metadata.
enum NoiseMessageType: UInt8 {
    case handshakeInitiation = 0x10
    case handshakeResponse = 0x11
    case handshakeFinal = 0x12
    case encryptedMessage = 0x13
    case sessionRenegotiation = 0x14
}

// MARK: - Noise Message Wrapper

/// Container for encrypted messages in the Noise protocol.
/// Provides versioning and type information for proper message handling.
/// The actual message content is encrypted in the payload field.
struct NoiseMessage: Codable {
    let type: UInt8
    let sessionID: String  // Random ID for this handshake session
    let payload: Data
    
    init(type: NoiseMessageType, sessionID: String, payload: Data) {
        self.type = type.rawValue
        self.sessionID = sessionID
        self.payload = payload
    }
    
    func encode() -> Data? {
        do {
            let encoded = try JSONEncoder().encode(self)
            return encoded
        } catch {
            return nil
        }
    }
    
    static func decode(from data: Data) -> NoiseMessage? {
        return try? JSONDecoder().decode(NoiseMessage.self, from: data)
    }
    
    static func decodeWithError(from data: Data) -> NoiseMessage? {
        do {
            let decoded = try JSONDecoder().decode(NoiseMessage.self, from: data)
            return decoded
        } catch {
            return nil
        }
    }
    
    // MARK: - Binary Encoding
    
    func toBinaryData() -> Data {
        var data = Data()
        data.appendUInt8(type)
        data.appendUUID(sessionID)
        data.appendData(payload)
        return data
    }
    
    static func fromBinaryData(_ data: Data) -> NoiseMessage? {
        // Create defensive copy
        let dataCopy = Data(data)
        
        var offset = 0
        
        guard let type = dataCopy.readUInt8(at: &offset),
              let sessionID = dataCopy.readUUID(at: &offset),
              let payload = dataCopy.readData(at: &offset) else { return nil }
        
        guard let messageType = NoiseMessageType(rawValue: type) else { return nil }
        
        return NoiseMessage(type: messageType, sessionID: sessionID, payload: payload)
    }
}

// MARK: - Errors

enum NoiseEncryptionError: Error {
    case handshakeRequired
    case sessionNotEstablished
}
