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

    @EnvironmentObject var viewModel: ChatViewModel
    let message: BitchatMessage
    let media: BitchatMessage.Media

    @Binding var imagePreviewURL: URL?

    var body: some View {
        let state = mediaSendState(for: message)
        let isFromMe = message.sender == viewModel.nickname || message.senderPeerID == viewModel.meshService.myPeerID
        let cancelAction: (() -> Void)? = state.canCancel ? { viewModel.cancelMediaSend(messageID: message.id) } : nil

        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 4) {
                Text(viewModel.formatMessageHeader(message, colorScheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if message.isPrivate && message.sender == viewModel.nickname,
                   let status = message.deliveryStatus {
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
                        onDelete: !isFromMe ? { viewModel.deleteMediaMessage(messageID: message.id) } : nil
                    )
                    .frame(maxWidth: 280)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func mediaSendState(for message: BitchatMessage) -> (isSending: Bool, progress: Double?, canCancel: Bool) {
        var isSending = false
        var progress: Double?
        if let status = message.deliveryStatus {
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
        let canCancel = isSending && message.sender == viewModel.nickname
        let clamped = progress.map { max(0, min(1, $0)) }
        return (isSending, isSending ? clamped : nil, canCancel)
    }
}
