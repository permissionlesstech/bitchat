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
    private let fileStore: AppSupportFileStore
    private var keyCache: [Data: Data] = [:]
    /// True when initial disk or keychain load failed with a transient error
    /// (such as locked background boot). Prevents `persist()` from overwriting
    /// durable group metadata on disk with a truncated in-memory roster.
    private var loadUnavailable = false

    /// - Parameter fileURL: Overrides the on-disk location (tests). Ignored
    ///   when `persistsToDisk` is false.
    init(keychain: KeychainManagerProtocol, persistsToDisk: Bool = true, fileURL: URL? = nil) {
        self.keychain = keychain
        self.fileStore = AppSupportFileStore(
            persistsToDisk: persistsToDisk,
            fileURL: fileURL,
            subdirectory: "groups",
            fileName: "groups.json",
            protection: .untilFirstUserAuthentication
        )
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

    /// Current-epoch symmetric key for the group, cached in memory after first keychain read.
    func key(forGroupID groupID: Data) -> Data? {
        if let cached = keyCache[groupID] {
            return cached
        }
        guard let fetched = keychain.getIdentityKey(forKey: Self.keychainKey(for: groupID)) else {
            return nil
        }
        keyCache[groupID] = fetched
        return fetched
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
    /// the hard cap, groups whose creator is missing from the roster, new
    /// groups beyond the store cap, and any change to the creator (fingerprint
    /// or signing key) of a group already held, so no caller can hand a known
    /// groupID to a different creator.
    @discardableResult
    func upsert(_ group: BitchatGroup, key: Data) -> Bool {
        guard key.count == BitchatGroup.keyLength,
              Self.isWellFormed(group) else { return false }
        let existingIndex = groups.firstIndex(where: { $0.groupID == group.groupID })
        if let existingIndex {
            let existing = groups[existingIndex]
            if !existing.hasSameCreator(as: group) {
                SecureLogger.warning(
                    "Refusing group state: creator \(group.creatorFingerprint.prefix(8))… does not match stored creator \(existing.creatorFingerprint.prefix(8))…",
                    category: .security
                )
                return false
            }
        } else if groups.count >= BitchatGroup.maxGroups {
            SecureLogger.warning(
                "Refusing new group \(group.groupID.hexEncodedString().prefix(8))…: group store at cap (\(BitchatGroup.maxGroups))",
                category: .security
            )
            return false
        }
        guard keychain.saveIdentityKey(key, forKey: Self.keychainKey(for: group.groupID)) else {
            SecureLogger.error("Failed to store group key in keychain", category: .security)
            return false
        }
        keyCache[group.groupID] = key
        if let existingIndex {
            groups[existingIndex] = group
        } else {
            groups.append(group)
        }
        persist()
        return true
    }

    /// Updates the roster of an existing group without changing key or epoch
    /// (creator-side invite). Enforces the member cap and keeps the creator's
    /// roster entry (fingerprint and signing key) pinned.
    @discardableResult
    func updateRoster(groupID: Data, members: [GroupMember]) -> BitchatGroup? {
        guard let index = groups.firstIndex(where: { $0.groupID == groupID }) else { return nil }
        var updated = groups[index]
        updated.members = members
        guard Self.isWellFormed(updated), groups[index].hasSameCreator(as: updated) else { return nil }
        groups[index] = updated
        persist()
        return updated
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
        keyCache.removeValue(forKey: groupID)
        _ = keychain.deleteIdentityKey(forKey: Self.keychainKey(for: groupID))
        persist()
    }

    /// Panic wipe: drop all group keys and metadata from memory and disk.
    /// (The panic flow also nukes the whole keychain; deleting per-group keys
    /// here keeps the store safe to wipe on its own.)
    func wipe() {
        loadUnavailable = false
        for group in groups {
            _ = keychain.deleteIdentityKey(forKey: Self.keychainKey(for: group.groupID))
        }
        groups.removeAll()
        keyCache.removeAll()
        fileStore.removeIgnoringErrors()
    }

    // MARK: - Internals

    private static func keychainKey(for groupID: Data) -> String {
        "groupKey-\(groupID.hexEncodedString())"
    }

    /// Structural invariants every stored group satisfies: a well-sized ID,
    /// a non-empty bounded name, a non-empty roster within the cap, and the
    /// creator in that roster.
    private static func isWellFormed(_ group: BitchatGroup) -> Bool {
        let trimmedName = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return group.groupID.count == BitchatGroup.groupIDLength
            && !trimmedName.isEmpty
            && trimmedName.count <= BitchatGroup.maxNameLength
            && group.name.utf8.count <= BitchatGroup.maxNameUTF8Bytes
            && !group.members.isEmpty
            && group.members.count <= BitchatGroup.maxMembers
            && group.creator != nil
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
        guard !loadUnavailable else {
            SecureLogger.warning("⚠️ Skipping group store save while prior disk/keychain load was unavailable", category: .security)
            return
        }
        do {
            try fileStore.saveJSON(groups, isEmpty: groups.isEmpty)
        } catch {
            SecureLogger.error("Failed to persist group store: \(error)", category: .session)
        }
    }

    private func loadFromDisk() {
        let stored: [BitchatGroup]?
        do {
            stored = try fileStore.loadJSON([BitchatGroup].self)
        } catch {
            loadUnavailable = true
            SecureLogger.warning("⚠️ Group store disk read unavailable at launch; deferring writes: \(error)", category: .security)
            return
        }
        guard let stored else {
            loadUnavailable = false
            return
        }
        // Only groups whose key survived in the keychain are usable. Loading
        // bypasses `upsert`, so re-check its invariants here too, and keep one
        // entry per groupID so a group can never carry two creators. If any
        // group's keychain read fails transiently (e.g. device locked), mark
        // `loadUnavailable` so we never overwrite durable metadata.
        var seenGroupIDs = Set<Data>()
        var loaded: [BitchatGroup] = []
        for group in stored {
            guard Self.isWellFormed(group),
                  seenGroupIDs.insert(group.groupID).inserted else { continue }
            switch keychain.getIdentityKeyWithResult(forKey: Self.keychainKey(for: group.groupID)) {
            case .success(let keyData):
                keyCache[group.groupID] = keyData
                loaded.append(group)
            case .itemNotFound:
                continue
            case .deviceLocked, .authenticationFailed, .accessDenied, .otherError:
                loadUnavailable = true
                SecureLogger.warning("⚠️ Group key keychain read unavailable at launch; deferring writes", category: .security)
                return
            }
        }
        loadUnavailable = false
        groups = loaded
    }
}
