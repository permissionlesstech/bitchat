//
//  CommandSuggestionsView.swift
//  bitchat
//
//  Created by Islam on 29/10/2025.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct CommandSuggestionsView: View {
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @ThemedPalette private var palette

    @Binding var messageText: String

    /// Row highlighted for keyboard navigation (macOS). Reset whenever the
    /// filtered list changes so the highlight never outlives its list.
    @State private var selectedIndex = 0
    #if os(macOS)
    /// Arrow keys never reach SwiftUI while the composer's field editor has
    /// focus (the single-line field consumes moveUp:/moveDown: itself), so
    /// navigation uses a local key monitor scoped to the panel's lifetime.
    @State private var keyMonitor: Any?
    #endif

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
            let commands = filteredCommands
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                    Button {
                        // In usage-reminder mode the row is informational; an
                        // insert here would wipe the arguments being typed.
                        guard !isUsageReminder else { return }
                        accept(command)
                    } label: {
                        buttonRow(for: command)
                    }
                    .buttonStyle(.plain)
                    .background(rowHighlight(index: index, isUsageReminder: isUsageReminder))
                }
            }
            .themedOverlayPanel()
            .onChange(of: commands) { _ in
                selectedIndex = 0
            }
            #if os(macOS)
            .onAppear { installKeyMonitor() }
            .onDisappear { removeKeyMonitor() }
            #endif
        }
    }

    /// Inserts the command with a trailing space, ready for arguments.
    private func accept(_ command: CommandInfo) {
        messageText = command.alias + " "
    }

    private func rowHighlight(index: Int, isUsageReminder: Bool) -> Color {
        #if os(macOS)
        if !isUsageReminder && index == selectedIndex {
            return palette.secondary.opacity(0.15)
        }
        #endif
        return .clear
    }

    #if os(macOS)
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    /// Standard autocomplete navigation: arrows move the highlight,
    /// return/tab insert the highlighted command. Returning nil consumes the
    /// event, so return completes instead of sending while the list is up;
    /// the usage-reminder row stays informational and passes everything
    /// through (return sends the composed command).
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let commands = filteredCommands
        guard !commands.isEmpty,
              typedCommandAlias == nil,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            return event
        }

        switch event.keyCode {
        case 126: // up arrow
            selectedIndex = max(0, selectedIndex - 1)
            return nil
        case 125: // down arrow
            selectedIndex = min(commands.count - 1, selectedIndex + 1)
            return nil
        case 36, 48: // return, tab
            accept(commands[min(selectedIndex, commands.count - 1)])
            return nil
        default:
            return event
        }
    }
    #endif


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
