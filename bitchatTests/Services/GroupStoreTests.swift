//
// GroupStoreTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
import BitFoundation
@testable import bitchat

@MainActor
struct GroupStoreTests {

    private func makeMember(seed: UInt8, nickname: String = "peer") -> GroupMember {
        GroupMember(
            fingerprint: Data(repeating: seed, count: 32).hexEncodedString(),
            signingKey: Data(repeating: seed &+ 1, count: 32),
            nickname: nickname
        )
    }

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("group-store-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("groups.json")
    }

    // MARK: - Create / read

    @Test func createGroupStoresMetadataAndKey() throws {
        let store = GroupStore(keychain: MockKeychain(), persistsToDisk: false)
        let creator = makeMember(seed: 0xC1, nickname: "me")

        let group = try #require(store.createGroup(named: "ops", creator: creator))
        #expect(group.groupID.count == BitchatGroup.groupIDLength)
        #expect(group.epoch == 1)
        #expect(group.members == [creator])
        #expect(group.creatorFingerprint == creator.fingerprint)

        #expect(store.group(withID: group.groupID) == group)
        #expect(store.group(for: group.peerID) == group)
        let key = try #require(store.key(forGroupID: group.groupID))
        #expect(key.count == BitchatGroup.keyLength)
        #expect(group.peerID.isGroup)
        #expect(group.peerID.groupIDData == group.groupID)
    }

    // MARK: - Roster cap

    @Test func rosterCapIsEnforced() throws {
        let store = GroupStore(keychain: MockKeychain(), persistsToDisk: false)
        let creator = makeMember(seed: 0xC1)
        let group = try #require(store.createGroup(named: "big", creator: creator))

        // Filling to the cap works…
        let fifteen = (1...15).map { makeMember(seed: UInt8($0)) }
        #expect(store.updateRoster(groupID: group.groupID, members: [creator] + fifteen) != nil)
        #expect(store.group(withID: group.groupID)?.members.count == BitchatGroup.maxMembers)

        // …one more is rejected.
        let overflow = [creator] + fifteen + [makeMember(seed: 0x99)]
        #expect(store.updateRoster(groupID: group.groupID, members: overflow) == nil)
        #expect(store.group(withID: group.groupID)?.members.count == BitchatGroup.maxMembers)

        // Direct upsert past the cap is rejected too.
        var oversized = group
        oversized.members = overflow
        #expect(!store.upsert(oversized, key: Data(repeating: 1, count: 32)))
    }

    @Test func rosterMustRetainCreator() throws {
        let store = GroupStore(keychain: MockKeychain(), persistsToDisk: false)
        let creator = makeMember(seed: 0xC1)
        let other = makeMember(seed: 0xA1)
        let group = try #require(store.createGroup(named: "crew", creator: creator))

        #expect(store.updateRoster(groupID: group.groupID, members: [other]) == nil)
        #expect(store.group(withID: group.groupID)?.members == [creator])
    }

    // MARK: - Rotation

    @Test func rotateKeyBumpsEpochAndReplacesKey() throws {
        let store = GroupStore(keychain: MockKeychain(), persistsToDisk: false)
        let creator = makeMember(seed: 0xC1)
        let removed = makeMember(seed: 0xA1)
        let group = try #require(store.createGroup(named: "crew", creator: creator))
        #expect(store.updateRoster(groupID: group.groupID, members: [creator, removed]) != nil)
        let oldKey = try #require(store.key(forGroupID: group.groupID))

        let rotation = try #require(store.rotateKey(groupID: group.groupID, members: [creator]))
        #expect(rotation.group.epoch == 2)
        #expect(rotation.group.members == [creator])
        #expect(rotation.key != oldKey)
        #expect(store.key(forGroupID: group.groupID) == rotation.key)
        #expect(store.group(withID: group.groupID)?.epoch == 2)
    }

    // MARK: - Persistence

    @Test func persistsAcrossInstances() throws {
        let keychain = MockKeychain()
        let fileURL = tempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let creator = makeMember(seed: 0xC1, nickname: "me")
        let group: BitchatGroup
        do {
            let store = GroupStore(keychain: keychain, fileURL: fileURL)
            group = try #require(store.createGroup(named: "hike", creator: creator))
        }

        let reloaded = GroupStore(keychain: keychain, fileURL: fileURL)
        #expect(reloaded.groups == [group])
        #expect(reloaded.key(forGroupID: group.groupID) != nil)
    }

    @Test func groupsWithoutKeysAreDroppedOnLoad() throws {
        let keychain = MockKeychain()
        let fileURL = tempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let group: BitchatGroup
        do {
            let store = GroupStore(keychain: keychain, fileURL: fileURL)
            group = try #require(store.createGroup(named: "stale", creator: makeMember(seed: 0xC1)))
        }
        // Simulate a keychain wipe without the metadata file being removed.
        _ = keychain.deleteAllKeychainData()

        let reloaded = GroupStore(keychain: keychain, fileURL: fileURL)
        #expect(reloaded.groups.isEmpty)
        #expect(reloaded.group(withID: group.groupID) == nil)
    }

    // MARK: - Panic wipe

    @Test func wipeRemovesMetadataAndKeys() throws {
        let keychain = MockKeychain()
        let fileURL = tempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = GroupStore(keychain: keychain, fileURL: fileURL)
        let group = try #require(store.createGroup(named: "gone", creator: makeMember(seed: 0xC1)))
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        store.wipe()

        #expect(store.groups.isEmpty)
        #expect(store.key(forGroupID: group.groupID) == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        // A fresh instance sees nothing either.
        let reloaded = GroupStore(keychain: keychain, fileURL: fileURL)
        #expect(reloaded.groups.isEmpty)
    }

    @Test func removeGroupDeletesItsKey() throws {
        let keychain = MockKeychain()
        let store = GroupStore(keychain: keychain, persistsToDisk: false)
        let group = try #require(store.createGroup(named: "bye", creator: makeMember(seed: 0xC1)))

        store.removeGroup(withID: group.groupID)
        #expect(store.groups.isEmpty)
        #expect(store.key(forGroupID: group.groupID) == nil)
    }
}
