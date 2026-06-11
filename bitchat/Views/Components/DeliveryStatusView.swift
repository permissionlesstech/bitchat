//
// DeliveryStatusView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import BitFoundation

struct DeliveryStatusView: View {
    @ThemedPalette private var palette
    let status: DeliveryStatus

    // MARK: - Computed Properties

    private var textColor: Color { palette.primary }

    private var secondaryTextColor: Color { palette.secondary }

    private enum Strings {
        static func delivered(to nickname: String) -> String {
            String(
                format: String(localized: "content.delivery.delivered_to", comment: "Tooltip for delivered private messages"),
                locale: .current,
                nickname
            )
        }

        static func read(by nickname: String) -> String {
            String(
                format: String(localized: "content.delivery.read_by", comment: "Tooltip for read private messages"),
                locale: .current,
                nickname
            )
        }

        static func failed(_ reason: String) -> String {
            String(
                format: String(localized: "content.delivery.failed", comment: "Tooltip for failed message delivery"),
                locale: .current,
                reason
            )
        }

        static func deliveredToMembers(_ reached: Int, _ total: Int) -> String {
            String(
                format: String(localized: "content.delivery.delivered_members", comment: "Tooltip for partially delivered messages"),
                locale: .current,
                reached,
                total
            )
        }
    }
    
    // MARK: - Body
    
    var body: some View {
        switch status {
        case .sending:
            Image(systemName: "circle")
                .font(.bitchatSystem(size: 10))
                .foregroundColor(secondaryTextColor.opacity(0.6))
            
        case .sent:
            Image(systemName: "checkmark")
                .font(.bitchatSystem(size: 10))
                .foregroundColor(secondaryTextColor.opacity(0.6))
            
        case .delivered(let nickname, _):
            HStack(spacing: -2) {
                Image(systemName: "checkmark")
                    .font(.bitchatSystem(size: 10))
                Image(systemName: "checkmark")
                    .font(.bitchatSystem(size: 10))
            }
            .foregroundColor(textColor.opacity(0.8))
            .help(Strings.delivered(to: nickname))
            
        case .read(let nickname, _):
            HStack(spacing: -2) {
                Image(systemName: "checkmark")
                    .font(.bitchatSystem(size: 10, weight: .bold))
                Image(systemName: "checkmark")
                    .font(.bitchatSystem(size: 10, weight: .bold))
            }
            .foregroundColor(palette.accentBlue)
            .help(Strings.read(by: nickname))
            
        case .failed(let reason):
            Image(systemName: "exclamationmark.triangle")
                .font(.bitchatSystem(size: 10))
                .foregroundColor(Color.red.opacity(0.8))
                .help(Strings.failed(reason))
            
        case .partiallyDelivered(let reached, let total):
            HStack(spacing: 1) {
                Image(systemName: "checkmark")
                    .font(.bitchatSystem(size: 10))
                Text(verbatim: "\(reached)/\(total)")
                    .bitchatFont(size: 10)
            }
            .foregroundColor(secondaryTextColor.opacity(0.6))
            .help(Strings.deliveredToMembers(reached, total))
        }
    }
}

#Preview {
    let statuses: [DeliveryStatus] = [
        .sending,
        .sent,
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
