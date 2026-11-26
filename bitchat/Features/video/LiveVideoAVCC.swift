//
// LiveVideoAVCC.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CoreMedia
import Foundation

/// Annex B <-> AVCC plumbing shared by the VideoToolbox/AVFoundation media
/// layer. The wire carries Annex B (4-byte start codes, SPS+PPS in-band on
/// every IDR) while CoreMedia wants length-prefixed NAL units plus a format
/// description built from the parameter sets.
enum LiveVideoAVCC {
    static let typeSlice: UInt8 = 1
    static let typeIDR: UInt8 = 5
    static let typeSEI: UInt8 = 6
    static let typeSPS: UInt8 = 7
    static let typePPS: UInt8 = 8
    static let typeAUD: UInt8 = 9
    static let typeFiller: UInt8 = 12

    /// Length-prefix size used for every AVCC sample this layer builds.
    static let lengthSize = 4
    static let startCode = Data([0, 0, 0, 1])

    static func nalType(_ nal: Data) -> UInt8 {
        guard let first = nal.first else { return 0 }
        return first & 0x1F
    }

    /// Splits an Annex B access unit (3- or 4-byte start codes) into NAL units
    /// without their start codes. Returns an empty array when the buffer does
    /// not start with a start code.
    static func nalUnits(inAnnexB data: Data) -> [Data] {
        let bytes = [UInt8](data)
        let count = bytes.count
        var starts: [(codeStart: Int, payloadStart: Int)] = []
        var index = 0
        while index + 2 < count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    let codeStart = index > 0 && bytes[index - 1] == 0 ? index - 1 : index
                    starts.append((codeStart, index + 3))
                    index += 3
                    continue
                }
                if bytes[index + 2] == 0 {
                    index += 1
                    continue
                }
            }
            index += 1
        }
        guard let first = starts.first, bytes[0..<first.codeStart].allSatisfy({ $0 == 0 }) else { return [] }

        var units: [Data] = []
        units.reserveCapacity(starts.count)
        for (position, start) in starts.enumerated() {
            var end = position + 1 < starts.count ? starts[position + 1].codeStart : count
            // trailing_zero_8bits belong to the stream, not the NAL.
            while end > start.payloadStart, bytes[end - 1] == 0 { end -= 1 }
            guard end > start.payloadStart else { continue }
            units.append(Data(bytes[start.payloadStart..<end]))
        }
        return units
    }

    /// Joins NAL units into Annex B with 4-byte start codes.
    static func annexB(from nalUnits: [Data]) -> Data {
        var out = Data(capacity: nalUnits.reduce(0) { $0 + $1.count + 4 })
        for nal in nalUnits {
            out.append(startCode)
            out.append(nal)
        }
        return out
    }

    /// Joins NAL units into an AVCC sample with 4-byte big-endian lengths.
    static func avccSample(from nalUnits: [Data]) -> Data {
        var out = Data(capacity: nalUnits.reduce(0) { $0 + $1.count + 4 })
        for nal in nalUnits {
            let length = UInt32(nal.count)
            out.append(UInt8(truncatingIfNeeded: length >> 24))
            out.append(UInt8(truncatingIfNeeded: length >> 16))
            out.append(UInt8(truncatingIfNeeded: length >> 8))
            out.append(UInt8(truncatingIfNeeded: length))
            out.append(nal)
        }
        return out
    }

    /// Splits a length-prefixed AVCC buffer back into NAL units. Stops at the
    /// first malformed length instead of reading past the buffer.
    static func nalUnits(inAVCC data: Data, lengthSize: Int) -> [Data] {
        guard (1...4).contains(lengthSize) else { return [] }
        var units: [Data] = []
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset + lengthSize <= raw.count {
                var length = 0
                for byte in 0..<lengthSize { length = (length << 8) | Int(base[offset + byte]) }
                offset += lengthSize
                guard length > 0, offset + length <= raw.count else { break }
                units.append(Data(bytes: base + offset, count: length))
                offset += length
            }
        }
        return units
    }

    /// First SPS and PPS of an Annex B access unit, if both are present.
    static func parameterSets(in nalUnits: [Data]) -> (sps: Data, pps: Data)? {
        guard let sps = nalUnits.first(where: { nalType($0) == typeSPS }),
              let pps = nalUnits.first(where: { nalType($0) == typePPS })
        else { return nil }
        return (sps, pps)
    }

    static func formatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsRaw -> OSStatus in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                guard let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress
                else { return -1 }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: Int32(lengthSize),
                    formatDescriptionOut: &description
                )
            }
        }
        return status == noErr ? description : nil
    }

    /// Every H.264 parameter set (SPS first, then PPS) of a format description,
    /// plus its NAL length-prefix size.
    static func parameterSets(of description: CMFormatDescription) -> (sets: [Data], lengthSize: Int)? {
        var count = 0
        var headerLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &headerLength
        )
        guard status == noErr, count > 0 else { return nil }
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                description,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        return (sets, Int(headerLength))
    }

    /// Wraps an AVCC sample in a ready CMSampleBuffer. A nil duration leaves it
    /// invalid (the consumer derives it from the next timestamp).
    static func sampleBuffer(
        avcc: Data,
        format: CMFormatDescription,
        pts: CMTime,
        duration: CMTime = .invalid,
        keyframe: Bool
    ) -> CMSampleBuffer? {
        guard !avcc.isEmpty, let block = blockBuffer(copying: avcc) else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = avcc.count
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { return nil }
        markSync(sample, keyframe: keyframe)
        return sample
    }

    static func markSync(_ sample: CMSampleBuffer, keyframe: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0
        else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        let notSync = keyframe ? kCFBooleanFalse : kCFBooleanTrue
        let dependsOnOthers = keyframe ? kCFBooleanFalse : kCFBooleanTrue
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
            Unmanaged.passUnretained(notSync!).toOpaque()
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(),
            Unmanaged.passUnretained(dependsOnOthers!).toOpaque()
        )
    }

    /// True unless the sample carries `NotSync = true`.
    static func isSync(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0
        else { return true }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        guard let value = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()) else {
            return true
        }
        return !CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    /// Copies `data` into a CMBlockBuffer that owns its memory.
    static func blockBuffer(copying data: Data) -> CMBlockBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        return status == noErr ? block : nil
    }

    /// Contiguous bytes of a sample buffer's data.
    static func data(of sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        return status == noErr ? data : nil
    }
}
