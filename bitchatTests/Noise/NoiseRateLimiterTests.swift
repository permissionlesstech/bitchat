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

    func test_allowLargeCiphertext_blocksAfterPerPeerLimit() {
        let limiter = NoiseRateLimiter()
        let peerID = makePeerID(11)

        for _ in 0..<NoiseSecurityConstants.maxLargeCiphertextsPerSecond {
            XCTAssertTrue(limiter.allowLargeCiphertext(from: peerID))
        }

        XCTAssertFalse(limiter.allowLargeCiphertext(from: peerID))
    }

    func test_allowLargeCiphertext_blocksAfterGlobalLimitAcrossPeers() {
        let limiter = NoiseRateLimiter()

        for index in 0..<NoiseSecurityConstants.maxGlobalLargeCiphertextsPerSecond {
            XCTAssertTrue(limiter.allowLargeCiphertext(from: makePeerID(1_000 + index)))
        }

        XCTAssertFalse(limiter.allowLargeCiphertext(from: makePeerID(20_000)))
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
}
