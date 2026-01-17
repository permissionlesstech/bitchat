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
/// layer (BLEService) and the cryptographic layer (NoiseProtocol).
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
/// - **BLEService**: Calls this service for all private messages
/// - **ChatViewModel**: Monitors encryption status for UI indicators
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

import BitLogger
import Foundation
import CryptoKit

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
            return String(localized: "encryption.status.failed", comment: "Status text when encryption failed")
        case .noHandshake:
            return String(localized: "encryption.status.not_encrypted", comment: "Status text when no encryption handshake happened")
        case .noiseHandshaking:
            return String(localized: "encryption.status.establishing", comment: "Status text when encryption is being established")
        case .noiseSecured:
            return String(localized: "encryption.status.secured", comment: "Status text when encryption is secured but not verified")
        case .noiseVerified:
            return String(localized: "encryption.status.verified", comment: "Status text when encryption is verified")
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .none:
            return String(localized: "encryption.accessibility.failed", comment: "Accessibility text when encryption failed")
        case .noHandshake:
            return String(localized: "encryption.accessibility.not_encrypted", comment: "Accessibility text when encryption is not established")
        case .noiseHandshaking:
            return String(localized: "encryption.accessibility.establishing", comment: "Accessibility text when encryption is being established")
        case .noiseSecured:
            return String(localized: "encryption.accessibility.secured", comment: "Accessibility text when encryption is secured")
        case .noiseVerified:
            return String(localized: "encryption.accessibility.verified", comment: "Accessibility text when encryption is verified")
        }
    }
}

// MARK: - Noise Encryption Service

/// Manages end-to-end encryption for BitChat using the Noise Protocol Framework.
/// Provides a high-level API for establishing secure channels between peers,
/// handling all cryptographic operations transparently.
/// - Important: This service maintains the device's cryptographic identity
final class NoiseEncryptionService {
    // Static identity key (persistent across sessions)
    private let staticIdentityKey: Curve25519.KeyAgreement.PrivateKey
    public let staticIdentityPublicKey: Curve25519.KeyAgreement.PublicKey
    
    // Ed25519 signing key (persistent across sessions)
    private let signingKey: Curve25519.Signing.PrivateKey
    public let signingPublicKey: Curve25519.Signing.PublicKey
    
    // Session manager
    private let sessionManager: NoiseSessionManager
    
    // Peer fingerprints (SHA256 hash of static public key)
    private var peerFingerprints: [PeerID: String] = [:]
    private var fingerprintToPeerID: [String: PeerID] = [:]
    
    // Thread safety
    private let serviceQueue = DispatchQueue(label: "chat.bitchat.noise.service", attributes: .concurrent)
    
    // Security components
    private let rateLimiter = NoiseRateLimiter()
    private let keychain: KeychainManagerProtocol
    
    // Session maintenance
    private var rekeyTimer: Timer?
    private let rekeyCheckInterval: TimeInterval = 60.0 // Check every minute
    
    // Callbacks
    private var onPeerAuthenticatedHandlers: [((PeerID, String) -> Void)] = [] // Array of handlers for peer authentication
    var onHandshakeRequired: ((PeerID) -> Void)? // peerID needs handshake
    
    // Add a handler for peer authentication
    func addOnPeerAuthenticatedHandler(_ handler: @escaping (PeerID, String) -> Void) {
        serviceQueue.async(flags: .barrier) { [weak self] in
            self?.onPeerAuthenticatedHandlers.append(handler)
        }
    }
    
    // Legacy support - setting this will add to the handlers array
    var onPeerAuthenticated: ((PeerID, String) -> Void)? {
        get { nil } // Always return nil for backward compatibility
        set {
            if let handler = newValue {
                addOnPeerAuthenticatedHandler(handler)
            }
        }
    }
    
    init(keychain: KeychainManagerProtocol) {
        self.keychain = keychain

        // BCH-01-009: Load or create static identity key with proper error handling
        let loadedKey: Curve25519.KeyAgreement.PrivateKey

        // Try to load from keychain with proper error classification
        let noiseKeyResult = keychain.getIdentityKeyWithResult(forKey: "noiseStaticKey")

        switch noiseKeyResult {
        case .success(let identityData):
            if let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identityData) {
                loadedKey = key
                SecureLogger.logKeyOperation(.load, keyType: "noiseStaticKey", success: true)
            } else {
                // Data corrupted, regenerate
                SecureLogger.warning("Noise static key data corrupted, regenerating", category: .keychain)
                loadedKey = Self.generateAndSaveNoiseKey(keychain: keychain)
            }

        case .itemNotFound:
            // Expected case: no key exists yet, create new one
            loadedKey = Self.generateAndSaveNoiseKey(keychain: keychain)

        case .accessDenied:
            // Critical error - log but proceed with ephemeral key (will be lost on restart)
            SecureLogger.error(NSError(domain: "Keychain", code: -1),
                               context: "Keychain access denied - using ephemeral identity", category: .keychain)
            loadedKey = Curve25519.KeyAgreement.PrivateKey()

        case .deviceLocked, .authenticationFailed:
            // Recoverable error - use ephemeral key and warn
            SecureLogger.warning("Device locked or auth failed - using ephemeral identity until unlocked", category: .keychain)
            loadedKey = Curve25519.KeyAgreement.PrivateKey()

        case .otherError(let status):
            // Unexpected error - log and use ephemeral key
            SecureLogger.error(NSError(domain: "Keychain", code: Int(status)),
                               context: "Unexpected keychain error - using ephemeral identity", category: .keychain)
            loadedKey = Curve25519.KeyAgreement.PrivateKey()
        }

        // Now assign the final value
        self.staticIdentityKey = loadedKey
        self.staticIdentityPublicKey = staticIdentityKey.publicKey

        // BCH-01-009: Load or create signing key pair with proper error handling
        let loadedSigningKey: Curve25519.Signing.PrivateKey

        let signingKeyResult = keychain.getIdentityKeyWithResult(forKey: "ed25519SigningKey")

        switch signingKeyResult {
        case .success(let signingData):
            if let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingData) {
                loadedSigningKey = key
                SecureLogger.logKeyOperation(.load, keyType: "ed25519SigningKey", success: true)
            } else {
                // Data corrupted, regenerate
                SecureLogger.warning("Ed25519 signing key data corrupted, regenerating", category: .keychain)
                loadedSigningKey = Self.generateAndSaveSigningKey(keychain: keychain)
            }

        case .itemNotFound:
            // Expected case: no key exists yet, create new one
            loadedSigningKey = Self.generateAndSaveSigningKey(keychain: keychain)

        case .accessDenied:
            // Critical error - log but proceed with ephemeral key
            SecureLogger.error(NSError(domain: "Keychain", code: -1),
                               context: "Keychain access denied - using ephemeral signing key", category: .keychain)
            loadedSigningKey = Curve25519.Signing.PrivateKey()

        case .deviceLocked, .authenticationFailed:
            // Recoverable error - use ephemeral key and warn
            SecureLogger.warning("Device locked or auth failed - using ephemeral signing key until unlocked", category: .keychain)
            loadedSigningKey = Curve25519.Signing.PrivateKey()

        case .otherError(let status):
            // Unexpected error - log and use ephemeral key
            SecureLogger.error(NSError(domain: "Keychain", code: Int(status)),
                               context: "Unexpected keychain error - using ephemeral signing key", category: .keychain)
            loadedSigningKey = Curve25519.Signing.PrivateKey()
        }

        // Now assign the signing keys
        self.signingKey = loadedSigningKey
        self.signingPublicKey = signingKey.publicKey

        // Initialize session manager
        self.sessionManager = NoiseSessionManager(localStaticKey: staticIdentityKey, keychain: keychain)

        // Set up session callbacks
        sessionManager.onSessionEstablished = { [weak self] peerID, remoteStaticKey in
            self?.handleSessionEstablished(peerID: peerID, remoteStaticKey: remoteStaticKey)
        }

        // Start session maintenance timer
        startRekeyTimer()
    }

    // MARK: - BCH-01-009: Key Generation Helpers with Save Verification

    /// Generate and save a new Noise static key, verifying the save succeeds
    private static func generateAndSaveNoiseKey(keychain: KeychainManagerProtocol) -> Curve25519.KeyAgreement.PrivateKey {
        let newKey = Curve25519.KeyAgreement.PrivateKey()
        let keyData = newKey.rawRepresentation

        // Save to keychain and verify success
        let saveResult = keychain.saveIdentityKeyWithResult(keyData, forKey: "noiseStaticKey")

        switch saveResult {
        case .success:
            SecureLogger.logKeyOperation(.create, keyType: "noiseStaticKey", success: true)
        case .duplicateItem:
            // This shouldn't happen since we just tried to load, but handle it
            SecureLogger.warning("Noise key already exists (race condition?)", category: .keychain)
        default:
            // Save failed - log but continue with the key (it will be ephemeral)
            SecureLogger.error(NSError(domain: "Keychain", code: -1),
                               context: "Failed to persist noise static key - identity will be lost on restart",
                               category: .keychain)
        }

        return newKey
    }

    /// Generate and save a new Ed25519 signing key, verifying the save succeeds
    private static func generateAndSaveSigningKey(keychain: KeychainManagerProtocol) -> Curve25519.Signing.PrivateKey {
        let newKey = Curve25519.Signing.PrivateKey()
        let keyData = newKey.rawRepresentation

        // Save to keychain and verify success
        let saveResult = keychain.saveIdentityKeyWithResult(keyData, forKey: "ed25519SigningKey")

        switch saveResult {
        case .success:
            SecureLogger.logKeyOperation(.create, keyType: "ed25519SigningKey", success: true)
        case .duplicateItem:
            // This shouldn't happen since we just tried to load, but handle it
            SecureLogger.warning("Signing key already exists (race condition?)", category: .keychain)
        default:
            // Save failed - log but continue with the key (it will be ephemeral)
            SecureLogger.error(NSError(domain: "Keychain", code: -1),
                               context: "Failed to persist signing key - identity will be lost on restart",
                               category: .keychain)
        }

        return newKey
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
        staticIdentityPublicKey.rawRepresentation.sha256Fingerprint()
    }
    
    /// Get peer's public key data
    func getPeerPublicKeyData(_ peerID: PeerID) -> Data? {
        return sessionManager.getRemoteStaticKey(for: peerID)?.rawRepresentation
    }
    
    /// Clear persistent identity (for panic mode)
    func clearPersistentIdentity() {
        // Clear from keychain
        let deletedStatic = keychain.deleteIdentityKey(forKey: "noiseStaticKey")
        let deletedSigning = keychain.deleteIdentityKey(forKey: "ed25519SigningKey")
        SecureLogger.logKeyOperation(.delete, keyType: "identity keys", success: deletedStatic && deletedSigning)
        SecureLogger.warning("Panic mode activated - identity cleared", category: .security)
        // Stop rekey timer
        stopRekeyTimer()
    }
    
    /// Sign data with our Ed25519 signing key
    func signData(_ data: Data) -> Data? {
        do {
            let signature = try signingKey.signature(for: data)
            return signature
        } catch {
            SecureLogger.error(error, context: "Failed to sign data")
            return nil
        }
    }
    
    /// Verify signature with a peer's Ed25519 public key
    func verifySignature(_ signature: Data, for data: Data, publicKey: Data) -> Bool {
        do {
            let signingPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            return signingPublicKey.isValidSignature(signature, for: data)
        } catch {
            SecureLogger.error(error, context: "Failed to verify signature")
            return false
        }
    }

    // MARK: - Announce Signature Helpers

    /// Build the canonical announce binding message bytes and sign with our Ed25519 key
    /// - Parameters:
    ///   - peerID: 8-byte routing ID (as in packet header)
    ///   - noiseKey: 32-byte Curve25519.KeyAgreement public key
    ///   - ed25519Key: 32-byte Ed25519 public key (self)
    ///   - nickname: UTF-8 nickname (<=255 bytes)
    ///   - timestampMs: UInt64 milliseconds since epoch
    /// - Returns: Ed25519 signature over the canonical bytes, or nil on failure
    func buildAnnounceSignature(peerID: Data, noiseKey: Data, ed25519Key: Data, nickname: String, timestampMs: UInt64) -> Data? {
        let message = canonicalAnnounceBytes(peerID: peerID, noiseKey: noiseKey, ed25519Key: ed25519Key, nickname: nickname, timestampMs: timestampMs)
        return signData(message)
    }

    /// Verify an announce signature
    func verifyAnnounceSignature(signature: Data, peerID: Data, noiseKey: Data, ed25519Key: Data, nickname: String, timestampMs: UInt64, publicKey: Data) -> Bool {
        let message = canonicalAnnounceBytes(peerID: peerID, noiseKey: noiseKey, ed25519Key: ed25519Key, nickname: nickname, timestampMs: timestampMs)
        return verifySignature(signature, for: message, publicKey: publicKey)
    }

    /// Build canonical bytes for announce signing.
    private func canonicalAnnounceBytes(peerID: Data, noiseKey: Data, ed25519Key: Data, nickname: String, timestampMs: UInt64) -> Data {
        var out = Data()
        // context
        let context = "bitchat-announce-v1".data(using: .utf8) ?? Data()
        out.append(UInt8(min(context.count, 255)))
        out.append(context.prefix(255))
        // peerID (expect 8 bytes; pad/truncate to 8 for canonicalization)
        let peerID8 = peerID.prefix(8)
        out.append(peerID8)
        if peerID8.count < 8 { out.append(Data(repeating: 0, count: 8 - peerID8.count)) }
        // noise static key (expect 32)
        let noise32 = noiseKey.prefix(32)
        out.append(noise32)
        if noise32.count < 32 { out.append(Data(repeating: 0, count: 32 - noise32.count)) }
        // ed25519 public key (expect 32)
        let ed32 = ed25519Key.prefix(32)
        out.append(ed32)
        if ed32.count < 32 { out.append(Data(repeating: 0, count: 32 - ed32.count)) }
        // nickname length + bytes
        let nickData = nickname.data(using: .utf8) ?? Data()
        out.append(UInt8(min(nickData.count, 255)))
        out.append(nickData.prefix(255))
        // timestamp
        var ts = timestampMs.bigEndian
        withUnsafeBytes(of: &ts) { raw in out.append(contentsOf: raw) }
        return out
    }
    
    // MARK: - Packet Signing/Verification
    
    /// Sign a BitchatPacket using the noise private key
    func signPacket(_ packet: BitchatPacket) -> BitchatPacket? {
        // Create canonical packet bytes for signing
        guard let packetData = packet.toBinaryDataForSigning() else {
            return nil
        }
        
        // Sign with the noise private key (converted to Ed25519 for signing)
        guard let signature = signData(packetData) else {
            return nil
        }
        
        // Return new packet with signature
        var signedPacket = packet
        signedPacket.signature = signature
        return signedPacket
    }
    
    /// Verify a BitchatPacket signature using the provided public key
    func verifyPacketSignature(_ packet: BitchatPacket, publicKey: Data) -> Bool {
        guard let signature = packet.signature else {
            return false
        }
        
        // Create canonical packet bytes for verification (without signature)
        
        guard let packetData = packet.toBinaryDataForSigning() else {
            return false
        }
        
        // For noise public keys, we need to derive the Ed25519 key for verification
        // This assumes the noise key can be used for Ed25519 signing
        return verifySignature(signature, for: packetData, publicKey: publicKey)
    }

    
    // MARK: - Handshake Management
    
    /// Initiate a Noise handshake with a peer
    func initiateHandshake(with peerID: PeerID) throws -> Data {
        
        // Validate peer ID
        guard peerID.isValid else {
            SecureLogger.warning(.authenticationFailed(peerID: peerID.id))
            throw NoiseSecurityError.invalidPeerID
        }
        
        // Check rate limit
        guard rateLimiter.allowHandshake(from: peerID) else {
            SecureLogger.warning(.authenticationFailed(peerID: "Rate limited: \(peerID)"))
            throw NoiseSecurityError.rateLimitExceeded
        }
        
        SecureLogger.info(.handshakeStarted(peerID: peerID.id))
        
        // Return raw handshake data without wrapper
        // The Noise protocol handles its own message format
        let handshakeData = try sessionManager.initiateHandshake(with: peerID)
        return handshakeData
    }
    
    /// Process an incoming handshake message
    func processHandshakeMessage(from peerID: PeerID, message: Data) throws -> Data? {
        
        // Validate peer ID
        guard peerID.isValid else {
            SecureLogger.warning(.authenticationFailed(peerID: peerID.id))
            throw NoiseSecurityError.invalidPeerID
        }
        
        // Validate message size
        guard NoiseSecurityValidator.validateHandshakeMessageSize(message) else {
            SecureLogger.warning(.handshakeFailed(peerID: peerID.id, error: "Message too large"))
            throw NoiseSecurityError.messageTooLarge
        }
        
        // Check rate limit
        guard rateLimiter.allowHandshake(from: peerID) else {
            SecureLogger.warning(.authenticationFailed(peerID: "Rate limited: \(peerID)"))
            throw NoiseSecurityError.rateLimitExceeded
        }
        
        // For handshakes, we process the raw data directly without NoiseMessage wrapper
        // The Noise protocol handles its own message format
        let responsePayload = try sessionManager.handleIncomingHandshake(from: peerID, message: message)
        
        
        // Return raw response without wrapper
        return responsePayload
    }
    
    /// Check if we have an established session with a peer
    func hasEstablishedSession(with peerID: PeerID) -> Bool {
        return sessionManager.getSession(for: peerID)?.isEstablished() ?? false
    }
    
    /// Check if we have a session (established or handshaking) with a peer
    func hasSession(with peerID: PeerID) -> Bool {
        return sessionManager.getSession(for: peerID) != nil
    }
    
    // MARK: - Encryption/Decryption
    
    /// Encrypt data for a specific peer
    func encrypt(_ data: Data, for peerID: PeerID) throws -> Data {
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
    func decrypt(_ data: Data, from peerID: PeerID) throws -> Data {
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
    func getPeerFingerprint(_ peerID: PeerID) -> String? {
        return serviceQueue.sync {
            return peerFingerprints[peerID]
        }
    }

    func clearEphemeralStateForPanic() {
        sessionManager.removeAllSessions()
        serviceQueue.sync(flags: .barrier) {
            peerFingerprints.removeAll()
            fingerprintToPeerID.removeAll()
        }
        rateLimiter.resetAll()
    }

    /// Clear session for a specific peer (e.g., on decryption failure to allow re-handshake)
    func clearSession(for peerID: PeerID) {
        sessionManager.removeSession(for: peerID)
        serviceQueue.sync(flags: .barrier) {
            if let fingerprint = peerFingerprints.removeValue(forKey: peerID) {
                fingerprintToPeerID.removeValue(forKey: fingerprint)
            }
        }
        SecureLogger.debug("🔓 Cleared Noise session for \(peerID)", category: .session)
    }
    
    // MARK: - Private Helpers
    
    private func handleSessionEstablished(peerID: PeerID, remoteStaticKey: Curve25519.KeyAgreement.PublicKey) {
        // Calculate fingerprint
        let fingerprint = remoteStaticKey.rawRepresentation.sha256Fingerprint()
        
        // Store fingerprint mapping
        serviceQueue.sync(flags: .barrier) {
            peerFingerprints[peerID] = fingerprint
            fingerprintToPeerID[fingerprint] = peerID
        }
        
        // Log security event
        SecureLogger.info(.handshakeCompleted(peerID: peerID.id))
        
        // Notify all handlers about authentication
        serviceQueue.async { [weak self] in
            self?.onPeerAuthenticatedHandlers.forEach { handler in
                handler(peerID, fingerprint)
            }
        }
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
                SecureLogger.debug("Key rotation initiated for peer: \(peerID)", category: .security)
                
                // Signal that handshake is needed
                onHandshakeRequired?(peerID)
            } catch {
                SecureLogger.error(error, context: "Failed to initiate rekey for peer: \(peerID)", category: .session)
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
