// ChatViewModel+Images.swift
// bitchat
//
// Extracted image sending helpers to keep ChatViewModel compact.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
#if os(iOS)
import UIKit
#endif

extension ChatViewModel {
    // MARK: - Images (Send)
    #if os(iOS)
    @MainActor
    func sendImage(_ image: UIImage) {
        // Downscale on long edge to 512px with 85% JPEG quality (Android parity)
        guard let data = downscaleJPEG(image, maxDimension: 512, quality: 0.85) else { return }

        // Persist to app files (outgoing)
        guard let fileURL = saveOutgoingImage(data: data) else { return }

        let name = fileURL.lastPathComponent
        let mime = "image/jpeg"
        let tlv = BitchatFilePacket(fileName: name, fileSize: UInt32(data.count), mimeType: mime, content: data)
        guard let payload = tlv.encode() else { return }
        let transferId = payload.sha256Hex()

        let contentMarker = "[image] \(fileURL.path)"
        let now = Date()

        if let peer = selectedPrivateChatPeer {
            let messageID = UUID().uuidString
            let msg = BitchatMessage(
                id: messageID,
                sender: nickname,
                content: contentMarker,
                timestamp: now,
                isRelay: false,
                originalSender: nil,
                isPrivate: true,
                recipientNickname: meshService.peerNickname(peerID: peer),
                senderPeerID: meshService.myPeerID,
                mentions: nil,
                deliveryStatus: .sending
            )
            // appendToPrivateChat is private in ChatViewModel; inline minimal append
            var arr = privateChats[peer] ?? []
            arr.append(msg)
            privateChats[peer] = arr
            objectWillChange.send()
            meshService.sendFileTransferTLV(payload, recipientPeerID: peer, transferId: transferId, messageID: messageID)
        } else {
            let messageID = UUID().uuidString
            let msg = BitchatMessage(
                id: messageID,
                sender: nickname,
                content: contentMarker,
                timestamp: now,
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: meshService.myPeerID,
                mentions: nil,
                deliveryStatus: .sending
            )
            // public buffer helpers are private; append directly to visible messages
            messages.append(msg)
            meshService.sendFileTransferTLV(payload, recipientPeerID: nil, transferId: transferId, messageID: messageID)
        }
    }

    // Downscale without cropping; preserves aspect ratio. Long edge == maxDimension.
    internal func downscaleJPEG(_ image: UIImage, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0 && size.height > 0 else { return image.jpegData(compressionQuality: quality) }
        let maxSide = max(size.width, size.height)
        let scale = min(1.0, maxDimension / maxSide)
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))

        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: rendererFormat)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return scaled.jpegData(compressionQuality: quality)
    }

    internal func saveOutgoingImage(data: Data) -> URL? {
        do {
            let fm = FileManager.default
            let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = base.appendingPathComponent("bitchat_images/outgoing", isDirectory: true)
            if !fm.fileExists(atPath: folder.path) {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let ts = Int(Date().timeIntervalSince1970)
            let fileURL = folder.appendingPathComponent("img_\(ts)_\(UUID().uuidString.prefix(8)).jpg")
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            // Avoid BitLogger dependency in this small extension
            print("❌ Failed to save outgoing image: \(error)")
            return nil
        }
    }
    #endif
}
