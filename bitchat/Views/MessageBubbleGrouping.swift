//
// MessageBubbleGrouping.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

/// Runs of consecutive messages from one author, for the bubble layout: only
/// the first bubble of a run names its sender, and bubbles inside a run sit
/// closer together than bubbles between runs, so the eye registers a name
/// only when the speaker actually changes. Mirrors the Android client's
/// `MessageGrouping`.
enum MessageBubbleGrouping {
    /// Messages further apart than this start a new run even from the same
    /// sender: a reply an hour later is a new thought, not a continuation.
    static let window: TimeInterval = 5 * 60

    /// Whether `current` continues the run of `previous`, its chronological
    /// predecessor in the rendered timeline, and so goes without a name.
    static func continuesRun(_ current: BitchatMessage, after previous: BitchatMessage?) -> Bool {
        guard let previous, hasSameAuthor(current, as: previous) else { return false }
        let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
        return elapsed >= 0 && elapsed <= window
    }

    /// Whether `current` comes from the same author as `previous`, however
    /// long after. This sets the spacing: consecutive bubbles from one
    /// author always sit at the tight run spacing, while a pause only brings
    /// back the name. Spacing by the time window too gave my own bubbles,
    /// which never show a name, gaps that changed for no visible reason.
    static func hasSameAuthor(_ current: BitchatMessage, as previous: BitchatMessage?) -> Bool {
        guard let previous else { return false }
        // System lines are narration: folding a real message into one would
        // attribute it to "system".
        if previous.sender == "system" || current.sender == "system" { return false }
        if previous.isPrivate != current.isPrivate { return false }
        return isSameSender(previous, current)
    }

    /// Sender IDs are authoritative when both rows carry one, since two peers
    /// can share a nickname; the display name (with its `#abcd` suffix) is the
    /// fallback for rows without one.
    private static func isSameSender(_ lhs: BitchatMessage, _ rhs: BitchatMessage) -> Bool {
        if let lhsID = lhs.senderPeerID, let rhsID = rhs.senderPeerID {
            return lhsID == rhsID
        }
        return lhs.sender == rhs.sender
    }
}
