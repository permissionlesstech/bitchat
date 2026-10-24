//
//  CommandSuggestionsView.swift
//  bitchat
//
//  Created by Islam on 29/10/2025.
//

import SwiftUI

/// The commands matching what a composer has typed, for the composer's own
/// conversation (`target`), which decides the commands that work there.
struct CommandSuggestionsView: View {
    @ThemedPalette private var palette

    @Binding var messageText: String
    /// The composer's conversation; nil offers nothing.
    let target: ConversationTarget?

    /// The command already typed in full, once arguments have begun.
    private var typedCommandAlias: String? {
        guard messageText.hasPrefix("/"),
              let spaceIndex = messageText.firstIndex(of: " ")
        else { return nil }
        return String(messageText[..<spaceIndex]).lowercased()
    }

    /// While arguments are being typed, only the matched command's usage
    /// row stays, instead of vanishing at the first space.
    private var filteredCommands: [CommandInfo] {
        guard let target else { return [] }
        return ChatComposerCoordinator.commandSuggestions(for: messageText, in: target)
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

    CommandSuggestionsView(messageText: $messageText, target: .mesh)
}
