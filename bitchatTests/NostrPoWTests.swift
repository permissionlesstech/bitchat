import XCTest
import CryptoKit
@testable import bitchat

final class NostrPoWTests: XCTestCase {
    func testLeadingZeroBits() {
        // 0x00 -> 8, 0x00 -> 8, 0xF0 -> 0 leading zeros
        let data = Data([0x00, 0x00, 0xF0]) + Data(repeating: 0x00, count: 29)
        let lz = NostrPoW.leadingZeroBits(data)
        XCTAssertEqual(lz, 16)
    }

    func testMineLowDifficulty() {
        let pubkey = String(repeating: "a", count: 64)
        let createdAt = Int(Date().timeIntervalSince1970)
        let kind = 20000
        let tags = [["g", "u4pruydqqvj"]]
        let content = "hello"
        let targetBits = 8 // keep it very low for test speed
        let (nonce, idHex) = NostrPoW.mine(pubkey: pubkey, createdAt: createdAt, kind: kind, baseTags: tags, content: content, targetBits: targetBits)
        XCTAssertGreaterThan(nonce, 0)
        // Verify difficulty
        let powTags = tags + [["nonce", String(nonce), String(targetBits)]]
        // Recompute ID
        let serialized: [Any] = [0, pubkey, createdAt, kind, powTags, content]
        let json = try! JSONSerialization.data(withJSONObject: serialized, options: [.withoutEscapingSlashes])
        let digest = CryptoKit.SHA256.hash(data: json)
        let idData = Data(digest)
        XCTAssertEqual(idHex.count, 64)
        XCTAssertGreaterThanOrEqual(NostrPoW.leadingZeroBits(idData), targetBits)
    }
}
