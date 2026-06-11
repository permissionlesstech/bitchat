//
//  MediaMessageView.swift
//  bitchat
//
//  Created by Islam on 30/03/2026.
//

import SwiftUI
import BitFoundation

struct MediaMessageView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    let message: BitchatMessage
    let media: BitchatMessage.Media
    /// Value snapshot of the message's mutable delivery status, captured at
    /// construction (see `TextMessageView.deliveryStatus`): `BitchatMessage`
    /// is a reference type mutated in place, and SwiftUI compares reference
    /// fields by identity, so without the snapshot a status-only change
    /// (send progress, delivered → read) would not re-render this row.
    private let deliveryStatus: DeliveryStatus?

    @Binding var imagePreviewURL: URL?

    init(message: BitchatMessage, media: BitchatMessage.Media, imagePreviewURL: Binding<URL?>) {
        self.message = message
        self.media = media
        self.deliveryStatus = message.deliveryStatus
        self._imagePreviewURL = imagePreviewURL
    }

    var body: some View {
        let state = mediaSendState(for: deliveryStatus)
        let isFromMe = conversationUIModel.isMediaMessageFromCurrentUser(message)
        let cancelAction: (() -> Void)? = state.canCancel ? { conversationUIModel.cancelMediaSend(messageID: message.id) } : nil

        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 4) {
                Text(conversationUIModel.formatMessageHeader(message, colorScheme: colorScheme, theme: theme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if message.isPrivate && conversationUIModel.isSentByCurrentUser(message),
                   let status = deliveryStatus {
                    DeliveryStatusView(status: status)
                        .padding(.leading, 4)
                }
            }

            Group {
                switch media {
                case .voice(let url):
                    VoiceNoteView(
                        url: url,
                        isSending: state.isSending,
                        sendProgress: state.progress,
                        onCancel: cancelAction
                    )
                case .image(let url):
                    BlockRevealImageView(
                        url: url,
                        revealProgress: state.progress,
                        isSending: state.isSending,
                        onCancel: cancelAction,
                        initiallyBlurred: !isFromMe,
                        onOpen: {
                            if !state.isSending {
                                imagePreviewURL = url
                            }
                        },
                        onDelete: !isFromMe ? { conversationUIModel.deleteMediaMessage(messageID: message.id) } : nil
                    )
                    .frame(maxWidth: 280)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func mediaSendState(for deliveryStatus: DeliveryStatus?) -> (isSending: Bool, progress: Double?, canCancel: Bool) {
        var isSending = false
        var progress: Double?
        if let status = deliveryStatus {
            switch status {
            case .sending:
                isSending = true
                progress = 0
            case .partiallyDelivered(let reached, let total):
                if total > 0 {
                    isSending = true
                    progress = Double(reached) / Double(total)
                }
            case .sent, .read, .delivered, .failed:
                break
            }
        }
        let canCancel = isSending && conversationUIModel.isSentByCurrentUser(message)
        let clamped = progress.map { max(0, min(1, $0)) }
        return (isSending, isSending ? clamped : nil, canCancel)
    }
}
