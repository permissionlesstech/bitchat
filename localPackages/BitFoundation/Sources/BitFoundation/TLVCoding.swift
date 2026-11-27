//
// TLVCoding.swift
// BitFoundation
//
// Shared big-endian integer and TLV (1-byte / 2-byte length) wire helpers.
// This is free and unencumbered software released into the public domain.
//

import Foundation

public extension Data {
    /// Appends a fixed-width integer in network byte order (big-endian).
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    /// Encodes a fixed-width integer in network byte order (big-endian).
    static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var big = value.bigEndian
        return Swift.withUnsafeBytes(of: &big) { Data($0) }
    }
}

public extension Collection where Element == UInt8 {
    /// Decodes a fixed-width unsigned integer from exact-width big-endian bytes.
    func readBigEndian<T: FixedWidthInteger & UnsignedInteger>(_ _: T.Type = T.self) -> T? {
        guard count == MemoryLayout<T>.size else { return nil }
        return reduce(T(0)) { ($0 << 8) | T($1) }
    }
}

public enum TLVLengthWidth {
    case oneByte
    case twoBytes

    var byteCount: Int {
        switch self {
        case .oneByte: return 1
        case .twoBytes: return 2
        }
    }
}

public struct TLVWriter {
    public private(set) var data: Data
    public let lengthWidth: TLVLengthWidth

    public init(lengthWidth: TLVLengthWidth, capacity: Int = 0) {
        self.lengthWidth = lengthWidth
        self.data = Data()
        if capacity > 0 {
            self.data.reserveCapacity(capacity)
        }
    }

    public init(lengthWidth: TLVLengthWidth, prefix: Data, capacity: Int = 0) {
        self.lengthWidth = lengthWidth
        self.data = Data()
        if capacity > 0 {
            self.data.reserveCapacity(prefix.count + capacity)
        }
        self.data.append(prefix)
    }

    public mutating func append(_ tag: UInt8, _ value: Data) {
        data.append(tag)
        switch lengthWidth {
        case .oneByte:
            data.append(UInt8(value.count))
        case .twoBytes:
            data.appendBigEndian(UInt16(value.count))
        }
        data.append(value)
    }

    public mutating func append(_ tag: UInt8, byte: UInt8) {
        data.append(tag)
        switch lengthWidth {
        case .oneByte:
            data.append(1)
        case .twoBytes:
            data.appendBigEndian(UInt16(1))
        }
        data.append(byte)
    }

    public mutating func append<T: FixedWidthInteger>(_ tag: UInt8, bigEndian value: T) {
        append(tag, Data.bigEndian(value))
    }
}

public enum TLVReadStep {
    case entry(type: UInt8, value: Data.SubSequence)
    case end
    case malformed
}

public struct TLVReader {
    private let data: Data
    private let lengthWidth: TLVLengthWidth
    private var cursor: Data.Index

    public init(_ data: Data, lengthWidth: TLVLengthWidth, startOffset: Int = 0) {
        self.data = data
        self.lengthWidth = lengthWidth
        self.cursor = data.index(data.startIndex, offsetBy: min(startOffset, data.count))
    }

    /// Reads the next TLV entry.
    /// - Parameter allowTrailingHeaderRemainder: When `true`, fewer than
    ///   `1 + lengthWidth` trailing bytes ends iteration cleanly (matching
    ///   legacy `while offset + header <= count` loops) instead of returning
    ///   `.malformed`. Truncated values always return `.malformed`.
    public mutating func next(allowTrailingHeaderRemainder: Bool = false) -> TLVReadStep {
        let remaining = data.distance(from: cursor, to: data.endIndex)
        guard remaining > 0 else { return .end }
        let headerSize = 1 + lengthWidth.byteCount
        guard remaining >= headerSize else {
            return allowTrailingHeaderRemainder ? .end : .malformed
        }

        let type = data[cursor]
        cursor = data.index(after: cursor)

        let length: Int
        switch lengthWidth {
        case .oneByte:
            length = Int(data[cursor])
            cursor = data.index(after: cursor)
        case .twoBytes:
            let hi = Int(data[cursor])
            let lo = Int(data[data.index(after: cursor)])
            length = (hi << 8) | lo
            cursor = data.index(cursor, offsetBy: 2)
        }

        guard data.distance(from: cursor, to: data.endIndex) >= length else {
            return .malformed
        }
        let valueEnd = data.index(cursor, offsetBy: length)
        let slice = data[cursor..<valueEnd]
        cursor = valueEnd
        return .entry(type: type, value: slice)
    }
}
