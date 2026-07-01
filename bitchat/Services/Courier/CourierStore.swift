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

/// Holds courier envelopes this device is carrying for offline third parties.
///
/// Envelopes are opaque ciphertext deposited by mutual favorites; this store
/// never learns sender, recipient, or content. Strict quotas keep the device
/// from becoming a public mailbag: bounded count, bounded per-depositor
/// count, bounded size, and a 24-hour lifetime aligned with the outbox
/// retention policy. Carried mail is included in the panic wipe.
final class CourierStore {
    struct StoredEnvelope: Codable, Equatable {
        let recipientTag: Data
        let expiry: UInt64
        let ciphertext: Data
        let depositorNoiseKey: Data
        let storedAt: Date

        var envelope: CourierEnvelope {
            CourierEnvelope(recipientTag: recipientTag, expiry: expiry, ciphertext: ciphertext)
        }
    }

    enum Limits {
        static let maxEnvelopes = 20
        static let maxPerDepositor = 5
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
    /// validity checks reject it. Trust policy (mutual favorite) is the
    /// caller's responsibility; this store only enforces resource bounds.
    @discardableResult
    func deposit(_ envelope: CourierEnvelope, from depositorNoiseKey: Data) -> Bool {
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

            // Identical ciphertext is the same envelope; accept idempotently.
            if envelopes.contains(where: { $0.ciphertext == envelope.ciphertext }) {
                return true
            }
            guard envelopes.filter({ $0.depositorNoiseKey == depositorNoiseKey }).count < Limits.maxPerDepositor else {
                SecureLogger.debug("📦 Courier deposit rejected: per-depositor quota reached", category: .session)
                return false
            }
            if envelopes.count >= Limits.maxEnvelopes {
                // Oldest-first eviction, matching outbox overflow behavior.
                let evicted = envelopes.removeFirst()
                SecureLogger.debug("📦 Courier store full - evicted envelope stored at \(evicted.storedAt)", category: .session)
            }

            envelopes.append(StoredEnvelope(
                recipientTag: envelope.recipientTag,
                expiry: envelope.expiry,
                ciphertext: envelope.ciphertext,
                depositorNoiseKey: depositorNoiseKey,
                storedAt: date
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
