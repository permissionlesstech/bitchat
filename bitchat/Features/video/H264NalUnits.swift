//
// H264NalUnits.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Minimal Annex B helpers: just enough to split access units and lift
/// SPS/PPS out of IDRs.
enum H264NalUnits {
    static let typeIDR = 5
    static let typeSPS = 7
    static let typePPS = 8
    static let typeAUD = 9
    static let typeFiller = 12

    private static let startCode = Data([0, 0, 0, 1])

    /// NAL units (without start codes) in an Annex B buffer.
    static func split(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(offset: Int, codeLength: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0 && bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append((index + 3, 3))
                    index += 3
                    continue
                }
                if index + 4 <= bytes.count && bytes[index + 2] == 0 && bytes[index + 3] == 1 {
                    starts.append((index + 4, 4))
                    index += 4
                    continue
                }
            }
            index += 1
        }
        return starts.enumerated().compactMap { position, start in
            let end = position + 1 < starts.count
                ? starts[position + 1].offset - starts[position + 1].codeLength
                : bytes.count
            return end > start.offset ? Data(bytes[start.offset..<end]) : nil
        }
    }

    /// NAL unit type (low five bits of the header byte), or -1 when empty.
    static func type(_ nal: Data) -> Int {
        guard let header = nal.first else { return -1 }
        return Int(header & 0x1F)
    }

    static func join(_ nals: [Data]) -> Data {
        var output = Data(capacity: nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            output.append(startCode)
            output.append(nal)
        }
        return output
    }

    static func containsType(_ data: Data, _ type: Int) -> Bool {
        split(data).contains { Self.type($0) == type }
    }

    /// SPS and PPS NAL payloads (without start codes), as
    /// `CMVideoFormatDescriptionCreateFromH264ParameterSets` takes them, or nil.
    static func parameterSets(_ data: Data) -> (sps: Data, pps: Data)? {
        let nals = split(data)
        guard let sps = nals.first(where: { type($0) == typeSPS }),
              let pps = nals.first(where: { type($0) == typePPS })
        else { return nil }
        return (sps, pps)
    }

    /// Drops filler NAL units, which some CBR encoders emit to pad the
    /// bitrate; pure airtime cost.
    static func withoutFiller(_ data: Data) -> Data {
        let nals = split(data)
        guard nals.contains(where: { type($0) == typeFiller }) else { return data }
        return join(nals.filter { type($0) != typeFiller })
    }

    /// Access unit with SPS, PPS and AUD removed, for muxing into MP4 where
    /// the format description carries them.
    static func withoutParameterSets(_ data: Data) -> Data {
        join(split(data).filter {
            let nalType = type($0)
            return nalType != typeSPS && nalType != typePPS && nalType != typeAUD
        })
    }
}
