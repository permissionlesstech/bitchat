//
// ChatImageDropTarget.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Lets the user drag images from other apps and drop them on the chat
    /// to send them to the current conversation.
    ///
    /// - Parameter isActive: Set it to false while another chat covers this
    ///   one, so that a drop cannot go to a chat the user does not see.
    func chatImageDropTarget(isActive: Bool) -> some View {
        modifier(ChatImageDropTargetModifier(isActive: isActive))
    }
}

private struct ChatImageDropTargetModifier: ViewModifier {
    // Observed here, not in the host view, so a model change re-renders only
    // this modifier.
    @EnvironmentObject private var conversationUIModel: ConversationUIModel

    let isActive: Bool

    @State private var isTargeted = false

    /// The chat refuses the drop where it cannot send media, such as in
    /// location channels.
    private var isEnabled: Bool {
        isActive && conversationUIModel.canSendMediaInCurrentContext
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    ChatImageDropHighlight()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds), value: isTargeted)
            .onDrop(
                of: DroppedImageLoader.acceptedTypes,
                delegate: ChatImageDropDelegate(
                    isEnabled: isEnabled,
                    isTargeted: $isTargeted,
                    onDrop: conversationUIModel.sendDroppedImages
                )
            )
            .onChange(of: isEnabled) { enabled in
                if !enabled {
                    isTargeted = false
                }
            }
    }
}

private struct ChatImageDropDelegate: DropDelegate {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    let onDrop: ([NSItemProvider]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && info.hasItemsConforming(to: DroppedImageLoader.acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: DroppedImageLoader.acceptedTypes)
        guard isEnabled, !providers.isEmpty else { return false }
        onDrop(providers)
        return true
    }
}

/// Marks the chat as a drop target while an image hovers over it.
private struct ChatImageDropHighlight: View {
    @ThemedPalette private var palette

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(palette.background.opacity(0.85))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            )
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus")
                        .bitchatFont(size: 28)
                    Text(
                        String(
                            localized: "content.drop.image_hint",
                            defaultValue: "drop to send image",
                            comment: "Label shown over the chat while the user drags an image over it"
                        )
                    )
                    .bitchatFont(size: 14, weight: .semibold)
                }
                .foregroundColor(palette.accent)
                .padding(16)
            )
            .padding(12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
#endif
