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

    private let fileURL: URL?
    private let keychain: KeychainManagerProtocol

    init(keychain: KeychainManagerProtocol, fileURL: URL? = nil) {
        self.keychain = keychain
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    // MARK: - API (call from the router's actor; IO is small and atomic)

    func load() -> [PeerID: [QueuedMessage]] {
        guard let fileURL,
              let sealed = try? Data(contentsOf: fileURL),
              let key = encryptionKey(createIfMissing: false),
              let box = try? ChaChaPoly.SealedBox(combined: sealed),
              let plaintext = try? ChaChaPoly.open(box, using: key),
              let decoded = try? JSONDecoder().decode([String: [QueuedMessage]].self, from: plaintext) else {
            return [:]
        }
        var outbox: [PeerID: [QueuedMessage]] = [:]
        for (peerID, queue) in decoded where !queue.isEmpty {
            outbox[PeerID(str: peerID)] = queue
        }
        return outbox
    }

    func save(_ outbox: [PeerID: [QueuedMessage]]) {
        guard let fileURL else { return }
        let flattened = outbox.filter { !$0.value.isEmpty }
        guard !flattened.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let key = encryptionKey(createIfMissing: true) else {
            SecureLogger.error("Outbox not persisted: no encryption key available", category: .session)
            return
        }
        do {
            let keyed = Dictionary(uniqueKeysWithValues: flattened.map { ($0.key.id, $0.value) })
            let plaintext = try JSONEncoder().encode(keyed)
            let sealed = try ChaChaPoly.seal(plaintext, using: key).combined
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtection)
            #endif
            try sealed.write(to: fileURL, options: options)
        } catch {
            SecureLogger.error("Failed to persist outbox: \(error)", category: .session)
        }
    }

    /// Panic wipe: drop the queued mail and the key that could ever read it.
    func wipe() {
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        keychain.delete(key: Self.keychainKey, service: Self.keychainService)
    }

    // MARK: - Internals

    private func encryptionKey(createIfMissing: Bool) -> SymmetricKey? {
        if let data = keychain.load(key: Self.keychainKey, service: Self.keychainService), data.count == 32 {
            return SymmetricKey(data: data)
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
        return key
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
            .appendingPathComponent("outbox.sealed")
    }
}
