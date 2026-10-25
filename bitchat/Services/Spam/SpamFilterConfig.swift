//
// SpamFilterConfig.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Tunables for `SpamFilter`. These are code-level knobs only; the user can
/// just turn the filter on or off.
struct SpamFilterConfig: Equatable {
    /// Messages per sender: a burst of 6, then one more every 10 seconds.
    var messageBucket = TokenBucketConfig(capacity: 6, refillPerSecond: 1.0 / 10.0)
    /// Characters per sender: 1200 per minute, refilled continuously (20 per second).
    var characterBucket = TokenBucketConfig(capacity: 1200, refillPerSecond: 1200.0 / 60.0)
    /// Links per sender: 2 per minute, refilled continuously (one every 30 seconds).
    var linkBucket = TokenBucketConfig(capacity: 2, refillPerSecond: 2.0 / 60.0)
    var repetition = RepetitionConfig()
    /// How far in the past a message timestamp is trusted. Relay backfill
    /// (geohash subscribes to the last hour) and gossip sync deliver history in
    /// bursts, so buckets run on message time; older or future timestamps are
    /// clamped into `[now - maxBackdate, now]`.
    var maxBackdate: TimeInterval = 60 * 60
    /// Least recently active senders beyond this are forgotten.
    var maxTrackedSenders = 1_000
    /// Verdicts remembered by message ID so multi-path duplicates are judged once.
    var maxRememberedVerdicts = 4_000
}

struct TokenBucketConfig: Equatable {
    var capacity: Double
    var refillPerSecond: Double
}

struct RepetitionConfig: Equatable {
    /// Messages shorter than this (in characters) are never checked for repeated characters.
    var minRepeatedCharactersLength = 32
    /// Hide when some shift of the message matches itself at this fraction of positions.
    var repeatedCharactersThreshold = 0.85
    /// Messages shorter than this are never compared with the sender's history.
    var minRepeatedMessageLength = 10
    /// Two messages count as the same when their best alignment matches this fraction.
    var repeatedMessageSimilarity = 0.8
    /// How many near-copies of one text a sender may post within `historyWindow`.
    var allowedRepeats = 1
    /// How many near-copies of a text *other* senders may already have posted
    /// within `historyWindow` before it is hidden. Catches spam spread over many
    /// identities.
    var crossUserAllowedRepeats = 2
    /// Messages shorter than this are never compared across senders; short replies coincide.
    var crossUserMinLength = 16
    /// Recent messages from all senders kept for the cross-user comparison.
    var crossUserHistorySize = 200
    /// Comparisons one message may run against other senders' texts once
    /// the trigram check passes, and full alignments among those. Ordinary
    /// chat rarely needs either (shared trigrams and the diagonal bound rule
    /// most pairs out), but texts built from a tiny alphabet or vocabulary
    /// pass both, and the caps keep a flood of them from stalling the main
    /// actor. A real campaign's copies are recent, and the scan runs newest
    /// first. Alignments must exceed `crossUserAllowedRepeats`, or no copy
    /// could ever be confirmed.
    var crossUserMaxComparisons = 64
    var crossUserMaxAlignments = 8
    /// Recent messages per sender kept for comparison.
    var historySize = 10
    var historyWindow: TimeInterval = 10 * 60
    /// Longer messages are analyzed on their first N characters only, bounding CPU per message.
    var maxAnalyzedLength = 1_000
    /// Messages are compared with others on their first N characters only.
    var maxComparedLength = 280
    /// Correlation peaks combined per comparison; extra peaks absorb inserted or deleted text.
    var maxAlignmentPeaks = 3
    /// Extra peaks only count runs of at least this many matching characters.
    var minPeakRun = 3
    /// Pairs sharing fewer trigrams than this fraction skip the full comparison.
    var minSharedTrigrams = 0.25
}
