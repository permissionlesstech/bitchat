import SwiftUI

#if os(iOS)
import UIKit
private typealias PlatformImage = UIImage
#else
import AppKit
private typealias PlatformImage = NSImage
#endif

struct BlockRevealImageView: View {
    @ThemedPalette private var palette
    private let url: URL
    private let revealProgress: Double?
    private let isSending: Bool
    private let onCancel: (() -> Void)?
    private let initiallyBlurred: Bool
    private let onOpen: (() -> Void)?
    private let onDelete: (() -> Void)?

    @State private var platformImage: PlatformImage?
    @State private var aspectRatio: CGFloat = 1
    @State private var isBlurred: Bool = false
    @State private var showDeleteConfirmation = false
    @State private var loadFailed = false

    private enum Strings {
        static let tapToReveal = String(localized: "media.image.tap_to_reveal", comment: "Caption on a blurred incoming image inviting a tap to reveal it")
        static let open = String(localized: "media.image.action.open", comment: "Context menu action that opens an image full screen")
        static let reveal = String(localized: "media.image.action.reveal", comment: "Context menu action that reveals a blurred image")
        static let hide = String(localized: "media.image.action.hide", comment: "Context menu action that re-blurs a revealed image")
        static let delete = String(localized: "media.image.action.delete", comment: "Context menu action that deletes a received image")
        static let deleteConfirmTitle = String(localized: "media.image.delete_confirm_title", comment: "Title of the confirmation dialog before deleting a received image")
        static let deleteConfirmMessage = String(localized: "media.image.delete_confirm_message", comment: "Body of the confirmation dialog before deleting a received image")
        static let hiddenImage = String(localized: "media.image.accessibility.hidden", comment: "Accessibility label for a blurred incoming image")
        static let revealedImage = String(localized: "media.image.accessibility.revealed", comment: "Accessibility label for a revealed image")
        static let revealHint = String(localized: "media.image.accessibility.hint.reveal", comment: "Accessibility hint for a blurred image; activating it reveals the image")
        static let openHint = String(localized: "media.image.accessibility.hint.open", comment: "Accessibility hint for a revealed image; activating it opens the image full screen")
        static let sendingImage = String(localized: "media.image.accessibility.sending", comment: "Accessibility label for an image that is still sending")
        static let unavailableImage = String(localized: "media.image.accessibility.unavailable", comment: "Accessibility label for an image whose file could not be loaded")
        static let cancelSend = String(localized: "media.accessibility.cancel_send", comment: "Accessibility label for the cancel button on an in-flight media send")
    }

    init(
        url: URL,
        revealProgress: Double?,
        isSending: Bool,
        onCancel: (() -> Void)?,
        initiallyBlurred: Bool = false,
        onOpen: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.url = url
        self.revealProgress = revealProgress
        self.isSending = isSending
        self.onCancel = onCancel
        self.initiallyBlurred = initiallyBlurred
        self.onOpen = onOpen
        self.onDelete = onDelete
    }

    private var fraction: Double {
        guard let revealProgress = revealProgress else { return 1 }
        return max(0, min(1, revealProgress))
    }

    var body: some View {
        // The DM sheet wraps the conversation in a high-priority
        // swipe-to-close DragGesture (ContentSheetViews). An ancestor
        // high-priority gesture starves descendant TapGestures, but Button
        // actions still fire — the reveal/open tap must stay a Button or
        // received DM images become untappable.
        Button(action: handleTap) {
            imageContent
        }
        .buttonStyle(.plain)
        // The cancel control must sit outside the Button label: nested
        // buttons don't get reliable independent hit testing, and the outer
        // tap is a no-op while sending — the x could become untappable.
        .overlay(alignment: .topTrailing) {
            if let onCancel = onCancel, isSending {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.bitchatSystem(size: 12, weight: .bold))
                        .padding(8)
                        .background(Circle().fill(Color.black.opacity(0.7)))
                        .foregroundColor(.white)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Strings.cancelSend)
            }
        }
        .simultaneousGesture(hideSwipe)
        .onAppear {
            isBlurred = initiallyBlurred
            loadImage()
        }
        .onChange(of: url) { _ in
            isBlurred = initiallyBlurred
            loadImage()
        }
        .contextMenu {
            if isSending {
                cancelSendAction
            } else {
                imageActions
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint(accessibilityHintText)
        .accessibilityAddTraits(isSending || loadFailed ? [] : .isButton)
        .accessibilityActions {
            if isSending {
                // children: .ignore collapses the visible cancel button, so
                // expose it as an action while the send is in flight.
                cancelSendAction
            } else {
                imageActions
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let image = platformImage {
            Image(platformImage: image)
                .resizable()
                .aspectRatio(aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .mask(
                    BlockRevealMask(
                        fraction: fraction,
                        columns: 24,
                        rows: 16
                    )
                    .animation(.easeOut(duration: 0.2), value: fraction)
                )
                .blur(radius: isBlurred ? 20 : 0)
                .overlay {
                    if isBlurred {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                            .overlay(
                                VStack(spacing: 6) {
                                    Image(systemName: "eye.slash.fill")
                                        .font(.bitchatSystem(size: 24, weight: .semibold))
                                    Text(verbatim: Strings.tapToReveal)
                                        // Themed: monospaced under matrix,
                                        // system under liquid glass.
                                        .bitchatFont(size: 12, weight: .medium)
                                }
                                .foregroundColor(.white.opacity(0.85))
                            )
                    }
                }
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.secondary.opacity(0.2))
                .frame(height: 200)
                .overlay {
                    if loadFailed {
                        Image(systemName: "photo")
                            .font(.bitchatSystem(size: 24, weight: .semibold))
                            .foregroundColor(palette.secondary)
                    } else {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }
                }
        }
    }

    @ViewBuilder
    private var cancelSendAction: some View {
        if let onCancel {
            Button(Strings.cancelSend, action: onCancel)
        }
    }

    @ViewBuilder
    private var imageActions: some View {
        // Open/reveal/hide would act on a file that failed to load, so only
        // offer delete (when available) to let users clean up the attachment.
        if !loadFailed {
            if isBlurred {
                Button(Strings.reveal) {
                    withAnimation(.easeOut(duration: 0.2)) { isBlurred = false }
                }
            } else {
                Button(Strings.open) { onOpen?() }
                Button(Strings.hide) {
                    withAnimation(.easeInOut(duration: 0.2)) { isBlurred = true }
                }
            }
        }
        if onDelete != nil {
            Button(Strings.delete, role: .destructive) { showDeleteConfirmation = true }
        }
    }

    private var accessibilityLabelText: String {
        if isSending { return Strings.sendingImage }
        if loadFailed { return Strings.unavailableImage }
        return isBlurred ? Strings.hiddenImage : Strings.revealedImage
    }

    private var accessibilityHintText: String {
        if isSending || loadFailed { return "" }
        return isBlurred ? Strings.revealHint : Strings.openHint
    }

    private func loadImage() {
        loadFailed = false
        DispatchQueue.global(qos: .userInitiated).async {
            #if os(iOS)
            let image = UIImage(contentsOfFile: url.path)
            #else
            let image = NSImage(contentsOf: url)
            #endif
            DispatchQueue.main.async {
                guard let image else {
                    self.loadFailed = true
                    return
                }
                self.platformImage = image
                self.aspectRatio = image.size.height > 0 ? image.size.width / image.size.height : 1
            }
        }
    }

    // Double-tap used to permanently delete the image — the most ingrained
    // photo gesture on mobile, racing the reveal tap, with no confirmation
    // and no way to get the file back. Delete now lives in the context menu
    // behind a confirmation; taps only reveal and open.
    private func handleTap() {
        guard !isSending, !loadFailed else { return }
        if isBlurred {
            withAnimation(.easeOut(duration: 0.2)) {
                isBlurred = false
            }
        } else {
            onOpen?()
        }
    }

    private var hideSwipe: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local).onEnded { value in
            guard !isSending, !loadFailed else { return }
            let horizontal = value.translation.width
            let vertical = value.translation.height
            guard abs(horizontal) > abs(vertical), abs(horizontal) > 40 else { return }
            if !isBlurred {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isBlurred = true
                }
            }
        }
    }
}

private struct BlockRevealMask: Shape {
    let fraction: Double
    let columns: Int
    let rows: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard fraction > 0, columns > 0, rows > 0 else { return path }
        let totalBlocks = columns * rows
        let revealCount = max(0, min(totalBlocks, Int(ceil(fraction * Double(totalBlocks)))))
        guard revealCount > 0 else { return path }
        let blockWidth = rect.width / CGFloat(columns)
        let blockHeight = rect.height / CGFloat(rows)
        var remaining = revealCount
        for row in 0..<rows {
            for column in 0..<columns {
                if remaining <= 0 { return path }
                let x = CGFloat(column) * blockWidth
                let y = CGFloat(row) * blockHeight
                path.addRect(CGRect(x: x, y: y, width: blockWidth, height: blockHeight))
                remaining -= 1
            }
        }
        return path
    }
}

private extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}
