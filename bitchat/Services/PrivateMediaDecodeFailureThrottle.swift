//
// PrivateMediaDecodeFailureThrottle.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

/// Rate-limits the system lines posted when authenticated private media fails
/// to decode (#1518).
///
/// Decode failures are attacker-triggerable: an authenticated peer can send
/// malformed media as fast as the link allows, and one system line per payload
/// would let them flood the DM thread. At most one line is posted per peer per
/// window; failures suppressed inside a window are counted and reported once
/// on the next line rather than dropped silently.
struct PrivateMediaDecodeFailureThrottle {
    enum Outcome: Equatable {
        /// Post the reason on its own — nothing was suppressed beforehand.
        case post(PrivateMediaDecodeFailureReason)
        /// Post the reason plus a count of failures suppressed since the last line.
        case postWithSuppressed(PrivateMediaDecodeFailureReason, suppressed: Int)
        /// Inside an open window: count it, say nothing.
        case suppress
    }

    /// One line per peer per window. Five minutes keeps a genuinely broken
    /// sender legible without giving a hostile one a usable flood rate.
    static let defaultWindow: TimeInterval = 300

    private struct Window {
        var openedAt: Date
        var suppressed: Int
    }

    private let window: TimeInterval
    private var windows: [PeerID: Window] = [:]

    init(window: TimeInterval = PrivateMediaDecodeFailureThrottle.defaultWindow) {
        self.window = window
    }

    /// Records a failure and decides whether it should surface.
    mutating func record(
        from peerID: PeerID,
        reason: PrivateMediaDecodeFailureReason,
        now: Date = Date()
    ) -> Outcome {
        prune(before: now)

        if var open = windows[peerID], now.timeIntervalSince(open.openedAt) < window {
            open.suppressed += 1
            windows[peerID] = open
            return .suppress
        }

        let suppressed = windows[peerID]?.suppressed ?? 0
        windows[peerID] = Window(openedAt: now, suppressed: 0)
        return suppressed > 0
            ? .postWithSuppressed(reason, suppressed: suppressed)
            : .post(reason)
    }

    /// Drops peers whose window closed long enough ago that their suppressed
    /// count is no longer worth reporting. Without this the map would grow with
    /// every rotated peer ID a hostile sender presents.
    private mutating func prune(before now: Date) {
        let deadline = now.addingTimeInterval(-window * 2)
        windows = windows.filter { $0.value.openedAt > deadline }
    }
}
