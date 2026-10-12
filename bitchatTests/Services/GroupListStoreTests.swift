//
// GroupListStoreTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
import BitFoundation
@testable import bitchat

@MainActor
struct GroupListStoreTests {
    private let author = Data(repeating: 0xA1, count: 32)
    private let creator = GroupMember(
        fingerprint: Data(repeating: 0xC1, count: 32).hexEncodedString(),
        signingKey: Data(repeating: 0xC2, count: 32),
        nickname: "me"
    )

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("group-list-store-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("groups.json")
    }

    private func itemID(_ seed: UInt8) -> Data {
        Data(repeating: seed, count: GroupList.itemIDLength)
    }

    private func addItem(_ text: String, seed: UInt8, to groupID: Data, in store: GroupStore) -> GroupListDelta? {
        store.lists.edit(groupID: groupID) { list in
            list.add(text: text, id: itemID(seed), author: author, nowMs: UInt64(seed))
        }
    }

    @Test
    func listsSurviveARelaunch() throws {
        let keychain = MockKeychain()
        let fileURL = tempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = GroupStore(keychain: keychain, fileURL: fileURL)
        let group = try #require(store.createGroup(named: "camp", creator: creator))
        #expect(addItem("water", seed: 1, to: group.groupID, in: store) != nil)
        #expect(addItem("maps", seed: 2, to: group.groupID, in: store) != nil)

        let relaunched = GroupStore(keychain: keychain, fileURL: fileURL)
        #expect(relaunched.lists.list(forGroupID: group.groupID).items.map(\.text) == ["water", "maps"])
    }

    @Test
    func failedEditsChangeNothing() throws {
        let store = GroupStore(keychain: MockKeychain(), persistsToDisk: false)
        let group = try #require(store.createGroup(named: "camp", creator: creator))
        let edit = store.lists.edit(groupID: group.groupID) { list in
            list.setChecked(true, id: itemID(9), author: author, nowMs: 1)
        }
        #expect(edit == nil)
        #expect(store.lists.lists.isEmpty)
    }

    @Test
    func mergeReportsWhetherAnythingChanged() throws {
        let store = GroupStore(keychain: MockKeychain(), persistsToDisk: false)
        let group = try #require(store.createGroup(named: "camp", creator: creator))
        let delta: GroupListDelta = [itemID(1): GroupListItemState(added: .init(stamp: GroupListStamp(timestampMs: 1, author: author), text: "water"))]

        let first = store.lists.merge(delta, intoGroupID: group.groupID)
        let repeated = store.lists.merge(delta, intoGroupID: group.groupID)
        #expect(first)
        #expect(repeated == false)
    }

    @Test
    func leavingAGroupDropsItsList() throws {
        let keychain = MockKeychain()
        let fileURL = tempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = GroupStore(keychain: keychain, fileURL: fileURL)
        let group = try #require(store.createGroup(named: "camp", creator: creator))
        #expect(addItem("water", seed: 1, to: group.groupID, in: store) != nil)

        store.removeGroup(withID: group.groupID)
        #expect(store.lists.list(forGroupID: group.groupID).records.isEmpty)
        #expect(GroupStore(keychain: keychain, fileURL: fileURL).lists.lists.isEmpty)
    }

    @Test
    func panicWipeDropsListsFromMemoryAndDisk() throws {
        let keychain = MockKeychain()
        let fileURL = tempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = GroupStore(keychain: keychain, fileURL: fileURL)
        let group = try #require(store.createGroup(named: "camp", creator: creator))
        #expect(addItem("water", seed: 1, to: group.groupID, in: store) != nil)

        store.wipe()
        #expect(store.lists.lists.isEmpty)
        let listsFile = fileURL.deletingLastPathComponent().appendingPathComponent("lists.json")
        #expect(FileManager.default.fileExists(atPath: listsFile.path) == false)
    }

    @Test
    func listsForGroupsWithoutAKeyAreDroppedOnLoad() throws {
        let keychain = MockKeychain()
        let fileURL = tempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = GroupStore(keychain: keychain, fileURL: fileURL)
        let group = try #require(store.createGroup(named: "camp", creator: creator))
        #expect(addItem("water", seed: 1, to: group.groupID, in: store) != nil)

        // The keychain lost the group key (e.g. restored onto a new device).
        let relaunched = GroupStore(keychain: MockKeychain(), fileURL: fileURL)
        #expect(relaunched.groups.isEmpty)
        #expect(relaunched.lists.lists.isEmpty)
    }
}
