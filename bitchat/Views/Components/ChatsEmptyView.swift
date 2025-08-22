//
//  ChatsEmptyView.swift
//  bitchat_iOS
//
//  Created by Saputra on 20/08/25.
//

import SwiftUI

struct ChatsEmptyView: View {
    var accent: Color = .brandPrimary
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeaderView(title: "Chats")
            VStack(alignment: .leading, spacing: 16) {
                InstructionRow(
                    icon: Image(systemName: "person.fill"),
                    text: "1. Click the button at the top right to create a new circle.",
                    accent: accent
                )
                InstructionRow(
                    icon: Image(systemName: "person.3.fill"),
                    text: "2. Or you can click the device near you to start a new chat.",
                    accent: accent
                )
            }
        }
    }
}

private struct InstructionRow: View {
    var icon: Image
    var text: String
    var accent: Color
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(accent.opacity(0.25))
                icon.foregroundStyle(accent)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            
            Text(text)
                .foregroundStyle(.secondary)
                .accessibilityLabel(text)
        }
    }
}

#Preview {
    ChatsEmptyView()
}
