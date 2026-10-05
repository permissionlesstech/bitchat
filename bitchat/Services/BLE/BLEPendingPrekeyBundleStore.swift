//
// BLEPendingPrekeyBundleStore.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import BitFoundation
import Foundation

/// Holds prekey bundles that arrived before their owner's announce bound a
/// signing key, so attribution can be retried when that announce lands.
///
/// Nothing about a stashed bundle has been verified — that is precisely why it
/// is stashed — so every entry has to be treated as attacker-controlled. A
/// bundle only needs a `senderID` matching the short ID derived from the
/// `noiseStaticPublicKey` it carries to reach the stash, and both of those are
/// public, so anyone in radio range can mint entries for owners that will never
/// announce. The store therefore bounds itself two ways: oldest-by-insertion
/// eviction at the cap, and an age sweep that drops entries whose owner never
/// showed up. The TTL exceeds the packet dedup window so delayed announces
/// can still drain a bundle while duplicate gossip cannot re-supply it.
///
/// Both bounds matter. Refusing new entries at a full cap — with no expiry —
/// lets a single burst of unattributable bundles wedge the stash for the rest
/// of the process, after which no bundle that races its owner's announce is
/// ever retried again.
struct BLEPendingPrekeyBundleStore {
    struct Config {
        /// Distinct owners that may hold a stashed bundle at once.
        var capacity: Int = TransportConfig.prekeyBundlePendingCap
        /// How long a stashed bundle waits for its owner's announce.
        var ttlSeconds: TimeInterval = TransportConfig.prekeyBundlePendingTTLSeconds
    }

    private struct Entry {
        let packet: BitchatPacket
        let stashedAt: Date
        let sequence: UInt64
    }

    private let config: Config
    private var insertionSequence: UInt64 = 0
    private var entries: [PeerID: Entry] = [:]

    init(config: Config = Config()) {
        self.config = config
    }

    var count: Int { entries.count }

    /// Retains the latest bundle seen for `owner`. Replacing an owner's entry
    /// never counts against the cap: a re-gossiped bundle must not be treated
    /// as a new claimant.
    mutating func stash(_ packet: BitchatPacket, for owner: PeerID, now: Date = Date()) {
        sweepExpired(now: now)
        let capacity = max(1, config.capacity)
        var evictedCount = 0
        if entries[owner] == nil {
            while entries.count >= capacity {
                guard let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence })?.key else { break }
                entries.removeValue(forKey: oldest)
                evictedCount += 1
            }
        }
        if evictedCount > 0 {
            // Bounds proof: capacity eviction removed unverified bundles.
            SecureLogger.warning("Evicted \(evictedCount) pending prekey bundle(s) over cap", category: .session)
        }
        insertionSequence &+= 1
        entries[owner] = Entry(packet: packet, stashedAt: now, sequence: insertionSequence)
    }

    /// Removes and returns `owner`'s stashed bundle, if one is still live. The
    /// entry is dropped either way — a bundle that outlived its TTL is not
    /// worth re-verifying, and the owner will gossip a fresh one.
    mutating func take(for owner: PeerID, now: Date = Date()) -> BitchatPacket? {
        guard let entry = entries.removeValue(forKey: owner) else { return nil }
        guard now.timeIntervalSince(entry.stashedAt) <= config.ttlSeconds else { return nil }
        return entry.packet
    }

    private mutating func sweepExpired(now: Date) {
        guard !entries.isEmpty else { return }
        let previousCount = entries.count
        entries = entries.filter { now.timeIntervalSince($0.value.stashedAt) <= config.ttlSeconds }
        let removedCount = previousCount - entries.count
        if removedCount > 0 {
            // Bounds proof: the age sweep removed expired unverified bundles.
            SecureLogger.warning("Swept \(removedCount) expired pending prekey bundle(s)", category: .session)
        }
    }
}
