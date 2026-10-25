//
// TokenBucketSchedule.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// A set of token buckets for one sender, evaluated on message time instead of
/// arrival order.
///
/// Relay backfill and gossip sync hand over a sender's recent history in one
/// burst, often newest first, so a plain arrival-time bucket would hide an
/// ordinary conversation. Instead each admitted message stays on a timeline,
/// and a candidate is admitted only if replaying every bucket over the timeline
/// with the candidate inserted never runs dry. For live, in-order traffic this
/// behaves exactly like a classic token bucket. Rejected messages cost nothing.
///
/// Entries older than the backdate window are folded into a checkpoint, and
/// nothing can be inserted before the checkpoint, so the replay stays short
/// and exact.
struct TokenBucketSchedule {
    private struct Entry {
        let time: TimeInterval
        let costs: [Double]
    }

    private static let epsilon = 1e-9

    private let buckets: [TokenBucketConfig]
    private var entries: [Entry] = []
    private var checkpoint: TimeInterval?
    private var checkpointTokens: [Double]
    /// Tokens left after the newest entry, as a replay would compute them, so
    /// an in-order message (live traffic) is checked without a replay.
    private var tailTokens: [Double]
    private var tailTime: TimeInterval?

    init(buckets: [TokenBucketConfig]) {
        self.buckets = buckets
        self.checkpointTokens = buckets.map(\.capacity)
        self.tailTokens = checkpointTokens
    }

    /// Admits and records the message when every bucket can pay `costs` at `time`.
    /// Returns nil on success, otherwise the index of the first bucket that ran dry.
    mutating func tryAdmit(at time: TimeInterval, costs: [Double]) -> Int? {
        precondition(costs.count == buckets.count)
        let time = checkpoint.map { max($0, time) } ?? time
        var insertAt = entries.count
        while insertAt > 0 && entries[insertAt - 1].time > time { insertAt -= 1 }
        let candidate = Entry(time: time, costs: costs)

        if insertAt == entries.count {
            var tokens = tailTokens
            refill(&tokens, from: tailTime, to: time)
            for b in buckets.indices {
                tokens[b] -= costs[b]
                if tokens[b] < -Self.epsilon { return b }
            }
            entries.append(candidate)
            tailTokens = tokens
            tailTime = time
            return nil
        }

        var tokens = checkpointTokens
        var last = checkpoint
        for i in 0...entries.count {
            let entry: Entry
            if i < insertAt {
                entry = entries[i]
            } else if i == insertAt {
                entry = candidate
            } else {
                entry = entries[i - 1]
            }
            refill(&tokens, from: last, to: entry.time)
            last = entry.time
            for b in buckets.indices {
                tokens[b] -= entry.costs[b]
                if tokens[b] < -Self.epsilon { return b }
            }
        }
        entries.insert(candidate, at: insertAt)
        // The replay ran through the newest entry; folding old entries into the
        // checkpoint later repeats the same steps, so this stays exact.
        tailTokens = tokens
        tailTime = last
        return nil
    }

    /// Folds entries before `cutoff` into the checkpoint.
    mutating func prune(before cutoff: TimeInterval) {
        var folded = 0
        while folded < entries.count && entries[folded].time < cutoff {
            let entry = entries[folded]
            refill(&checkpointTokens, from: checkpoint, to: entry.time)
            for b in buckets.indices { checkpointTokens[b] -= entry.costs[b] }
            checkpoint = entry.time
            folded += 1
        }
        if folded > 0 { entries.removeFirst(folded) }
    }

    private func refill(_ tokens: inout [Double], from: TimeInterval?, to: TimeInterval) {
        guard let from, to > from else { return }
        let seconds = to - from
        for b in buckets.indices {
            tokens[b] = min(buckets[b].capacity, tokens[b] + seconds * buckets[b].refillPerSecond)
        }
    }
}
