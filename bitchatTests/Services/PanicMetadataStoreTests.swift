import BitFoundation
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import bitchat

@Suite(.serialized)
@MainActor
struct PanicMetadataStoreTests {
    enum Store: CaseIterable { case groups, board, courier, gossip, bridge, events }

    @Test(arguments: Store.allCases)
    func deletionFailureIsReportedAndRetryPreservesSibling(_ store: Store) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { _ = chmod(root.path, 0o700); try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("metadata.json")
        let sibling = root.appendingPathComponent("keep.txt")
        let wipe: () -> Bool
        switch store {
        case .groups:
            let owner = GroupStore(keychain: MockKeychain(), fileURL: file)
            wipe = { owner.wipe() }
        case .board:
            let owner = BoardStore(fileURL: file)
            wipe = { owner.wipe() }
        case .courier:
            let owner = CourierStore(fileURL: file)
            wipe = { owner.wipe() }
        case .gossip:
            let owner = GossipMessageArchive(fileURL: file)
            wipe = { owner.wipe() }
        case .bridge:
            let owner = BridgeDropDedupStore(fileURL: file)
            wipe = { owner.wipe() }
        case .events:
            let owner = NostrProcessedEventStore(fileURL: file)
            wipe = { owner.wipe() }
        }
        // Deletion is independent of record decoding; producer/reload coverage is separate.
        let bytes = Data("SYNTHETIC_METADATA_DELETE_UNIT_FIXTURE".utf8)
        try bytes.write(to: file)
        try Data("KEEP".utf8).write(to: sibling)
        #expect(chmod(root.path, 0o500) == 0)
        #expect(!wipe(), "A denied metadata deletion must be reported")
        #expect(try Data(contentsOf: file) == bytes)
        #expect(chmod(root.path, 0o700) == 0)
        #expect(wipe(), "Metadata deletion must succeed after access is restored")
        #expect(!fm.fileExists(atPath: file.path))
        #expect(fm.fileExists(atPath: sibling.path), "Unrelated metadata sibling must survive")
        if fm.fileExists(atPath: sibling.path) {
            #expect(try Data(contentsOf: sibling) == Data("KEEP".utf8))
        }
        #expect(wipe(), "An absent metadata file must be harmless")
    }

    @Test(arguments: [false, true])
    func panicRetirementPreventsPersistenceAndOrdinaryStopPreservesIt(_ retire: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("archive.json")
        let archive = GossipMessageArchive(fileURL: file)
        let sender = PeerID(str: "1122334455667788")
        let packet = BitchatPacket(type: MessageType.message.rawValue,
                                   senderID: Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]),
                                   recipientID: nil,
                                   timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                                   payload: Data("SYNTHETIC_PUBLIC_PACKET".utf8), signature: nil, ttl: 1)
        let encoded = try #require(packet.toBinaryData(padding: false))
        archive.save([encoded])
        let manager = GossipSyncManager(myPeerID: sender, requestSyncManager: RequestSyncManager(), archive: archive)
        #expect(manager._messageCount(for: sender) == 1)
        if retire { manager.stopForPanic() } else { manager.stop(); manager.start() }
        defer { manager.stop() }
        #expect(archive.wipe())
        manager.persistNow()
        _ = manager._messageCount(for: sender)
        #expect(fm.fileExists(atPath: file.path) == !retire,
                "A retired owner must not save; ordinary stop/start must retain persistence")
    }
}
