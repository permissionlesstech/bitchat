//
// NoiseRateLimiter.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import BitFoundation
import Foundation

final class NoiseRateLimiter {
    private var handshakeTimestamps: [PeerID: [Date]] = [:]
    private var messageTimestamps: [PeerID: [Date]] = [:]
    private var lastPrune: Date = .distantPast
    
    // Global rate limiting
    private var globalHandshakeTimestamps: [Date] = []
    private var globalMessageTimestamps: [Date] = []
    
    private let queue = DispatchQueue(label: "chat.bitchat.noise.ratelimit", attributes: .concurrent)

    /// Clock seam. Every sibling limiter takes `now` as a parameter
    /// (`SyncResponseRateLimiter`, `BLESubscriptionAnnounceLimiter`,
    /// `BLEAnnounceThrottle`); this one read `Date()` inline, which is why its
    /// time-dependent behaviour had no coverage. Injected here instead of
    /// threading a parameter through nine call sites.
    private let currentDate: () -> Date

    /// Sweeping every peer on every admission would put an O(peers) walk on the
    /// message path, which runs up to `maxGlobalMessagesPerSecond` times a
    /// second. Once a second is frequent enough to keep both maps to peers seen
    /// inside their own windows.
    private static let pruneInterval: TimeInterval = 1

    init(currentDate: @escaping () -> Date = Date.init) {
        self.currentDate = currentDate
    }

    /// Peers currently retained in either map. Mirrors
    /// `BLESubscriptionAnnounceLimiter.trackedCentralCount`.
    var trackedPeerCount: Int {
        queue.sync {
            Set(handshakeTimestamps.keys).union(messageTimestamps.keys).count
        }
    }
    
    func allowHandshake(from peerID: PeerID) -> Bool {
        return queue.sync(flags: .barrier) {
            let now = currentDate()
            pruneStalePeersLocked(now: now)
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
            let now = currentDate()
            pruneStalePeersLocked(now: now)
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
    
    /// Drops peers whose timestamps have all aged out of their window.
    ///
    /// Without this the two maps only ever grew: a peer's array was filtered
    /// when that same peer was next queried, but a peer that never came back
    /// kept its entry for the lifetime of the process. `reset(for:)` below is
    /// the per-peer counterpart and is never called from production code, so
    /// nothing else reclaimed them. Must be called with the barrier held.
    private func pruneStalePeersLocked(now: Date) {
        guard now.timeIntervalSince(lastPrune) >= Self.pruneInterval else { return }
        lastPrune = now

        let handshakeCutoff = now.addingTimeInterval(-60)
        handshakeTimestamps = handshakeTimestamps.compactMapValues { timestamps in
            let recent = timestamps.filter { $0 > handshakeCutoff }
            return recent.isEmpty ? nil : recent
        }

        let messageCutoff = now.addingTimeInterval(-1)
        messageTimestamps = messageTimestamps.compactMapValues { timestamps in
            let recent = timestamps.filter { $0 > messageCutoff }
            return recent.isEmpty ? nil : recent
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
