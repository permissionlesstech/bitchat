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

    @Test("Binary encode and decode round-trip stable fields")
    func binaryRoundTrip() throws {
        let receipt = ReadReceipt(
            originalMessageID: UUID().uuidString,
            readerID: PeerID(str: "fedcba9876543210"),
            readerNickname: "Bob"
        )

        let decoded = try #require(
            ReadReceipt.fromBinaryData(receipt.toBinaryData()),
            "Receipt should decode from binary data"
        )

        #expect(decoded.originalMessageID == receipt.originalMessageID.uppercased())
        #expect(decoded.receiptID == receipt.receiptID.uppercased())
        #expect(decoded.readerID == receipt.readerID)
        #expect(decoded.readerNickname == receipt.readerNickname)
    }

    @Test("Binary decode rejects truncated data")
    func binaryDecodeRejectsTruncatedData() {
        #expect(ReadReceipt.fromBinaryData(Data()) == nil)
        #expect(ReadReceipt.fromBinaryData(Data(repeating: 0, count: 48)) == nil)
    }

    @Test("Binary decode rejects stale timestamps")
    func binaryDecodeRejectsStaleTimestamp() {
        let receipt = ReadReceipt(
            originalMessageID: UUID().uuidString,
            readerID: PeerID(str: "0011223344556677"),
            readerNickname: "Carol"
        )
        var data = receipt.toBinaryData()

        data.replaceSubrange(40..<48, with: Data(repeating: 0, count: 8))

        #expect(ReadReceipt.fromBinaryData(data) == nil)
    }
}
