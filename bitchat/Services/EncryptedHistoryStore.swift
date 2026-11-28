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

    private let keychain: KeychainManagerProtocol
    private let fileStore: AppSupportFileStore
    private let persistenceEnabledProvider: () -> Bool
    private var cachedKey: SymmetricKey?
    /// True when a transient Keychain or disk failure prevented reading durable
    /// data at launch. Refuses to overwrite durable history until healthy.
    private var loadUnavailable = false
    private var lifecycleGeneration: UInt64 = 0

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

    // MARK: - Load & Save

    /// Loads and decrypts persisted private conversations, pruning any messages
    /// past their per-chat disappearing timer. Returns `nil` when persistence is
    /// disabled or no history file exists.
    func load(now: Date = Date()) -> Snapshot? {
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
        let generation = lifecycleGeneration
        fileStore.readRawAsync { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.lifecycleGeneration == generation else {
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
    func save(
        from store: ConversationStore,
        nostrKeyMapping: [PeerID: String],
        now: Date = Date()
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
        persistSnapshot(snapshot)
    }

    /// Persists an explicit snapshot (used by tests and direct callers).
    func saveSnapshot(_ snapshot: Snapshot, now: Date = Date()) {
        guard persistenceEnabledProvider() else {
            clearDiskFileOnly()
            return
        }
        guard !loadUnavailable else { return }
        let sanitized = Self.prunedSnapshot(snapshot, now: now)
        applyLoadedTimers(sanitized.timersByPeerID)
        persistSnapshot(sanitized)
    }

    /// Removes persisted history from disk while leaving the encryption key
    /// untouched (e.g., when switching to Stealth Mode).
    func clearPersistedHistory() {
        clearDiskFileOnly()
    }

    /// Panic wipe: destroys disk file, Keychain encryption key, and timer state.
    func wipe() {
        lifecycleGeneration &+= 1
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

    private func persistSnapshot(_ snapshot: Snapshot) {
        guard fileStore.fileURL != nil else { return }
        if snapshot.isEmpty {
            fileStore.removeOffMain()
            return
        }
        guard let key = resolveOrCreateKey() else {
            return
        }
        do {
            let plaintext = try JSONEncoder().encode(snapshot)
            let sealed = try ChaChaPoly.seal(plaintext, using: key)
            try fileStore.writeRawOffMain(sealed.combined)
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
