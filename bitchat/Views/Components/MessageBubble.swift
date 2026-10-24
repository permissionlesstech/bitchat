//
// MessageBubble.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import BitFoundation

/// Geometry and tint of the bubble layout (`ChatStyle.bubbles`), matching the
/// Android client's `ChatVisualTokens`.
enum MessageBubbleMetrics {
    /// Corner radius of the three "free" corners.
    static let cornerRadius: CGFloat = 16
    /// Tightened corner on the speaker's side, giving the bubble a subtle tail.
    static let tailRadius: CGFloat = 4
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 8
    /// A bubble never grows past this fraction of the row, so long lines
    /// still wrap well clear of the opposite edge.
    static let maxWidthFraction: CGFloat = 0.8
    /// Author-color wash inside the bubble; light enough to keep body text
    /// legible on both the dark and light backgrounds.
    static let fillOpacity: Double = 0.18
    /// Author-color hairline, stronger than the fill so the shape reads.
    static let borderOpacity: Double = 0.38
    /// Space above a bubble that follows one from the same author, and above
    /// one where the author changes. The outline is drawn inside the bubble,
    /// so these are the gaps as seen.
    static let runSpacing: CGFloat = 2
    static let newRunSpacing: CGFloat = 8
    static let metaFontSize: CGFloat = 10

    /// Bubble timestamps drop the seconds the IRC rows show: they add noise
    /// without helping anyone scan a conversation.
    static func timestamp(for date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// Rounded bubble outline whose bottom corner on the speaker's side is
/// tightened into a tail. Written out rather than `UnevenRoundedRectangle`,
/// which needs iOS 17 / macOS 14. Insettable so its outline can be stroked
/// inside the bubble's bounds rather than straddling them.
struct MessageBubbleShape: InsettableShape {
    let isOwn: Bool
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> MessageBubbleShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }

    func path(in bounds: CGRect) -> Path {
        let rect = bounds.insetBy(dx: insetAmount, dy: insetAmount)
        let corner = max(0, min(MessageBubbleMetrics.cornerRadius - insetAmount, rect.width / 2, rect.height / 2))
        let tail = max(0, min(MessageBubbleMetrics.tailRadius - insetAmount, corner))
        let bottomLeft = isOwn ? corner : tail
        let bottomRight = isOwn ? tail : corner

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + corner, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + corner), radius: corner)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY), radius: bottomRight)
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottomLeft), radius: bottomLeft)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + corner))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + corner, y: rect.minY), radius: corner)
        path.closeSubpath()
        return path
    }
}

/// Places one bubble row: offers the bubble at most `maxWidthFraction` of
/// the row and pins it to the trailing edge (own) or leading edge (everyone
/// else). A layout rather than a GeometryReader, so rows keep their natural
/// height and cost nothing extra to measure.
struct MessageBubbleRowLayout: Layout {
    let isOwn: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let bubble = subviews.first else { return .zero }
        let size = bubble.sizeThatFits(bubbleProposal(for: proposal.width))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let bubbleProposal = bubbleProposal(for: bounds.width)
        let size = bubble.sizeThatFits(bubbleProposal)
        let x = isOwn ? bounds.maxX - size.width : bounds.minX
        bubble.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: size.width, height: size.height))
    }

    private func bubbleProposal(for width: CGFloat?) -> ProposedViewSize {
        ProposedViewSize(width: width.map { $0 * MessageBubbleMetrics.maxWidthFraction }, height: nil)
    }
}

extension View {
    /// Fills and outlines the receiver as a message bubble washed with `tint`.
    func messageBubbleChrome(tint: Color, isOwn: Bool) -> some View {
        let shape = MessageBubbleShape(isOwn: isOwn)
        return self
            .padding(.horizontal, MessageBubbleMetrics.horizontalPadding)
            .padding(.vertical, MessageBubbleMetrics.verticalPadding)
            .background(shape.fill(tint.opacity(MessageBubbleMetrics.fillOpacity)))
            .overlay(shape.strokeBorder(tint.opacity(MessageBubbleMetrics.borderOpacity), lineWidth: 1))
    }
}

extension View {
    /// A bubble row lifts into its context menu as a rounded card, not as a
    /// sharp-cornered rectangle. (Context menu previews are iOS-only.)
    @ViewBuilder
    func bubbleContextMenuPreviewShape(isBubble: Bool) -> some View {
        #if os(iOS)
        contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: isBubble ? MessageBubbleMetrics.cornerRadius : 0, style: .continuous))
        #else
        self
        #endif
    }
}

/// The cluster in a bubble's bottom-trailing corner: an optional bridge
/// glyph, the time, and (own private messages) the tappable delivery status.
///
/// Text bubbles ride it on the body's last line when that line has room and
/// drop it onto a line of its own when not. They reserve its exact width
/// with `placeholder`, appended to the body text, and overlay the cluster on
/// top: every slot has a fixed width, so the two always agree.
struct MessageBubbleMeta: View {
    @Environment(\.appTheme) private var theme

    let time: String
    let isBridged: Bool
    /// Delivery status to show; nil for rows that show none.
    let status: DeliveryStatus?
    let onStatusTap: () -> Void

    private static let spacing: CGFloat = 3
    private static let bridgeSlotWidth: CGFloat = 10

    var body: some View {
        HStack(spacing: Self.spacing) {
            if isBridged {
                Image(systemName: "network")
                    .font(.bitchatSystem(size: 8))
                    .foregroundColor(Color.cyan.opacity(0.75))
                    .frame(width: Self.bridgeSlotWidth)
                    .accessibilityLabel(
                        String(localized: "content.accessibility.bridged_message", defaultValue: "Arrived across a mesh bridge", comment: "Accessibility label for the glyph marking a message that arrived across a mesh bridge")
                    )
            }
            // The placeholder in the body already reads the time out.
            Text(verbatim: time)
                .font(.bitchatSystem(size: MessageBubbleMetrics.metaFontSize, design: theme.bodyFontDesign))
                // Neutral grey like the IRC timestamps: the bubble's tint
                // already says whose it is.
                .foregroundColor(Color.gray.opacity(0.8))
                .lineLimit(1)
                .accessibilityHidden(true)
            if let status {
                Button(action: onStatusTap) {
                    DeliveryStatusView(status: status)
                        .frame(width: Self.statusSlotWidth(for: status), alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(
                    String(localized: "content.accessibility.delivery_detail_hint", comment: "Accessibility hint for the delivery status glyph explaining a tap reveals details")
                )
            }
        }
        .fixedSize()
    }

    /// Clear run appended to a body text that reserves the cluster's width
    /// at the end of its last line: a gap, the time itself (VoiceOver reads
    /// it there), and kerned spaces standing in for the glyph slots. Only the
    /// leading space can break, so the run wraps as one piece.
    static func placeholder(time: String, isBridged: Bool, status: DeliveryStatus?, design: Font.Design) -> Text {
        var slots: CGFloat = 0
        if isBridged { slots += bridgeSlotWidth + spacing }
        if let status { slots += spacing + statusSlotWidth(for: status) }
        let timeRun = Text(verbatim: " \u{00A0}" + time)
            .font(.bitchatSystem(size: MessageBubbleMetrics.metaFontSize, design: design))
            .foregroundColor(.clear)
        guard slots > 0 else { return timeRun }
        return timeRun + Text(verbatim: "\u{00A0}")
            .font(.bitchatSystem(size: MessageBubbleMetrics.metaFontSize, design: design))
            .kerning(slots)
            .foregroundColor(.clear)
    }

    /// Fixed width of the status glyph, wide enough for the widest glyph of
    /// that status (`DeliveryStatusView`).
    private static func statusSlotWidth(for status: DeliveryStatus) -> CGFloat {
        switch status {
        case .delivered: return 18
        case .read: return 22
        case .partiallyDelivered(let reached, let total):
            return 14 + CGFloat("\(reached)/\(total)".count) * 7
        case .notSentYet, .sending, .sent, .carried, .failed:
            return 12
        }
    }
}

/// Caption under an own private bubble: the failure reason (always shown) or
/// the tapped-open status detail.
struct MessageBubbleDeliveryCaption: View {
    @ThemedPalette private var palette
    let status: DeliveryStatus
    let showsDetail: Bool

    var body: some View {
        if case .failed = status {
            caption.foregroundColor(Color.red.opacity(0.9))
        } else if showsDetail {
            caption.foregroundColor(palette.secondary)
        }
    }

    private var caption: some View {
        Text(verbatim: status.bitchatDescription)
            .bitchatFont(size: 11)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 4)
    }
}
