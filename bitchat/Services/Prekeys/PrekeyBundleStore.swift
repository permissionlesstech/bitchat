//
// PrekeyBundleStore.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import Foundation

/// Signature-verified one-time prekey bundles received from other peers.
///
/// One bundle per Noise static key: a newer `generatedAt` replaces the cached
/// copy, keeping the IDs we already sealed with marked used so a prekey is
/// never reused across messages. Assignments are remembered per message ID so
/// deposit retries of the same message re-use its prekey (and its budget)
/// instead of burning a fresh one per courier.
///
/// Only public key material lives here; it persists to disk so a sender can
/// prekey-seal for recipients met long ago. Included in the panic wipe.
final class PrekeyBundleStore {
    struct StoredBundle: Codable {
        // noiseKey is read in loadFromDisk (dictionary keying), but the
        // Periphery indexer intermittently misses that read and flaked CI
        // with "assign-only" — even past its baselined USR. Covered
        // deterministically by retain_codable_properties in .periphery.yml
        // (an in-source ignore can't work: strict mode flags it as
        // superfluous on the runs where the indexer gets it right).
        let noiseKey: Data
        var generatedAt: UInt64
        var prekeyIDs: [UInt32]
        var prekeyPublicKeys: [Data]
        /// IDs this device already sealed with (never reused).
        var usedIDs: Set<UInt32>
        /// messageID → prekey ID, so re-deposits of one message share one prekey.
        var assignments: [String: UInt32]
        var updatedAt: Date
    }

    enum Limits {
        static let maxPeers = 200
        /// Don't seal to bundles older than this: the owner may have rotated
        /// the unconsumed keys out (see `LocalPrekeyStore.Policy`).
        static let maxBundleAgeForSealingSeconds: TimeInterval = 7 * 24 * 60 * 60
    }

    static let shared = PrekeyBundleStore()

    private var bundles: [Data: StoredBundle] = [:]
    private let queue = DispatchQueue(label: "chat.bitchat.prekeys.bundles")
    private let fileURL: URL?
    private let maxPeers: Int
    private let now: () -> Date

    /// - Parameter fileURL: Overrides the on-disk location (tests). Ignored
    ///   when `persistsToDisk` is false.
    init(
        persistsToDisk: Bool = true,
        fileURL: URL? = nil,
        maxPeers: Int = Limits.maxPeers,
        now: @escaping () -> Date = Date.init
    ) {
        self.now = now
        self.maxPeers = maxPeers
        self.fileURL = persistsToDisk ? (fileURL ?? Self.defaultFileURL()) : nil
        loadFromDisk()
    }

    // MARK: - Ingest

    /// Stores a bundle whose signature the caller has already verified
    /// against the owner's announce-bound signing key. Returns false when an
    /// equal-or-newer bundle is already cached (nothing changed).
    @discardableResult
    func ingest(_ bundle: PrekeyBundle) -> Bool {
        guard bundle.noiseStaticPublicKey.count == PrekeyBundle.keyLength,
              !bundle.prekeys.isEmpty else { return false }
        return queue.sync {
            if let existing = bundles[bundle.noiseStaticPublicKey],
               existing.generatedAt >= bundle.generatedAt {
                return false
            }
            let previous = bundles[bundle.noiseStaticPublicKey]
            let newIDs = Set(bundle.prekeys.map(\.id))
            // Keep consumption state for IDs the fresh bundle still offers
            // (a top-up keeps the owner's unconsumed keys); drop the rest.
            let carriedUsed = (previous?.usedIDs ?? []).intersection(newIDs)
            let carriedAssignments = (previous?.assignments ?? [:]).filter { newIDs.contains($0.value) }
            bundles[bundle.noiseStaticPublicKey] = StoredBundle(
                noiseKey: bundle.noiseStaticPublicKey,
                generatedAt: bundle.generatedAt,
                prekeyIDs: bundle.prekeys.map(\.id),
                prekeyPublicKeys: bundle.prekeys.map(\.publicKey),
                usedIDs: carriedUsed,
                assignments: carriedAssignments,
                updatedAt: now()
            )
            enforceCapLocked()
            persistLocked()
            return true
        }
    }

    // MARK: - Sealing support

    /// Whether an unexpired bundle with sealable prekeys is cached for a peer.
    func hasUsableBundle(for noiseKey: Data) -> Bool {
        queue.sync {
            guard let bundle = bundles[noiseKey], isFreshLocked(bundle) else { return false }
            return bundle.usedIDs.count < bundle.prekeyIDs.count
        }
    }

    /// The prekey to seal a message with: the message's existing assignment if
    /// any (re-deposits reuse it), else the lowest unused ID, which is then
    /// marked used. Nil when no fresh bundle is cached or all its prekeys are
    /// spent — callers fall back to static sealing.
    func assignPrekey(messageID: String, recipientNoiseKey: Data) -> PrekeyBundle.Prekey? {
        queue.sync {
            guard var bundle = bundles[recipientNoiseKey], isFreshLocked(bundle) else { return nil }

            if let assigned = bundle.assignments[messageID],
               let index = bundle.prekeyIDs.firstIndex(of: assigned) {
                return PrekeyBundle.Prekey(id: assigned, publicKey: bundle.prekeyPublicKeys[index])
            }

            guard let index = bundle.prekeyIDs.indices
                .filter({ !bundle.usedIDs.contains(bundle.prekeyIDs[$0]) })
                .min(by: { bundle.prekeyIDs[$0] < bundle.prekeyIDs[$1] }) else {
                return nil
            }
            let id = bundle.prekeyIDs[index]
            bundle.usedIDs.insert(id)
            bundle.assignments[messageID] = id
            bundle.updatedAt = now()
            bundles[recipientNoiseKey] = bundle
            persistLocked()
            return PrekeyBundle.Prekey(id: id, publicKey: bundle.prekeyPublicKeys[index])
        }
    }

    // MARK: - Maintenance

    /// Panic wipe: drop all cached bundles from memory and disk.
    func wipe() {
        queue.sync {
            bundles.removeAll()
            if let fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    // MARK: - Internals (call only on `queue`)

    private func isFreshLocked(_ bundle: StoredBundle) -> Bool {
        let ageSeconds = now().timeIntervalSince1970 - Double(bundle.generatedAt) / 1000
        return ageSeconds <= Limits.maxBundleAgeForSealingSeconds
    }

    private func enforceCapLocked() {
        while bundles.count > maxPeers {
            guard let victim = bundles.min(by: { $0.value.updatedAt < $1.value.updatedAt }) else { return }
            bundles.removeValue(forKey: victim.key)
        }
    }

    private func persistLocked() {
        guard let fileURL else { return }
        do {
            if bundles.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Array(bundles.values))
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtection)
            #endif
            try data.write(to: fileURL, options: options)
        } catch {
            SecureLogger.error("Failed to persist prekey bundle store: \(error)", category: .security)
        }
    }

    private func loadFromDisk() {
        guard let fileURL else { return }
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let stored = try? JSONDecoder().decode([StoredBundle].self, from: data) else {
                return
            }
            for bundle in stored where bundle.prekeyIDs.count == bundle.prekeyPublicKeys.count {
                bundles[bundle.noiseKey] = bundle
            }
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
            .appendingPathComponent("prekeys", isDirectory: true)
            .appendingPathComponent("bundles.json")
    }
}
