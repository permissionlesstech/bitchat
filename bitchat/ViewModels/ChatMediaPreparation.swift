import BitFoundation
import Foundation

enum ChatMediaPreparationError: Error, Equatable {
    case encodingFailed
    case voiceNoteTooLarge(bytes: Int)
    case imageTooLarge(bytes: Int)
}

struct ChatPreparedImage {
    let outputURL: URL
    let packet: BitchatFilePacket
}

enum ChatMediaPreparation {
    static func prepareVoiceNotePacket(at url: URL) throws -> BitchatFilePacket {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? Int else {
            throw ChatMediaPreparationError.voiceNoteTooLarge(bytes: 0)
        }
        guard fileSize <= FileTransferLimits.maxVoiceNoteBytes else {
            throw ChatMediaPreparationError.voiceNoteTooLarge(bytes: fileSize)
        }

        let data = try Data(contentsOf: url)
        let packet = BitchatFilePacket(
            fileName: url.lastPathComponent,
            fileSize: UInt64(data.count),
            mimeType: "audio/mp4",
            content: data
        )
        guard packet.encode() != nil else { throw ChatMediaPreparationError.encodingFailed }
        return packet
    }

    static func prepareImagePacket(from sourceURL: URL) throws -> ChatPreparedImage {
        let outputURL = try ImageUtils.processImage(at: sourceURL)
        return try prepareProcessedImagePacket(from: outputURL)
    }

    /// Builds a `ChatPreparedImage` from a JPEG file that has already been
    /// processed by `ImageUtils.processImage`, avoiding a second decode/encode pass.
    static func prepareProcessedImagePacket(from processedURL: URL) throws -> ChatPreparedImage {
        do {
            let data = try Data(contentsOf: processedURL)
            guard data.count <= FileTransferLimits.maxImageBytes else {
                throw ChatMediaPreparationError.imageTooLarge(bytes: data.count)
            }

            let packet = BitchatFilePacket(
                fileName: processedURL.lastPathComponent,
                fileSize: UInt64(data.count),
                mimeType: "image/jpeg",
                content: data
            )
            guard packet.encode() != nil else { throw ChatMediaPreparationError.encodingFailed }
            return ChatPreparedImage(outputURL: processedURL, packet: packet)
        } catch {
            try? FileManager.default.removeItem(at: processedURL)
            throw error
        }
    }
}
