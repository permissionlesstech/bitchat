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
    /// Highlighted row. The composer owns it so the keyboard handler and
    /// the list agree.
    var selectedIndex: Int = 0
    /// Escape hides the panel until the text changes.
    var isDismissed: Bool = false

    private var availableCommands: [CommandInfo] {
        let isGeoPublic = locationChannelsModel.selectedChannel.isLocation
        let isGeoDM = privateConversationModel.selectedPeerID?.isGeoDM == true
        return CommandInfo.all(isGeoPublic: isGeoPublic, isGeoDM: isGeoDM)
    }

    private var panel: CommandSuggestionNavigation.Panel? {
        guard !isDismissed else { return nil }
        return CommandSuggestionNavigation.panel(
            typedText: messageText,
            commands: availableCommands.map {
                CommandSuggestionNavigation.Command(alias: $0.alias, hasPlaceholder: $0.placeholder != nil)
            }
        )
    }

    private var filteredCommands: [CommandInfo] {
        guard let panel else { return [] }
        let byAlias = Dictionary(uniqueKeysWithValues: availableCommands.map { ($0.alias, $0) })
        return panel.aliases.compactMap { byAlias[$0] }
    }

    var body: some View {
        // Render nothing when there are no matches: a zero-height view would
        // still receive the composer VStack's spacing and push the input row
        // off-center.
        if let panel, !filteredCommands.isEmpty {
            let highlighted = CommandSuggestionNavigation.clamped(selectedIndex, count: filteredCommands.count)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                    Button {
                        // In usage-reminder mode the row is informational; an
                        // insert here would wipe the arguments being typed.
                        guard !panel.isUsageReminder else { return }
                        messageText = command.alias + " "
                    } label: {
                        buttonRow(for: command, isSelected: index == highlighted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .themedOverlayPanel()
        }
    }

    private func buttonRow(for command: CommandInfo, isSelected: Bool) -> some View {
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
        .background(isSelected ? palette.secondary.opacity(0.15) : Color.clear)
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
