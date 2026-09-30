import XCTest
import BitFoundation
@testable import bitchat

final class NoiseRateLimiterTests: XCTestCase {
    func test_allowHandshake_blocksAfterPerPeerLimit() {
        let limiter = NoiseRateLimiter()
        let peerID = makePeerID(1)

        for _ in 0..<NoiseSecurityConstants.maxHandshakesPerMinute {
            XCTAssertTrue(limiter.allowHandshake(from: peerID))
        }

        XCTAssertFalse(limiter.allowHandshake(from: peerID))
    }

    func test_allowHandshake_blocksAfterGlobalLimitAcrossPeers() {
        let limiter = NoiseRateLimiter()

        for index in 0..<NoiseSecurityConstants.maxGlobalHandshakesPerMinute {
            XCTAssertTrue(limiter.allowHandshake(from: makePeerID(index)))
        }

        XCTAssertFalse(limiter.allowHandshake(from: makePeerID(10_000)))
    }

    func test_reset_clearsPerPeerHandshakeLimit() async {
        let limiter = NoiseRateLimiter()
        let peerID = makePeerID(7)

        for _ in 0..<NoiseSecurityConstants.maxHandshakesPerMinute {
            XCTAssertTrue(limiter.allowHandshake(from: peerID))
        }
        XCTAssertFalse(limiter.allowHandshake(from: peerID))

        limiter.reset(for: peerID)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(limiter.allowHandshake(from: peerID))
    }

    func test_allowMessage_blocksAfterPerPeerLimit() {
        let limiter = NoiseRateLimiter()
        let peerID = makePeerID(9)

        for _ in 0..<NoiseSecurityConstants.maxMessagesPerSecond {
            XCTAssertTrue(limiter.allowMessage(from: peerID))
        }

        XCTAssertFalse(limiter.allowMessage(from: peerID))
    }

    func test_resetAll_clearsGlobalHandshakeLimit() async {
        let limiter = NoiseRateLimiter()

        for index in 0..<NoiseSecurityConstants.maxGlobalHandshakesPerMinute {
            XCTAssertTrue(limiter.allowHandshake(from: makePeerID(index)))
        }
        XCTAssertFalse(limiter.allowHandshake(from: makePeerID(20_000)))

        limiter.resetAll()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(limiter.allowHandshake(from: makePeerID(20_001)))
    }

    private func makePeerID(_ value: Int) -> PeerID {
        PeerID(str: String(format: "%016x", value))
    }

    // MARK: - Peer-map retention

    /// Drives the limiter's clock so window expiry is observable.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        init(_ start: Date) { _now = start }
        var now: Date { lock.withLock { _now } }
        func advance(_ seconds: TimeInterval) { lock.withLock { _now += seconds } }
    }

    func test_handshakeMap_doesNotRetainPeersPastTheirWindow() {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let limiter = NoiseRateLimiter(now: { clock.now })

        // A burst of one-shot peers, each handshaking once and never returning.
        // Stay inside the global per-minute budget so every one is admitted.
        let peerCount = 20
        for index in 0..<peerCount {
            XCTAssertTrue(limiter.allowHandshake(from: makePeerID(index + 1)))
        }
        XCTAssertEqual(limiter.trackedHandshakePeerCount, peerCount)

        // Past the one-minute handshake window, none of them is still relevant.
        clock.advance(NoiseSecurityConstants.handshakeRateLimitWindow + 1)
        XCTAssertTrue(limiter.allowHandshake(from: makePeerID(200)))

        XCTAssertEqual(
            limiter.trackedHandshakePeerCount,
            1,
            "departed peers must not be retained once their handshake window has passed"
        )
    }

    func test_messageMap_doesNotRetainPeersPastTheirWindow() {
        let clock = TestClock(Date(timeIntervalSince1970: 20_000))
        let limiter = NoiseRateLimiter(now: { clock.now })

        let peerCount = 10
        for index in 0..<peerCount {
            XCTAssertTrue(limiter.allowMessage(from: makePeerID(index + 1)))
        }
        XCTAssertEqual(limiter.trackedMessagePeerCount, peerCount)

        clock.advance(NoiseSecurityConstants.messageRateLimitWindow + 1)
        XCTAssertTrue(limiter.allowMessage(from: makePeerID(200)))

        XCTAssertEqual(
            limiter.trackedMessagePeerCount,
            1,
            "departed peers must not be retained once their message window has passed"
        )
    }

    func test_pruningUsesEachMapsWindow() {
        let clock = TestClock(Date(timeIntervalSince1970: 25_000))
        let limiter = NoiseRateLimiter(now: { clock.now })
        let peerID = makePeerID(1)
        XCTAssertTrue(limiter.allowHandshake(from: peerID))
        XCTAssertTrue(limiter.allowMessage(from: peerID))

        clock.advance(NoiseSecurityConstants.messageRateLimitWindow)
        XCTAssertTrue(limiter.allowHandshake(from: makePeerID(2)))
        XCTAssertEqual(limiter.trackedMessagePeerCount, 0)
        XCTAssertEqual(limiter.trackedHandshakePeerCount, 2)

        clock.advance(NoiseSecurityConstants.handshakeRateLimitWindow)
        XCTAssertTrue(limiter.allowMessage(from: peerID))
        XCTAssertEqual(limiter.trackedHandshakePeerCount, 0)
        XCTAssertEqual(limiter.trackedMessagePeerCount, 1)
    }

    func test_pruningKeepsAPeerStillInsideItsWindow() {
        // The counterpart: pruning must not discard a peer whose budget is still
        // being enforced, or the limit becomes trivially bypassable by waiting.
        let clock = TestClock(Date(timeIntervalSince1970: 30_000))
        let limiter = NoiseRateLimiter(now: { clock.now })
        let peerID = makePeerID(7)

        for _ in 0..<NoiseSecurityConstants.maxHandshakesPerMinute {
            XCTAssertTrue(limiter.allowHandshake(from: peerID))
        }
        XCTAssertFalse(limiter.allowHandshake(from: peerID))

        // Well past the prune interval, but well inside the one-minute window.
        clock.advance(5)
        XCTAssertFalse(
            limiter.allowHandshake(from: peerID),
            "a peer still inside its window must stay rate limited across a prune"
        )
        XCTAssertEqual(limiter.trackedHandshakePeerCount, 1)
    }

    func test_pruneRecoversAfterBackwardClockStep() {
        let clock = TestClock(Date(timeIntervalSince1970: 40_000))
        let limiter = NoiseRateLimiter(now: { clock.now })

        // Plant lastPrune ahead of wall time.
        XCTAssertTrue(limiter.allowHandshake(from: makePeerID(1)))
        clock.advance(-100) // now = 39_900; lastPrune = 40_000

        let peerCount = 20
        for index in 0..<peerCount {
            XCTAssertTrue(limiter.allowHandshake(from: makePeerID(index + 10)))
        }

        // Expire that cohort while lastPrune is still in the future without
        // the fix (elapsed stays negative). With the fix, prune runs and the
        // aged cohort is reclaimed.
        clock.advance(NoiseSecurityConstants.handshakeRateLimitWindow + 1) // now = 39_961
        XCTAssertTrue(limiter.allowHandshake(from: makePeerID(200)))

        XCTAssertLessThanOrEqual(
            limiter.trackedHandshakePeerCount,
            2,
            "a backwards clock step must not latch pruning off"
        )
        XCTAssertGreaterThanOrEqual(limiter.trackedHandshakePeerCount, 1)
    }
}
