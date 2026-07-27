//
// PTTAudioFormat.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import AVFoundation
import Foundation

/// Shared audio parameters for live push-to-talk: AAC-LC, 16 kHz, mono,
/// ~16 kbps — deliberately identical to `VoiceRecorder`'s voice-note settings
/// so a burst's finalized `.m4a` and its live frames sound the same.
enum PTTAudioFormat {
    static let sampleRate: Double = 16_000
    static let channelCount: AVAudioChannelCount = 1
    static let bitRate = 16_000
    /// AAC-LC frame size is fixed by the codec: 1024 samples = 64 ms at 16 kHz.
    static let samplesPerFrame: AVAudioFrameCount = 1024
    static var frameDuration: TimeInterval { Double(samplesPerFrame) / sampleRate }

    /// Uncompressed processing format (deinterleaved float PCM).
    static var pcmFormat: AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)
    }

    /// Compressed wire format.
    static var aacFormat: AVAudioFormat? {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: samplesPerFrame,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        return AVAudioFormat(streamDescription: &description)
    }

    /// Voice-note container settings for the finalized `.m4a`, mirroring
    /// `VoiceRecorder.startRecording()`.
    static var voiceNoteFileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVEncoderBitRateKey: bitRate
        ]
    }
}

/// Builds ADTS-framed AAC so a receiver can persist a burst progressively:
/// unlike `.m4a` (whose moov atom only exists after close), an ADTS `.aac`
/// stream is playable at any prefix — a partially received burst is still a
/// replayable voice note.
enum ADTSFramer {
    private static let headerSize = 7
    /// MPEG-4 sampling frequency index for 16 kHz.
    private static let samplingFrequencyIndex: UInt8 = 8
    private static let channelConfiguration: UInt8 = 1

    /// Wraps one raw AAC-LC frame in an ADTS header.
    static func frame(_ aacFrame: Data) -> Data {
        let frameLength = aacFrame.count + headerSize
        var data = Data(capacity: frameLength)
        // Syncword 0xFFF, MPEG-4, layer 00, no CRC.
        data.append(0xFF)
        data.append(0xF1)
        // Profile AAC-LC (audio object type 2 -> bits 01), frequency index,
        // private bit 0, channel config high bit.
        data.append((0b01 << 6) | (samplingFrequencyIndex << 2) | ((channelConfiguration >> 2) & 0x1))
        data.append(((channelConfiguration & 0x3) << 6) | UInt8((frameLength >> 11) & 0x3))
        data.append(UInt8((frameLength >> 3) & 0xFF))
        data.append(UInt8((frameLength & 0x7) << 5) | 0x1F)
        // Buffer fullness 0x7FF (VBR), one AAC frame per ADTS frame.
        data.append(0xFC)
        data.append(aacFrame)
        return data
    }
}
