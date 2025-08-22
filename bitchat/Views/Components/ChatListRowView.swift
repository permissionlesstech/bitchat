//
//  ChatListRowView.swift
//  bitchat
//
//  Created by Saputra on 20/08/25.
//

import SwiftUI

struct ChatListRowView: View {
    var item: ChatItem
    var accent: Color = .orange
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            LeadingIconCircleView(systemName: item.iconSystemName, bg: item.iconBackground, size: 44)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if item.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(accent)
                            .accessibilityHidden(true)
                    }
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer(minLength: 8)
            
            VStack(alignment: .trailing, spacing: 6) {
                if let time = item.time {
                    Text(time)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                UnreadBadgeView(count: 2)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(rowA11yText))
    }
    
    private var rowA11yText: String {
        var parts: [String] = []
        if item.pinned { parts.append("Pinned") }
        parts.append(item.title)
        if let subtitle = item.subtitle { parts.append(subtitle) }
        if let time = item.time { parts.append(time) }
        if item.unreadCount > 0 { parts.append("\(item.unreadCount) unread") }
        return parts.joined(separator: ". ")
    }
}

//#Preview {
//    ChatListRowView()
//}
