import SwiftUI

/// Row for a received or sent `[file]` transfer. The payload is already on
/// disk (`files/incoming` or `files/outgoing`); the timeline used to render
/// it as ordinary chat text, so there was no way to open it.
struct FileAttachmentView: View {
    @ThemedPalette private var palette

    let url: URL
    let isSending: Bool
    let sendProgress: Double?
    let onCancel: (() -> Void)?
    let onDelete: (() -> Void)?

    @State private var showDeleteConfirmation = false

    private enum Strings {
        static let delete = String(localized: "media.image.action.delete", comment: "Context menu action that deletes a received image")
        static let deleteConfirmTitle = String(localized: "media.image.delete_confirm_title", comment: "Title of the confirmation dialog before deleting a received image")
        static let deleteConfirmMessage = String(localized: "media.image.delete_confirm_message", comment: "Body of the confirmation dialog before deleting a received image")
        static let cancelSend = String(localized: "media.accessibility.cancel_send", comment: "Accessibility label for the cancel button on an in-flight media send")
        static let sending = String(localized: "media.image.accessibility.sending", comment: "Accessibility label for an image that is still sending")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "doc.fill")
                .font(.bitchatSystem(size: 22, weight: .semibold))
                .foregroundColor(palette.primary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: url.lastPathComponent)
                    .bitchatFont(size: 13, weight: .medium)
                    .foregroundColor(palette.primary)
                    .lineLimit(2)
                if fileByteCount > 0 {
                    Text(verbatim: byteCountLabel)
                        .bitchatFont(size: 11)
                        .foregroundColor(palette.secondary)
                }
            }

            Spacer(minLength: 8)

            if isSending {
                if let onCancel {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.bitchatSystem(size: 12, weight: .bold))
                            .padding(8)
                            .background(Circle().fill(Color.black.opacity(0.7)))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Strings.cancelSend)
                }
            } else {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.bitchatSystem(size: 14, weight: .semibold))
                        .foregroundColor(palette.secondary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.secondary.opacity(0.12))
        )
        .overlay(alignment: .bottom) {
            if let sendProgress, isSending {
                GeometryReader { geo in
                    Rectangle()
                        .fill(palette.primary.opacity(0.35))
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, sendProgress))))
                }
                .frame(height: 3)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .contextMenu {
            if isSending {
                if let onCancel {
                    Button(Strings.cancelSend, action: onCancel)
                }
            } else if onDelete != nil {
                Button(Strings.delete, role: .destructive) {
                    showDeleteConfirmation = true
                }
            }
        }
        .confirmationDialog(
            Strings.deleteConfirmTitle,
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(Strings.delete, role: .destructive) {
                onDelete?()
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text(verbatim: Strings.deleteConfirmMessage)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isSending ? Strings.sending : url.lastPathComponent)
        .frame(maxWidth: 280)
    }

    private var fileByteCount: Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    private var byteCountLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileByteCount), countStyle: .file)
    }
}
