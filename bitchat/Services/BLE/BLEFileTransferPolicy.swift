import AudioToolbox
import BitFoundation
import Foundation
import ImageIO

struct BLEFileTransferDeliveryPlan: Equatable {
    let isPrivateMessage: Bool
    let shouldTrackForSync: Bool
}

enum BLEFileTransferPolicy {
    static func isSelfEcho(packet: BitchatPacket, from peerID: PeerID, localPeerID: PeerID) -> Bool {
        peerID == localPeerID && packet.ttl != 0
    }

    static func deliveryPlan(packet: BitchatPacket, localPeerID: PeerID) -> BLEFileTransferDeliveryPlan? {
        guard let recipientID = packet.recipientID else {
            return BLEFileTransferDeliveryPlan(isPrivateMessage: false, shouldTrackForSync: true)
        }

        let isBroadcast = recipientID.allSatisfy { $0 == 0xFF }
        if isBroadcast {
            return BLEFileTransferDeliveryPlan(isPrivateMessage: false, shouldTrackForSync: true)
        }

        guard PeerID(hexData: recipientID) == localPeerID else {
            return nil
        }

        return BLEFileTransferDeliveryPlan(isPrivateMessage: true, shouldTrackForSync: false)
    }
}

struct BLEIncomingFileAcceptance {
    let filePacket: BitchatFilePacket
    let mime: MimeType
}

enum BLEIncomingFileRejection: Error, Equatable {
    case malformedPayload
    case payloadTooLarge(bytes: Int)
    case unsupportedMime(mimeType: String?, bytes: Int)
    case magicMismatch(mime: MimeType, bytes: Int, prefixHex: String)
    case invalidAudio(mime: MimeType, bytes: Int, reason: String)
    case invalidImage(mime: MimeType, bytes: Int, reason: String)
}

enum BLEIncomingFileValidator {
    static func validate(payload: Data) -> Result<BLEIncomingFileAcceptance, BLEIncomingFileRejection> {
        guard let filePacket = BitchatFilePacket.decode(payload) else {
            return .failure(.malformedPayload)
        }

        guard FileTransferLimits.isValidPayload(filePacket.content.count) else {
            return .failure(.payloadTooLarge(bytes: filePacket.content.count))
        }

        guard let mime = MimeType(filePacket.mimeType), mime.isAllowed else {
            return .failure(.unsupportedMime(
                mimeType: filePacket.mimeType,
                bytes: filePacket.content.count
            ))
        }

        guard mime.matches(data: filePacket.content) else {
            return .failure(.magicMismatch(
                mime: mime,
                bytes: filePacket.content.count,
                prefixHex: filePacket.content.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " ")
            ))
        }

        if mime.category == .audio,
           let failureReason = AudioContainerValidator.validate(data: filePacket.content, mime: mime) {
            return .failure(.invalidAudio(
                mime: mime,
                bytes: filePacket.content.count,
                reason: failureReason
            ))
        }

        if mime.category == .image,
           let failureReason = ImageContainerValidator.validate(data: filePacket.content, mime: mime) {
            return .failure(.invalidImage(
                mime: mime,
                bytes: filePacket.content.count,
                reason: failureReason
            ))
        }

        return .success(BLEIncomingFileAcceptance(filePacket: filePacket, mime: mime))
    }
}

/// Inspects incoming image headers in memory via ImageIO without decoding pixel
/// buffers. Blocks decompression bombs (tiny compressed payloads claiming huge
/// pixel dimensions or frame counts) and container/UTI spoofing before a file
/// is persisted, tracked for gossip sync, or rendered.
enum ImageContainerValidator {
    static let maxDimensionPixels = 4_096
    static let maxTotalPixels = 16_777_216 // 4096 x 4096 (~64 MiB RGBA max)
    static let maxFrameCount = 120

    private static let metadataOptions: CFDictionary = [
        kCGImageSourceShouldCache: false
    ] as CFDictionary

    static func validate(data: Data, mime: MimeType) -> String? {
        guard let expectedUTI = expectedTypeIdentifier(for: mime) else {
            return "unsupported image MIME \(mime)"
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, metadataOptions) else {
            return "unreadable image container"
        }

        guard let detectedUTI = CGImageSourceGetType(source) as String?,
              detectedUTI == expectedUTI else {
            let detected = (CGImageSourceGetType(source) as String?) ?? "unknown"
            return "image container UTI \(detected) does not match \(mime)"
        }

        return validateDimensions(of: source)
    }

    static func validateDimensions(of source: CGImageSource) -> String? {
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount >= 1 else {
            return "image contains no frames"
        }
        guard frameCount <= maxFrameCount else {
            return "image frame count \(frameCount) exceeds limit \(maxFrameCount)"
        }

        for index in 0..<frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, metadataOptions) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
                return "missing pixel dimensions at frame \(index)"
            }
            guard width > 0, height > 0 else {
                return "non-positive pixel dimensions \(width)x\(height)"
            }
            guard width <= maxDimensionPixels, height <= maxDimensionPixels else {
                return "pixel dimensions \(width)x\(height) exceed max \(maxDimensionPixels)"
            }
            let totalPixels = Int64(width) * Int64(height)
            guard totalPixels <= Int64(maxTotalPixels) else {
                return "pixel count \(totalPixels) exceeds max \(maxTotalPixels)"
            }
        }

        return nil
    }

    private static func expectedTypeIdentifier(for mime: MimeType) -> String? {
        switch mime {
        case .jpeg, .jpg:
            return "public.jpeg"
        case .png:
            return "public.png"
        case .gif:
            return "com.compuserve.gif"
        case .webp:
            return "org.webmproject.webp"
        default:
            return nil
        }
    }
}

/// Inspects incoming audio payloads in memory with CoreAudio before they are
/// persisted or tracked for gossip sync. Blocks container spoofing (e.g., CAF
/// disguised as M4A) and crafted headers claiming absurd durations or frame
/// counts.
enum AudioContainerValidator {
    private final class MemoryReader {
        let data: Data
        init(data: Data) { self.data = data }
    }

    static func validate(data: Data, mime: MimeType) -> String? {
        guard let allowedFormats = allowedFileFormats(for: mime) else {
            // Formats CoreAudio does not parse (e.g., Ogg) rely on magic + size checks.
            return nil
        }

        let reader = MemoryReader(data: data)
        return withExtendedLifetime(reader) {
            let clientData = Unmanaged.passUnretained(reader).toOpaque()
            var audioFileID: AudioFileID?

            let openStatus = AudioFileOpenWithCallbacks(
                clientData,
                { inClientData, inPosition, requestCount, buffer, actualCount in
                    let reader = Unmanaged<MemoryReader>.fromOpaque(inClientData).takeUnretainedValue()
                    guard inPosition >= 0 else { return kAudioFilePositionError }
                    let total = Int64(reader.data.count)
                    if inPosition >= total {
                        actualCount.pointee = 0
                        return noErr
                    }
                    let available = Int(min(Int64(requestCount), total - inPosition))
                    if available > 0 {
                        let start = Int(inPosition)
                        reader.data.copyBytes(
                            to: buffer.assumingMemoryBound(to: UInt8.self),
                            from: start..<(start + available)
                        )
                    }
                    actualCount.pointee = UInt32(available)
                    return noErr
                },
                nil,
                { inClientData in
                    let reader = Unmanaged<MemoryReader>.fromOpaque(inClientData).takeUnretainedValue()
                    return Int64(reader.data.count)
                },
                nil,
                0,
                &audioFileID
            )

            guard openStatus == noErr, let fileID = audioFileID else {
                return "unparseable container (status \(openStatus))"
            }
            defer { AudioFileClose(fileID) }

            var detectedFormat: AudioFileTypeID = 0
            var formatSize = UInt32(MemoryLayout<AudioFileTypeID>.size)
            let formatStatus = AudioFileGetProperty(fileID, kAudioFilePropertyFileFormat, &formatSize, &detectedFormat)
            guard formatStatus == noErr, allowedFormats.contains(detectedFormat) else {
                return "container format mismatch (\(detectedFormat))"
            }

            var asbd = AudioStreamBasicDescription()
            var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let asbdStatus = AudioFileGetProperty(fileID, kAudioFilePropertyDataFormat, &asbdSize, &asbd)
            guard asbdStatus == noErr,
                  asbd.mSampleRate.isFinite,
                  asbd.mSampleRate > 0,
                  asbd.mChannelsPerFrame > 0 else {
                return "invalid audio stream description"
            }

            var estimatedDuration: TimeInterval = 0
            var durationSize = UInt32(MemoryLayout<TimeInterval>.size)
            let durationStatus = AudioFileGetProperty(
                fileID,
                kAudioFilePropertyEstimatedDuration,
                &durationSize,
                &estimatedDuration
            )
            if durationStatus == noErr {
                guard estimatedDuration.isFinite,
                      estimatedDuration >= 0,
                      estimatedDuration <= WaveformCache.maxWaveformDurationSeconds else {
                    return "duration out of bounds (\(estimatedDuration)s)"
                }
            }

            var packetCount: UInt64 = 0
            var packetCountSize = UInt32(MemoryLayout<UInt64>.size)
            let packetStatus = AudioFileGetProperty(
                fileID,
                kAudioFilePropertyAudioDataPacketCount,
                &packetCountSize,
                &packetCount
            )
            if packetStatus == noErr, asbd.mFramesPerPacket > 0 {
                let (totalFrames, overflow) = packetCount.multipliedReportingOverflow(by: UInt64(asbd.mFramesPerPacket))
                if overflow || totalFrames > UInt64(WaveformCache.maxWaveformFrames) {
                    return "frame count out of bounds"
                }
                if Double(totalFrames) / asbd.mSampleRate > WaveformCache.maxWaveformDurationSeconds {
                    return "frame duration out of bounds"
                }
            }

            return nil
        }
    }

    private static func allowedFileFormats(for mime: MimeType) -> Set<AudioFileTypeID>? {
        switch mime {
        case .m4a, .mp4Audio:
            return [kAudioFileM4AType, kAudioFileMPEG4Type, kAudioFile3GPType, kAudioFile3GP2Type]
        case .aac:
            return [kAudioFileAAC_ADTSType, kAudioFileM4AType, kAudioFileMPEG4Type]
        case .mp3, .mpeg:
            return [kAudioFileMP3Type, kAudioFileMP2Type, kAudioFileMP1Type]
        case .wav, .xWav:
            return [kAudioFileWAVEType]
        default:
            return nil
        }
    }
}
