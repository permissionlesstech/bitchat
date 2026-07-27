//
// LocalPrekeyStore.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import CryptoKit
import Foundation

/// Owns this device's one-time Curve25519 prekey private keys.
///
/// Privates persist in the Keychain (single blob, same protection class as
/// the identity keys). A batch of `batchSize` unconsumed prekeys backs the
/// gossiped bundle; when consumption drops the unconsumed count below
/// `replenishThreshold`, the batch tops back up and the bundle's
/// `generatedAt` bumps so peers replace their cached copy.
///
/// Redelivery grace: spray-and-wait means the same prekey-sealed ciphertext
/// (or a re-seal of the same message to the same prekey ID) can arrive via
/// several couriers days apart. A consumed prekey's private key is therefore
/// retained for `consumedGraceSeconds` after first use and only then deleted.
/// Tradeoff: during the grace window a compromise of the device still exposes
/// mail sealed to that prekey — the forward-secrecy clock starts at deletion,
/// not at first open. Refusing new ciphertexts while accepting redeliveries
/// is not possible (the recipient cannot distinguish them), so the window is
/// kept short and fixed.
final class LocalPrekeyStore {
    struct Record: Codable {
        let id: UInt32
        let privateKey: Data
        let createdAt: Date
        var consumedAt: Date?
    }

    private struct Persisted: Codable {
        var records: [Record]
        var nextID: UInt32
        var generatedAt: UInt64
    }

    enum Policy {
        static let batchSize = PrekeyBundle.maxPrekeys
        static let replenishThreshold = 3
        /// How long a consumed prekey private survives for duplicate courier
        /// deliveries of mail sealed to it.
        static let consumedGraceSeconds: TimeInterval = 48 * 60 * 60
        /// Unconsumed prekeys older than this are rotated out: no honest
        /// sender seals to a bundle that stale (see
        /// `PrekeyBundleStore.Limits.maxBundleAgeForSealingSeconds`).
        static let unconsumedRetentionSeconds: TimeInterval = 30 * 24 * 60 * 60
    }

    private static let keychainKey = "prekeysV1"

    private let keychain: KeychainManagerProtocol
    private let now: () -> Date
    private let queue = DispatchQueue(label: "chat.bitchat.prekeys.local")

    // Guarded by `queue`.
    private var records: [Record] = []
    private var nextID: UInt32 = 0
    private var generatedAt: UInt64 = 0
    private var loaded = false

    init(keychain: KeychainManagerProtocol, now: @escaping () -> Date = Date.init) {
        self.keychain = keychain
        self.now = now
    }

    // MARK: - Bundle contents (public prekeys)

    /// Unconsumed public prekeys for the gossiped bundle, generating the
    /// initial batch on first use. Sorted by ID for canonical signing bytes.
    func currentBundlePrekeys() -> (prekeys: [PrekeyBundle.Prekey], generatedAt: UInt64) {
        queue.sync {
            loadLocked()
            _ = replenishLocked()
            let prekeys = records
                .filter { $0.consumedAt == nil }
                .sorted { $0.id < $1.id }
                .compactMap { record -> PrekeyBundle.Prekey? in
                    guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: record.privateKey) else { return nil }
                    return PrekeyBundle.Prekey(id: record.id, publicKey: key.publicKey.rawRepresentation)
                }
            return (prekeys, generatedAt)
        }
    }

    // MARK: - Opening (private prekeys)

    /// Private key for a prekey ID: unconsumed, or consumed within the
    /// redelivery grace window.
    func privateKey(for id: UInt32) -> Curve25519.KeyAgreement.PrivateKey? {
        queue.sync {
            loadLocked()
            let date = now()
            guard let record = records.first(where: { $0.id == id }) else { return nil }
            if let consumedAt = record.consumedAt,
               date.timeIntervalSince(consumedAt) > Policy.consumedGraceSeconds {
                return nil
            }
            return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: record.privateKey)
        }
    }

    /// Marks a prekey consumed (starts its grace clock). Idempotent: a
    /// redelivery within the grace window does not restart the clock.
    ///
    /// Returns true when this call actually retired a prekey, i.e. the
    /// published bundle shrank. Consuming a prekey drops it from
    /// `currentBundlePrekeys()`, so `generatedAt` must advance strictly too:
    /// otherwise peers that cached the old bundle reject the same-`generatedAt`
    /// replacement in `PrekeyBundleStore.ingest`, keep assigning the consumed
    /// ID, and their mail starts failing `unknownPrekey` once the 48h grace
    /// lapses. The caller re-gossips on a true result.
    @discardableResult
    func markConsumed(_ id: UInt32) -> Bool {
        queue.sync {
            loadLocked()
            guard let index = records.firstIndex(where: { $0.id == id }),
                  records[index].consumedAt == nil else { return false }
            records[index].consumedAt = now()
            advanceGeneratedAtLocked()
            persistLocked()
            return true
        }
    }

    /// Prunes dead prekeys and tops the unconsumed batch back up when it runs
    /// low. Returns true when the published bundle changed (caller should
    /// re-gossip).
    @discardableResult
    func replenishIfNeeded() -> Bool {
        queue.sync {
            loadLocked()
            return replenishLocked()
        }
    }

    var unconsumedCount: Int {
        queue.sync {
            loadLocked()
            return records.filter { $0.consumedAt == nil }.count
        }
    }

    /// Panic wipe: drop all prekey privates from memory and the Keychain.
    func wipe() {
        queue.sync {
            records.removeAll()
            nextID = 0
            generatedAt = 0
            loaded = true
            _ = keychain.deleteIdentityKey(forKey: Self.keychainKey)
        }
    }

    // MARK: - Internals (call only on `queue`)

    private func replenishLocked() -> Bool {
        let date = now()

        // Consumed prekeys past the grace window are gone for good; stale
        // unconsumed ones rotate out (their bundle is too old to seal to).
        let recordsBefore = records.count
        let unconsumedBefore = records.filter { $0.consumedAt == nil }.count
        records.removeAll { record in
            if let consumedAt = record.consumedAt {
                return date.timeIntervalSince(consumedAt) > Policy.consumedGraceSeconds
            }
            return date.timeIntervalSince(record.createdAt) > Policy.unconsumedRetentionSeconds
        }
        // Only a change to the *unconsumed* set alters the published bundle;
        // grace-expired consumed keys were never in it.
        let unconsumed = records.filter { $0.consumedAt == nil }.count
        var bundleChanged = unconsumed != unconsumedBefore

        if unconsumed < Policy.replenishThreshold {
            for _ in unconsumed..<Policy.batchSize {
                let key = Curve25519.KeyAgreement.PrivateKey()
                records.append(Record(id: nextID, privateKey: key.rawRepresentation, createdAt: date, consumedAt: nil))
                nextID &+= 1
            }
            advanceGeneratedAtLocked()
            bundleChanged = true
            SecureLogger.debug("🔑 Replenished one-time prekeys (unconsumed was \(unconsumed))", category: .security)
        }

        if bundleChanged || records.count != recordsBefore { persistLocked() }
        return bundleChanged
    }

    /// Advance `generatedAt` strictly monotonically. Uses wall-clock millis but
    /// never repeats or regresses, so two changes within the same millisecond
    /// still produce distinct, increasing stamps that peers' monotonic ingest
    /// accepts.
    private func advanceGeneratedAtLocked() {
        let nowMillis = UInt64(max(0, now().timeIntervalSince1970 * 1000))
        generatedAt = max(nowMillis, generatedAt &+ 1)
    }

    private func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard let data = keychain.getIdentityKey(forKey: Self.keychainKey),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return
        }
        records = persisted.records
        nextID = persisted.nextID
        generatedAt = persisted.generatedAt
    }

    private func persistLocked() {
        let persisted = Persisted(records: records, nextID: nextID, generatedAt: generatedAt)
        guard let data = try? JSONEncoder().encode(persisted) else {
            SecureLogger.error("Failed to encode prekey store", category: .keychain)
            return
        }
        if !keychain.saveIdentityKey(data, forKey: Self.keychainKey) {
            SecureLogger.error("Failed to persist prekey store", category: .keychain)
        }
    }
}
