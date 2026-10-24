import Foundation
import Testing
import BitFoundation
@testable import bitchat

@Suite("ReadReceipt Tests")
struct ReadReceiptTests {

    @Test("JSON encode and decode round-trip stable fields")
    func jsonRoundTrip() throws {
        let receipt = ReadReceipt(
            originalMessageID: UUID().uuidString,
            readerID: PeerID(str: "0123456789abcdef"),
            readerNickname: "Alice"
        )

        let encoded = try #require(receipt.encode(), "Receipt should encode to JSON")
        let decoded = try #require(ReadReceipt.decode(from: encoded), "Receipt should decode from JSON")

        #expect(decoded.originalMessageID == receipt.originalMessageID)
        #expect(decoded.receiptID == receipt.receiptID)
        #expect(decoded.readerID == receipt.readerID)
        #expect(decoded.readerNickname == receipt.readerNickname)
        #expect(abs(decoded.timestamp.timeIntervalSince(receipt.timestamp)) < 0.001)
    }
}
