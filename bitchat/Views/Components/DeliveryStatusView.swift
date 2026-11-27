//
// DeliveryStatusView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import BitFoundation

extension DeliveryStatus {
    /// Localized, user-facing description of the status. Used for macOS
    /// tooltips, the tap-to-reveal caption under a message, and VoiceOver —
    /// the glyphs alone are unexplained 10pt icons.
    var bitchatDescription: String {
        switch self {
        case .notSentYet:
            return String(localized: "content.delivery.not_sent_yet", defaultValue: "Not sent yet", comment: "Delivery status description for a message that has not entered any send pipeline")
        case .sending:
            return String(localized: "content.delivery.sending", comment: "Delivery status description while a private message is being sent")
        case .sent:
            return String(localized: "content.delivery.sent", comment: "Delivery status description for a sent but not yet confirmed private message")
        case .carried:
            return String(localized: "content.delivery.carried", defaultValue: "Carried by a friend who may meet them", comment: "Delivery status description for messages handed to a courier for physical delivery")
        case .delivered(let nickname, _):
            return String(
                format: String(localized: "content.delivery.delivered_to", comment: "Tooltip for delivered private messages"),
                locale: .current,
                nickname
            )
        case .read(let nickname, _):
            return String(
                format: String(localized: "content.delivery.read_by", comment: "Tooltip for read private messages"),
                locale: .current,
                nickname
            )
        case .failed(let reason):
            return String(
                format: String(localized: "content.delivery.failed", comment: "Tooltip for failed message delivery"),
                locale: .current,
                reason
            )
        case .partiallyDelivered(let reached, let total):
            return String(
                format: String(localized: "content.delivery.delivered_members", comment: "Tooltip for partially delivered messages"),
                locale: .current,
                reached,
                total
            )
        }
    }
}

struct DeliveryStatusView: View {
    @ThemedPalette private var palette
    let status: DeliveryStatus

    // MARK: - Computed Properties

    private var textColor: Color { palette.primary }

    private var secondaryTextColor: Color { palette.secondary }

    // MARK: - Body

    var body: some View {
        statusGlyph
            .help(status.bitchatDescription)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.bitchatDescription)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch status {
        case .notSentYet:
            // Normally hidden by callers; shown as a hollow dotted circle if
            // it ever surfaces so the state is visible rather than invisible.
            Image(systemName: "circle.dotted")
                .font(.bitchatSystem(size: 10))
                .foregroundColor(secondaryTextColor.opacity(0.6))

        case .sending:
            Image(systemName: "circle")
                .font(.bitchatSystem(size: 10))
                .foregroundColor(secondaryTextColor.opacity(0.6))

        case .sent:
            Image(systemName: "checkmark")
                .font(.bitchatSystem(size: 10))
                .foregroundColor(secondaryTextColor.opacity(0.6))

        case .carried:
            Image(systemName: "figure.walk")
                .font(.bitchatSystem(size: 10))
                .foregroundColor(secondaryTextColor.opacity(0.8))

        case .delivered:
            HStack(spacing: -2) {
                Image(systemName: "checkmark")
                    .font(.bitchatSystem(size: 10))
                Image(systemName: "checkmark")
                    .font(.bitchatSystem(size: 10))
            }
            .foregroundColor(textColor.opacity(0.8))

        case .read:
            // Filled variant so read vs delivered is legible without color.
            HStack(spacing: 0) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.bitchatSystem(size: 9, weight: .bold))
                Image(systemName: "checkmark.circle.fill")
                    .font(.bitchatSystem(size: 9, weight: .bold))
            }
            .foregroundColor(palette.accentBlue)

        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.bitchatSystem(size: 10))
                .foregroundColor(Color.red.opacity(0.8))

        case .partiallyDelivered(let reached, let total):
            HStack(spacing: 1) {
                Image(systemName: "checkmark")
                    .font(.bitchatSystem(size: 10))
                Text(verbatim: "\(reached)/\(total)")
                    .bitchatFont(size: 10)
            }
            .foregroundColor(secondaryTextColor.opacity(0.6))
        }
    }
}

/// Leading inline badges shared by text and media message rows.
struct MessageLeadingBadges: View {
    let isPrivate: Bool
    let showsVerifiedSeal: Bool
    var isBridged: Bool = false

    var body: some View {
        if isPrivate {
            Image(systemName: "lock.fill")
                .font(.bitchatSystem(size: 8))
                .foregroundColor(Color.orange.opacity(0.75))
                .padding(.trailing, 4)
                .accessibilityHidden(true)
        }
        if showsVerifiedSeal {
            Image(systemName: "checkmark.seal.fill")
                .font(.bitchatSystem(size: 8))
                .foregroundColor(Color.green.opacity(0.85))
                .padding(.trailing, 4)
                .accessibilityLabel(
                    String(localized: "content.accessibility.verified_sender", defaultValue: "Verified sender", comment: "Accessibility label for the seal next to a verified peer's name on a private message")
                )
        }
        if isBridged {
            Image(systemName: "network")
                .font(.bitchatSystem(size: 8))
                .foregroundColor(Color.cyan.opacity(0.75))
                .padding(.trailing, 4)
                .accessibilityLabel(
                    String(localized: "content.accessibility.bridged_message", defaultValue: "Arrived across a mesh bridge", comment: "Accessibility label for the glyph marking a message that arrived across a mesh bridge")
                )
        }
    }
}

/// Tappable delivery-status glyph for outgoing private messages.
struct MessageDeliveryStatusButton: View {
    let status: DeliveryStatus
    @Binding var showDetail: Bool

    var body: some View {
        Button {
            showDetail.toggle()
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

/// Expanded delivery-status caption under an outgoing private message.
/// Failure reasons stay visible without a tap; other statuses reveal on demand.
struct MessageDeliveryDetailCaption: View {
    @ThemedPalette private var palette
    let status: DeliveryStatus
    let showDetail: Bool

    var body: some View {
        if case .failed = status {
            Text(verbatim: status.bitchatDescription)
                .bitchatFont(size: 11)
                .foregroundColor(Color.red.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        } else if showDetail {
            Text(verbatim: status.bitchatDescription)
                .bitchatFont(size: 11)
                .foregroundColor(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    let statuses: [DeliveryStatus] = [
        .notSentYet,
        .sending,
        .sent,
        .carried,
        .delivered(to: "John Doe", at: Date()),
        .read(by: "Jane Doe", at: Date()),
        .failed(reason: "Offline"),
        .partiallyDelivered(reached: 2, total: 5)
    ]
    
    List {
        ForEach(statuses, id: \.self) { status in
            HStack {
                Text(status.displayText)
                Spacer()
                DeliveryStatusView(status: status)
            }
        }
    }
    .environment(\.colorScheme, .light)

    List {
        ForEach(statuses, id: \.self) { status in
            HStack {
                Text(status.displayText)
                Spacer()
                DeliveryStatusView(status: status)
            }
        }
    }
    .environment(\.colorScheme, .dark)
}
