//
// NoiseHandshakeCoordinator.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Coordinates Noise handshakes to prevent race conditions and ensure reliable encryption establishment
class NoiseHandshakeCoordinator {
    
    // MARK: - Handshake State
    
    enum HandshakeState: Equatable {
        case idle
        case waitingToInitiate(since: Date)
        case initiating(attempt: Int, lastAttempt: Date)
        case responding(since: Date)
        case waitingForResponse(messagesSent: [Data], timeout: Date)
        case established(since: Date)
        case failed(reason: String, canRetry: Bool, lastAttempt: Date)
        
        var isActive: Bool {
            switch self {
            case .idle, .established, .failed:
                return false
            default:
                return true
            }
        }
    }
    
    // MARK: - Properties
    
    private var handshakeStates: [String: HandshakeState] = [:]
    private var handshakeQueue = DispatchQueue(label: "chat.bitchat.noise.handshake", attributes: .concurrent)
    
    // Configuration
    private let maxHandshakeAttempts = 3
    private let handshakeTimeout: TimeInterval = 10.0
    private let retryDelay: TimeInterval = 2.0
    private let minTimeBetweenHandshakes: TimeInterval = 1.0 // Reduced from 5.0 for faster recovery
    private let establishedSessionTTL: TimeInterval = 300.0 // 5 minutes - sessions older than this can be cleaned up
    private let maxEstablishedSessions = 50 // Limit total established sessions
    
    // Track handshake messages to detect duplicates
    private var processedHandshakeMessages: Set<Data> = []
    private let messageHistoryLimit = 100
    
    // MARK: - Role Determination
    
    /// Deterministically determine who should initiate the handshake
    /// Lower peer ID becomes the initiator to prevent simultaneous attempts
    func determineHandshakeRole(myPeerID: String, remotePeerID: String) -> NoiseRole {
        // Use simple string comparison for deterministic ordering
        return myPeerID < remotePeerID ? .initiator : .responder
    }
    
    /// Check if we should initiate handshake with a peer
    func shouldInitiateHandshake(myPeerID: String, remotePeerID: String, forceIfStale: Bool = false) -> Bool {
        return handshakeQueue.sync {
            // Check if we're already in an active handshake
            if let state = handshakeStates[remotePeerID], state.isActive {
                // Check if the handshake is stale and we should force a new one
                if forceIfStale {
                    switch state {
                    case .initiating(_, let lastAttempt):
                        if Date().timeIntervalSince(lastAttempt) > handshakeTimeout {
                            SecureLogger.log("Forcing new handshake with \(remotePeerID) - previous stuck in initiating", 
                                           category: SecureLogger.handshake, level: .warning)
                            return true
                        }
                    default:
                        break
                    }
                }
                
                SecureLogger.log("Already in active handshake with \(remotePeerID), state: \(state)", 
                               category: SecureLogger.handshake, level: .debug)
                return false
            }
            
            // Check role
            let role = determineHandshakeRole(myPeerID: myPeerID, remotePeerID: remotePeerID)
            if role != .initiator {
                return false
            }
            
            // Check if we've failed recently and can't retry yet
            if case .failed(_, let canRetry, let lastAttempt) = handshakeStates[remotePeerID] {
                if !canRetry {
                    return false
                }
                if Date().timeIntervalSince(lastAttempt) < retryDelay {
                    return false
                }
            }
            
            return true
        }
    }
    
    /// Record that we're initiating a handshake
    func recordHandshakeInitiation(peerID: String) {
        handshakeQueue.async(flags: .barrier) {
            let attempt = self.getCurrentAttempt(for: peerID) + 1
            self.handshakeStates[peerID] = .initiating(attempt: attempt, lastAttempt: Date())
            SecureLogger.log("Recording handshake initiation with \(peerID), attempt \(attempt)", 
                           category: SecureLogger.handshake, level: .info)
        }
    }
    
    /// Record that we're responding to a handshake
    func recordHandshakeResponse(peerID: String) {
        handshakeQueue.async(flags: .barrier) {
            self.handshakeStates[peerID] = .responding(since: Date())
            SecureLogger.log("Recording handshake response to \(peerID)", 
                           category: SecureLogger.handshake, level: .info)
        }
    }
    
    /// Record successful handshake completion
    func recordHandshakeSuccess(peerID: String) {
        handshakeQueue.async(flags: .barrier) {
            self.handshakeStates[peerID] = .established(since: Date())
            SecureLogger.log("Handshake successfully established with \(peerID)", 
                           category: SecureLogger.handshake, level: .info)
        }
    }
    
    /// Record handshake failure
    func recordHandshakeFailure(peerID: String, reason: String) {
        handshakeQueue.async(flags: .barrier) {
            let attempts = self.getCurrentAttempt(for: peerID)
            let canRetry = attempts < self.maxHandshakeAttempts
            self.handshakeStates[peerID] = .failed(reason: reason, canRetry: canRetry, lastAttempt: Date())
            SecureLogger.log("Handshake failed with \(peerID): \(reason), canRetry: \(canRetry)", 
                           category: SecureLogger.handshake, level: .warning)
        }
    }
    
    /// Check if we should accept an incoming handshake initiation
    func shouldAcceptHandshakeInitiation(myPeerID: String, remotePeerID: String) -> Bool {
        return handshakeQueue.sync {
            // If we're already established, reject new handshakes
            if case .established = handshakeStates[remotePeerID] {
                SecureLogger.log("Rejecting handshake from \(remotePeerID) - already established", 
                               category: SecureLogger.handshake, level: .debug)
                return false
            }
            
            let role = determineHandshakeRole(myPeerID: myPeerID, remotePeerID: remotePeerID)
            
            // If we're the initiator and already initiating, this is a race condition
            if role == .initiator {
                if case .initiating = handshakeStates[remotePeerID] {
                    // They shouldn't be initiating, but accept it to recover from race condition
                    SecureLogger.log("Accepting handshake from \(remotePeerID) despite being initiator (race condition recovery)", 
                                   category: SecureLogger.handshake, level: .warning)
                    return true
                }
            }
            
            // If we're the responder, we should accept
            return true
        }
    }
    
    /// Check if this is a duplicate handshake message
    func isDuplicateHandshakeMessage(_ data: Data) -> Bool {
        return handshakeQueue.sync {
            if processedHandshakeMessages.contains(data) {
                return true
            }
            
            // Add to processed messages with size limit
            if processedHandshakeMessages.count >= messageHistoryLimit {
                processedHandshakeMessages.removeAll()
            }
            processedHandshakeMessages.insert(data)
            return false
        }
    }
    
    /// Get time to wait before next handshake attempt
    func getRetryDelay(for peerID: String) -> TimeInterval? {
        return handshakeQueue.sync {
            guard let state = handshakeStates[peerID] else { return nil }
            
            switch state {
            case .failed(_, let canRetry, let lastAttempt):
                if !canRetry { return nil }
                let timeSinceFailure = Date().timeIntervalSince(lastAttempt)
                if timeSinceFailure >= retryDelay {
                    return 0
                }
                return retryDelay - timeSinceFailure
                
            case .initiating(_, let lastAttempt):
                let timeSinceAttempt = Date().timeIntervalSince(lastAttempt)
                if timeSinceAttempt >= minTimeBetweenHandshakes {
                    return 0
                }
                return minTimeBetweenHandshakes - timeSinceAttempt
                
            default:
                return nil
            }
        }
    }
    
    /// Reset handshake state for a peer
    func resetHandshakeState(for peerID: String) {
        handshakeQueue.async(flags: .barrier) {
            self.handshakeStates.removeValue(forKey: peerID)
            SecureLogger.log("Reset handshake state for \(peerID)", 
                           category: SecureLogger.handshake, level: .debug)
        }
    }
    
    /// Clean up stale handshake states and old established sessions
    func cleanupStaleHandshakes(staleTimeout: TimeInterval = 30.0) -> [String] {
        return handshakeQueue.sync {
            let now = Date()
            var stalePeerIDs: [String] = []
            var establishedSessions: [(peerID: String, since: Date)] = []
            
            for (peerID, state) in handshakeStates {
                var isStale = false
                
                switch state {
                case .initiating(_, let lastAttempt):
                    if now.timeIntervalSince(lastAttempt) > staleTimeout {
                        isStale = true
                    }
                case .responding(let since):
                    if now.timeIntervalSince(since) > staleTimeout {
                        isStale = true
                    }
                case .waitingForResponse(_, let timeout):
                    if now > timeout {
                        isStale = true
                    }
                case .established(let since):
                    // Track established sessions for potential cleanup
                    establishedSessions.append((peerID, since))
                    // Clean up very old established sessions
                    if now.timeIntervalSince(since) > establishedSessionTTL {
                        isStale = true
                    }
                default:
                    break
                }
                
                if isStale {
                    stalePeerIDs.append(peerID)
                    SecureLogger.log("Found stale handshake state for \(peerID): \(state)", 
                                   category: SecureLogger.handshake, level: .warning)
                }
            }
            
            // If we have too many established sessions, clean up the oldest ones
            if establishedSessions.count > maxEstablishedSessions {
                // Sort by age (oldest first)
                let sortedSessions = establishedSessions.sorted { $0.since < $1.since }
                let sessionsToRemove = sortedSessions.count - maxEstablishedSessions
                
                for i in 0..<sessionsToRemove {
                    let peerID = sortedSessions[i].peerID
                    stalePeerIDs.append(peerID)
                    SecureLogger.log("Removing old established session for \(peerID) to maintain session limit", 
                                   category: SecureLogger.handshake, level: .info)
                }
            }
            
            // Clean up stale states
            for peerID in stalePeerIDs {
                handshakeStates.removeValue(forKey: peerID)
            }
            
            if !stalePeerIDs.isEmpty {
                SecureLogger.log("Cleaned up \(stalePeerIDs.count) stale handshake states", 
                               category: SecureLogger.handshake, level: .info)
            }
            
            return stalePeerIDs
        }
    }
    
    /// Get current handshake state
    func getHandshakeState(for peerID: String) -> HandshakeState {
        return handshakeQueue.sync {
            return handshakeStates[peerID] ?? .idle
        }
    }
    
    /// Get current retry count for a peer
    func getRetryCount(for peerID: String) -> Int {
        return handshakeQueue.sync {
            switch handshakeStates[peerID] {
            case .initiating(let attempt, _):
                return attempt - 1  // Attempts start at 1, retries start at 0
            default:
                return 0
            }
        }
    }
    
    /// Increment retry count for a peer
    func incrementRetryCount(for peerID: String) {
        handshakeQueue.async(flags: .barrier) {
            let currentAttempt = self.getCurrentAttempt(for: peerID)
            self.handshakeStates[peerID] = .initiating(attempt: currentAttempt + 1, lastAttempt: Date())
        }
    }
    
    // MARK: - Private Helpers
    
    private func getCurrentAttempt(for peerID: String) -> Int {
        switch handshakeStates[peerID] {
        case .initiating(let attempt, _):
            return attempt
        case .failed(_, _, _):
            // Count previous attempts
            return 1 // Simplified for now
        default:
            return 0
        }
    }
    
    /// Log current handshake states for debugging
    func logHandshakeStates() {
        handshakeQueue.sync {
            SecureLogger.log("=== Handshake States ===", category: SecureLogger.handshake, level: .debug)
            for (peerID, state) in handshakeStates {
                let stateDesc: String
                switch state {
                case .idle:
                    stateDesc = "idle"
                case .waitingToInitiate(let since):
                    stateDesc = "waiting to initiate (since \(since))"
                case .initiating(let attempt, let lastAttempt):
                    stateDesc = "initiating (attempt \(attempt), last: \(lastAttempt))"
                case .responding(let since):
                    stateDesc = "responding (since: \(since))"
                case .waitingForResponse(let messages, let timeout):
                    stateDesc = "waiting for response (\(messages.count) messages, timeout: \(timeout))"
                case .established(let since):
                    stateDesc = "established (since \(since))"
                case .failed(let reason, let canRetry, let lastAttempt):
                    stateDesc = "failed: \(reason) (canRetry: \(canRetry), last: \(lastAttempt))"
                }
                SecureLogger.log("  \(peerID): \(stateDesc)", category: SecureLogger.handshake, level: .debug)
            }
            SecureLogger.log("========================", category: SecureLogger.handshake, level: .debug)
        }
    }
    
    /// Clear all handshake states - used during panic mode
    func clearAllHandshakeStates() {
        handshakeQueue.async(flags: .barrier) {
            SecureLogger.log("Clearing all handshake states for panic mode", category: SecureLogger.handshake, level: .warning)
            self.handshakeStates.removeAll()
            self.processedHandshakeMessages.removeAll()
        }
    }
}