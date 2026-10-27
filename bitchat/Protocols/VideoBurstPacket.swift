//
// VideoBurstPacket.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Security

/// Video codec carried by a live video START packet.
enum LiveVideoCodec: UInt8 {
    /// H.264 Constrained Baseline, Annex B access units; every IDR carries
    /// SPS and PPS in-band.
    case h264AnnexB = 0x01
}

/// Optional audio track codec carried by a live video START packet.
enum LiveVideoAudioCodec: UInt8 {
    case none = 0x00
    /// Raw (ADTS-less) AAC-LC access units, 16 kHz mono; the same encoding
    /// as live voice v1.
    case aacLC16kMono = 0x01
}

/// Stream parameters announced at sequence 0 and repeated before every keyframe.
struct LiveVideoConfig: Equatable {
    let videoCodec: LiveVideoCodec
    let width: Int
    let height: Int
    let fps: Int
    let bitrateKbps: Int
    let audioCodec: LiveVideoAudioCodec

    var hasAudio: Bool { audioCodec != .none }
}

/// Media track of one entry inside a data shard.
enum LiveVideoTrack: UInt8, CaseIterable {
    case video = 0
    case audio = 1
}

/// One fragment (or the whole) of a media unit inside a data shard.
///
/// `[flags: UInt8][unitSeq: UInt16][ptsMs: UInt32][fragIndex: UInt8][fragCount: UInt8][length: UInt16][bytes]`
struct LiveVideoEntry: Equatable {
    static let headerSize = 11
    private static let trackMask: UInt8 = 0x03
    private static let keyframeFlag: UInt8 = 0x04

    let track: LiveVideoTrack
    let keyframe: Bool
    let unitSequence: Int
    let ptsMs: Int64
    let fragmentIndex: Int
    let fragmentCount: Int
    let bytes: Data

    var encodedSize: Int { Self.headerSize + bytes.count }

    var isValid: Bool {
        (0...0xFFFF).contains(unitSequence)
            && (0...0xFFFF_FFFF).contains(ptsMs)
            && (1...0xFF).contains(fragmentCount)
            && (0..<fragmentCount).contains(fragmentIndex)
            && !bytes.isEmpty && bytes.count <= 0xFFFF
            && (!keyframe || track == .video)
    }

    static func encodeAll(_ entries: [LiveVideoEntry], into output: inout Data) {
        for entry in entries {
            output.append(entry.track.rawValue | (entry.keyframe ? keyframeFlag : 0))
            output.appendU16BE(entry.unitSequence)
            output.appendU32BE(entry.ptsMs)
            output.append(UInt8(truncatingIfNeeded: entry.fragmentIndex))
            output.append(UInt8(truncatingIfNeeded: entry.fragmentCount))
            output.appendU16BE(entry.bytes.count)
            output.append(entry.bytes)
        }
    }

    /// Parses an entries region; returns nil when any entry is malformed or
    /// the region is empty.
    static func decodeAll(_ region: Data) -> [LiveVideoEntry]? {
        let data = [UInt8](region)
        var entries: [LiveVideoEntry] = []
        var cursor = 0
        while cursor < data.count {
            guard data.count - cursor >= headerSize else { return nil }
            let flags = data[cursor]
            guard flags & ~(trackMask | keyframeFlag) == 0,
                  let track = LiveVideoTrack(rawValue: flags & trackMask)
            else { return nil }
            let header = cursor
            let length = data.u16(header + 9)
            cursor += headerSize
            guard length > 0, data.count - cursor >= length else { return nil }
            let entry = LiveVideoEntry(
                track: track,
                keyframe: flags & keyframeFlag != 0,
                unitSequence: data.u16(header + 1),
                ptsMs: data.u32(header + 3),
                fragmentIndex: Int(data[header + 7]),
                fragmentCount: Int(data[header + 8]),
                bytes: Data(data[cursor..<(cursor + length)])
            )
            guard entry.isValid else { return nil }
            entries.append(entry)
            cursor += length
        }
        return entries.isEmpty ? nil : entries
    }
}

/// One live video packet (the inner payload of `NoisePayloadType.videoFrame`,
/// and — for public mesh streams — the payload of `MessageType.videoFrame`).
///
/// Wire format (see docs/LIVE_VIDEO_V1.md):
/// ```
/// [streamID: 8][seq: UInt16 BE][kind: UInt8][body…]
/// ```
/// - kind 0x01 (START):    [version=1][videoCodec][width: UInt16][height: UInt16][fps][bitrateKbps: UInt16][audioCodec]
/// - kind 0x00 (DATA):     [block: UInt16][index: UInt8][entries region]
/// - kind 0x03 (PARITY):   [block: UInt16][parityIndex][k][r][symbolLen: UInt16][symbol]
/// - kind 0x02 (END):      [durationMs: UInt32][videoUnits: UInt16][audioUnits: UInt16][packets: UInt16]
/// - kind 0x04 (CANCELED): empty body; receivers discard the stream
struct VideoBurstPacket: Equatable {
    enum Kind: Equatable {
        case start(LiveVideoConfig)
        /// Systematic FEC source shard: `entriesRegion` is the coded symbol body.
        case data(block: Int, index: Int, entriesRegion: Data)
        /// Reed-Solomon parity shard over the `sourceCount` source symbols of `block`.
        case parity(block: Int, parityIndex: Int, sourceCount: Int, parityCount: Int, symbol: Data)
        case end(durationMs: Int64, videoUnits: Int, audioUnits: Int, packets: Int)
        case canceled
    }

    static let version: UInt8 = 1
    static let streamIDSize = 8
    static let headerSize = streamIDSize + 2 + 1
    static let dataHeaderSize = headerSize + 3
    static let parityHeaderSize = headerSize + 7

    /// Whole-packet ceiling. Keeps a Noise-wrapped, signed, source-routed (up
    /// to four hops) live video packet under the 512-byte BLE fragmentation
    /// threshold.
    static let maxPacketBytes = 352
    /// Largest entries region: a parity symbol (`[len: UInt16][region]`) must fit too.
    static let maxEntriesRegion = maxPacketBytes - parityHeaderSize - 2
    static let maxBlockSourceShards = 32
    static let maxBlockParityShards = 16
    static let maxDimension = 1_920
    static let maxFPS = 60

    private enum KindByte {
        static let data: UInt8 = 0x00
        static let start: UInt8 = 0x01
        static let end: UInt8 = 0x02
        static let parity: UInt8 = 0x03
        static let canceled: UInt8 = 0x04
    }

    let streamID: Data
    let sequence: Int
    let kind: Kind

    init?(streamID: Data, sequence: Int, kind: Kind) {
        guard streamID.count == Self.streamIDSize, (0...0xFFFF).contains(sequence) else { return nil }
        let valid: Bool
        switch kind {
        case .start(let config):
            valid = (16...Self.maxDimension).contains(config.width)
                && (16...Self.maxDimension).contains(config.height)
                && config.width % 2 == 0 && config.height % 2 == 0
                && (1...Self.maxFPS).contains(config.fps)
                && (1...0xFFFF).contains(config.bitrateKbps)
        case .data(let block, let index, let region):
            valid = (0...0xFFFF).contains(block)
                && (0..<Self.maxBlockSourceShards).contains(index)
                && (1...Self.maxEntriesRegion).contains(region.count)
                && LiveVideoEntry.decodeAll(region) != nil
        case .parity(let block, let parityIndex, let sourceCount, let parityCount, let symbol):
            valid = (0...0xFFFF).contains(block)
                && (1...Self.maxBlockSourceShards).contains(sourceCount)
                && (1...Self.maxBlockParityShards).contains(parityCount)
                && (0..<parityCount).contains(parityIndex)
                && (3...(Self.maxEntriesRegion + 2)).contains(symbol.count)
        case .end(let durationMs, let videoUnits, let audioUnits, let packets):
            valid = (0...0xFFFF_FFFF).contains(durationMs)
                && (0...0xFFFF).contains(videoUnits)
                && (0...0xFFFF).contains(audioUnits)
                && (0...0xFFFF).contains(packets)
        case .canceled:
            valid = true
        }
        guard valid else { return nil }
        self.streamID = Data(streamID)
        self.sequence = sequence
        self.kind = kind
    }

    func encode() -> Data {
        var data = Data(capacity: Self.headerSize + 64)
        data.append(streamID)
        data.appendU16BE(sequence)
        switch kind {
        case .start(let config):
            data.append(KindByte.start)
            data.append(Self.version)
            data.append(config.videoCodec.rawValue)
            data.appendU16BE(config.width)
            data.appendU16BE(config.height)
            data.append(UInt8(truncatingIfNeeded: config.fps))
            data.appendU16BE(config.bitrateKbps)
            data.append(config.audioCodec.rawValue)
        case .data(let block, let index, let region):
            data.append(KindByte.data)
            data.appendU16BE(block)
            data.append(UInt8(truncatingIfNeeded: index))
            data.append(region)
        case .parity(let block, let parityIndex, let sourceCount, let parityCount, let symbol):
            data.append(KindByte.parity)
            data.appendU16BE(block)
            data.append(UInt8(truncatingIfNeeded: parityIndex))
            data.append(UInt8(truncatingIfNeeded: sourceCount))
            data.append(UInt8(truncatingIfNeeded: parityCount))
            data.appendU16BE(symbol.count)
            data.append(symbol)
        case .end(let durationMs, let videoUnits, let audioUnits, let packets):
            data.append(KindByte.end)
            data.appendU32BE(durationMs)
            data.appendU16BE(videoUnits)
            data.appendU16BE(audioUnits)
            data.appendU16BE(packets)
        case .canceled:
            data.append(KindByte.canceled)
        }
        return data
    }

    static func decode(_ data: Data) -> VideoBurstPacket? {
        guard data.count >= headerSize, data.count <= maxPacketBytes else { return nil }
        // Work on a zero-indexed copy so subscripting is offset-safe.
        let bytes = [UInt8](data)
        let streamID = Data(bytes[0..<streamIDSize])
        let sequence = bytes.u16(streamIDSize)
        let body = headerSize

        let kind: Kind
        switch bytes[streamIDSize + 2] {
        case KindByte.start:
            guard bytes.count == body + 10, bytes[body] == version,
                  let codec = LiveVideoCodec(rawValue: bytes[body + 1]),
                  let audio = LiveVideoAudioCodec(rawValue: bytes[body + 9])
            else { return nil }
            kind = .start(LiveVideoConfig(
                videoCodec: codec,
                width: bytes.u16(body + 2),
                height: bytes.u16(body + 4),
                fps: Int(bytes[body + 6]),
                bitrateKbps: bytes.u16(body + 7),
                audioCodec: audio
            ))
        case KindByte.data:
            guard bytes.count > body + 3 else { return nil }
            kind = .data(
                block: bytes.u16(body),
                index: Int(bytes[body + 2]),
                entriesRegion: Data(bytes[(body + 3)...])
            )
        case KindByte.parity:
            guard bytes.count >= body + 7 else { return nil }
            let length = bytes.u16(body + 5)
            guard bytes.count == body + 7 + length else { return nil }
            kind = .parity(
                block: bytes.u16(body),
                parityIndex: Int(bytes[body + 2]),
                sourceCount: Int(bytes[body + 3]),
                parityCount: Int(bytes[body + 4]),
                symbol: Data(bytes[(body + 7)...])
            )
        case KindByte.end:
            guard bytes.count == body + 10 else { return nil }
            kind = .end(
                durationMs: bytes.u32(body),
                videoUnits: bytes.u16(body + 4),
                audioUnits: bytes.u16(body + 6),
                packets: bytes.u16(body + 8)
            )
        case KindByte.canceled:
            guard bytes.count == body else { return nil }
            kind = .canceled
        default:
            return nil
        }
        return VideoBurstPacket(streamID: streamID, sequence: sequence, kind: kind)
    }

    static func makeStreamID() -> Data {
        var bytes = Data(count: streamIDSize)
        let result = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, streamIDSize, $0.baseAddress!)
        }
        guard result == errSecSuccess else {
            return Data((0..<streamIDSize).map { _ in UInt8.random(in: .min ... .max) })
        }
        return bytes
    }

    /// The stream ID as lowercase hex, as used in `video_<streamID>.mp4` names.
    static func streamIDHex(_ streamID: Data) -> String {
        streamID.map { String(format: "%02x", $0) }.joined()
    }

    /// Encodes an entries region; the caller keeps it within `maxEntriesRegion`.
    static func encodeEntries(_ entries: [LiveVideoEntry]) -> Data {
        var output = Data(capacity: entries.reduce(0) { $0 + $1.encodedSize })
        LiveVideoEntry.encodeAll(entries, into: &output)
        return output
    }
}

// MARK: - Big-endian helpers

fileprivate extension Data {
    mutating func appendU16BE(_ value: Int) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendU32BE(_ value: Int64) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}

fileprivate extension Array where Element == UInt8 {
    func u16(_ offset: Int) -> Int {
        (Int(self[offset]) << 8) | Int(self[offset + 1])
    }

    func u32(_ offset: Int) -> Int64 {
        (Int64(self[offset]) << 24) | (Int64(self[offset + 1]) << 16)
            | (Int64(self[offset + 2]) << 8) | Int64(self[offset + 3])
    }
}
