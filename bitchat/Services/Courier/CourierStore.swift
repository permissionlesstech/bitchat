//
// CourierStore.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import Combine
import Foundation

/// Trust level of a courier deposit, decided by the caller's policy.
/// Favorites get the larger quota and are never evicted to make room for
/// verified-tier mail; verified (signature-verified announce, not a mutual
/// favorite) get a small quota so a crowd of strangers can still carry mail.
enum CourierDepositTier: String, Codable {
    case favorite
    case verified
}

/// Holds courier envelopes this device is carrying for offline third parties.
///
/// Envelopes are opaque ciphertext; this store never learns sender,
/// recipient, or content. Strict quotas keep the device from becoming a
/// public mailbag: bounded count, bounded per-depositor count by trust tier,
/// bounded size, and a 24-hour lifetime aligned with the outbox retention
/// policy. Carried mail is included in the panic wipe.
final class CourierStore {
    struct StoredEnvelope: Codable, Equatable {
        let recipientTag: Data
        let expiry: UInt64
        let ciphertext: Data
        let depositorNoiseKey: Data
        let storedAt: Date
        var tier: CourierDepositTier
        /// Remaining spray-and-wait budget (1 = carry-only).
        var copies: UInt8
        /// Couriers this envelope was already sprayed to, so a repeat announce
        /// from the same peer doesn't burn budget on a copy they already hold.
        var sprayedTo: Set<Data>
        /// Last speculative multi-hop handover toward a relayed announce.
        var lastRemoteHandoverAt: Date?

        var envelope: CourierEnvelope {
            CourierEnvelope(recipientTag: recipientTag, expiry: expiry, ciphertext: ciphertext, copies: copies)
        }

        init(
            recipientTag: Data,
            expiry: UInt64,
            ciphertext: Data,
            depositorNoiseKey: Data,
            storedAt: Date,
            tier: CourierDepositTier,
            copies: UInt8,
            sprayedTo: Set<Data> = [],
            lastRemoteHandoverAt: Date? = nil
        ) {
            self.recipientTag = recipientTag
            self.expiry = expiry
            self.ciphertext = ciphertext
            self.depositorNoiseKey = depositorNoiseKey
            self.storedAt = storedAt
            self.tier = tier
            self.copies = copies
            self.sprayedTo = sprayedTo
            self.lastRemoteHandoverAt = lastRemoteHandoverAt
        }

        // Files written before tiers/spray lack the newer fields; treat that
        // mail as favorite-tier carry-only, which is what it was.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            recipientTag = try container.decode(Data.self, forKey: .recipientTag)
            expiry = try container.decode(UInt64.self, forKey: .expiry)
            ciphertext = try container.decode(Data.self, forKey: .ciphertext)
            depositorNoiseKey = try container.decode(Data.self, forKey: .depositorNoiseKey)
            storedAt = try container.decode(Date.self, forKey: .storedAt)
            tier = try container.decodeIfPresent(CourierDepositTier.self, forKey: .tier) ?? .favorite
            copies = try container.decodeIfPresent(UInt8.self, forKey: .copies) ?? 1
            sprayedTo = try container.decodeIfPresent(Set<Data>.self, forKey: .sprayedTo) ?? []
            lastRemoteHandoverAt = try container.decodeIfPresent(Date.self, forKey: .lastRemoteHandoverAt)
        }
    }

    enum Limits {
        static let maxEnvelopes = 40
        /// Verified-tier mail can never crowd out favorites' share.
        static let maxVerifiedEnvelopes = 20
        static let maxPerFavoriteDepositor = 5
        static let maxPerVerifiedDepositor = 2
        /// Slack on top of the 24h lifetime for depositor clock skew.
        static let maxExpirySlack: TimeInterval = 60 * 60
    }

    static let shared = CourierStore()

    /// Number of envelopes currently carried, published on the main thread
    /// so the UI can show a "carrying mail" indicator.
    @Published private(set) var carriedCount: Int = 0

    /// Fast path so hot code (announce handling) can skip tag computation.
    var isEmpty: Bool {
        queue.sync { envelopes.isEmpty }
    }

    private var envelopes: [StoredEnvelope] = []
    private let queue = DispatchQueue(label: "chat.bitchat.courier.store")
    private let fileURL: URL?
    private let now: () -> Date

    /// - Parameter fileURL: Overrides the on-disk location (tests). Ignored
    ///   when `persistsToDisk` is false.
    init(persistsToDisk: Bool = true, fileURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.now = now
        self.fileURL = persistsToDisk ? (fileURL ?? Self.defaultFileURL()) : nil
        loadFromDisk()
    }

    // MARK: - Depositing (courier side)

    /// Accept an envelope from a depositor. Returns false when quotas or
    /// validity checks reject it. Trust policy (which tier a depositor gets,
    /// if any) is the caller's responsibility; this store only enforces
    /// resource bounds.
    @discardableResult
    func deposit(_ envelope: CourierEnvelope, from depositorNoiseKey: Data, tier: CourierDepositTier = .favorite) -> Bool {
        let date = now()
        guard envelope.recipientTag.count == CourierEnvelope.tagLength,
              !envelope.ciphertext.isEmpty,
              envelope.ciphertext.count <= CourierEnvelope.maxCiphertextBytes,
              !envelope.isExpired(at: date) else {
            return false
        }
        // Reject expiries beyond the policy lifetime so depositors can't pin
        // storage longer than the outbox would retain the message itself.
        let maxExpiry = date.addingTimeInterval(CourierEnvelope.maxLifetimeSeconds + Limits.maxExpirySlack)
        guard envelope.expiry <= UInt64(maxExpiry.timeIntervalSince1970 * 1000) else {
            return false
        }

        return queue.sync {
            pruneExpiredLocked(at: date)

            // Identical ciphertext is the same envelope; accept idempotently,
            // keeping the larger spray budget (bounded by maxCopies either way).
            if let existing = envelopes.firstIndex(where: { $0.ciphertext == envelope.ciphertext }) {
                envelopes[existing].copies = max(envelopes[existing].copies, envelope.copies)
                persistLocked()
                return true
            }

            let perDepositorLimit = tier == .favorite ? Limits.maxPerFavoriteDepositor : Limits.maxPerVerifiedDepositor
            guard envelopes.filter({ $0.depositorNoiseKey == depositorNoiseKey }).count < perDepositorLimit else {
                SecureLogger.debug("📦 Courier deposit rejected: per-depositor quota reached (\(tier.rawValue))", category: .session)
                return false
            }
            if tier == .verified,
               envelopes.filter({ $0.tier == .verified }).count >= Limits.maxVerifiedEnvelopes {
                SecureLogger.debug("📦 Courier deposit rejected: verified-tier pool full", category: .session)
                return false
            }
            if envelopes.count >= Limits.maxEnvelopes {
                // Oldest-first eviction, shedding verified-tier mail before
                // favorites' so open couriering can't crowd out trusted mail.
                // A verified deposit never displaces a favorite: when only
                // favorite mail is stored, it is rejected instead.
                if let victim = envelopes.firstIndex(where: { $0.tier == .verified }) {
                    let evicted = envelopes.remove(at: victim)
                    SecureLogger.debug("📦 Courier store full - evicted verified envelope stored at \(evicted.storedAt)", category: .session)
                } else if tier == .favorite {
                    let evicted = envelopes.removeFirst()
                    SecureLogger.debug("📦 Courier store full - evicted favorite envelope stored at \(evicted.storedAt)", category: .session)
                } else {
                    SecureLogger.debug("📦 Courier deposit rejected: store full of favorite-tier mail", category: .session)
                    return false
                }
            }

            envelopes.append(StoredEnvelope(
                recipientTag: envelope.recipientTag,
                expiry: envelope.expiry,
                ciphertext: envelope.ciphertext,
                depositorNoiseKey: depositorNoiseKey,
                storedAt: date,
                tier: tier,
                copies: envelope.copies
            ))
            persistLocked()
            return true
        }
    }

    // MARK: - Handover (on encountering a peer)

    /// Remove and return all envelopes addressed to the given peer, matching
    /// the rotating recipient tag across adjacent days. Envelopes are removed
    /// optimistically: handover happens over a live link, and the depositor's
    /// outbox still retains the original for direct delivery.
    func takeEnvelopes(for noiseStaticKey: Data) -> [CourierEnvelope] {
        let date = now()
        let candidates = CourierEnvelope.candidateTags(noiseStaticKey: noiseStaticKey, around: date)
        return queue.sync {
            pruneExpiredLocked(at: date)
            let matched = envelopes.filter { candidates.contains($0.recipientTag) }
            guard !matched.isEmpty else { return [] }
            envelopes.removeAll { stored in matched.contains(stored) }
            persistLocked()
            return matched.map(\.envelope)
        }
    }

    /// Envelopes addressed to a recipient we heard from via a *relayed*
    /// announce. Non-destructive: a multi-hop send is speculative, so the
    /// envelope stays carried until a direct handover or expiry. The per-
    /// envelope cooldown keeps repeated announces from re-flooding the mesh.
    func envelopesForRemoteHandover(recipientNoiseKey: Data, cooldown: TimeInterval) -> [CourierEnvelope] {
        let date = now()
        let candidates = CourierEnvelope.candidateTags(noiseStaticKey: recipientNoiseKey, around: date)
        return queue.sync {
            pruneExpiredLocked(at: date)
            var matched: [CourierEnvelope] = []
            for index in envelopes.indices where candidates.contains(envelopes[index].recipientTag) {
                if let last = envelopes[index].lastRemoteHandoverAt,
                   date.timeIntervalSince(last) < cooldown {
                    continue
                }
                envelopes[index].lastRemoteHandoverAt = date
                // The delivered copy carries no spray budget.
                matched.append(envelopes[index].envelope.withCopies(1))
            }
            if !matched.isEmpty { persistLocked() }
            return matched
        }
    }

    // MARK: - Spray-and-wait (on encountering another courier)

    /// Envelopes to re-deposit with a courier we just encountered, each with
    /// half its remaining budget (binary spray). Skips envelopes the courier
    /// deposited, envelopes addressed to them (those ride the handover path),
    /// carry-only envelopes, and couriers already sprayed.
    func takeSprayCopies(for courierNoiseKey: Data) -> [CourierEnvelope] {
        let date = now()
        let courierTags = CourierEnvelope.candidateTags(noiseStaticKey: courierNoiseKey, around: date)
        return queue.sync {
            pruneExpiredLocked(at: date)
            var sprayed: [CourierEnvelope] = []
            for index in envelopes.indices {
                let stored = envelopes[index]
                guard stored.copies > 1,
                      stored.depositorNoiseKey != courierNoiseKey,
                      !stored.sprayedTo.contains(courierNoiseKey),
                      !courierTags.contains(stored.recipientTag) else { continue }
                let given = stored.copies / 2
                envelopes[index].copies = stored.copies - given
                envelopes[index].sprayedTo.insert(courierNoiseKey)
                sprayed.append(stored.envelope.withCopies(given))
            }
            if !sprayed.isEmpty { persistLocked() }
            return sprayed
        }
    }

    // MARK: - Maintenance

    func pruneExpired() {
        let date = now()
        queue.sync {
            pruneExpiredLocked(at: date)
            persistLocked()
        }
    }

    /// Panic wipe: drop all carried mail from memory and disk.
    func wipe() {
        queue.sync {
            envelopes.removeAll()
            if let fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            publishCountLocked()
        }
    }

    // MARK: - Internals (call only on `queue`)

    private func pruneExpiredLocked(at date: Date) {
        let before = envelopes.count
        envelopes.removeAll { $0.envelope.isExpired(at: date) }
        if envelopes.count != before {
            SecureLogger.debug("📦 Courier store pruned \(before - envelopes.count) expired envelope(s)", category: .session)
        }
    }

    private func publishCountLocked() {
        let count = envelopes.count
        DispatchQueue.main.async { [weak self] in
            self?.carriedCount = count
        }
    }

    private func persistLocked() {
        publishCountLocked()
        guard let fileURL else { return }
        do {
            if envelopes.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(envelopes)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtection)
            #endif
            try data.write(to: fileURL, options: options)
        } catch {
            SecureLogger.error("Failed to persist courier store: \(error)", category: .session)
        }
    }

    private func loadFromDisk() {
        guard let fileURL else { return }
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let stored = try? JSONDecoder().decode([StoredEnvelope].self, from: data) else {
                return
            }
            envelopes = stored
            pruneExpiredLocked(at: now())
            publishCountLocked()
        }
    }

    private static func defaultFileURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return base
            .appendingPathComponent("courier", isDirectory: true)
            .appendingPathComponent("envelopes.json")
    }
}
