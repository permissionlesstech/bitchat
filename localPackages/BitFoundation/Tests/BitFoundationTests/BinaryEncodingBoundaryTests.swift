import Foundation
import XCTest
@testable import BitFoundation

final class BinaryEncodingBoundaryTests: XCTestCase {
    func testReadsUseOffsetsRelativeToSlicedData() {
        let data = Data([99, 0, 2, 0x61, 0x62]).dropFirst()
        var offset = 0
        XCTAssertEqual(data.readData(at: &offset), Data([0x61, 0x62]))
        XCTAssertEqual(offset, 4)
    }

    func testInvalidOffsetsAndCountsFailWithoutAdvancing() {
        let data = Data(repeating: 0, count: 32)
        for initial in [-1, Int.min, Int.max, 33] {
            var offset = initial
            XCTAssertNil(data.readUInt16(at: &offset))
            XCTAssertEqual(offset, initial)
            XCTAssertNil(data.readUInt32(at: &offset))
            XCTAssertNil(data.readUInt64(at: &offset))
            XCTAssertNil(data.readUUID(at: &offset))
            XCTAssertNil(data.readFixedBytes(at: &offset, count: 1))
        }
        for count in [-1, Int.min, Int.max] {
            var offset = 1
            XCTAssertNil(data.readFixedBytes(at: &offset, count: count))
            XCTAssertEqual(offset, 1)
        }
    }

    func testStringTruncationPreservesUTF8() {
        for text in ["aé", "a€", "a😀"] {
            var data = Data()
            data.appendString(text, maxLength: 2)
            var offset = 0
            XCTAssertEqual(data.readString(at: &offset, maxLength: 2), "a")
        }
    }

    func testDecodersEnforceConfiguredLengthLimit() {
        let data = Data([3, 0x61, 0x62, 0x63])
        var offset = 0
        XCTAssertNil(data.readString(at: &offset, maxLength: 2))
        offset = 0
        XCTAssertNil(data.readData(at: &offset, maxLength: 2))
    }

    func testInvalidLengthLimitsDoNotMutateDestination() {
        for limit in [-1, Int.min, 65_536, Int.max] {
            var data = Data([99])
            data.appendString(String(repeating: "a", count: 65_536), maxLength: limit)
            XCTAssertEqual(data, Data([99]))
            data.appendData(Data(repeating: 0, count: 65_536), maxLength: limit)
            XCTAssertEqual(data, Data([99]))
        }
    }

    func testMalformedUUIDsDoNotTrapOrCreateAnotherID() {
        for invalid in ["a", "001", "", String(repeating: "g", count: 32),
                        "000000000000000000000000000000001",
                        "0-0000000000000000000000000000000"] {
            var data = Data([99])
            data.appendUUID(invalid)
            XCTAssertEqual(data, Data([99]))
        }
    }

    func testUnrepresentableDatesDoNotTrapOrMutateDestination() {
        for seconds in [-1.0, Double.nan, Double.infinity, Double(UInt64.max)] {
            var data = Data([99])
            data.appendDate(Date(timeIntervalSince1970: seconds))
            XCTAssertEqual(data, Data([99]))
        }
    }

    func testFailedVariableReadDoesNotConsumePrefix() {
        for data in [Data([3, 0x61]), Data([1, 0xff])] {
            var offset = 0
            XCTAssertNil(data.readString(at: &offset))
            XCTAssertEqual(offset, 0)
        }
    }

    func testBoundaryLengthPrefixesRoundTrip() {
        for length in [0, 1, 255, 256, 65535] {
            var encoded = Data()
            let payload = Data(repeating: 0x61, count: length)
            XCTAssertTrue(encoded.appendData(payload, maxLength: length))
            var offset = 0
            XCTAssertEqual(encoded.readData(at: &offset, maxLength: length), payload)
            XCTAssertEqual(offset, encoded.count)
        }
        var compact = Data()
        XCTAssertTrue(compact.appendUUID("00112233445566778899aabbccddeeff"))
        XCTAssertEqual(compact.count, 16)
    }

    func testGoldenUUIDDateAndLengthPrefixes() {
        var data = Data()
        data.appendUUID("00112233-4455-6677-8899-AABBCCDDEEFF")
        data.appendDate(Date(timeIntervalSince1970: 1))
        data.appendString("hi")
        data.appendData(Data([0xaa, 0xbb]))
        XCTAssertEqual(data.hexEncodedString(),
                       "00112233445566778899aabbccddeeff00000000000003e80268690002aabb")
        var offset = 0
        XCTAssertEqual(data.readUUID(at: &offset), "00112233-4455-6677-8899-AABBCCDDEEFF")
        XCTAssertEqual(data.readDate(at: &offset), Date(timeIntervalSince1970: 1))
        XCTAssertEqual(data.readString(at: &offset), "hi")
        XCTAssertEqual(data.readData(at: &offset), Data([0xaa, 0xbb]))
        XCTAssertEqual(offset, data.count)
    }
}
