//
//  CommandSuggestionsView.swift
//  bitchat
//
//  Created by Islam on 29/10/2025.
//

import SwiftUI

struct CommandSuggestionsView: View {
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @ThemedPalette private var palette

    @Binding var messageText: String

    private var filteredCommands: [CommandInfo] {
        guard messageText.hasPrefix("/") && !messageText.contains(" ") else { return [] }
        let isGeoPublic = locationChannelsModel.selectedChannel.isLocation
        let isGeoDM = privateConversationModel.selectedPeerID?.isGeoDM == true
        return CommandInfo.all(isGeoPublic: isGeoPublic, isGeoDM: isGeoDM).filter { command in
            command.alias.starts(with: messageText.lowercased())
        }
    }
    
    var body: some View {
        // Render nothing when there are no matches: a zero-height view would
        // still receive the composer VStack's spacing and push the input row
        // off-center.
        if !filteredCommands.isEmpty {
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
            .themedOverlayPanel()
        }
    }
    
    private func buttonRow(for command: CommandInfo) -> some View {
        HStack {
            Text(command.alias)
                .bitchatFont(size: 11)
                .foregroundColor(palette.primary)
                .fontWeight(.medium)

            if let placeholder = command.placeholder {
                Text(placeholder)
                    .bitchatFont(size: 10)
                    .foregroundColor(palette.secondary.opacity(0.8))
            }

            Spacer()

            Text(command.description)
                .bitchatFont(size: 10)
                .foregroundColor(palette.secondary)
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
    let privateConversationModel = PrivateConversationModel(
        chatViewModel: viewModel,
        conversations: viewModel.conversations
    )
    let locationChannelsModel = LocationChannelsModel()
    
    CommandSuggestionsView(messageText: $messageText)
        .environmentObject(privateConversationModel)
        .environmentObject(locationChannelsModel)
}
