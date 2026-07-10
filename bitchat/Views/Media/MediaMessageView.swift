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
    @ThemedPalette private var palette
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    let message: BitchatMessage
    let media: BitchatMessage.Media
    /// Value snapshot of the message's mutable delivery status, captured at
    /// construction (see `TextMessageView.deliveryStatus`): `BitchatMessage`
    /// is a reference type mutated in place, and SwiftUI compares reference
    /// fields by identity, so without the snapshot a status-only change
    /// (send progress, delivered → read) would not re-render this row.
    private let deliveryStatus: DeliveryStatus?
    @State private var showDeliveryDetail = false

    @Binding var imagePreviewURL: URL?

    init(message: BitchatMessage, media: BitchatMessage.Media, imagePreviewURL: Binding<URL?>) {
        self.message = message
        self.media = media
        self.deliveryStatus = message.deliveryStatus
        self._imagePreviewURL = imagePreviewURL
    }

    var body: some View {
        let isFromMe = conversationUIModel.isMediaMessageFromCurrentUser(message)
        let state = mediaSendState(for: deliveryStatus, isFromMe: isFromMe)
        let cancelAction: (() -> Void)? = state.canCancel ? { conversationUIModel.cancelMediaSend(messageID: message.id) } : nil

        // Baseline alignment (via the header text inside the VStack) keeps the
        // lock on the header line; a fixed top padding left its solid body
        // hanging below the line's visual center.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if message.isPrivate {
                Image(systemName: "lock.fill")
                    .font(.bitchatSystem(size: 8))
                    .foregroundColor(Color.orange.opacity(0.75))
                    .padding(.trailing, 4)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 4) {
                    Text(conversationUIModel.formatMessageHeader(message, colorScheme: colorScheme, theme: theme))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Delivery status indicator for private messages. Tappable:
                    // .help() tooltips only exist on macOS, so iOS users get the
                    // explanation as a caption under the row instead.
                    if message.isPrivate && conversationUIModel.isSentByCurrentUser(message),
                       let status = deliveryStatus {
                        Button {
                            showDeliveryDetail.toggle()
                        } label: {
                            DeliveryStatusView(status: status)
                                .padding(.leading, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(
                            String(localized: "content.accessibility.delivery_detail_hint", comment: "Accessibility hint for the delivery status glyph explaining a tap reveals details")
                        )
                    }
                }

                // Failure reasons stay visible without a tap; other statuses
                // reveal on demand.
                if message.isPrivate && conversationUIModel.isSentByCurrentUser(message),
                   let status = deliveryStatus {
                    if case .failed = status {
                        Text(verbatim: status.bitchatDescription)
                            .bitchatFont(size: 11)
                            .foregroundColor(Color.red.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    } else if showDeliveryDetail {
                        Text(verbatim: status.bitchatDescription)
                            .bitchatFont(size: 11)
                            .foregroundColor(palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Group {
                    switch media {
                    case .voice(let url):
                        VoiceNoteView(
                            url: url,
                            isSending: state.isSending,
                            sendProgress: state.progress,
                            isLive: conversationUIModel.isLiveVoiceMessage(message),
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
        }
        .padding(.vertical, 4)
        // Collapse the revealed caption when the status advances (e.g.
        // sending → sent → delivered) so a detail opened for one state
        // doesn't linger and silently morph into another. Guarded write:
        // under a message storm many rows change status within one frame,
        // and an unconditional state write per change trips SwiftUI's
        // "tried to update multiple times per frame" re-entrancy warning.
        .onChange(of: deliveryStatus) { _ in
            if showDeliveryDetail {
                showDeliveryDetail = false
            }
        }
    }

    private func mediaSendState(for deliveryStatus: DeliveryStatus?, isFromMe: Bool) -> (isSending: Bool, progress: Double?, canCancel: Bool) {
        // A received message is never in a send state: BitchatMessage defaults
        // private messages to .sending, so an incoming message's status must
        // not drive the reveal mask or disable the reveal tap.
        guard isFromMe else { return (false, nil, false) }
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
            case .sent, .carried, .read, .delivered, .failed:
                break
            }
        }
        let canCancel = isSending && conversationUIModel.isSentByCurrentUser(message)
        let clamped = progress.map { max(0, min(1, $0)) }
        return (isSending, isSending ? clamped : nil, canCancel)
    }
}
