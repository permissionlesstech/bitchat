//
//  CommandSuggestionsView.swift
//  bitchat
//
//  Created by Islam on 29/10/2025.
//

import SwiftUI

struct CommandSuggestionsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var locationManager = LocationChannelManager.shared
    
    @Binding var messageText: String
    
    let textColor: Color
    let backgroundColor: Color
    let secondaryTextColor: Color
    
    private var filteredCommands: [CommandInfo] {
        guard messageText.hasPrefix("/") && !messageText.contains(" ") else { return [] }
        let isGeoPublic = locationManager.selectedChannel.isLocation
        let isGeoDM = viewModel.selectedPrivateChatPeer?.isGeoDM == true
        return CommandInfo.all(isGeoPublic: isGeoPublic, isGeoDM: isGeoDM).filter { command in
            command.alias.starts(with: messageText.lowercased())
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(filteredCommands) { command in
                Button {
                    messageText = command.alias + " "
                } label: {
                    buttonRow(for: command)
                }
                .buttonStyle(.plain)
                .background(Color.gray.opacity(0.1))
            }
        }
        .background(backgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(secondaryTextColor.opacity(0.3), lineWidth: 1)
        )
    }
    
    private func buttonRow(for command: CommandInfo) -> some View {
        HStack {
            Text(command.alias)
                .font(.bitchatSystem(size: 11, design: .monospaced))
                .foregroundColor(textColor)
                .fontWeight(.medium)
            
            if let placeholder = command.placeholder {
                Text(placeholder)
                    .font(.bitchatSystem(size: 10, design: .monospaced))
                    .foregroundColor(secondaryTextColor.opacity(0.8))
            }

            Spacer()
            
            Text(command.description)
                .font(.bitchatSystem(size: 10, design: .monospaced))
                .foregroundColor(secondaryTextColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(iOS 17, macOS 14, *)
#Preview {
    @Previewable @State var messageText: String = "/"
    let keychain = KeychainManager()
    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: NostrIdentityBridge(),
        identityManager: SecureIdentityStateManager(keychain)
    )
    
    CommandSuggestionsView(
        messageText: $messageText,
        textColor: .green,
        backgroundColor: .primary,
        secondaryTextColor: .secondary
    )
    .environmentObject(viewModel)
}
