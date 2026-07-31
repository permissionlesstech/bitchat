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
        do {
            let data = try Data(contentsOf: outputURL)
            guard data.count <= FileTransferLimits.maxImageBytes else {
                throw ChatMediaPreparationError.imageTooLarge(bytes: data.count)
            }

            let packet = BitchatFilePacket(
                fileName: outputURL.lastPathComponent,
                fileSize: UInt64(data.count),
                mimeType: "image/jpeg",
                content: data
            )
            guard packet.encode() != nil else { throw ChatMediaPreparationError.encodingFailed }
            return ChatPreparedImage(outputURL: outputURL, packet: packet)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    static func prepareOriginalImagePacket(from sourceURL: URL) throws -> ChatPreparedImage {
        try ImageUtils.validateImageSource(at: sourceURL)
        let mimeType = try ImageUtils.mimeTypeForImage(at: sourceURL)
        guard let mime = MimeType(mimeType),
              mime.category == .image,
              mime.isAllowed else {
            throw ImageUtilsError.invalidImage
        }

        let outputURL = try ImageUtils.copyOriginalImage(at: sourceURL)
        do {
            let data = try Data(contentsOf: outputURL)
            guard data.count <= FileTransferLimits.maxImageBytes else {
                throw ChatMediaPreparationError.imageTooLarge(bytes: data.count)
            }
            guard mime.matches(data: data) else {
                throw ImageUtilsError.invalidImage
            }

            let packet = BitchatFilePacket(
                fileName: outputURL.lastPathComponent,
                fileSize: UInt64(data.count),
                mimeType: mime.mimeString,
                content: data
            )
            guard packet.encode() != nil else { throw ChatMediaPreparationError.encodingFailed }
            return ChatPreparedImage(outputURL: outputURL, packet: packet)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}
