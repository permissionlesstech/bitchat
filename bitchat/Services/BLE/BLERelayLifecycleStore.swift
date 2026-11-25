//
// BLERelayLifecycleStore.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

/// Explicit process-local relay lifecycle per packet `messageID` (engine-owned).
///
/// Separates local-delivery deduplication from relay deduplication so a
/// cryptographically authenticated packet suppressed by MPR on its first
/// non-electing hop can still relay once if a verified duplicate arrives from
/// an electing previous hop:
/// - `nil -> .suppressed`: first ingress suppressed by MPR.
/// - `nil -> .relayed`: first ingress claimed for relay (terminal).
/// - `.suppressed -> .relayed`: authenticated duplicate from an electing hop
///   claimed for relay (terminal).
/// - `.suppressed -> .suppressed`: additional non-electing hop saw it; refreshes
///   expiry without reopening terminal state.
/// - `.relayed -> *`: terminal; never reopens.
struct BLERelayLifecycleStore {
    enum State: Equatable {
        case suppressed
        case relayed
    }

    private struct Entry {
        var state: State
        var updatedAt: Date
        /// Cryptographic digest binding the suppressed record to the exact
        /// authenticated signed packet fields + signature. Nil for unsigned
        /// packets (which cannot be re-admitted on duplicate ingress).
        var authenticatedDigest: Data?
    }

    private var entries: [String: Entry] = [:]
    // Insertion-ordered key log (re-appended on update; stale positions skipped
    // during pruning) for bounded capacity and O(expired) expiry cleanup.
    private var order: [(key: String, updatedAt: Date)] = []
    private var head: Int = 0

    let maxCount: Int
    let ttl: TimeInterval

    init(
        maxCount: Int = TransportConfig.bleRelayLifecycleMaxCount,
        ttl: TimeInterval = TransportConfig.bleRelayLifecycleMaxAgeSeconds
    ) {
        self.maxCount = max(1, maxCount)
        self.ttl = max(0, ttl)
    }

    var count: Int {
        entries.count
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        head = 0
    }

    static func canTransition(from: State?, to: State) -> Bool {
        switch (from, to) {
        case (nil, .suppressed),
             (nil, .relayed),
             (.suppressed, .suppressed),
             (.suppressed, .relayed):
            return true
        case (.relayed, .suppressed),
             (.relayed, .relayed):
            return false
        }
    }

    /// Computes a deterministic authentication tag covering every signed packet
    /// field and the signature bytes. Supports outer-signed packets as well as
    /// self-authenticating `boardPost` packets carrying a verified embedded
    /// Ed25519 signature inside `payload`. Returns `nil` for unsigned packets.
    static func authenticationDigest(for packet: BitchatPacket) -> Data? {
        guard let signingData = packet.toBinaryDataForSigning() else {
            return nil
        }
        if let signature = packet.signature {
            var combined = Data()
            combined.reserveCapacity(signingData.count + signature.count)
            combined.append(signingData)
            combined.append(signature)
            return combined.sha256Hash()
        }
        if packet.type == MessageType.boardPost.rawValue,
           let wire = BoardWire.decode(from: packet.payload),
           wire.verifySignature() {
            return signingData.sha256Hash()
        }
        return nil
    }

    /// Returns the current unexpired lifecycle state for `messageID`, if any.
    mutating func state(for messageID: String, now: Date = Date()) -> State? {
        prune(now: now)
        return entries[messageID]?.state
    }

    /// Returns `true` when `messageID` is currently `.suppressed` and `packet`
    /// cryptographically matches the authenticated packet that was suppressed.
    mutating func canReconsiderSuppressed(
        messageID: String,
        packet: BitchatPacket,
        now: Date = Date()
    ) -> Bool {
        prune(now: now)
        guard let entry = entries[messageID],
              entry.state == .suppressed,
              let expectedDigest = entry.authenticatedDigest,
              let incomingDigest = Self.authenticationDigest(for: packet) else {
            return false
        }
        return expectedDigest == incomingDigest
    }

    /// Returns `true` if `messageID` may enter relay evaluation.
    ///
    /// When `messageID` is already `.suppressed` and `packet` is provided,
    /// reopening requires the packet to match the stored authenticated digest
    /// (covering packets such as fragments that bypass global message dedup
    /// after the short ingress-link window expires).
    mutating func canProceed(
        messageID: String,
        isDuplicateIngress: Bool,
        packet: BitchatPacket? = nil,
        now: Date = Date()
    ) -> Bool {
        prune(now: now)
        guard let entry = entries[messageID] else {
            return !isDuplicateIngress
        }
        switch entry.state {
        case .relayed:
            return false
        case .suppressed:
            guard let packet else { return true }
            guard let expectedDigest = entry.authenticatedDigest,
                  let incomingDigest = Self.authenticationDigest(for: packet) else {
                return false
            }
            return expectedDigest == incomingDigest
        }
    }

    /// Atomically claims `messageID` for relay (terminal `.relayed`).
    mutating func tryClaimRelay(
        messageID: String,
        isDuplicateIngress: Bool,
        now: Date = Date()
    ) -> Bool {
        prune(now: now)
        let current = entries[messageID]?.state
        if isDuplicateIngress && current != .suppressed {
            return false
        }
        guard Self.canTransition(from: current, to: .relayed) else {
            return false
        }
        put(
            key: messageID,
            entry: Entry(state: .relayed, updatedAt: now, authenticatedDigest: nil)
        )
        return true
    }

    /// Marks `messageID` as `.relayed` (e.g., after source-route unicast forwarding).
    mutating func markRelayed(messageID: String, now: Date = Date()) {
        prune(now: now)
        let current = entries[messageID]?.state
        guard Self.canTransition(from: current, to: .relayed) else { return }
        put(
            key: messageID,
            entry: Entry(state: .relayed, updatedAt: now, authenticatedDigest: nil)
        )
    }

    /// Marks `messageID` as `.suppressed`. Preserves the authenticated digest so
    /// a later verified duplicate from an electing hop can still relay once.
    mutating func markSuppressed(
        messageID: String,
        packet: BitchatPacket,
        isAuthenticated: Bool,
        now: Date = Date()
    ) {
        prune(now: now)
        let existing = entries[messageID]
        guard Self.canTransition(from: existing?.state, to: .suppressed) else { return }
        let digest = existing?.authenticatedDigest ?? (isAuthenticated ? Self.authenticationDigest(for: packet) : nil)
        put(
            key: messageID,
            entry: Entry(state: .suppressed, updatedAt: now, authenticatedDigest: digest)
        )
    }

    mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-ttl)
        while head < order.count {
            let item = order[head]
            if item.updatedAt >= cutoff && entries.count <= maxCount {
                break
            }
            head += 1
            if let current = entries[item.key], current.updatedAt == item.updatedAt {
                if item.updatedAt < cutoff || entries.count > maxCount {
                    entries.removeValue(forKey: item.key)
                }
            }
        }
        compactOrderIfNeeded()
    }

    private mutating func put(key: String, entry: Entry) {
        entries[key] = entry
        order.append((key: key, updatedAt: entry.updatedAt))
        while entries.count > maxCount && head < order.count {
            let victim = order[head]
            head += 1
            if let current = entries[victim.key], current.updatedAt == victim.updatedAt {
                entries.removeValue(forKey: victim.key)
            }
        }
        compactOrderIfNeeded()
    }

    private mutating func compactOrderIfNeeded() {
        if head >= 64 && head * 2 >= order.count {
            order.removeFirst(head)
            head = 0
        }
    }
}
