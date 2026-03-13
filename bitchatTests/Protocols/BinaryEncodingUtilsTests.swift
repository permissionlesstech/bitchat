import Foundation
import XCTest
@testable import bitchat

final class BinaryEncodingUtilsTests: XCTestCase {
    func test_appendAndReadPrimitiveValues_roundTrip() throws {
        var data = Data()
        data.appendUInt8(0x12)
        data.appendUInt16(0x3456)
        data.appendUInt32(0x789ABCDE)
        data.appendUInt64(0x0123456789ABCDEF)

        var offset = 0
        XCTAssertEqual(data.readUInt8(at: &offset), 0x12)
        XCTAssertEqual(data.readUInt16(at: &offset), 0x3456)
        XCTAssertEqual(data.readUInt32(at: &offset), 0x789ABCDE)
        XCTAssertEqual(data.readUInt64(at: &offset), 0x0123456789ABCDEF)
        XCTAssertEqual(offset, data.count)
    }

    func test_appendAndReadStringDataAndDate_roundTrip() throws {
        let expectedDate = Date(timeIntervalSince1970: 1_700_000_000.123)
        let expectedPayload = Data([0xAA, 0xBB, 0xCC, 0xDD])
        var data = Data()

        data.appendString("hello")
        data.appendData(expectedPayload)
        data.appendDate(expectedDate)

        var offset = 0
        XCTAssertEqual(data.readString(at: &offset), "hello")
        XCTAssertEqual(data.readData(at: &offset), expectedPayload)
        let decodedDate = try XCTUnwrap(data.readDate(at: &offset))
        XCTAssertEqual(decodedDate.timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_appendUUID_and_readUUID_roundTrip() throws {
        let uuid = "12345678-90ab-cdef-1234-567890abcdef"
        var data = Data()

        data.appendUUID(uuid)

        var offset = 0
        XCTAssertEqual(data.readUUID(at: &offset), uuid.uppercased())
    }

    func test_appendStringAndData_truncateToConfiguredMaxLength() throws {
        var data = Data()
        data.appendString("abcdef", maxLength: 4)
        data.appendData(Data([1, 2, 3, 4, 5]), maxLength: 3)

        var offset = 0
        XCTAssertEqual(data.readString(at: &offset), "abcd")
        XCTAssertEqual(data.readData(at: &offset, maxLength: 3), Data([1, 2, 3]))
    }

    func test_readMethods_returnNilWhenOutOfBounds() {
        var offset = 0
        let shortData = Data([0x01])

        XCTAssertNil(shortData.readUInt16(at: &offset))
        XCTAssertEqual(offset, 0)

        offset = 0
        XCTAssertNil(shortData.readString(at: &offset))
        XCTAssertEqual(offset, 1)

        offset = 0
        XCTAssertNil(shortData.readFixedBytes(at: &offset, count: 2))
        XCTAssertEqual(offset, 0)
    }

    func test_sha256Hex_andExtendedLengthStringRoundTrip() throws {
        XCTAssertEqual(
            Data("abc".utf8).sha256Hex(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )

        var data = Data()
        data.appendString("hello", maxLength: 300)

        var offset = 0
        XCTAssertEqual(data.readString(at: &offset, maxLength: 300), "hello")
    }

    func test_readString_returnsNilForInvalidUTF8ExtendedPayload() {
        let invalidUTF8 = Data([0x00, 0x02, 0xFF, 0xFF])
        var offset = 0

        XCTAssertNil(invalidUTF8.readString(at: &offset, maxLength: 300))
        XCTAssertEqual(offset, invalidUTF8.count)
    }
}
