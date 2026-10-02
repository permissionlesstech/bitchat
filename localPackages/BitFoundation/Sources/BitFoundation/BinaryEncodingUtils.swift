//
// BinaryEncodingUtils.swift
// bitchat
//
// Binary encoding utilities for efficient protocol messages
//

import struct Foundation.Data
import struct Foundation.Date
import struct Foundation.UUID

// MARK: - Binary Encoding Utilities

extension Data {
    // MARK: Writing
    
    @inlinable public mutating func appendUInt8(_ value: UInt8) {
        self.append(value)
    }
    
    @inlinable mutating func appendUInt16(_ value: UInt16) {
        self.append(UInt8((value >> 8) & 0xFF))
        self.append(UInt8(value & 0xFF))
    }
    
    @inlinable mutating func appendUInt32(_ value: UInt32) {
        self.append(UInt8((value >> 24) & 0xFF))
        self.append(UInt8((value >> 16) & 0xFF))
        self.append(UInt8((value >> 8) & 0xFF))
        self.append(UInt8(value & 0xFF))
    }
    
    @inlinable mutating func appendUInt64(_ value: UInt64) {
        for i in (0..<8).reversed() {
            self.append(UInt8((value >> (i * 8)) & 0xFF))
        }
    }
    
    /// Returns false without modifying the destination when the length field
    /// cannot represent the requested limit. Truncation preserves UTF-8.
    @discardableResult
    public mutating func appendString(_ string: String, maxLength: Int = 255) -> Bool {
        guard (0...65535).contains(maxLength) else { return false }
        var bytes = Data(string.utf8.prefix(maxLength))
        while String(data: bytes, encoding: .utf8) == nil {
            bytes.removeLast()
        }
        return appendData(bytes, maxLength: maxLength)
    }

    @discardableResult
    public mutating func appendData(_ data: Data, maxLength: Int = 65535) -> Bool {
        guard (0...65535).contains(maxLength) else { return false }
        let length = Swift.min(data.count, maxLength)
        if maxLength <= 255 {
            append(UInt8(length))
        } else {
            appendUInt16(UInt16(length))
        }
        append(data.prefix(length))
        return true
    }

    @discardableResult
    public mutating func appendDate(_ date: Date) -> Bool {
        let milliseconds = date.timeIntervalSince1970 * 1000
        // Double(UInt64.max) rounds up to 2^64, which is not representable.
        guard milliseconds.isFinite, milliseconds >= 0,
              milliseconds < Double(UInt64.max) else { return false }
        appendUInt64(UInt64(milliseconds))
        return true
    }

    /// Accept canonical UUIDs and the compact 32-hex form. Invalid IDs must
    /// not silently become a zero-padded or truncated different ID.
    @discardableResult
    public mutating func appendUUID(_ uuid: String) -> Bool {
        let compact: String
        if uuid.utf8.count == 32 {
            compact = uuid
        } else if let value = UUID(uuidString: uuid) {
            compact = value.uuidString.replacingOccurrences(of: "-", with: "")
        } else {
            return false
        }
        guard compact.utf8.count == 32,
              let bytes = Data(hexString: compact), bytes.count == 16 else { return false }
        append(bytes)
        return true
    }

    // MARK: Reading
    
    /// Offsets are byte counts relative to this Data value, including slices.
    /// Check by subtraction so hostile offsets/counts cannot overflow.
    @usableFromInline
    func binaryRange(at offset: Int, count length: Int) -> Range<Int>? {
        guard offset >= 0, length >= 0, offset <= count,
              length <= count - offset else { return nil }
        let first = index(startIndex, offsetBy: offset)
        return first..<index(first, offsetBy: length)
    }

    @inlinable public func readUInt8(at offset: inout Int) -> UInt8? {
        guard let range = binaryRange(at: offset, count: 1) else { return nil }
        let value = self[range.lowerBound]
        offset += 1
        return value
    }

    @inlinable func readUInt16(at offset: inout Int) -> UInt16? {
        guard let range = binaryRange(at: offset, count: 2) else { return nil }
        let value = self[range].reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
        offset += 2
        return value
    }

    @inlinable func readUInt32(at offset: inout Int) -> UInt32? {
        guard let range = binaryRange(at: offset, count: 4) else { return nil }
        let value = self[range].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return value
    }

    @inlinable func readUInt64(at offset: inout Int) -> UInt64? {
        guard let range = binaryRange(at: offset, count: 8) else { return nil }
        let value = self[range].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        offset += 8
        return value
    }

    public func readString(at offset: inout Int, maxLength: Int = 255) -> String? {
        var cursor = offset
        guard let bytes = readData(at: &cursor, maxLength: maxLength),
              let value = String(data: bytes, encoding: .utf8) else { return nil }
        offset = cursor
        return value
    }

    public func readData(at offset: inout Int, maxLength: Int = 65535) -> Data? {
        guard (0...65535).contains(maxLength) else { return nil }
        var cursor = offset
        let length: Int
        if maxLength <= 255 {
            guard let value = readUInt8(at: &cursor) else { return nil }
            length = Int(value)
        } else {
            guard let value = readUInt16(at: &cursor) else { return nil }
            length = Int(value)
        }
        guard length <= maxLength,
              let bytes = readFixedBytes(at: &cursor, count: length) else { return nil }
        offset = cursor
        return bytes
    }

    public func readDate(at offset: inout Int) -> Date? {
        guard let timestamp = readUInt64(at: &offset) else { return nil }
        return Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
    }

    public func readUUID(at offset: inout Int) -> String? {
        guard let bytes = readFixedBytes(at: &offset, count: 16) else { return nil }
        let uuid = bytes.hexEncodedString()
        var result = ""
        for (index, char) in uuid.enumerated() {
            if index == 8 || index == 12 || index == 16 || index == 20 {
                result += "-"
            }
            result.append(char)
        }
        return result.uppercased()
    }

    public func readFixedBytes(at offset: inout Int, count: Int) -> Data? {
        guard let range = binaryRange(at: offset, count: count) else { return nil }
        let bytes = self[range]
        offset += count
        return bytes
    }
}
