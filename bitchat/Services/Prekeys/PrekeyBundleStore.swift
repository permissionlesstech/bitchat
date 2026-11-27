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
        /// Noise-authenticated Ed25519 signing key that verified this bundle.
        /// Nil only for legacy on-disk entries written before signing-key tracking.
        var signingPublicKey: Data?
    }

    enum Limits {
        static let maxPeers = 200
        /// Don't seal to bundles older than this: the owner may have rotated
        /// the unconsumed keys out (see `LocalPrekeyStore.Policy`).
        static let maxBundleAgeForSealingSeconds: TimeInterval = 7 * 24 * 60 * 60
        /// Reject future-dated bundles beyond normal clock drift so a single
        /// far-future `generatedAt` cannot freeze out genuine replacements.
        static let maxFutureClockSkewSeconds: TimeInterval = 5 * 60
    }

    static let shared = PrekeyBundleStore()

    private var bundles: [Data: StoredBundle] = [:]
    private let queue = DispatchQueue(label: "chat.bitchat.prekeys.bundles")
    private let fileStore: AppSupportFileStore
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
        self.fileStore = AppSupportFileStore(
            persistsToDisk: persistsToDisk,
            fileURL: fileURL,
            subdirectory: "prekeys",
            fileName: "bundles.json",
            protection: .untilFirstUserAuthentication
        )
        loadFromDisk()
    }

    // MARK: - Ingest

    /// Stores a bundle whose signature the caller has already verified
    /// against the owner's Noise-authenticated signing key. Returns false when
    /// `generatedAt` is outside the valid clock window or an equal-or-newer
    /// bundle under the same signing key is already cached.
    @discardableResult
    func ingest(_ bundle: PrekeyBundle, signingPublicKey: Data? = nil) -> Bool {
        guard bundle.noiseStaticPublicKey.count == PrekeyBundle.keyLength,
              !bundle.prekeys.isEmpty else { return false }
        return queue.sync {
            guard isWithinValidWindowLocked(bundle.generatedAt) else {
                return false
            }
            let previous = bundles[bundle.noiseStaticPublicKey]
            let signingKeyChanged = signingPublicKey != nil && previous?.signingPublicKey != signingPublicKey
            if let existing = previous,
               !signingKeyChanged,
               existing.generatedAt >= bundle.generatedAt {
                return false
            }
            let newIDs = Set(bundle.prekeys.map(\.id))
            // Keep consumption state for IDs the fresh bundle still offers
            // (a top-up keeps the owner's unconsumed keys), unless the
            // verifying signing key itself changed; drop the rest.
            let carriedUsed = signingKeyChanged
                ? Set<UInt32>()
                : (previous?.usedIDs ?? []).intersection(newIDs)
            let carriedAssignments = signingKeyChanged
                ? [String: UInt32]()
                : (previous?.assignments ?? [:]).filter { newIDs.contains($0.value) }
            bundles[bundle.noiseStaticPublicKey] = StoredBundle(
                noiseKey: bundle.noiseStaticPublicKey,
                generatedAt: bundle.generatedAt,
                prekeyIDs: bundle.prekeys.map(\.id),
                prekeyPublicKeys: bundle.prekeys.map(\.publicKey),
                usedIDs: carriedUsed,
                assignments: carriedAssignments,
                updatedAt: now(),
                signingPublicKey: signingPublicKey
            )
            enforceCapLocked()
            persistLocked()
            return true
        }
    }

    /// Drops any cached bundle for `noiseKey` unless it was verified under
    /// `signingPublicKey`. Called when Noise authentication binds or updates a
    /// peer's Ed25519 signing key so legacy/mismatched bundles are purged.
    func invalidate(forNoiseKey noiseKey: Data, unlessSignedBy signingPublicKey: Data) {
        queue.sync {
            guard let existing = bundles[noiseKey],
                  existing.signingPublicKey != signingPublicKey else { return }
            bundles.removeValue(forKey: noiseKey)
            persistLocked()
        }
    }

    // MARK: - Sealing support

    #if DEBUG
    /// Whether an unexpired bundle with sealable prekeys is cached for a peer.
    func hasUsableBundle(for noiseKey: Data) -> Bool {
        queue.sync {
            guard let bundle = bundles[noiseKey], isFreshLocked(bundle) else { return false }
            return bundle.usedIDs.count < bundle.prekeyIDs.count
        }
    }
    #endif

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
            fileStore.removeIgnoringErrors()
        }
    }

    // MARK: - Internals (call only on `queue`)

    private func isFreshLocked(_ bundle: StoredBundle) -> Bool {
        isWithinValidWindowLocked(bundle.generatedAt)
    }

    private func isWithinValidWindowLocked(_ generatedAtMs: UInt64) -> Bool {
        let ageSeconds = now().timeIntervalSince1970 - Double(generatedAtMs) / 1000
        return ageSeconds <= Limits.maxBundleAgeForSealingSeconds
            && ageSeconds >= -Limits.maxFutureClockSkewSeconds
    }

    private func enforceCapLocked() {
        while bundles.count > maxPeers {
            guard let victim = bundles.min(by: { $0.value.updatedAt < $1.value.updatedAt }) else { return }
            bundles.removeValue(forKey: victim.key)
        }
    }

    private func persistLocked() {
        do {
            try fileStore.saveJSON(Array(bundles.values), isEmpty: bundles.isEmpty)
        } catch {
            SecureLogger.error("Failed to persist prekey bundle store: \(error)", category: .security)
        }
    }

    private func loadFromDisk() {
        guard fileStore.fileURL != nil else { return }
        queue.sync {
            guard let stored = try? fileStore.loadJSON([StoredBundle].self) else { return }
            for bundle in stored where bundle.prekeyIDs.count == bundle.prekeyPublicKeys.count {
                bundles[bundle.noiseKey] = bundle
            }
        }
    }
}
