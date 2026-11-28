//
// EncryptedHistoryStore.swift
// bitchat
//
// Encrypted local persistence for private direct messages and private group
// chats, plus per-conversation disappearing message timers.
//
// Sealed with a 256-bit ChaChaPoly symmetric key stored in the Keychain on top
// of iOS FileProtectionType.completeUntilFirstUserAuthentication. Public mesh
// and geohash timelines are never stored here. Cleared synchronously on panic
// wipe or when switching to Stealth Mode.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import Combine
import CryptoKit
import Foundation

/// Per-conversation message retention window.
enum DisappearingTimer: String, Codable, CaseIterable, Identifiable, Equatable {
    case off
    case hours24
    case days7
    case ephemeral

    var id: String { rawValue }

    /// Retention duration in seconds. `nil` means keep until cleared/wiped;
    /// `0` means RAM-only (never written to disk).
    var duration: TimeInterval? {
        switch self {
        case .off: return nil
        case .hours24: return 24 * 60 * 60
        case .days7: return 7 * 24 * 60 * 60
        case .ephemeral: return 0
        }
    }

    var shortLabel: String {
        switch self {
        case .off: return String(localized: "timer.short.off", defaultValue: "Off", comment: "Short label when disappearing messages are off")
        case .hours24: return String(localized: "timer.short.24h", defaultValue: "24h", comment: "Short label for 24-hour disappearing messages")
        case .days7: return String(localized: "timer.short.7d", defaultValue: "7d", comment: "Short label for 7-day disappearing messages")
        case .ephemeral: return String(localized: "timer.short.ephemeral", defaultValue: "RAM only", comment: "Short label for RAM-only ephemeral chat")
        }
    }

    var displayName: String {
        switch self {
        case .off: return String(localized: "timer.display.off", defaultValue: "Keep history", comment: "Menu label for keeping encrypted chat history")
        case .hours24: return String(localized: "timer.display.24h", defaultValue: "Disappear after 24 hours", comment: "Menu label for 24-hour disappearing messages")
        case .days7: return String(localized: "timer.display.7d", defaultValue: "Disappear after 7 days", comment: "Menu label for 7-day disappearing messages")
        case .ephemeral: return String(localized: "timer.display.ephemeral", defaultValue: "Ephemeral (don't save)", comment: "Menu label for RAM-only ephemeral messages")
        }
    }

    /// Privacy strictness rank used when reconciling timers across peer ID
    /// aliases: ephemeral (RAM-only) > 24h > 7d > off.
    var strictnessRank: Int {
        switch self {
        case .off: return 0
        case .days7: return 1
        case .hours24: return 2
        case .ephemeral: return 3
        }
    }

    /// Returns the stricter (more privacy-preserving) of two timers.
    static func stricter(_ lhs: DisappearingTimer, _ rhs: DisappearingTimer) -> DisappearingTimer {
        lhs.strictnessRank >= rhs.strictnessRank ? lhs : rhs
    }

    var iconName: String {
        switch self {
        case .off: return "clock.arrow.circlepath"
        case .hours24, .days7: return "timer"
        case .ephemeral: return "flame"
        }
    }
}

@MainActor
final class EncryptedHistoryStore: ObservableObject {
    struct Snapshot: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        var messagesByPeerID: [String: [BitchatMessage]]
        var timersByPeerID: [String: DisappearingTimer]
        var unreadPeerIDs: [String]
        var nostrKeyMapping: [String: String]

        init(
            version: Int = currentVersion,
            messagesByPeerID: [String: [BitchatMessage]] = [:],
            timersByPeerID: [String: DisappearingTimer] = [:],
            unreadPeerIDs: [String] = [],
            nostrKeyMapping: [String: String] = [:]
        ) {
            self.version = version
            self.messagesByPeerID = messagesByPeerID
            self.timersByPeerID = timersByPeerID
            self.unreadPeerIDs = unreadPeerIDs
            self.nostrKeyMapping = nostrKeyMapping
        }

        var isEmpty: Bool {
            messagesByPeerID.values.allSatisfy(\.isEmpty) && timersByPeerID.isEmpty
        }
    }

    static let maxMessagesPerConversation = 500
    private static let encryptionKeyName = "privateHistoryEncryptionKey"

    @Published private(set) var timers: [PeerID: DisappearingTimer] = [:]

    /// Thread-safe generation token shared between `@MainActor` callers and
    /// `AppSupportFileStore.ioQueue` so a panic wipe provably invalidates any
    /// in-flight reads AND queued writes.
    private final class GenerationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func current() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        @discardableResult
        func bump() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            value &+= 1
            return value
        }

        func matches(_ expected: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value == expected
        }
    }

    private let keychain: KeychainManagerProtocol
    private let fileStore: AppSupportFileStore
    private let persistenceEnabledProvider: () -> Bool
    private var cachedKey: SymmetricKey?
    /// True when a transient Keychain or disk failure prevented reading durable
    /// data at launch. Refuses to overwrite durable history until healthy.
    private var loadUnavailable = false
    private let generationGate = GenerationGate()

    init(
        keychain: KeychainManagerProtocol,
        persistsToDisk: Bool = true,
        fileURL: URL? = nil,
        persistenceEnabledProvider: @escaping () -> Bool = { PrivacyModeSettings.persistPrivateHistory }
    ) {
        self.keychain = keychain
        self.fileStore = AppSupportFileStore(
            persistsToDisk: persistsToDisk,
            fileURL: fileURL,
            subdirectory: "history",
            fileName: "private-chats.sealed",
            protection: .untilFirstUserAuthentication
        )
        self.persistenceEnabledProvider = persistenceEnabledProvider
    }

    // MARK: - Timers

    func timer(for peerID: PeerID) -> DisappearingTimer {
        timers[peerID] ?? .off
    }

    func setTimer(_ timer: DisappearingTimer, for peerID: PeerID) {
        if timer == .off {
            timers.removeValue(forKey: peerID)
        } else {
            timers[peerID] = timer
        }
    }

    /// Moves a disappearing timer when a conversation migrates from one peer ID
    /// alias to another (e.g. full 64-hex Noise key ↔ 16-hex short mesh ID),
    /// keeping the stricter timer when both aliases already have settings so
    /// RAM-only or short-retention messages can never silently lose protection.
    func migrateTimer(from oldPeerID: PeerID, to newPeerID: PeerID) {
        guard oldPeerID != newPeerID else { return }
        let oldTimer = timer(for: oldPeerID)
        let newTimer = timer(for: newPeerID)
        timers.removeValue(forKey: oldPeerID)
        let merged = DisappearingTimer.stricter(oldTimer, newTimer)
        setTimer(merged, for: newPeerID)
    }

    /// Reconciles the destination peer ID's timer with the source peer ID's
    /// timer without removing the source (used for partial migrations).
    func reconcileTimer(from sourcePeerID: PeerID, to destinationPeerID: PeerID) {
        guard sourcePeerID != destinationPeerID else { return }
        let merged = DisappearingTimer.stricter(timer(for: sourcePeerID), timer(for: destinationPeerID))
        setTimer(merged, for: destinationPeerID)
    }

    // MARK: - Load & Save

    /// Synchronous test-only loader (`Data(contentsOf:)` on `@MainActor`).
    /// Production cold launch must use `loadAsync(now:completion:)`.
    internal func load(now: Date = Date()) -> Snapshot? {
        guard persistenceEnabledProvider() else {
            return nil
        }
        guard let fileURL = fileStore.fileURL else {
            return nil
        }
        AppSupportFileStore.drainPendingWrites()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            loadUnavailable = false
            return nil
        }

        guard let key = resolveExistingKey() else {
            return nil
        }

        let sealedBytes: Data
        do {
            sealedBytes = try Data(contentsOf: fileURL)
        } catch {
            if AppSupportFileStore.isMissingFileError(error) {
                loadUnavailable = false
                return nil
            }
            loadUnavailable = true
            SecureLogger.warning("Private history unreadable; deferring writes: \(error)", category: .security)
            return nil
        }

        return decodeAndPrune(sealedBytes: sealedBytes, key: key, now: now)
    }

    /// Reads the sealed history file off the main thread, then decrypts and
    /// delivers the snapshot on `@MainActor`.
    func loadAsync(now: Date = Date(), completion: @escaping @MainActor (Snapshot?) -> Void) {
        guard persistenceEnabledProvider(), fileStore.fileURL != nil else {
            completion(nil)
            return
        }
        let generation = generationGate.current()
        fileStore.readRawAsync { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.generationGate.matches(generation) else {
                    completion(nil)
                    return
                }
                guard self.persistenceEnabledProvider() else {
                    completion(nil)
                    return
                }
                switch result {
                case .success(nil):
                    self.loadUnavailable = false
                    completion(nil)
                case .success(let sealedBytes?):
                    guard let key = self.resolveExistingKey() else {
                        completion(nil)
                        return
                    }
                    completion(self.decodeAndPrune(sealedBytes: sealedBytes, key: key, now: now))
                case .failure(let error):
                    if AppSupportFileStore.isMissingFileError(error) {
                        self.loadUnavailable = false
                    } else {
                        self.loadUnavailable = true
                        SecureLogger.warning("Private history unreadable; deferring writes: \(error)", category: .security)
                    }
                    completion(nil)
                }
            }
        }
    }

    private func decodeAndPrune(sealedBytes: Data, key: SymmetricKey, now: Date) -> Snapshot? {
        do {
            let sealedBox = try ChaChaPoly.SealedBox(combined: sealedBytes)
            let plaintext = try ChaChaPoly.open(sealedBox, using: key)
            let decoded = try JSONDecoder().decode(Snapshot.self, from: plaintext)
            let pruned = Self.prunedSnapshot(decoded, now: now)
            loadUnavailable = false
            applyLoadedTimers(pruned.timersByPeerID)
            return pruned
        } catch {
            SecureLogger.error("Failed to decrypt or decode private history: \(error)", category: .security)
            return nil
        }
    }

    /// Seals and persists private conversations + disappearing timers to disk.
    /// Removes the file if persistence is disabled or the sanitized snapshot is empty.
    /// Pass `synchronous: true` on lifecycle boundaries (`background` / `terminate`)
    /// so the queued I/O write lands on disk before the call returns.
    func save(
        from store: ConversationStore,
        nostrKeyMapping: [PeerID: String],
        now: Date = Date(),
        synchronous: Bool = false
    ) {
        guard persistenceEnabledProvider() else {
            clearDiskFileOnly()
            return
        }
        guard !loadUnavailable else {
            SecureLogger.warning("Skipping private history save while prior load was unavailable", category: .security)
            return
        }
        guard fileStore.fileURL != nil else { return }

        var messagesByPeerID: [String: [BitchatMessage]] = [:]
        var unreadPeerIDs: [String] = []
        var mappedKeys: [String: String] = [:]

        for (id, conversation) in store.conversationsByID {
            guard case .direct(let handle) = id else { continue }
            let peerID = handle.routingPeerID
            let rawPeerID = peerID.id
            let chatTimer = timer(for: peerID)
            guard chatTimer != .ephemeral else { continue }

            let retained = Self.filterMessages(conversation.messages, timer: chatTimer, now: now)
            guard !retained.isEmpty else { continue }

            let bounded = retained.count > Self.maxMessagesPerConversation
                ? Array(retained.suffix(Self.maxMessagesPerConversation))
                : retained
            messagesByPeerID[rawPeerID] = bounded

            if conversation.isUnread {
                unreadPeerIDs.append(rawPeerID)
            }
            if let nostrKey = nostrKeyMapping[peerID] {
                mappedKeys[rawPeerID] = nostrKey
            }
        }

        var timersByPeerID: [String: DisappearingTimer] = [:]
        for (peerID, timer) in timers where timer != .off {
            timersByPeerID[peerID.id] = timer
        }

        let snapshot = Snapshot(
            messagesByPeerID: messagesByPeerID,
            timersByPeerID: timersByPeerID,
            unreadPeerIDs: unreadPeerIDs,
            nostrKeyMapping: mappedKeys
        )
        persistSnapshot(snapshot, synchronous: synchronous)
    }

    /// Removes persisted history from disk while leaving the encryption key
    /// untouched (e.g., when switching to Stealth Mode).
    func clearPersistedHistory() {
        clearDiskFileOnly()
    }

    /// Panic wipe: destroys disk file, Keychain encryption key, and timer state.
    func wipe() {
        generationGate.bump()
        loadUnavailable = false
        cachedKey = nil
        timers.removeAll()
        fileStore.removeIgnoringErrors()
        _ = keychain.deleteIdentityKey(forKey: Self.encryptionKeyName)
    }

    // MARK: - Expiration Filtering

    static func prunedSnapshot(_ snapshot: Snapshot, now: Date) -> Snapshot {
        var prunedMessages: [String: [BitchatMessage]] = [:]
        var validUnread: [String] = []
        let unreadSet = Set(snapshot.unreadPeerIDs)

        for (rawPeerID, messages) in snapshot.messagesByPeerID {
            let timer = snapshot.timersByPeerID[rawPeerID] ?? .off
            guard timer != .ephemeral else { continue }
            let retained = filterMessages(messages, timer: timer, now: now)
            guard !retained.isEmpty else { continue }
            let bounded = retained.count > maxMessagesPerConversation
                ? Array(retained.suffix(maxMessagesPerConversation))
                : retained
            prunedMessages[rawPeerID] = bounded
            if unreadSet.contains(rawPeerID) {
                validUnread.append(rawPeerID)
            }
        }

        let activeTimers = snapshot.timersByPeerID.filter { $0.value != .off }
        let keptKeys = snapshot.nostrKeyMapping.filter { prunedMessages[$0.key] != nil }

        return Snapshot(
            version: Snapshot.currentVersion,
            messagesByPeerID: prunedMessages,
            timersByPeerID: activeTimers,
            unreadPeerIDs: validUnread,
            nostrKeyMapping: keptKeys
        )
    }

    static func filterMessages(
        _ messages: [BitchatMessage],
        timer: DisappearingTimer,
        now: Date
    ) -> [BitchatMessage] {
        switch timer {
        case .off:
            return messages
        case .ephemeral:
            return []
        case .hours24, .days7:
            guard let duration = timer.duration else { return messages }
            let cutoff = now.addingTimeInterval(-duration)
            return messages.filter { $0.timestamp >= cutoff }
        }
    }

    // MARK: - Internals

    private func applyLoadedTimers(_ stored: [String: DisappearingTimer]) {
        var loaded: [PeerID: DisappearingTimer] = [:]
        for (rawPeerID, timer) in stored where timer != .off {
            loaded[PeerID(str: rawPeerID)] = timer
        }
        timers = loaded
    }

    private func clearDiskFileOnly() {
        fileStore.removeIgnoringErrors()
    }

    private func persistSnapshot(_ snapshot: Snapshot, synchronous: Bool) {
        guard fileStore.fileURL != nil else { return }
        let expectedGeneration = generationGate.current()
        let gate = generationGate
        let shouldExecute: @Sendable () -> Bool = {
            gate.matches(expectedGeneration)
        }
        if snapshot.isEmpty {
            fileStore.removeOffMain(shouldExecute: shouldExecute)
            if synchronous {
                AppSupportFileStore.drainPendingWrites()
            }
            return
        }
        guard let key = resolveOrCreateKey() else {
            return
        }
        do {
            let plaintext = try JSONEncoder().encode(snapshot)
            let sealed = try ChaChaPoly.seal(plaintext, using: key)
            try fileStore.writeRawOffMain(sealed.combined, shouldExecute: shouldExecute)
            if synchronous {
                AppSupportFileStore.drainPendingWrites()
            }
        } catch {
            SecureLogger.error("Failed to seal and persist private history: \(error)", category: .security)
        }
    }

    private func resolveExistingKey() -> SymmetricKey? {
        if let cachedKey {
            return cachedKey
        }
        switch keychain.getIdentityKeyWithResult(forKey: Self.encryptionKeyName) {
        case .success(let data) where data.count == 32:
            let key = SymmetricKey(data: data)
            cachedKey = key
            return key
        case .success, .itemNotFound:
            return nil
        case .deviceLocked, .authenticationFailed, .accessDenied, .otherError:
            loadUnavailable = true
            SecureLogger.warning("Private history key unavailable; deferring load/save", category: .security)
            return nil
        }
    }

    private func resolveOrCreateKey() -> SymmetricKey? {
        if let cachedKey {
            return cachedKey
        }
        switch keychain.getIdentityKeyWithResult(forKey: Self.encryptionKeyName) {
        case .success(let data) where data.count == 32:
            let key = SymmetricKey(data: data)
            cachedKey = key
            return key
        case .success, .itemNotFound:
            let newKey = SymmetricKey(size: .bits256)
            let raw = newKey.withUnsafeBytes { Data($0) }
            guard keychain.saveIdentityKey(raw, forKey: Self.encryptionKeyName) else {
                SecureLogger.error("Failed to save private history key in keychain", category: .security)
                return nil
            }
            cachedKey = newKey
            return newKey
        case .deviceLocked, .authenticationFailed, .accessDenied, .otherError:
            loadUnavailable = true
            SecureLogger.warning("Private history key unavailable; skipping write", category: .security)
            return nil
        }
    }
}
