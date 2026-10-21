//
// LANFrameCodec.swift
// bitchat
//
// Wire framing for the Wi-Fi LAN transport.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Errors raised by the LAN frame codec.
enum LANFrameError: Error, Equatable {
    /// The declared frame length exceeds the configured maximum. The stream
    /// is not recoverable: the reader drops the connection.
    case frameTooLarge(declaredLength: Int, maximumLength: Int)
    /// The frame payload is not a decodable BitChat packet.
    case malformedPayload
}

/// Length-prefixed framing for the LAN transport.
///
/// Wire format (v1):
///
/// ```text
/// +--------------------+---------------------------+
/// | length (4 bytes)   | payload (length bytes)    |
/// | big-endian uint32  | one BitChat packet        |
/// +--------------------+---------------------------+
/// ```
///
/// The length prefix is the only addition to the existing BitChat packet
/// format: it turns the TCP byte stream into a message boundary, so the
/// payload of every frame is exactly one `BitchatPacket` binary encoding
/// (the same encoding the BLE mesh uses).
enum LANFrameCodec {
    /// Size of the length prefix in bytes.
    static let headerLength = 4

    /// Default maximum accepted payload size.
    static let maximumPayloadLength = LANTransportConfig.maximumFramePayloadBytes

    /// Encode one packet payload into a length-prefixed frame.
    static func encode(
        payload: Data,
        maximumPayloadLength: Int = LANFrameCodec.maximumPayloadLength
    ) throws -> Data {
        guard payload.count <= maximumPayloadLength else {
            throw LANFrameError.frameTooLarge(
                declaredLength: payload.count,
                maximumLength: maximumPayloadLength
            )
        }
        let length = UInt32(payload.count)
        var frame = Data()
        frame.reserveCapacity(LANFrameCodec.headerLength + payload.count)
        frame.append(UInt8((length >> 24) & 0xFF))
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(payload)
        return frame
    }

    /// Decode the length prefix of a frame header.
    ///
    /// - Returns: the declared payload length, or `nil` when fewer than
    ///   `headerLength` bytes are available.
    static func declaredLength(in header: Data) -> Int? {
        guard header.count >= LANFrameCodec.headerLength else { return nil }
        return (Int(header[header.startIndex]) << 24)
            | (Int(header[header.startIndex + 1]) << 16)
            | (Int(header[header.startIndex + 2]) << 8)
            | Int(header[header.startIndex + 3])
    }
}

/// Incremental decoder for length-prefixed frames.
///
/// The decoder is fed arbitrary byte chunks (a TCP read can split a frame
/// anywhere, including in the middle of the length prefix) and returns the
/// payloads of every frame that became complete. A partial frame stays
/// buffered until the rest arrives.
final class LANFrameDecoder {
    private var buffer = Data()
    private let maximumPayloadLength: Int

    init(maximumPayloadLength: Int = LANFrameCodec.maximumPayloadLength) {
        self.maximumPayloadLength = maximumPayloadLength
    }

    /// Number of buffered bytes that do not yet form a complete frame.
    var bufferedByteCount: Int { buffer.count }

    /// Append received bytes and return the payloads of all complete frames.
    ///
    /// - Throws: `LANFrameError.frameTooLarge` when the stream declares a
    ///   frame larger than the configured maximum. The buffer is dropped in
    ///   that case because the stream can no longer be resynchronised.
    func append(_ bytes: Data) throws -> [Data] {
        guard !bytes.isEmpty else { return [] }
        buffer.append(bytes)

        var payloads: [Data] = []
        while true {
            guard let declared = LANFrameCodec.declaredLength(in: buffer) else { break }
            if declared > maximumPayloadLength {
                buffer.removeAll()
                throw LANFrameError.frameTooLarge(
                    declaredLength: declared,
                    maximumLength: maximumPayloadLength
                )
            }
            guard buffer.count >= LANFrameCodec.headerLength + declared else { break }
            let payload = Data(buffer.dropFirst(LANFrameCodec.headerLength).prefix(declared))
            buffer.removeFirst(LANFrameCodec.headerLength + declared)
            payloads.append(payload)
        }
        return payloads
    }

    /// Drop all buffered bytes (used when a link is torn down).
    func reset() {
        buffer.removeAll()
    }
}
