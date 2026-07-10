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

    /// The command already typed in full, once arguments have begun.
    private var typedCommandAlias: String? {
        guard messageText.hasPrefix("/"),
              let spaceIndex = messageText.firstIndex(of: " ")
        else { return nil }
        return String(messageText[..<spaceIndex]).lowercased()
    }

    private var filteredCommands: [CommandInfo] {
        guard messageText.hasPrefix("/") else { return [] }
        let isGeoPublic = locationChannelsModel.selectedChannel.isLocation
        let isGeoDM = privateConversationModel.selectedPeerID?.isGeoDM == true
        let commands = CommandInfo.all(isGeoPublic: isGeoPublic, isGeoDM: isGeoDM)
        // While arguments are being typed, keep the matched command's usage
        // row visible instead of vanishing at the first space.
        if let typed = typedCommandAlias {
            return commands.filter { $0.alias == typed && $0.placeholder != nil }
        }
        return commands.filter { command in
            command.alias.starts(with: messageText.lowercased())
        }
    }

    var body: some View {
        // Render nothing when there are no matches: a zero-height view would
        // still receive the composer VStack's spacing and push the input row
        // off-center.
        if !filteredCommands.isEmpty {
            let isUsageReminder = typedCommandAlias != nil
            VStack(alignment: .leading, spacing: 0) {
                ForEach(filteredCommands) { command in
                    Button {
                        // In usage-reminder mode the row is informational; an
                        // insert here would wipe the arguments being typed.
                        guard !isUsageReminder else { return }
                        messageText = command.alias + " "
                    } label: {
                        buttonRow(for: command)
                    }
                    .buttonStyle(.plain)
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
