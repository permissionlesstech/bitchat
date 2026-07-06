//
// MessageOutboxStoreTests.swift
// bitchatTests
//
// Tests for the encrypted-at-rest outbox persistence.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

struct MessageOutboxStoreTests {

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-\(UUID().uuidString).sealed")
    }

    private func makeMessage(_ id: String, content: String = "hello") -> MessageOutboxStore.QueuedMessage {
        MessageOutboxStore.QueuedMessage(
            content: content,
            nickname: "peer",
            messageID: id,
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            sendAttempts: 2,
            depositedCourierKeys: [Data(repeating: 0xC1, count: 32)]
        )
    }

    @Test func roundTripAcrossInstances() {
        let fileURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let peerID = PeerID(str: "0000000000000001")

        let store = MessageOutboxStore(keychain: keychain, fileURL: fileURL)
        store.save([peerID: [makeMessage("m1")]])

        // Same keychain (encryption key) reads it back, fields intact.
        let reloaded = MessageOutboxStore(keychain: keychain, fileURL: fileURL).load()
        #expect(reloaded[peerID]?.count == 1)
        #expect(reloaded[peerID]?.first?.messageID == "m1")
        #expect(reloaded[peerID]?.first?.sendAttempts == 2)
        #expect(reloaded[peerID]?.first?.depositedCourierKeys.count == 1)
    }

    @Test func contentIsNotPlaintextOnDisk() throws {
        let fileURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = MessageOutboxStore(keychain: MockKeychain(), fileURL: fileURL)
        store.save([PeerID(str: "0000000000000001"): [makeMessage("m1", content: "very secret message")]])

        let raw = try Data(contentsOf: fileURL)
        #expect(!raw.isEmpty)
        // Sealed bytes must not contain the message plaintext.
        #expect(raw.range(of: Data("very secret message".utf8)) == nil)
    }

    @Test func loadWithoutKeyReturnsEmpty() {
        let fileURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = MessageOutboxStore(keychain: MockKeychain(), fileURL: fileURL)
        store.save([PeerID(str: "0000000000000001"): [makeMessage("m1")]])

        // A different keychain (fresh device / wiped key) cannot read the file.
        let other = MessageOutboxStore(keychain: MockKeychain(), fileURL: fileURL)
        #expect(other.load().isEmpty)
    }

    @Test func wipeRemovesFileAndKey() {
        let fileURL = makeTempURL()
        let keychain = MockKeychain()
        let store = MessageOutboxStore(keychain: keychain, fileURL: fileURL)
        store.save([PeerID(str: "0000000000000001"): [makeMessage("m1")]])
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        store.wipe()
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(store.load().isEmpty)
    }

    @Test func savingEmptyOutboxRemovesFile() {
        let fileURL = makeTempURL()
        let keychain = MockKeychain()
        let store = MessageOutboxStore(keychain: keychain, fileURL: fileURL)
        let peerID = PeerID(str: "0000000000000001")
        store.save([peerID: [makeMessage("m1")]])
        store.save([peerID: []])
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }
}
