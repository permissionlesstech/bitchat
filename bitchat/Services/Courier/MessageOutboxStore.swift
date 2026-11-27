//
// MessageOutboxStore.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import CryptoKit
import Foundation
import Security
#if os(iOS)
import UIKit
#endif

/// Disk persistence for the MessageRouter outbox, so private messages queued
/// for an offline peer survive an app kill instead of silently evaporating.
///
/// Nothing else in the app persists message plaintext, and this store keeps
/// that property: the outbox is sealed with a ChaChaPoly key that lives only
/// in the Keychain (after-first-unlock, this device only), on top of iOS file
/// protection. Wiped on panic alongside the courier store.
final class MessageOutboxStore {
    struct QueuedMessage: Codable, Equatable {
        let content: String
        let nickname: String
        let messageID: String
        let timestamp: Date
        var sendAttempts: Int
        /// Noise keys of couriers already carrying this message, so deposit
        /// retries add couriers instead of re-burning the same ones.
        var depositedCourierKeys: Set<Data>

        init(
            content: String,
            nickname: String,
            messageID: String,
            timestamp: Date,
            sendAttempts: Int = 0,
            depositedCourierKeys: Set<Data> = []
        ) {
            self.content = content
            self.nickname = nickname
            self.messageID = messageID
            self.timestamp = timestamp
            self.sendAttempts = sendAttempts
            self.depositedCourierKeys = depositedCourierKeys
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            content = try container.decode(String.self, forKey: .content)
            nickname = try container.decode(String.self, forKey: .nickname)
            messageID = try container.decode(String.self, forKey: .messageID)
            timestamp = try container.decode(Date.self, forKey: .timestamp)
            sendAttempts = try container.decodeIfPresent(Int.self, forKey: .sendAttempts) ?? 0
            depositedCourierKeys = try container.decodeIfPresent(Set<Data>.self, forKey: .depositedCourierKeys) ?? []
        }
    }

    private static let keychainService = "chat.bitchat.outbox"
    private static let keychainKey = "outbox-encryption-key"

    typealias Snapshot = [PeerID: [QueuedMessage]]

    private enum DiskState {
        case unknown
        case loaded
        case deferred
    }

    private enum DiskReadResult {
        case missing
        case loaded(Snapshot)
        case deferred(Error?)
        case corrupt(Error)
    }

    private enum EncryptionKeyReadResult {
        case available(SymmetricKey)
        case missing
        case invalid
        case unavailable(Error?)
    }

    private struct RecoveredSnapshot {
        let snapshot: Snapshot
        let generation: UInt64
        let unseenDurable: Snapshot
    }

    private let fileStore: AppSupportFileStore
    private var fileURL: URL? { fileStore.fileURL }
    private let keychain: KeychainManagerProtocol
    private let readData: (URL) throws -> Data
    private let writeData: (Data, URL, Data.WritingOptions) throws -> Void
    private let beforeRecoveryNotification: () -> Void
    private let lock = NSLock()
    private var diskState: DiskState = .unknown
    private var cachedSnapshot: Snapshot = [:]
    /// Mutations made after a protected-data load failed. They are merged
    /// with the durable snapshot once it becomes readable, never written on
    /// top of an unreadable file.
    private var pendingSnapshot: Snapshot?
    /// True after a write failed after the durable baseline was already
    /// loaded. That full-router snapshot includes removals and must replace,
    /// rather than union with, the older disk contents on retry.
    private var pendingSnapshotIsAuthoritative = false
    /// Delivery/read acknowledgments received before a deferred cold-load
    /// reveals the durable queue. Applied to every merge before persistence.
    private var pendingRemovalMessageIDs = Set<String>()
    /// Peer-scoped acknowledgments received before a deferred cold-load
    /// reveals the durable queue. Unlike the legacy global tombstones above,
    /// these must not remove a colliding message ID queued for another peer.
    private var pendingScopedRemovalMessageIDs: [PeerID: Set<String>] = [:]
    private var recoveryHandler: (@MainActor (Snapshot) -> Void)?
    /// Recovery loaded durable state that MessageRouter has not merged yet.
    /// While true, router saves must union with `cachedSnapshot` instead of
    /// replacing unseen durable messages.
    private var recoveryDeliveryPending = false
    /// Recovery read durable state and classified the unseen subset, but the
    /// merged snapshot could not yet be persisted. Preserve that classification
    /// across retries instead of treating the cached union as router-known.
    private var unseenRecoveryPendingPersistence = false
    /// MessageRouter's latest authoritative in-memory snapshot while a
    /// recovery classification is awaiting persistence or delivery. This is
    /// deliberately separate from `pendingSnapshot`, which may contain the
    /// union of router-known and unseen durable work after a failed write.
    private var recoveryRouterSnapshot: Snapshot = [:]
    /// The durable messages absent from MessageRouter's locked-wake snapshot
    /// when recovery completed. Only this subset is unioned into authoritative
    /// router saves before the recovery callback is claimed.
    private var unseenRecoveredSnapshot: Snapshot = [:]
    /// Covers the narrow launch race where protected data becomes available
    /// after `load()` returned but before MessageRouter installs its handler.
    private var unreportedRecoveredSnapshot: RecoveredSnapshot?
    /// Invalidates recovery callbacks already queued onto the main actor when
    /// panic wipe begins.
    private var lifecycleGeneration: UInt64 = 0
    #if os(iOS)
    private var protectedDataObserver: NSObjectProtocol?
    #endif

    init(
        keychain: KeychainManagerProtocol,
        fileURL: URL? = nil,
        readData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) },
        writeData: @escaping (Data, URL, Data.WritingOptions) throws -> Void = {
            try $0.write(to: $1, options: $2)
        },
        beforeRecoveryNotification: @escaping () -> Void = {}
    ) {
        self.keychain = keychain
        self.fileStore = AppSupportFileStore(
            fileURL: fileURL,
            subdirectory: "courier",
            fileName: "outbox.sealed",
            protection: .untilFirstUserAuthentication
        )
        self.readData = readData
        self.writeData = writeData
        self.beforeRecoveryNotification = beforeRecoveryNotification
        #if os(iOS)
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.retryDeferredLoad()
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

    // MARK: - API (call from the router's actor; IO is small and atomic)

    /// True while protected-data deferral or recovery may still hide durable
    /// entries not yet visible in `MessageRouter`'s in-memory outbox.
    var hasDeferredDiskState: Bool {
        lock.lock()
        defer { lock.unlock() }
        return diskState != .loaded || recoveryDeliveryPending || unseenRecoveryPendingPersistence
    }

    func load() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }

        if case .loaded = diskState {
            return cachedSnapshot
        }
        // Once a deferred recovery has classified the durable baseline,
        // `cachedSnapshot` is the only safe synchronous view. Re-reading via
        // the generic load path would confuse its durable+router union with a
        // fully router-known authoritative snapshot.
        if unseenRecoveryPendingPersistence || recoveryDeliveryPending {
            return cachedSnapshot
        }

        let wasDeferred = diskState == .deferred
        let durable: Snapshot?
        switch readSnapshotLocked() {
        case .loaded(let snapshot):
            durable = snapshot
        case .missing:
            durable = nil
        case .corrupt(let error):
            SecureLogger.error("Failed to decode encrypted outbox: \(error)", category: .session)
            durable = nil
        case .deferred(let error):
            diskState = .deferred
            if !wasDeferred {
                SecureLogger.warning("Outbox unavailable; deferring load until protected data is available: \(String(describing: error))", category: .session)
            }
            return pendingSnapshot ?? [:]
        }

        let base: Snapshot
        if let durable, !pendingSnapshotIsAuthoritative {
            base = Self.merge(durable, pendingSnapshot ?? [:])
        } else {
            base = pendingSnapshot ?? [:]
        }
        cachedSnapshot = applyingPendingRemovalsLocked(base)
        diskState = .loaded
        _ = commitOrDeferPersistLocked(cachedSnapshot, skipIfClean: true)
        // The recovery callback is driven by `retryDeferredLoad`; `load`
        // itself returns the recovered value synchronously to its caller.
        return cachedSnapshot
    }

    func save(_ outbox: Snapshot) {
        var recovered: RecoveredSnapshot?

        lock.lock()
        let recoveryWasPending = recoveryDeliveryPending
        let recoveryStateWasPending = recoveryWasPending || unseenRecoveryPendingPersistence
        let flattened = applyingPendingRemovalsLocked(outbox.filter { !$0.value.isEmpty })
        if recoveryStateWasPending {
            // `save` is the router's complete current view. Keep it separate
            // from the durable union retained for disk retry.
            recoveryRouterSnapshot = flattened
        }
        switch diskState {
        case .loaded:
            cachedSnapshot = applyingPendingRemovalsLocked(
                recoveryStateWasPending
                    ? Self.merge(unseenRecoveredSnapshot, recoveryRouterSnapshot)
                    : flattened
            )
            // On failure, retain the latest complete router snapshot. Because its
            // durable baseline was already loaded, it replaces the older disk
            // file after protected data returns (preserving removals).
            _ = commitOrDeferPersistLocked(cachedSnapshot, skipIfClean: false)

        case .unknown, .deferred:
            let wasDeferred = diskState == .deferred
            // A non-authoritative deferred snapshot means the initial cold
            // load never completed. An authoritative deferred snapshot with
            // no recovery state is merely an ordinary post-load write retry.
            let isRecoveryAttempt = recoveryStateWasPending ||
                (wasDeferred && !pendingSnapshotIsAuthoritative)
            let deferFallback = applyingPendingRemovalsLocked(
                recoveryStateWasPending
                    ? Self.merge(unseenRecoveredSnapshot, recoveryRouterSnapshot)
                    : flattened
            )
            recovered = resolveDiskReadLocked(
                known: flattened,
                isRecoveryAttempt: isRecoveryAttempt,
                recoveryWasPending: recoveryWasPending,
                recoveryStateWasPending: recoveryStateWasPending,
                skipPersistIfClean: false,
                deferFallbackSnapshot: deferFallback,
                corruptLogContext: "Failed to decode encrypted outbox"
            )
        }
        finalizeRecoveryStateLocked(recovered)
        lock.unlock()

        deliverRecoveryIfNeeded(recovered)
    }

    /// Installs the router-side merge hook used when a cold, locked launch
    /// initially received an empty snapshot and protected data later becomes
    /// readable.
    func setRecoveryHandler(_ handler: @escaping @MainActor (Snapshot) -> Void) {
        lock.lock()
        recoveryHandler = handler
        let unreported = unreportedRecoveredSnapshot
        unreportedRecoveredSnapshot = nil
        lock.unlock()
        if let unreported {
            Task { @MainActor [weak self] in
                guard let latest = self?.claimPendingRecovery(generation: unreported.generation) else { return }
                handler(latest)
            }
        }
    }

    /// Records an ack even when a locked cold-load has not revealed the
    /// matching durable message yet. The next `save`/recovery applies this
    /// tombstone before writing or notifying MessageRouter.
    func recordRemoval(messageID: String) {
        lock.lock()
        pendingRemovalMessageIDs.insert(messageID)
        cachedSnapshot = Self.removing([messageID], from: cachedSnapshot)
        unseenRecoveredSnapshot = Self.removing([messageID], from: unseenRecoveredSnapshot)
        recoveryRouterSnapshot = Self.removing([messageID], from: recoveryRouterSnapshot)
        if let pendingSnapshot {
            self.pendingSnapshot = Self.removing([messageID], from: pendingSnapshot)
        }
        lock.unlock()
    }

    /// Records an ack for only the supplied peer aliases. This preserves
    /// another recipient's queued entry when message IDs happen to collide,
    /// including while the durable snapshot is hidden by protected data.
    func recordRemoval(messageID: String, for peerIDs: Set<PeerID>) {
        guard !peerIDs.isEmpty else { return }

        lock.lock()
        for peerID in peerIDs {
            pendingScopedRemovalMessageIDs[peerID, default: []].insert(messageID)
        }
        cachedSnapshot = Self.removing(pendingScopedRemovalMessageIDs, from: cachedSnapshot)
        unseenRecoveredSnapshot = Self.removing(pendingScopedRemovalMessageIDs, from: unseenRecoveredSnapshot)
        recoveryRouterSnapshot = Self.removing(pendingScopedRemovalMessageIDs, from: recoveryRouterSnapshot)
        if let pendingSnapshot {
            self.pendingSnapshot = Self.removing(pendingScopedRemovalMessageIDs, from: pendingSnapshot)
        }
        lock.unlock()
    }

    /// Retries a deferred protected-data load. The returned snapshot includes
    /// both durable messages and any messages queued during the locked wake.
    @discardableResult
    func retryDeferredLoad() -> Snapshot? {
        lock.lock()
        guard diskState == .deferred else {
            lock.unlock()
            return nil
        }
        let recoveryWasPending = recoveryDeliveryPending
        let recoveryStateWasPending = recoveryWasPending || unseenRecoveryPendingPersistence
        // `pendingSnapshotIsAuthoritative` alone means a normal write failed
        // after the router had already loaded its baseline. It must retry, but
        // must not masquerade as cold-load recovery or schedule a callback.
        let isRecoveryAttempt = recoveryStateWasPending || !pendingSnapshotIsAuthoritative
        let known = recoveryStateWasPending ? recoveryRouterSnapshot : (pendingSnapshot ?? [:])
        let recovered = resolveDiskReadLocked(
            known: known,
            isRecoveryAttempt: isRecoveryAttempt,
            recoveryWasPending: recoveryWasPending,
            recoveryStateWasPending: recoveryStateWasPending,
            skipPersistIfClean: true,
            deferFallbackSnapshot: nil,
            corruptLogContext: "Failed to decode encrypted outbox after protected-data recovery"
        )
        finalizeRecoveryStateLocked(recovered)
        lock.unlock()

        deliverRecoveryIfNeeded(recovered)
        return recovered?.snapshot
    }

    /// Must be called with `lock` held. Resolves a disk read during deferred
    /// recovery or initial save, merging any unseen durable messages and
    /// committing or re-deferring the persisted snapshot.
    private func resolveDiskReadLocked(
        known: Snapshot,
        isRecoveryAttempt: Bool,
        recoveryWasPending: Bool,
        recoveryStateWasPending: Bool,
        skipPersistIfClean: Bool,
        deferFallbackSnapshot: Snapshot?,
        corruptLogContext: String
    ) -> RecoveredSnapshot? {
        let durable: Snapshot?
        switch readSnapshotLocked() {
        case .loaded(let snapshot):
            durable = snapshot
        case .missing:
            durable = nil
        case .corrupt(let error):
            SecureLogger.error("\(corruptLogContext): \(error)", category: .session)
            durable = nil
        case .deferred:
            if let deferFallbackSnapshot {
                pendingSnapshot = deferFallbackSnapshot
                diskState = .deferred
            }
            return nil
        }

        if isRecoveryAttempt && !recoveryStateWasPending {
            unseenRecoveredSnapshot = durable.map {
                applyingPendingRemovalsLocked(Self.excludingKnownMessages(from: $0, known: known))
            } ?? [:]
            recoveryRouterSnapshot = known
            unseenRecoveryPendingPersistence = true
        }
        let preservesUnseenRecovery = recoveryStateWasPending || unseenRecoveryPendingPersistence
        let rawMerged: Snapshot
        if preservesUnseenRecovery {
            rawMerged = Self.merge(unseenRecoveredSnapshot, recoveryRouterSnapshot)
        } else if let durable, !pendingSnapshotIsAuthoritative {
            rawMerged = Self.merge(durable, known)
        } else {
            rawMerged = known
        }

        let merged = applyingPendingRemovalsLocked(rawMerged)
        cachedSnapshot = merged
        diskState = .loaded
        guard commitOrDeferPersistLocked(merged, skipIfClean: skipPersistIfClean) else {
            return nil
        }
        guard isRecoveryAttempt && !recoveryWasPending else {
            return nil
        }
        return RecoveredSnapshot(
            snapshot: merged,
            generation: lifecycleGeneration,
            unseenDurable: unseenRecoveredSnapshot
        )
    }

    /// Must be called with `lock` held. Persists `snapshot` (unless `skipIfClean`
    /// and nothing is dirty) or defers it as authoritative pending state on error.
    private func commitOrDeferPersistLocked(_ snapshot: Snapshot, skipIfClean: Bool) -> Bool {
        if skipIfClean && pendingSnapshot == nil && !hasPendingRemovalsLocked {
            return true
        }
        if persistSnapshotAndClearRemovalsLocked(snapshot) {
            pendingSnapshot = nil
            pendingSnapshotIsAuthoritative = false
            return true
        }
        pendingSnapshot = snapshot
        pendingSnapshotIsAuthoritative = true
        diskState = .deferred
        return false
    }

    /// Must be called with `lock` held.
    private func finalizeRecoveryStateLocked(_ recovered: RecoveredSnapshot?) {
        guard let recovered else { return }
        unseenRecoveryPendingPersistence = false
        recoveryDeliveryPending = true
        unseenRecoveredSnapshot = recovered.unseenDurable
    }

    private func deliverRecoveryIfNeeded(_ recovered: RecoveredSnapshot?) {
        guard let recovered else { return }
        beforeRecoveryNotification()
        notifyRecovered(recovered.snapshot, generation: recovered.generation)
    }

    /// Panic wipe: drop the queued mail and the key that could ever read it.
    func wipe() {
        lock.lock()
        diskState = .loaded
        cachedSnapshot = [:]
        pendingSnapshot = nil
        pendingSnapshotIsAuthoritative = false
        pendingRemovalMessageIDs.removeAll()
        pendingScopedRemovalMessageIDs.removeAll()
        recoveryDeliveryPending = false
        unseenRecoveryPendingPersistence = false
        unseenRecoveredSnapshot = [:]
        recoveryRouterSnapshot = [:]
        unreportedRecoveredSnapshot = nil
        lifecycleGeneration &+= 1
        cachedEncryptionKey = nil
        fileStore.removeIgnoringErrors()
        keychain.delete(key: Self.keychainKey, service: Self.keychainService)
        lock.unlock()
    }

    // MARK: - Internals

    private var cachedEncryptionKey: SymmetricKey?

    private func encryptionKey(createIfMissing: Bool) -> SymmetricKey? {
        switch readEncryptionKey() {
        case .available(let key):
            return key
        case .missing:
            break
        case .invalid:
            guard createIfMissing else { return nil }
            cachedEncryptionKey = nil
            keychain.delete(key: Self.keychainKey, service: Self.keychainService)
        case .unavailable:
            return nil
        }
        guard createIfMissing else { return nil }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        // After-first-unlock so queued mail can flush from background BLE wakes.
        keychain.save(
            key: Self.keychainKey,
            data: data,
            service: Self.keychainService,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        // The protocol's generic save predates result-bearing writes. Verify
        // the item before sealing a file: otherwise a locked/full Keychain
        // could drop the key while we successfully write unrecoverable mail.
        guard case .success(let stored) = keychain.loadWithResult(
            key: Self.keychainKey,
            service: Self.keychainService
        ), stored == data else {
            keychain.delete(key: Self.keychainKey, service: Self.keychainService)
            SecureLogger.error("Outbox encryption key was not retained by Keychain", category: .session)
            return nil
        }
        cachedEncryptionKey = key
        return key
    }

    private func readEncryptionKey() -> EncryptionKeyReadResult {
        if let cachedEncryptionKey {
            return .available(cachedEncryptionKey)
        }
        switch keychain.loadWithResult(key: Self.keychainKey, service: Self.keychainService) {
        case .success(let data):
            guard data.count == 32 else { return .invalid }
            let key = SymmetricKey(data: data)
            cachedEncryptionKey = key
            return .available(key)
        case .itemNotFound:
            return .missing
        case .deviceLocked, .authenticationFailed:
            return .unavailable(nil)
        case .accessDenied:
            return .unavailable(NSError(domain: NSOSStatusErrorDomain, code: Int(errSecNotAvailable)))
        case .otherError(let status):
            return .unavailable(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }
    }

    /// Must be called with `lock` held.
    private func readSnapshotLocked() -> DiskReadResult {
        guard let fileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return .missing
        }
        let sealed: Data
        do {
            sealed = try readData(fileURL)
        } catch {
            return .deferred(error)
        }
        // A locked Keychain is transient; a genuine item-not-found next to an
        // existing sealed file is permanent (notably after restoring onto a
        // new device, because the key is ThisDeviceOnly). Remove that
        // unrecoverable ciphertext before allowing a replacement key/file.
        let key: SymmetricKey
        switch readEncryptionKey() {
        case .available(let availableKey):
            key = availableKey
        case .missing:
            return discardOrphanedSnapshotLocked(reason: "encryption key is missing")
        case .invalid:
            keychain.delete(key: Self.keychainKey, service: Self.keychainService)
            return discardOrphanedSnapshotLocked(reason: "encryption key has an invalid length")
        case .unavailable(let error):
            return .deferred(error)
        }
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealed)
            let plaintext = try ChaChaPoly.open(box, using: key)
            let decoded = try JSONDecoder().decode([String: [QueuedMessage]].self, from: plaintext)
            var outbox: Snapshot = [:]
            for (peerID, queue) in decoded where !queue.isEmpty {
                outbox[PeerID(str: peerID)] = queue
            }
            fileStore.migrateProtectionIfNeeded(logContext: "outbox")
            return .loaded(outbox)
        } catch {
            return .corrupt(error)
        }
    }

    /// Must be called with `lock` held. A ciphertext whose ThisDeviceOnly key
    /// is definitively absent can never become readable; removing it is safer
    /// than deferring forever or overwriting it while pretending it loaded.
    private func discardOrphanedSnapshotLocked(reason: String) -> DiskReadResult {
        guard let fileURL else { return .missing }
        do {
            try FileManager.default.removeItem(at: fileURL)
            SecureLogger.warning("Removed unrecoverable encrypted outbox because its \(reason)", category: .session)
            return .missing
        } catch {
            SecureLogger.error("Could not remove unrecoverable encrypted outbox: \(error)", category: .session)
            return .deferred(error)
        }
    }

    /// Must be called with `lock` held.
    @discardableResult
    private func persistSnapshotLocked(_ snapshot: Snapshot) -> Bool {
        guard let fileURL else { return true }
        do {
            if snapshot.isEmpty {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                return true
            }
            guard let key = encryptionKey(createIfMissing: true) else {
                SecureLogger.error("Outbox not persisted: no encryption key available", category: .session)
                return false
            }
            let keyed = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.key.id, $0.value) })
            let plaintext = try JSONEncoder().encode(keyed)
            let sealed = try ChaChaPoly.seal(plaintext, using: key).combined
            try fileStore.writeRaw(sealed, write: writeData)
            return true
        } catch {
            SecureLogger.error("Failed to persist outbox: \(error)", category: .session)
            return false
        }
    }

    /// Must be called with `lock` held.
    private func persistSnapshotAndClearRemovalsLocked(_ snapshot: Snapshot) -> Bool {
        guard persistSnapshotLocked(snapshot) else { return false }
        pendingRemovalMessageIDs.removeAll()
        pendingScopedRemovalMessageIDs.removeAll()
        return true
    }

    /// Must be called with `lock` held.
    private func applyingPendingRemovalsLocked(_ snapshot: Snapshot) -> Snapshot {
        Self.removing(
            pendingScopedRemovalMessageIDs,
            from: Self.removing(pendingRemovalMessageIDs, from: snapshot)
        )
    }

    /// Must be read with `lock` held.
    private var hasPendingRemovalsLocked: Bool {
        !pendingRemovalMessageIDs.isEmpty || !pendingScopedRemovalMessageIDs.isEmpty
    }

    private static func removing(_ messageIDs: Set<String>, from snapshot: Snapshot) -> Snapshot {
        guard !messageIDs.isEmpty else { return snapshot }
        var filtered: Snapshot = [:]
        for (peerID, queue) in snapshot {
            let remaining = queue.filter { !messageIDs.contains($0.messageID) }
            if !remaining.isEmpty { filtered[peerID] = remaining }
        }
        return filtered
    }

    private static func removing(
        _ messageIDsByPeer: [PeerID: Set<String>],
        from snapshot: Snapshot
    ) -> Snapshot {
        guard !messageIDsByPeer.isEmpty else { return snapshot }
        var filtered = snapshot
        for (peerID, messageIDs) in messageIDsByPeer {
            guard !messageIDs.isEmpty, let queue = filtered[peerID] else { continue }
            let remaining = queue.filter { !messageIDs.contains($0.messageID) }
            filtered[peerID] = remaining.isEmpty ? nil : remaining
        }
        return filtered
    }

    private static func excludingKnownMessages(from durable: Snapshot, known: Snapshot) -> Snapshot {
        var unseen: Snapshot = [:]
        for (peerID, durableQueue) in durable {
            let knownIDs = Set(known[peerID]?.map(\.messageID) ?? [])
            let remaining = durableQueue.filter { !knownIDs.contains($0.messageID) }
            if !remaining.isEmpty { unseen[peerID] = remaining }
        }
        return unseen
    }

    static func merge(_ durable: Snapshot, _ pending: Snapshot) -> Snapshot {
        var merged = durable
        for (peerID, pendingQueue) in pending {
            var queue = merged[peerID] ?? []
            for var candidate in pendingQueue {
                if let index = queue.firstIndex(where: { $0.messageID == candidate.messageID }) {
                    candidate.sendAttempts = max(candidate.sendAttempts, queue[index].sendAttempts)
                    candidate.depositedCourierKeys.formUnion(queue[index].depositedCourierKeys)
                    queue[index] = candidate
                } else {
                    queue.append(candidate)
                }
            }
            queue.sort { $0.timestamp < $1.timestamp }
            if !queue.isEmpty { merged[peerID] = queue }
        }
        return merged.filter { !$0.value.isEmpty }
    }

    private func notifyRecovered(_ snapshot: Snapshot, generation: UInt64) {
        lock.lock()
        guard lifecycleGeneration == generation else {
            lock.unlock()
            return
        }
        let handler = recoveryHandler
        if handler == nil {
            unreportedRecoveredSnapshot = RecoveredSnapshot(
                snapshot: snapshot,
                generation: generation,
                unseenDurable: unseenRecoveredSnapshot
            )
        }
        lock.unlock()
        guard let handler else { return }
        Task { @MainActor [weak self] in
            guard let latest = self?.claimPendingRecovery(generation: generation) else { return }
            handler(latest)
        }
    }

    private func claimPendingRecovery(generation: UInt64) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard lifecycleGeneration == generation, recoveryDeliveryPending else { return nil }
        let latest = cachedSnapshot
        recoveryDeliveryPending = false
        unseenRecoveryPendingPersistence = false
        unseenRecoveredSnapshot = [:]
        recoveryRouterSnapshot = [:]
        unreportedRecoveredSnapshot = nil
        return latest
    }
}
