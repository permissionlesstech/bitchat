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
#if os(iOS)
import UIKit
#endif

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
        /// Last publish of this envelope as a bridge courier drop on relays.
        var lastBridgePublishAt: Date?
        /// Prekey-sealed (envelope v2) discriminator; nil for static-sealed v1.
        let prekeyID: UInt32?

        var envelope: CourierEnvelope {
            CourierEnvelope(recipientTag: recipientTag, expiry: expiry, ciphertext: ciphertext, copies: copies, prekeyID: prekeyID)
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
            lastRemoteHandoverAt: Date? = nil,
            lastBridgePublishAt: Date? = nil,
            prekeyID: UInt32? = nil
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
            self.lastBridgePublishAt = lastBridgePublishAt
            self.prekeyID = prekeyID
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
            lastBridgePublishAt = try container.decodeIfPresent(Date.self, forKey: .lastBridgePublishAt)
            prekeyID = try container.decodeIfPresent(UInt32.self, forKey: .prekeyID)
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
    private let readData: (URL) throws -> Data
    /// A protected file can be present but unreadable during an iOS
    /// background restoration before first unlock. Keep that distinct from
    /// an absent file: mutations may proceed in memory, but must not replace
    /// the unreadable durable snapshot until it can be merged.
    private var diskLoadDeferred = false
    #if os(iOS)
    private var protectedDataObserver: NSObjectProtocol?
    #endif

    /// - Parameter fileURL: Overrides the on-disk location (tests). Ignored
    ///   when `persistsToDisk` is false.
    init(
        persistsToDisk: Bool = true,
        fileURL: URL? = nil,
        now: @escaping () -> Date = Date.init,
        readData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.now = now
        self.fileURL = persistsToDisk ? (fileURL ?? Self.defaultFileURL()) : nil
        self.readData = readData
        loadFromDisk()
        #if os(iOS)
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.retryDeferredPersistence()
        }
        #endif
    }

    deinit {
        #if os(iOS)
        if let protectedDataObserver {
            NotificationCenter.default.removeObserver(protectedDataObserver)
        }
        #endif
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

            // Identical ciphertext is the same envelope. Before any spray,
            // a carry-only copy may legitimately arrive ahead of the original
            // higher-budget copy, so keep the larger initial budget. Once a
            // branch has sprayed, however, replaying the depositor's original
            // packet must never replenish spent copies: that would defeat
            // spray-and-wait and let `sprayedTo` grow without bound.
            if let existing = envelopes.firstIndex(where: { $0.ciphertext == envelope.ciphertext }) {
                if envelopes[existing].sprayedTo.isEmpty {
                    envelopes[existing].copies = max(envelopes[existing].copies, envelope.copies)
                }
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
                copies: envelope.copies,
                prekeyID: envelope.prekeyID
            ))
            persistLocked()
            return true
        }
    }

    // MARK: - Handover (on encountering a peer)

    /// Remove and return all envelopes addressed to the given peer, matching
    /// the rotating recipient tag across adjacent days. This compatibility
    /// helper accepts every offer; transport callers should use
    /// `handoverEnvelopes(for:accepting:)` so failed sends remain durable.
    func takeEnvelopes(for noiseStaticKey: Data) -> [CourierEnvelope] {
        var handedOver: [CourierEnvelope] = []
        handoverEnvelopes(for: noiseStaticKey) { envelope in
            handedOver.append(envelope)
            return true
        }
        return handedOver
    }

    /// Attempts direct handover without retiring the durable carried copy
    /// until the transport accepts it onto the intended peer's physical link.
    /// A failed encode, stale binding, or backpressure rejection leaves the
    /// envelope unchanged for the next authenticated encounter.
    @discardableResult
    func handoverEnvelopes(
        for noiseStaticKey: Data,
        accepting: (CourierEnvelope) -> Bool
    ) -> Int {
        let date = now()
        let candidates = CourierEnvelope.candidateTags(noiseStaticKey: noiseStaticKey, around: date)
        let offered = queue.sync {
            pruneExpiredLocked(at: date)
            return envelopes
                .filter { candidates.contains($0.recipientTag) }
                .map(\.envelope)
        }

        var acceptedCount = 0
        for envelope in offered where accepting(envelope) {
            // Do not hold the store queue while the acceptance closure enters
            // BLE/collections queues. Commit in a second short critical
            // section, rechecking that another handover did not win first.
            let committed = queue.sync {
                guard let index = envelopes.firstIndex(where: { $0.ciphertext == envelope.ciphertext }) else {
                    return false
                }
                envelopes.remove(at: index)
                persistLocked()
                return true
            }
            if committed { acceptedCount += 1 }
        }
        return acceptedCount
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

    /// Envelopes eligible to park on relays as bridge courier drops. Merely
    /// offering one does not start its cooldown: the caller commits that only
    /// after a relay explicitly accepts the event via NIP-20 OK.
    func envelopesForBridgePublish(cooldown: TimeInterval) -> [CourierEnvelope] {
        let date = now()
        return queue.sync {
            pruneExpiredLocked(at: date)
            return envelopes.compactMap { stored in
                if let last = stored.lastBridgePublishAt,
                   date.timeIntervalSince(last) < cooldown {
                    return nil
                }
                // The relay copy carries no spray budget.
                return stored.envelope.withCopies(1)
            }
        }
    }

    /// Starts the bridge-publish cooldown only for a relay-confirmed copy.
    func markBridgePublished(_ envelope: CourierEnvelope) {
        let date = now()
        queue.sync {
            guard let index = envelopes.firstIndex(where: { $0.ciphertext == envelope.ciphertext }) else {
                return
            }
            envelopes[index].lastBridgePublishAt = date
            persistLocked()
        }
    }

    // MARK: - Spray-and-wait (on encountering another courier)

    /// Envelopes to re-deposit with a courier we just encountered, each with
    /// half its remaining budget (binary spray). Skips envelopes the courier
    /// deposited, envelopes addressed to them (those ride the handover path),
    /// carry-only envelopes, and couriers already sprayed.
    func takeSprayCopies(for courierNoiseKey: Data) -> [CourierEnvelope] {
        var sprayed: [CourierEnvelope] = []
        transferSprayCopies(to: courierNoiseKey) { envelope in
            sprayed.append(envelope)
            return true
        }
        return sprayed
    }

    /// Offers binary-spray copies one at a time and commits the reduced local
    /// budget plus `sprayedTo` marker only after the directed transport accepts
    /// that copy. A false result is a rollback: retrying the same courier sees
    /// the original budget and eligibility.
    @discardableResult
    func transferSprayCopies(
        to courierNoiseKey: Data,
        accepting: (CourierEnvelope) -> Bool
    ) -> Int {
        let date = now()
        let courierTags = CourierEnvelope.candidateTags(noiseStaticKey: courierNoiseKey, around: date)
        let offered = queue.sync {
            pruneExpiredLocked(at: date)
            return envelopes.compactMap { stored -> CourierEnvelope? in
                guard stored.copies > 1,
                      stored.depositorNoiseKey != courierNoiseKey,
                      !stored.sprayedTo.contains(courierNoiseKey),
                      !courierTags.contains(stored.recipientTag) else { return nil }
                return stored.envelope.withCopies(stored.copies / 2)
            }
        }

        var acceptedCount = 0
        for copy in offered where accepting(copy) {
            // As with direct handover, BLE acceptance runs outside the store
            // queue. Revalidate and commit the exact budget that left this
            // device; a competing successful transfer makes this a no-op.
            let committed = queue.sync {
                guard let index = envelopes.firstIndex(where: { $0.ciphertext == copy.ciphertext }) else {
                    return false
                }
                let stored = envelopes[index]
                guard stored.copies > copy.copies,
                      stored.depositorNoiseKey != courierNoiseKey,
                      !stored.sprayedTo.contains(courierNoiseKey),
                      !courierTags.contains(stored.recipientTag) else {
                    return false
                }
                envelopes[index].copies = stored.copies - copy.copies
                envelopes[index].sprayedTo.insert(courierNoiseKey)
                persistLocked()
                return true
            }
            if committed { acceptedCount += 1 }
        }
        return acceptedCount
    }

    // MARK: - Maintenance

    /// Panic wipe: drop all carried mail from memory and disk.
    func wipe() {
        queue.sync {
            envelopes.removeAll()
            diskLoadDeferred = false
            if let fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            publishCountLocked()
        }
    }

    /// Retries a protected-data read and merges any envelopes accepted while
    /// the file was unavailable. Internal so persistence tests can drive the
    /// same transition as iOS's protected-data notification.
    func retryDeferredPersistence() {
        queue.sync {
            guard diskLoadDeferred, resolveDeferredLoadLocked() else { return }
            persistLocked()
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
        // Never turn a transient protected-data read failure into an
        // authoritative empty/new file. Once readable, resolve first by
        // merging the durable and in-memory snapshots.
        if diskLoadDeferred, !resolveDeferredLoadLocked() {
            return
        }
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
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try data.write(to: fileURL, options: options)
        } catch {
            SecureLogger.error("Failed to persist courier store: \(error)", category: .session)
        }
    }

    private func loadFromDisk() {
        guard let fileURL else { return }
        queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                diskLoadDeferred = false
                return
            }
            do {
                let data = try readData(fileURL)
                do {
                    envelopes = try JSONDecoder().decode([StoredEnvelope].self, from: data)
                    diskLoadDeferred = false
                    pruneExpiredLocked(at: now())
                    publishCountLocked()
                    Self.migrateFileProtectionIfNeeded(at: fileURL)
                } catch {
                    // The bytes were readable, so this is corruption/schema
                    // failure rather than protected-data unavailability.
                    diskLoadDeferred = false
                    SecureLogger.error("Failed to decode courier store: \(error)", category: .session)
                }
            } catch {
                diskLoadDeferred = true
                SecureLogger.warning("Courier store unavailable; deferring load until protected data is available: \(error)", category: .session)
            }
        }
    }

    /// Must be called on `queue`.
    private func resolveDeferredLoadLocked() -> Bool {
        guard diskLoadDeferred, let fileURL else { return true }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            diskLoadDeferred = false
            return true
        }
        do {
            let data = try readData(fileURL)
            let durable = try JSONDecoder().decode([StoredEnvelope].self, from: data)
            envelopes = Self.merge(durable: durable, inMemory: envelopes)
            diskLoadDeferred = false
            pruneExpiredLocked(at: now())
            publishCountLocked()
            Self.migrateFileProtectionIfNeeded(at: fileURL)
            return true
        } catch let error as DecodingError {
            // Readability returned but the snapshot is corrupt. Do not pin
            // persistence forever; retain the valid in-memory snapshot.
            diskLoadDeferred = false
            SecureLogger.error("Failed to decode deferred courier store: \(error)", category: .session)
            return true
        } catch {
            SecureLogger.warning("Courier store still unavailable: \(error)", category: .session)
            return false
        }
    }

    private static func merge(durable: [StoredEnvelope], inMemory: [StoredEnvelope]) -> [StoredEnvelope] {
        var merged = durable
        for candidate in inMemory {
            if let index = merged.firstIndex(where: { $0.ciphertext == candidate.ciphertext }) {
                // Union progress before deciding the budget. Once either copy
                // has sprayed, the lower remaining budget is authoritative;
                // an older durable/original snapshot must not replenish it.
                let durableHasProgress = !merged[index].sprayedTo.isEmpty
                let memoryHasProgress = !candidate.sprayedTo.isEmpty
                let combinedSprayedTo = merged[index].sprayedTo.union(candidate.sprayedTo)
                switch (durableHasProgress, memoryHasProgress) {
                case (false, false):
                    merged[index].copies = max(merged[index].copies, candidate.copies)
                case (true, false):
                    break // durable progress owns its remaining budget
                case (false, true):
                    merged[index].copies = candidate.copies
                case (true, true):
                    // Concurrent progress can only spend budget; choosing the
                    // lower branch prevents a merge from minting copies.
                    merged[index].copies = min(merged[index].copies, candidate.copies)
                }
                merged[index].sprayedTo = combinedSprayedTo
                if candidate.tier == .favorite { merged[index].tier = .favorite }
                merged[index].lastRemoteHandoverAt = [merged[index].lastRemoteHandoverAt, candidate.lastRemoteHandoverAt]
                    .compactMap { $0 }
                    .max()
                merged[index].lastBridgePublishAt = [merged[index].lastBridgePublishAt, candidate.lastBridgePublishAt]
                    .compactMap { $0 }
                    .max()
            } else {
                merged.append(candidate)
            }
        }

        // A long locked wake can accept new mail alongside a full durable
        // store. Re-apply deposit quotas: existing per-depositor mail keeps
        // its slot, while total-cap eviction sheds oldest verified mail first.
        merged.sort { $0.storedAt < $1.storedAt }
        var perDepositorCounts: [Data: Int] = [:]
        merged = merged.filter { envelope in
            let limit = envelope.tier == .favorite
                ? Limits.maxPerFavoriteDepositor
                : Limits.maxPerVerifiedDepositor
            let count = perDepositorCounts[envelope.depositorNoiseKey, default: 0]
            guard count < limit else { return false }
            perDepositorCounts[envelope.depositorNoiseKey] = count + 1
            return true
        }
        while merged.filter({ $0.tier == .verified }).count > Limits.maxVerifiedEnvelopes {
            guard let victim = merged.firstIndex(where: { $0.tier == .verified }) else { break }
            merged.remove(at: victim)
        }
        while merged.count > Limits.maxEnvelopes {
            if let victim = merged.firstIndex(where: { $0.tier == .verified }) {
                merged.remove(at: victim)
            } else {
                merged.removeFirst()
            }
        }
        return merged
    }

    private static func migrateFileProtectionIfNeeded(at fileURL: URL) {
        #if os(iOS)
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
        } catch {
            SecureLogger.warning("Failed to migrate courier store file protection: \(error)", category: .session)
        }
        #endif
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
