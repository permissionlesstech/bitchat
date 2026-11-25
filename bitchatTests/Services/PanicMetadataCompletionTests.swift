import Foundation
import BitFoundation
import XCTest
@testable import bitchat

final class PanicMetadataCompletionTests: XCTestCase {
    // Dispatch workers own the synchronous store calls. The lock protects the
    // observation shared with the asynchronous XCTest method.
    private final class Fixture: @unchecked Sendable {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = DispatchQueue(label: "test.processed-events.panic")
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var released = false
        var file: URL { root.appendingPathComponent("events.json") }
        lazy var store = NostrProcessedEventStore(fileURL: file, ioQueue: queue)
        lazy var archive = GossipMessageArchive(fileURL: root.appendingPathComponent("gossip.json"))
        lazy var gossip = GossipSyncManager(
            myPeerID: PeerID(str: "0102030405060708"),
            requestSyncManager: RequestSyncManager(),
            archive: archive
        )

        func openQueue() {
            lock.lock()
            released = true
            lock.unlock()
            release.signal()
        }

        var queueWasReleased: Bool {
            lock.lock()
            defer { lock.unlock() }
            return released
        }
    }

    func testProcessedEventWipeWaitsForEarlierAppendAndAllowsFreshPersistence() async {
        let fixture = Fixture()
        let held = expectation(description: "serial file queue held after seed")
        let entered = expectation(description: "worker about to wipe queued append")
        let returnedEarly = expectation(description: "wipe returned while file queue held")
        returnedEarly.isInverted = true
        let completed = expectation(description: "wipe and fresh persistence completed")
        defer { fixture.openQueue() }

        DispatchQueue.global().async {
            fixture.store.append(["synthetic-seed"], cap: 10)
            XCTAssertEqual(fixture.store.load(), ["synthetic-seed"])
            fixture.queue.async {
                held.fulfill()
                fixture.release.wait()
            }
        }
        await fulfillment(of: [held], timeout: TestConstants.settleTimeout)

        DispatchQueue.global().async {
            fixture.store.append(["synthetic-pre-panic"], cap: 10)
            entered.fulfill()
            let wiped = fixture.store.wipe()
            if !fixture.queueWasReleased { returnedEarly.fulfill() }
            XCTAssertTrue(wiped)
            XCTAssertTrue(fixture.queueWasReleased, "Processed-event wipe must finish deletion before returning")
            // Inspect before a load or another queue fence could hide an early return.
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path),
                           "Processed-event wipe must finish deletion before returning")
            fixture.store.append(["synthetic-fresh"], cap: 10)
            XCTAssertEqual(fixture.store.load(), ["synthetic-fresh"])
            let reopened = NostrProcessedEventStore(fileURL: fixture.file)
            XCTAssertEqual(reopened.load(), ["synthetic-fresh"])
            try? FileManager.default.removeItem(at: fixture.root)
            completed.fulfill()
        }
        await fulfillment(of: [entered], timeout: TestConstants.settleTimeout)
        // This bounded observation is scheduling evidence; the intended removal
        // control must reach the early-return assertion to establish sensitivity.
        await fulfillment(of: [returnedEarly], timeout: TestConstants.negativeWaitWindow)
        fixture.openQueue()
        await fulfillment(of: [completed], timeout: TestConstants.settleTimeout)
    }

    func testGossipPanicRetirementDrainsQueuedPersistenceBeforeArchiveDeletion() async {
        let fixture = Fixture()
        let held = expectation(description: "gossip queue held by packet collection")
        let entered = expectation(description: "worker about to retire gossip owner")
        let returnedEarly = expectation(description: "retirement returned while gossip queue held")
        returnedEarly.isInverted = true
        let completed = expectation(description: "retirement and archive deletion completed")
        defer { fixture.openQueue() }

        DispatchQueue.global().async {
            fixture.gossip.collectPublicMessagePackets { _ in
                held.fulfill()
                fixture.release.wait()
            }
        }
        await fulfillment(of: [held], timeout: TestConstants.settleTimeout)
        DispatchQueue.global().async {
            let sender = PeerID(str: "1122334455667788")
            let packet = BitchatPacket(
                type: MessageType.message.rawValue,
                senderID: Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]),
                recipientID: nil,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: Data("SYNTHETIC_QUEUED_GOSSIP".utf8), signature: nil, ttl: 1
            )
            fixture.gossip.onPublicPacketSeen(packet)
            fixture.gossip.persistNow()
            entered.fulfill()
            fixture.gossip.stopForPanic()
            XCTAssertTrue(fixture.queueWasReleased, "Gossip retirement must wait for queued persistence")
            if !fixture.queueWasReleased { returnedEarly.fulfill() }
            XCTAssertEqual(fixture.archive.load().count, 1,
                           "The queued pre-panic packet must reach persistence before retirement returns")
            XCTAssertTrue(fixture.archive.wipe())
            let latePacket = BitchatPacket(
                type: packet.type, senderID: packet.senderID, recipientID: nil,
                timestamp: packet.timestamp,
                payload: Data("SYNTHETIC_RETIRED_OWNER_CALLBACK".utf8), signature: nil, ttl: 1
            )
            fixture.gossip.onPublicPacketSeen(latePacket)
            fixture.gossip.persistNow()
            XCTAssertEqual(fixture.gossip._messageCount(for: sender), 2)
            XCTAssertTrue(fixture.archive.load().isEmpty,
                          "The retired owner must not recreate its deleted archive")
            fixture.gossip.stop()
            try? FileManager.default.removeItem(at: fixture.root)
            completed.fulfill()
        }
        await fulfillment(of: [entered], timeout: TestConstants.settleTimeout)
        await fulfillment(of: [returnedEarly], timeout: TestConstants.negativeWaitWindow)
        fixture.openQueue()
        await fulfillment(of: [completed], timeout: TestConstants.settleTimeout)
    }
}
