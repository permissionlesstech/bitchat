//
// NoiseRateLimiter.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

final class NoiseRateLimiter {
    private var handshakeTimestamps: [PeerID: [Date]] = [:]
    private var messageTimestamps: [PeerID: [Date]] = [:]
    
    // Global rate limiting
    private var globalHandshakeTimestamps: [Date] = []
    private var globalMessageTimestamps: [Date] = []
    
    private let queue = DispatchQueue(label: "chat.bitchat.noise.ratelimit", attributes: .concurrent)
    
    func allowHandshake(from peerID: PeerID) -> Bool {
        return queue.sync(flags: .barrier) {
            let now = Date()
            let oneMinuteAgo = now.addingTimeInterval(-60)
            
            // Check global rate limit first
            globalHandshakeTimestamps = globalHandshakeTimestamps.filter { $0 > oneMinuteAgo }
            if globalHandshakeTimestamps.count >= NoiseSecurityConstants.maxGlobalHandshakesPerMinute {
                SecureLogger.warning("Global handshake rate limit exceeded: \(globalHandshakeTimestamps.count)/\(NoiseSecurityConstants.maxGlobalHandshakesPerMinute) per minute", category: .security)
                return false
            }
            
            // Check per-peer rate limit
            var timestamps = handshakeTimestamps[peerID] ?? []
            timestamps = timestamps.filter { $0 > oneMinuteAgo }
            
            if timestamps.count >= NoiseSecurityConstants.maxHandshakesPerMinute {
                SecureLogger.warning("Per-peer handshake rate limit exceeded for \(peerID): \(timestamps.count)/\(NoiseSecurityConstants.maxHandshakesPerMinute) per minute", category: .security)
                return false
            }
            
            // Record new handshake
            timestamps.append(now)
            handshakeTimestamps[peerID] = timestamps
            globalHandshakeTimestamps.append(now)
            return true
        }
    }
    
    func allowMessage(from peerID: PeerID) -> Bool {
        return queue.sync(flags: .barrier) {
            let now = Date()
            let oneSecondAgo = now.addingTimeInterval(-1)
            
            // Check global rate limit first
            globalMessageTimestamps = globalMessageTimestamps.filter { $0 > oneSecondAgo }
            if globalMessageTimestamps.count >= NoiseSecurityConstants.maxGlobalMessagesPerSecond {
                SecureLogger.warning("Global message rate limit exceeded: \(globalMessageTimestamps.count)/\(NoiseSecurityConstants.maxGlobalMessagesPerSecond) per second", category: .security)
                return false
            }
            
            // Check per-peer rate limit
            var timestamps = messageTimestamps[peerID] ?? []
            timestamps = timestamps.filter { $0 > oneSecondAgo }
            
            if timestamps.count >= NoiseSecurityConstants.maxMessagesPerSecond {
                SecureLogger.warning("Per-peer message rate limit exceeded for \(peerID): \(timestamps.count)/\(NoiseSecurityConstants.maxMessagesPerSecond) per second", category: .security)
                return false
            }
            
            // Record new message
            timestamps.append(now)
            messageTimestamps[peerID] = timestamps
            globalMessageTimestamps.append(now)
            return true
        }
    }
    
    func reset(for peerID: PeerID) {
        queue.async(flags: .barrier) {
            self.handshakeTimestamps.removeValue(forKey: peerID)
            self.messageTimestamps.removeValue(forKey: peerID)
        }
    }

    func resetAll() {
        queue.async(flags: .barrier) {
            self.handshakeTimestamps.removeAll()
            self.messageTimestamps.removeAll()
            self.globalHandshakeTimestamps.removeAll()
            self.globalMessageTimestamps.removeAll()
        }
    }
}
