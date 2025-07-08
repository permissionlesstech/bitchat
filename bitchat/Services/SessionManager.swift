//
//  SessionManager.swift
//  bitchat
//
//  Created by Unit 221B on 2025-01-08.
//

import Foundation
import CryptoKit

/// Manages secure sessions with mutual authentication, token management, and message integrity
final class SessionManager {
    
    // MARK: - Properties
    
    static let shared = SessionManager()
    
    private var sessions: [UUID: SecureSession] = [:]
    private let sessionQueue = DispatchQueue(label: "com.unit221b.bitchat.sessionmanager", attributes: .concurrent)
    private let sessionExpirationInterval: TimeInterval = 3600 // 1 hour
    private let sessionRenewalThreshold: TimeInterval = 300 // 5 minutes before expiration
    
    // MARK: - Session Model
    
    struct SecureSession {
        let sessionId: UUID
        let userId: String
        let deviceId: String
        let sharedSecret: SymmetricKey
        let createdAt: Date
        var expiresAt: Date
        var sequenceNumber: UInt64
        var lastActivity: Date
        let publicKey: P256.KeyAgreement.PublicKey
        let privateKey: P256.KeyAgreement.PrivateKey
        
        var isExpired: Bool {
            Date() > expiresAt
        }
        
        var needsRenewal: Bool {
            expiresAt.timeIntervalSince(Date()) < SessionManager.shared.sessionRenewalThreshold
        }
    }
    
    // MARK: - Errors
    
    enum SessionError: LocalizedError {
        case invalidCredentials
        case sessionExpired
        case invalidSignature
        case replayAttack
        case sessionNotFound
        case authenticationFailed
        case keyGenerationFailed
        
        var errorDescription: String? {
            switch self {
            case .invalidCredentials:
                return "Invalid credentials provided"
            case .sessionExpired:
                return "Session has expired"
            case .invalidSignature:
                return "Message signature verification failed"
            case .replayAttack:
                return "Replay attack detected"
            case .sessionNotFound:
                return "Session not found"
            case .authenticationFailed:
                return "Authentication failed"
            case .keyGenerationFailed:
                return "Failed to generate cryptographic keys"
            }
        }
    }
    
    // MARK: - Initialization
    
    private init() {
        startSessionCleanupTimer()
    }
    
    // MARK: - Session Establishment
    
    /// Establishes a new secure session with mutual authentication
    /// - Parameters:
    ///   - userId: The user identifier
    ///   - deviceId: The device identifier
    ///   - remotePublicKey: The remote party's public key for key agreement
    ///   - authenticationToken: Token for mutual authentication
    /// - Returns: Session information including session ID and public key
    func establishSession(
        userId: String,
        deviceId: String,
        remotePublicKey: P256.KeyAgreement.PublicKey,
        authenticationToken: String
    ) async throws -> (sessionId: UUID, publicKey: P256.KeyAgreement.PublicKey) {
        
        // Verify authentication token
        guard await verifyAuthenticationToken(authenticationToken, userId: userId) else {
            throw SessionError.authenticationFailed
        }
        
        // Generate ephemeral key pair for this session
        let privateKey = P256.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey
        
        // Perform key agreement
        let sharedSecret: SymmetricKey
        do {
            let sharedSecretData = try privateKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
            sharedSecret = sharedSecretData.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: "BitChat-Session-2025".data(using: .utf8)!,
                sharedInfo: Data(),
                outputByteCount: 32
            )
        } catch {
            throw SessionError.keyGenerationFailed
        }
        
        // Create session
        let sessionId = UUID()
        let now = Date()
        let session = SecureSession(
            sessionId: sessionId,
            userId: userId,
            deviceId: deviceId,
            sharedSecret: sharedSecret,
            createdAt: now,
            expiresAt: now.addingTimeInterval(sessionExpirationInterval),
            sequenceNumber: 0,
            lastActivity: now,
            publicKey: publicKey,
            privateKey: privateKey
        )
        
        // Store session
        sessionQueue.async(flags: .barrier) {
            self.sessions[sessionId] = session
        }
        
        // Log session establishment
        logSessionEvent(.established, sessionId: sessionId, userId: userId)
        
        return (sessionId, publicKey)
    }
    
    // MARK: - Message Authentication
    
    /// Creates an authenticated message with HMAC and sequence number
    /// - Parameters:
    ///   - message: The message data to authenticate
    ///   - sessionId: The session identifier
    /// - Returns: Authenticated message with HMAC and sequence number
    func createAuthenticatedMessage(
        _ message: Data,
        sessionId: UUID
    ) throws -> AuthenticatedMessage {
        
        var session = try getSession(sessionId)
        
        // Increment sequence number
        session.sequenceNumber += 1
        
        // Create message with sequence number
        let messageWithSequence = AuthenticatedMessage(
            sessionId: sessionId,
            sequenceNumber: session.sequenceNumber,
            timestamp: Date(),
            message: message,
            hmac: Data() // Will be set below
        )
        
        // Calculate HMAC
        let dataToSign = messageWithSequence.dataForHMAC()
        let hmac = HMAC<SHA256>.authenticationCode(
            for: dataToSign,
            using: session.sharedSecret
        )
        
        // Update message with HMAC
        var authenticatedMessage = messageWithSequence
        authenticatedMessage.hmac = Data(hmac)
        
        // Update session
        sessionQueue.async(flags: .barrier) {
            session.lastActivity = Date()
            self.sessions[sessionId] = session
        }
        
        return authenticatedMessage
    }
    
    /// Verifies an authenticated message
    /// - Parameters:
    ///   - message: The authenticated message to verify
    /// - Returns: The verified message data
    func verifyAuthenticatedMessage(
        _ message: AuthenticatedMessage
    ) throws -> Data {
        
        let session = try getSession(message.sessionId)
        
        // Verify HMAC
        let dataToVerify = message.dataForHMAC()
        let isValid = HMAC<SHA256>.isValidAuthenticationCode(
            message.hmac,
            authenticating: dataToVerify,
            using: session.sharedSecret
        )
        
        guard isValid else {
            throw SessionError.invalidSignature
        }
        
        // Check sequence number for replay attacks
        guard message.sequenceNumber > session.sequenceNumber else {
            throw SessionError.replayAttack
        }
        
        // Update sequence number
        sessionQueue.async(flags: .barrier) {
            if var updatedSession = self.sessions[message.sessionId] {
                updatedSession.sequenceNumber = message.sequenceNumber
                updatedSession.lastActivity = Date()
                self.sessions[message.sessionId] = updatedSession
            }
        }
        
        return message.message
    }
    
    // MARK: - Session Renewal
    
    /// Renews an existing session
    /// - Parameter sessionId: The session to renew
    /// - Returns: New expiration date
    @discardableResult
    func renewSession(_ sessionId: UUID) throws -> Date {
        var session = try getSession(sessionId)
        
        guard !session.isExpired else {
            throw SessionError.sessionExpired
        }
        
        let newExpirationDate = Date().addingTimeInterval(sessionExpirationInterval)
        
        sessionQueue.async(flags: .barrier) {
            session.expiresAt = newExpirationDate
            session.lastActivity = Date()
            self.sessions[sessionId] = session
        }
        
        logSessionEvent(.renewed, sessionId: sessionId, userId: session.userId)
        
        return newExpirationDate
    }
    
    /// Automatically renews sessions that are close to expiration
    func autoRenewSessions() {
        sessionQueue.sync {
            for (sessionId, session) in sessions {
                if session.needsRenewal && !session.isExpired {
                    do {
                        try renewSession(sessionId)
                    } catch {
                        print("Failed to auto-renew session \(sessionId): \(error)")
                    }
                }
            }
        }
    }
    
    // MARK: - Session Management
    
    /// Terminates a session
    /// - Parameter sessionId: The session to terminate
    func terminateSession(_ sessionId: UUID) {
        sessionQueue.async(flags: .barrier) {
            if let session = self.sessions.removeValue(forKey: sessionId) {
                self.logSessionEvent(.terminated, sessionId: sessionId, userId: session.userId)
            }
        }
    }
    
    /// Terminates all sessions for a user
    /// - Parameter userId: The user whose sessions to terminate
    func terminateAllSessions(for userId: String) {
        sessionQueue.async(flags: .barrier) {
            let sessionsToRemove = self.sessions.filter { $0.value.userId == userId }
            for (sessionId, _) in sessionsToRemove {
                self.sessions.removeValue(forKey: sessionId)
                self.logSessionEvent(.terminated, sessionId: sessionId, userId: userId)
            }
        }
    }
    
    /// Gets active session count for a user
    /// - Parameter userId: The user identifier
    /// - Returns: Number of active sessions
    func activeSessionCount(for userId: String) -> Int {
        sessionQueue.sync {
            sessions.values.filter { $0.userId == userId && !$0.isExpired }.count
        }
    }
    
    // MARK: - Private Methods
    
    private func getSession(_ sessionId: UUID) throws -> SecureSession {
        guard let session = sessionQueue.sync(execute: { sessions[sessionId] }) else {
            throw SessionError.sessionNotFound
        }
        
        guard !session.isExpired else {
            // Remove expired session
            terminateSession(sessionId)
            throw SessionError.sessionExpired
        }
        
        return session
    }
    
    private func verifyAuthenticationToken(_ token: String, userId: String) async -> Bool {
        // In production, this would verify the token against a backend service
        // For now, we'll implement a basic verification
        // This should be replaced with actual authentication logic
        
        // Simulate async verification
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Basic token format validation
        let components = token.components(separatedBy: ".")
        guard components.count == 3 else { return false }
        
        // In production: Verify JWT signature, check expiration, validate claims
        return true
    }
    
    private func startSessionCleanupTimer() {
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            self.cleanupExpiredSessions()
            self.autoRenewSessions()
        }
    }
    
    private func cleanupExpiredSessions() {
        sessionQueue.async(flags: .barrier) {
            let expiredSessions = self.sessions.filter { $0.value.isExpired }
            for (sessionId, session) in expiredSessions {
                self.sessions.removeValue(forKey: sessionId)
                self.logSessionEvent(.expired, sessionId: sessionId, userId: session.userId)
            }
        }
    }
    
    // MARK: - Logging
    
    private enum SessionEvent {
        case established
        case renewed
        case terminated
        case expired
    }
    
    private func logSessionEvent(_ event: SessionEvent, sessionId: UUID, userId: String) {
        let eventName: String
        switch event {
        case .established:
            eventName = "SESSION_ESTABLISHED"
        case .renewed:
            eventName = "SESSION_RENEWED"
        case .terminated:
            eventName = "SESSION_TERMINATED"
        case .expired:
            eventName = "SESSION_EXPIRED"
        }
        
        print("[\(Date())] \(eventName): sessionId=\(sessionId), userId=\(userId)")
        
        // In production: Send to secure logging service
    }
}

// MARK: - Authenticated Message Structure

struct AuthenticatedMessage: Codable {
    let sessionId: UUID
    let sequenceNumber: UInt64
    let timestamp: Date
    let message: Data
    var hmac: Data
    
    func dataForHMAC() -> Data {
        var data = Data()
        data.append(sessionId.uuidString.data(using: .utf8)!)
        data.append(withUnsafeBytes(of: sequenceNumber) { Data($0) })
        data.append(withUnsafeBytes(of: timestamp.timeIntervalSince1970) { Data($0) })
        data.append(message)
        return data
    }
}

// MARK: - Session Token

struct SessionToken: Codable {
    let sessionId: UUID
    let userId: String
    let deviceId: String
    let issuedAt: Date
    let expiresAt: Date
    let signature: Data
    
    var isValid: Bool {
        Date() < expiresAt
    }
}