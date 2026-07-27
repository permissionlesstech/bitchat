//
// GroupStore.swift
// bitchat
//
// Persistence for private groups: symmetric keys in the keychain, metadata
// (roster, name, epoch) as protected JSON in Application Support. Both are
// dropped by the panic wipe.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import Combine
import Foundation
import Security

@MainActor
final class GroupStore: ObservableObject {
    /// All groups this device is a member of, in creation/join order.
    @Published private(set) var groups: [BitchatGroup] = []

    private let keychain: KeychainManagerProtocol
    private let fileURL: URL?

    /// - Parameter fileURL: Overrides the on-disk location (tests). Ignored
    ///   when `persistsToDisk` is false.
    init(keychain: KeychainManagerProtocol, persistsToDisk: Bool = true, fileURL: URL? = nil) {
        self.keychain = keychain
        self.fileURL = persistsToDisk ? (fileURL ?? Self.defaultFileURL()) : nil
        loadFromDisk()
    }

    // MARK: - Reads

    func group(withID groupID: Data) -> BitchatGroup? {
        groups.first { $0.groupID == groupID }
    }

    func group(for peerID: PeerID) -> BitchatGroup? {
        guard let groupID = peerID.groupIDData else { return nil }
        return group(withID: groupID)
    }

    /// Current-epoch symmetric key for the group, from the keychain.
    func key(forGroupID groupID: Data) -> Data? {
        keychain.getIdentityKey(forKey: Self.keychainKey(for: groupID))
    }

    // MARK: - Mutations

    /// Creates a new group with a random 16-byte ID and 32-byte key at
    /// epoch 1, with the creator as sole member. Returns nil when key
    /// generation or persistence fails.
    func createGroup(named name: String, creator: GroupMember) -> BitchatGroup? {
        guard let groupID = Self.randomBytes(BitchatGroup.groupIDLength),
              let key = Self.randomBytes(BitchatGroup.keyLength) else { return nil }
        let group = BitchatGroup(
            groupID: groupID,
            name: name,
            epoch: 1,
            members: [creator],
            creatorFingerprint: creator.fingerprint
        )
        guard upsert(group, key: key) else { return nil }
        return group
    }

    /// Inserts or replaces a group and its current key. Rejects rosters over
    /// the hard cap or groups whose creator is missing from the roster.
    @discardableResult
    func upsert(_ group: BitchatGroup, key: Data) -> Bool {
        guard group.groupID.count == BitchatGroup.groupIDLength,
              key.count == BitchatGroup.keyLength,
              !group.members.isEmpty,
              group.members.count <= BitchatGroup.maxMembers,
              group.creator != nil else { return false }
        guard keychain.saveIdentityKey(key, forKey: Self.keychainKey(for: group.groupID)) else {
            SecureLogger.error("Failed to store group key in keychain", category: .security)
            return false
        }
        if let index = groups.firstIndex(where: { $0.groupID == group.groupID }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
        persist()
        return true
    }

    /// Updates the roster of an existing group without changing key or epoch
    /// (creator-side invite). Enforces the member cap.
    @discardableResult
    func updateRoster(groupID: Data, members: [GroupMember]) -> BitchatGroup? {
        guard let index = groups.firstIndex(where: { $0.groupID == groupID }),
              !members.isEmpty,
              members.count <= BitchatGroup.maxMembers,
              members.contains(where: { $0.fingerprint == groups[index].creatorFingerprint }) else { return nil }
        groups[index].members = members
        persist()
        return groups[index]
    }

    /// Rotates the group key (creator-side removal/rotation): new random key,
    /// epoch + 1, and the given roster. Returns the updated group and new key.
    func rotateKey(groupID: Data, members: [GroupMember]) -> (group: BitchatGroup, key: Data)? {
        guard let existing = group(withID: groupID),
              let newKey = Self.randomBytes(BitchatGroup.keyLength) else { return nil }
        var rotated = existing
        rotated.epoch = existing.epoch &+ 1
        rotated.members = members
        guard upsert(rotated, key: newKey) else { return nil }
        return (rotated, newKey)
    }

    func removeGroup(withID groupID: Data) {
        groups.removeAll { $0.groupID == groupID }
        _ = keychain.deleteIdentityKey(forKey: Self.keychainKey(for: groupID))
        persist()
    }

    /// Panic wipe: drop all group keys and metadata from memory and disk.
    /// (The panic flow also nukes the whole keychain; deleting per-group keys
    /// here keeps the store safe to wipe on its own.)
    func wipe() {
        for group in groups {
            _ = keychain.deleteIdentityKey(forKey: Self.keychainKey(for: group.groupID))
        }
        groups.removeAll()
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Internals

    private static func keychainKey(for groupID: Data) -> String {
        "groupKey-\(groupID.hexEncodedString())"
    }

    private static func randomBytes(_ count: Int) -> Data? {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        return status == errSecSuccess ? bytes : nil
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            if groups.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(groups)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtection)
            #endif
            try data.write(to: fileURL, options: options)
        } catch {
            SecureLogger.error("Failed to persist group store: \(error)", category: .session)
        }
    }

    private func loadFromDisk() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([BitchatGroup].self, from: data) else {
            return
        }
        // Only groups whose key survived in the keychain are usable.
        groups = stored.filter { key(forGroupID: $0.groupID) != nil }
    }

    private static func defaultFileURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return base
            .appendingPathComponent("groups", isDirectory: true)
            .appendingPathComponent("groups.json")
    }
}
