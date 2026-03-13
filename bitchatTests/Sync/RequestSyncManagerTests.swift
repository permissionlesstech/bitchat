import XCTest
@testable import bitchat

final class RequestSyncManagerTests: XCTestCase {
    func test_isValidResponse_returnsFalseWhenPacketIsNotRSR() {
        let clock = MutableSyncClock(now: 1_000)
        let manager = RequestSyncManager(responseWindow: 30, now: { clock.now })

        manager.registerRequest(to: PeerID(str: "aaaaaaaaaaaaaaaa"))
        XCTAssertFalse(manager.isValidResponse(from: PeerID(str: "aaaaaaaaaaaaaaaa"), isRSR: false))
    }

    func test_isValidResponse_returnsFalseForUnsolicitedRSR() {
        let clock = MutableSyncClock(now: 1_000)
        let manager = RequestSyncManager(responseWindow: 30, now: { clock.now })

        XCTAssertFalse(manager.isValidResponse(from: PeerID(str: "bbbbbbbbbbbbbbbb"), isRSR: true))
    }

    func test_isValidResponse_acceptsRecentRequest() async {
        let clock = MutableSyncClock(now: 1_000)
        let manager = RequestSyncManager(responseWindow: 30, now: { clock.now })
        let peerID = PeerID(str: "cccccccccccccccc")

        manager.registerRequest(to: peerID)
        let registered = await waitUntil {
            manager.debugPendingRequestCount == 1
        }
        XCTAssertTrue(registered)

        clock.now = 1_020
        XCTAssertTrue(manager.isValidResponse(from: peerID, isRSR: true))
    }

    func test_cleanup_removesExpiredRequestsAndPreservesFreshOnes() async {
        let clock = MutableSyncClock(now: 1_000)
        let manager = RequestSyncManager(responseWindow: 30, now: { clock.now })
        let expiredPeer = PeerID(str: "dddddddddddddddd")
        let freshPeer = PeerID(str: "eeeeeeeeeeeeeeee")

        manager.registerRequest(to: expiredPeer)
        _ = await waitUntil { manager.debugPendingRequestCount == 1 }

        clock.now = 1_010
        manager.registerRequest(to: freshPeer)
        let bothRegistered = await waitUntil {
            manager.debugPendingRequestCount == 2
        }
        XCTAssertTrue(bothRegistered)

        clock.now = 1_035
        XCTAssertFalse(manager.isValidResponse(from: expiredPeer, isRSR: true))
        XCTAssertTrue(manager.isValidResponse(from: freshPeer, isRSR: true))

        manager.cleanup()
        let cleaned = await waitUntil {
            manager.debugPendingRequestCount == 1
        }
        XCTAssertTrue(cleaned)
        XCTAssertFalse(manager.isValidResponse(from: expiredPeer, isRSR: true))
        XCTAssertTrue(manager.isValidResponse(from: freshPeer, isRSR: true))
    }

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

private final class MutableSyncClock {
    var now: TimeInterval

    init(now: TimeInterval) {
        self.now = now
    }
}
