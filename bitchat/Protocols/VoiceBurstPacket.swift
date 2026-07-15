//
// VoiceBurstPacket.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Security

/// Audio codec of a live voice burst. START packets carry it so receivers can
/// reject bursts they can't decode instead of feeding garbage to the decoder.
enum VoiceBurstCodec: UInt8 {
    /// AAC-LC, 16 kHz, mono, ~16 kbps — matches the voice-note recorder, so
    /// the finalized `.m4a` and the live frames come from the same encoder
    /// settings.
    case aacLC16kMono = 0x01
}

/// One packet of a live push-to-talk voice burst (the inner payload of
/// `NoisePayloadType.voiceFrame`, and — for public mesh bursts — the payload
/// of `MessageType.voiceFrame`).
///
/// Wire format:
/// ```
/// [burstID: 8][seq: UInt16 BE][flags: UInt8][payload…]
/// ```
/// - flags 0x01 (START): payload = [codec: UInt8]
/// - flags 0x02 (END):   payload = [totalDataPackets: UInt16 BE][durationMs: UInt32 BE]
/// - flags 0x04 (CANCELED): empty payload; receivers discard the burst
/// - flags 0x00 (data):  payload = repeated [length: UInt16 BE][AAC frame]
struct VoiceBurstPacket: Equatable {
    enum Kind: Equatable {
        case start(codec: VoiceBurstCodec)
        case frames([Data])
        case end(totalDataPackets: UInt16, durationMs: UInt32)
        case canceled
    }

    static let burstIDSize = 8
    private static let headerSize = burstIDSize + 2 + 1
    /// Sanity cap on frames per packet; real packets carry 1-2 frames.
    static let maxFramesPerPacket = 8

    private enum Flags {
        static let start: UInt8 = 0x01
        static let end: UInt8 = 0x02
        static let canceled: UInt8 = 0x04
    }

    let burstID: Data
    let seq: UInt16
    let kind: Kind

    init?(burstID: Data, seq: UInt16, kind: Kind) {
        guard burstID.count == Self.burstIDSize else { return nil }
        if case .frames(let frames) = kind {
            guard !frames.isEmpty,
                  frames.count <= Self.maxFramesPerPacket,
                  frames.allSatisfy({ !$0.isEmpty && $0.count <= Int(UInt16.max) })
            else { return nil }
        }
        self.burstID = burstID
        self.seq = seq
        self.kind = kind
    }

    func encode() -> Data {
        var data = Data(capacity: Self.headerSize + payloadSize)
        data.append(burstID)
        data.append(UInt8((seq >> 8) & 0xFF))
        data.append(UInt8(seq & 0xFF))
        switch kind {
        case .start(let codec):
            data.append(Flags.start)
            data.append(codec.rawValue)
        case .frames(let frames):
            data.append(0)
            for frame in frames {
                let length = UInt16(frame.count)
                data.append(UInt8((length >> 8) & 0xFF))
                data.append(UInt8(length & 0xFF))
                data.append(frame)
            }
        case .end(let totalDataPackets, let durationMs):
            data.append(Flags.end)
            data.append(UInt8((totalDataPackets >> 8) & 0xFF))
            data.append(UInt8(totalDataPackets & 0xFF))
            for shift in stride(from: 24, through: 0, by: -8) {
                data.append(UInt8((durationMs >> UInt32(shift)) & 0xFF))
            }
        case .canceled:
            data.append(Flags.canceled)
        }
        return data
    }

    static func decode(_ data: Data) -> VoiceBurstPacket? {
        // Work on a re-based copy so subscripting is offset-safe.
        let data = Data(data)
        guard data.count >= headerSize else { return nil }

        let burstID = data.prefix(burstIDSize)
        let seq = (UInt16(data[burstIDSize]) << 8) | UInt16(data[burstIDSize + 1])
        let flags = data[burstIDSize + 2]
        let payload = data.dropFirst(headerSize)

        let kind: Kind
        switch flags {
        case Flags.start:
            guard let codecByte = payload.first,
                  let codec = VoiceBurstCodec(rawValue: codecByte)
            else { return nil }
            kind = .start(codec: codec)
        case Flags.end:
            guard payload.count >= 6 else { return nil }
            let bytes = Array(payload)
            let total = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            let duration = bytes[2...5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            kind = .end(totalDataPackets: total, durationMs: duration)
        case Flags.canceled:
            kind = .canceled
        case 0:
            var frames: [Data] = []
            var offset = payload.startIndex
            while offset < payload.endIndex {
                guard payload.distance(from: offset, to: payload.endIndex) >= 2 else { return nil }
                let length = (Int(payload[offset]) << 8) | Int(payload[payload.index(after: offset)])
                offset = payload.index(offset, offsetBy: 2)
                guard length > 0,
                      payload.distance(from: offset, to: payload.endIndex) >= length,
                      frames.count < maxFramesPerPacket
                else { return nil }
                let end = payload.index(offset, offsetBy: length)
                frames.append(Data(payload[offset..<end]))
                offset = end
            }
            guard !frames.isEmpty else { return nil }
            kind = .frames(frames)
        default:
            return nil
        }

        return VoiceBurstPacket(burstID: Data(burstID), seq: seq, kind: kind)
    }

    static func makeBurstID() -> Data {
        var bytes = Data(count: burstIDSize)
        let result = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, burstIDSize, $0.baseAddress!)
        }
        guard result == errSecSuccess else {
            return Data((0..<burstIDSize).map { _ in UInt8.random(in: .min ... .max) })
        }
        return bytes
    }

    private var payloadSize: Int {
        switch kind {
        case .start: return 1
        case .frames(let frames): return frames.reduce(0) { $0 + 2 + $1.count }
        case .end: return 6
        case .canceled: return 0
        }
    }
}

/// Greedy packetizer for outgoing bursts: batches encoded frames into
/// `VoiceBurstPacket`s without exceeding the byte budget that keeps each
/// packet in a single BLE frame after Noise encryption and padding.
/// Not thread-safe — confine to one queue.
struct VoiceBurstPacketizer {
    let burstID: Data
    private let budget: Int
    private var pendingFrames: [Data] = []
    private var pendingSize = 0
    /// seq 0 is reserved for START; data packets start at 1.
    private(set) var nextSeq: UInt16 = 1
    private(set) var dataPacketCount: UInt16 = 0

    init(burstID: Data, budget: Int = TransportConfig.pttMaxBurstContentBytes) {
        self.burstID = burstID
        self.budget = budget
    }

    /// Adds one encoded frame, returning any packets that became full.
    /// Frames larger than the budget are dropped (the encoder's ~130-byte
    /// frames never hit this; it guards against misconfiguration looping).
    mutating func add(_ frame: Data) -> [Data] {
        let frameCost = 2 + frame.count
        guard VoiceBurstPacket.burstIDSize + 3 + frameCost <= budget else { return [] }

        var packets: [Data] = []
        if !pendingFrames.isEmpty,
           VoiceBurstPacket.burstIDSize + 3 + pendingSize + frameCost > budget
            || pendingFrames.count >= VoiceBurstPacket.maxFramesPerPacket {
            packets.append(contentsOf: flush())
        }
        pendingFrames.append(frame)
        pendingSize += frameCost
        return packets
    }

    /// Emits any buffered frames as a final data packet.
    mutating func flush() -> [Data] {
        guard !pendingFrames.isEmpty,
              let packet = VoiceBurstPacket(burstID: burstID, seq: nextSeq, kind: .frames(pendingFrames))
        else {
            pendingFrames = []
            pendingSize = 0
            return []
        }
        pendingFrames = []
        pendingSize = 0
        nextSeq &+= 1
        dataPacketCount &+= 1
        return [packet.encode()]
    }
}
