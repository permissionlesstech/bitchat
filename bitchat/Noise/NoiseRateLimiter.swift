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
            window: TimeInterval,
            globalLimit: Int,
            perPeerLimit: Int,
            label: String,
            unit: String
        ) -> Bool {
            let now = Date()
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

        mutating func removeAll() {
            global.removeAll()
            byPeer.removeAll()
        }
    }

    private var handshakes = SlidingWindow()
    private var messages = SlidingWindow()
    private let lock = NSLock()

    func allowHandshake(from peerID: PeerID) -> Bool {
        lock.withLock {
            handshakes.allow(
                peerID: peerID,
                window: 60,
                globalLimit: NoiseSecurityConstants.maxGlobalHandshakesPerMinute,
                perPeerLimit: NoiseSecurityConstants.maxHandshakesPerMinute,
                label: "handshake",
                unit: "minute"
            )
        }
    }

    func allowMessage(from peerID: PeerID) -> Bool {
        lock.withLock {
            messages.allow(
                peerID: peerID,
                window: 1,
                globalLimit: NoiseSecurityConstants.maxGlobalMessagesPerSecond,
                perPeerLimit: NoiseSecurityConstants.maxMessagesPerSecond,
                label: "message",
                unit: "second"
            )
        }
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
