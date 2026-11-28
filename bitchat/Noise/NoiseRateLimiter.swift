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
    private struct SlidingWindow {
        var global: [Date] = []
        var byPeer: [PeerID: [Date]] = [:]

        mutating func allow(
            peerID: PeerID,
            now: Date,
            window: TimeInterval,
            globalLimit: Int,
            perPeerLimit: Int,
            label: String,
            unit: String
        ) -> Bool {
            let cutoff = now.addingTimeInterval(-window)

            global = global.filter { $0 > cutoff }
            if global.count >= globalLimit {
                SecureLogger.warning("Global \(label) rate limit exceeded: \(global.count)/\(globalLimit) per \(unit)", category: .security)
                return false
            }

            var timestamps = (byPeer[peerID] ?? []).filter { $0 > cutoff }
            if timestamps.count >= perPeerLimit {
                SecureLogger.warning("Per-peer \(label) rate limit exceeded for \(peerID): \(timestamps.count)/\(perPeerLimit) per \(unit)", category: .security)
                return false
            }

            timestamps.append(now)
            byPeer[peerID] = timestamps
            global.append(now)
            return true
        }

        /// Drops peers whose timestamps have all aged out of their window.
        /// A peer that never comes back otherwise keeps its entry for the
        /// lifetime of the process.
        mutating func prune(now: Date, window: TimeInterval) {
            let cutoff = now.addingTimeInterval(-window)
            global = global.filter { $0 > cutoff }
            byPeer = byPeer.compactMapValues { timestamps in
                let recent = timestamps.filter { $0 > cutoff }
                return recent.isEmpty ? nil : recent
            }
        }

        mutating func removeAll() {
            global.removeAll()
            byPeer.removeAll()
        }
    }

    private var handshakes = SlidingWindow()
    private var messages = SlidingWindow()
    private let lock = NSLock()
    private var lastPrune: Date = .distantPast

    /// Sweeping every peer on every admission would put an O(peers) walk on the
    /// message path. Once a second is frequent enough to keep both maps to
    /// peers seen inside their own windows.
    private static let pruneInterval: TimeInterval = 1

    /// Clock seam. Injected so time-dependent retention can be tested without
    /// threading `now` through every call site.
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    var trackedHandshakePeerCount: Int {
        lock.withLock { handshakes.byPeer.count }
    }

    var trackedMessagePeerCount: Int {
        lock.withLock { messages.byPeer.count }
    }

    func allowHandshake(from peerID: PeerID) -> Bool {
        lock.withLock {
            let now = self.now()
            pruneStalePeersLocked(now: now)
            return handshakes.allow(
                peerID: peerID,
                now: now,
                window: NoiseSecurityConstants.handshakeRateLimitWindow,
                globalLimit: NoiseSecurityConstants.maxGlobalHandshakesPerMinute,
                perPeerLimit: NoiseSecurityConstants.maxHandshakesPerMinute,
                label: "handshake",
                unit: "minute"
            )
        }
    }

    func allowMessage(from peerID: PeerID) -> Bool {
        lock.withLock {
            let now = self.now()
            pruneStalePeersLocked(now: now)
            return messages.allow(
                peerID: peerID,
                now: now,
                window: NoiseSecurityConstants.messageRateLimitWindow,
                globalLimit: NoiseSecurityConstants.maxGlobalMessagesPerSecond,
                perPeerLimit: NoiseSecurityConstants.maxMessagesPerSecond,
                label: "message",
                unit: "second"
            )
        }
    }

    /// Must be called with the lock held.
    private func pruneStalePeersLocked(now: Date) {
        let elapsed = now.timeIntervalSince(lastPrune)
        // A backwards clock step parks lastPrune in the future; without the
        // `elapsed < 0` arm pruning would stop until wall time catches up.
        guard elapsed >= Self.pruneInterval || elapsed < 0 else { return }
        lastPrune = now
        handshakes.prune(now: now, window: NoiseSecurityConstants.handshakeRateLimitWindow)
        messages.prune(now: now, window: NoiseSecurityConstants.messageRateLimitWindow)
    }

    func reset(for peerID: PeerID) {
        lock.withLock {
            handshakes.byPeer.removeValue(forKey: peerID)
            messages.byPeer.removeValue(forKey: peerID)
        }
    }

    func resetAll() {
        lock.withLock {
            handshakes.removeAll()
            messages.removeAll()
        }
    }
}
