//
// VoiceBurstPacket.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
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
/// [burstID: 8][seq: UInt16 BE][flags: UInt8][groupID?: 16][payload…]
/// ```
/// - flags bit `0x80` (GROUP_SCOPED): when set, a 16-byte `groupID` immediately
///   follows `flags` before `payload`, routing this encrypted frame to the group
///   conversation instead of the 1:1 DM. Unset (0) is wire-identical to v1.
/// - flags low bits `0x01` (START): payload = [codec: UInt8]
/// - flags low bits `0x02` (END):   payload = [totalDataPackets: UInt16 BE][durationMs: UInt32 BE]
/// - flags low bits `0x04` (CANCELED): empty payload; receivers discard the burst
/// - flags low bits `0x00` (data):  payload = repeated [length: UInt16 BE][AAC frame]
struct VoiceBurstPacket: Equatable {
    enum Kind: Equatable {
        case start(codec: VoiceBurstCodec)
        case frames([Data])
        case end(totalDataPackets: UInt16, durationMs: UInt32)
        case canceled
    }

    static let burstIDSize = 8
    static let groupIDSize = BitchatGroup.groupIDLength
    private static let baseHeaderSize = burstIDSize + 2 + 1
    /// Sanity cap on frames per packet; real packets carry 1-2 frames.
    static let maxFramesPerPacket = 8

    private enum Flags {
        static let start: UInt8 = 0x01
        static let end: UInt8 = 0x02
        static let canceled: UInt8 = 0x04
        static let groupScoped: UInt8 = 0x80
        static let kindMask: UInt8 = 0x7F
    }

    let burstID: Data
    let seq: UInt16
    let kind: Kind
    /// Non-nil when this voice burst belongs to a mesh group conversation.
    let groupID: Data?

    init?(burstID: Data, seq: UInt16, kind: Kind, groupID: Data? = nil) {
        guard burstID.count == Self.burstIDSize else { return nil }
        if let groupID {
            guard groupID.count == Self.groupIDSize else { return nil }
        }
        if case .frames(let frames) = kind {
            guard !frames.isEmpty,
                  frames.count <= Self.maxFramesPerPacket,
                  frames.allSatisfy({ !$0.isEmpty && $0.count <= Int(UInt16.max) })
            else { return nil }
        }
        self.burstID = burstID
        self.seq = seq
        self.kind = kind
        self.groupID = groupID
    }

    func encode() -> Data {
        let groupBytes = groupID?.count ?? 0
        var data = Data(capacity: Self.baseHeaderSize + groupBytes + payloadSize)
        data.append(burstID)
        data.appendBigEndian(seq)
        let groupFlag: UInt8 = groupID != nil ? Flags.groupScoped : 0
        switch kind {
        case .start(let codec):
            data.append(Flags.start | groupFlag)
            if let groupID { data.append(groupID) }
            data.append(codec.rawValue)
        case .frames(let frames):
            data.append(groupFlag)
            if let groupID { data.append(groupID) }
            for frame in frames {
                data.appendBigEndian(UInt16(frame.count))
                data.append(frame)
            }
        case .end(let totalDataPackets, let durationMs):
            data.append(Flags.end | groupFlag)
            if let groupID { data.append(groupID) }
            data.appendBigEndian(totalDataPackets)
            data.appendBigEndian(durationMs)
        case .canceled:
            data.append(Flags.canceled | groupFlag)
            if let groupID { data.append(groupID) }
        }
        return data
    }

    static func decode(_ data: Data) -> VoiceBurstPacket? {
        // Work on a re-based copy so subscripting is offset-safe.
        let data = Data(data)
        guard data.count >= baseHeaderSize,
              let seq: UInt16 = data[burstIDSize..<(burstIDSize + 2)].readBigEndian() else { return nil }

        let burstID = data.prefix(burstIDSize)
        let flags = data[burstIDSize + 2]
        let isGroupScoped = (flags & Flags.groupScoped) != 0
        let kindFlags = flags & Flags.kindMask

        let groupID: Data?
        let payloadStart: Int
        if isGroupScoped {
            let groupEnd = baseHeaderSize + groupIDSize
            guard data.count >= groupEnd else { return nil }
            groupID = Data(data[baseHeaderSize..<groupEnd])
            payloadStart = groupEnd
        } else {
            groupID = nil
            payloadStart = baseHeaderSize
        }

        let payload = data.dropFirst(payloadStart)

        let kind: Kind
        switch kindFlags {
        case Flags.start:
            guard let codecByte = payload.first,
                  let codec = VoiceBurstCodec(rawValue: codecByte)
            else { return nil }
            kind = .start(codec: codec)
        case Flags.end:
            guard payload.count >= 6,
                  let total: UInt16 = payload.prefix(2).readBigEndian(),
                  let duration: UInt32 = payload.dropFirst(2).prefix(4).readBigEndian()
            else { return nil }
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

        return VoiceBurstPacket(burstID: Data(burstID), seq: seq, kind: kind, groupID: groupID)
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
    let groupID: Data?
    private let budget: Int
    private var pendingFrames: [Data] = []
    private var pendingSize = 0
    /// seq 0 is reserved for START; data packets start at 1.
    private(set) var nextSeq: UInt16 = 1
    private(set) var dataPacketCount: UInt16 = 0

    private var headerOverhead: Int {
        VoiceBurstPacket.burstIDSize + 3 + (groupID?.count ?? 0)
    }

    init(burstID: Data, groupID: Data? = nil, budget: Int = TransportConfig.pttMaxBurstContentBytes) {
        self.burstID = burstID
        self.groupID = groupID
        self.budget = budget
    }

    /// Adds one encoded frame, returning any packets that became full.
    /// Frames larger than the budget are dropped (the encoder's ~130-byte
    /// frames never hit this; it guards against misconfiguration looping).
    mutating func add(_ frame: Data) -> [Data] {
        let frameCost = 2 + frame.count
        guard headerOverhead + frameCost <= budget else { return [] }

        var packets: [Data] = []
        if !pendingFrames.isEmpty,
           headerOverhead + pendingSize + frameCost > budget
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
              let packet = VoiceBurstPacket(burstID: burstID, seq: nextSeq, kind: .frames(pendingFrames), groupID: groupID)
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
