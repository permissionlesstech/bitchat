//
// NoiseHandshakeCoordinator.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

/// Coordinates Noise handshakes to prevent race conditions and ensure reliable encryption establishment
final class NoiseHandshakeCoordinator {
    
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
    
    private var handshakeStates: [Peer: HandshakeState] = [:]
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
    func determineHandshakeRole(myPeer: Peer, remotePeer: Peer) -> NoiseRole {
        // Use simple string comparison for deterministic ordering
        return myPeer < remotePeer ? .initiator : .responder
    }
    
    /// Check if we should initiate handshake with a peer
    func shouldInitiateHandshake(myPeer: Peer, remotePeer: Peer, forceIfStale: Bool = false) -> Bool {
        return handshakeQueue.sync {
            // Check if we're already in an active handshake
            if let state = handshakeStates[remotePeer], state.isActive {
                // Check if the handshake is stale and we should force a new one
                if forceIfStale {
                    switch state {
                    case .initiating(_, let lastAttempt):
                        if Date().timeIntervalSince(lastAttempt) > handshakeTimeout {
                            SecureLogger.warning("Forcing new handshake with \(remotePeer.id) - previous stuck in initiating", category: .handshake)
                            return true
                        }
                    default:
                        break
                    }
                }
                
                SecureLogger.debug("Already in active handshake with \(remotePeer.id), state: \(state)", category: .handshake)
                return false
            }
            
            // Check role
            let role = determineHandshakeRole(myPeer: myPeer, remotePeer: remotePeer)
            if role != .initiator {
                return false
            }
            
            // Check if we've failed recently and can't retry yet
            if case .failed(_, let canRetry, let lastAttempt) = handshakeStates[remotePeer] {
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
    func recordHandshakeInitiation(peer: Peer) {
        handshakeQueue.async(flags: .barrier) {
            let attempt = self.getCurrentAttempt(for: peer) + 1
            self.handshakeStates[peer] = .initiating(attempt: attempt, lastAttempt: Date())
            SecureLogger.info("Recording handshake initiation with \(peer.id), attempt \(attempt)", category: .handshake)
        }
    }
    
    /// Record that we're responding to a handshake
    func recordHandshakeResponse(peer: Peer) {
        handshakeQueue.async(flags: .barrier) {
            self.handshakeStates[peer] = .responding(since: Date())
            SecureLogger.info("Recording handshake response to \(peer.id)", category: .handshake)
        }
    }
    
    /// Record successful handshake completion
    func recordHandshakeSuccess(peer: Peer) {
        handshakeQueue.async(flags: .barrier) {
            self.handshakeStates[peer] = .established(since: Date())
            SecureLogger.info("Handshake successfully established with \(peer.id)", category: .handshake)
        }
    }
    
    /// Record handshake failure
    func recordHandshakeFailure(peer: Peer, reason: String) {
        handshakeQueue.async(flags: .barrier) {
            let attempts = self.getCurrentAttempt(for: peer)
            let canRetry = attempts < self.maxHandshakeAttempts
            self.handshakeStates[peer] = .failed(reason: reason, canRetry: canRetry, lastAttempt: Date())
            SecureLogger.warning("Handshake failed with \(peer.id): \(reason), canRetry: \(canRetry)", category: .handshake)
        }
    }
    
    /// Check if we should accept an incoming handshake initiation
    func shouldAcceptHandshakeInitiation(myPeer: Peer, remotePeer: Peer) -> Bool {
        return handshakeQueue.sync {
            // If we're already established, reject new handshakes
            if case .established = handshakeStates[remotePeer] {
                SecureLogger.debug("Rejecting handshake from \(remotePeer.id) - already established", category: .handshake)
                return false
            }
            
            let role = determineHandshakeRole(myPeer: myPeer, remotePeer: remotePeer)
            
            // If we're the initiator and already initiating, this is a race condition
            if role == .initiator {
                if case .initiating = handshakeStates[remotePeer] {
                    // They shouldn't be initiating, but accept it to recover from race condition
                    SecureLogger.warning("Accepting handshake from \(remotePeer.id) despite being initiator (race condition recovery)", category: .handshake)
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
    func getRetryDelay(for peer: Peer) -> TimeInterval? {
        return handshakeQueue.sync {
            guard let state = handshakeStates[peer] else { return nil }
            
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
    func resetHandshakeState(for peer: Peer) {
        handshakeQueue.async(flags: .barrier) {
            self.handshakeStates.removeValue(forKey: peer)
            SecureLogger.debug("Reset handshake state for \(peer.id)", category: .handshake)
        }
    }
    
    /// Clean up stale handshake states and old established sessions
    func cleanupStaleHandshakes(staleTimeout: TimeInterval = 30.0) -> [Peer] {
        return handshakeQueue.sync {
            let now = Date()
            var stalePeers: [Peer] = []
            var establishedSessions: [(peer: Peer, since: Date)] = []
            
            for (peer, state) in handshakeStates {
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
                    establishedSessions.append((peer, since))
                    // Clean up very old established sessions
                    if now.timeIntervalSince(since) > establishedSessionTTL {
                        isStale = true
                    }
                default:
                    break
                }
                
                if isStale {
                    stalePeers.append(peer)
                    SecureLogger.warning("Found stale handshake state for \(peer.id): \(state)", category: .handshake)
                }
            }
            
            // If we have too many established sessions, clean up the oldest ones
            if establishedSessions.count > maxEstablishedSessions {
                // Sort by age (oldest first)
                let sortedSessions = establishedSessions.sorted { $0.since < $1.since }
                let sessionsToRemove = sortedSessions.count - maxEstablishedSessions
                
                for i in 0..<sessionsToRemove {
                    let peer = sortedSessions[i].peer
                    stalePeers.append(peer)
                    SecureLogger.info("Removing old established session for \(peer.id) to maintain session limit", category: .handshake)
                }
            }
            
            // Clean up stale states
            for peer in stalePeers {
                handshakeStates.removeValue(forKey: peer)
            }
            
            if !stalePeers.isEmpty {
                SecureLogger.info("Cleaned up \(stalePeers.count) stale handshake states", category: .handshake)
            }
            
            return stalePeers
        }
    }
    
    /// Get current handshake state
    func getHandshakeState(for peer: Peer) -> HandshakeState {
        return handshakeQueue.sync {
            return handshakeStates[peer] ?? .idle
        }
    }
    
    /// Get current retry count for a peer
    func getRetryCount(for peer: Peer) -> Int {
        return handshakeQueue.sync {
            switch handshakeStates[peer] {
            case .initiating(let attempt, _):
                return attempt - 1  // Attempts start at 1, retries start at 0
            default:
                return 0
            }
        }
    }
    
    /// Increment retry count for a peer
    func incrementRetryCount(for peer: Peer) {
        handshakeQueue.async(flags: .barrier) {
            let currentAttempt = self.getCurrentAttempt(for: peer)
            self.handshakeStates[peer] = .initiating(attempt: currentAttempt + 1, lastAttempt: Date())
        }
    }
    
    // MARK: - Private Helpers
    
    private func getCurrentAttempt(for peer: Peer) -> Int {
        switch handshakeStates[peer] {
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
            SecureLogger.debug("=== Handshake States ===", category: .handshake)
            for (peer, state) in handshakeStates {
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
                SecureLogger.debug("  \(peer.id): \(stateDesc)", category: .handshake)
            }
            SecureLogger.debug("========================", category: .handshake)
        }
    }
    
    /// Clear all handshake states - used during panic mode
    func clearAllHandshakeStates() {
        handshakeQueue.async(flags: .barrier) {
            SecureLogger.warning("Clearing all handshake states for panic mode", category: .handshake)
            self.handshakeStates.removeAll()
            self.processedHandshakeMessages.removeAll()
        }
    }
}
