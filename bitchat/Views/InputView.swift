
//
//  InputView.swift
//  bitchat
//
//  Created by Gemini on 7/9/25.
//

import SwiftUI

struct InputView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var messageText = ""
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.colorScheme) var colorScheme

    private var colorPalette: ColorPalette {
        ColorPalette.forColorScheme(colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            // @mentions autocomplete
            if viewModel.showAutocomplete && !viewModel.autocompleteSuggestions.isEmpty {
                autocompleteView
            }

            // Command suggestions
            if viewModel.showCommandSuggestions && !viewModel.commandSuggestions.isEmpty {
                commandSuggestionsView
            }

            HStack(alignment: .center, spacing: 4) {
                prompt

                TextField("", text: $messageText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(colorPalette.textColor)
                    .autocorrectionDisabled()
                    .focused($isTextFieldFocused)
                    .onChange(of: messageText) { newValue in
                        viewModel.updateAutocomplete(for: newValue)
                        viewModel.updateCommandSuggestions(for: newValue)
                    }
                    .onSubmit {
                        sendMessage()
                    }

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(messageText.isEmpty ? Color.gray : colorPalette.textColor)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
            }
            .padding(.vertical, 8)
            .background(colorPalette.backgroundColor.opacity(0.95))
        }
        .onAppear {
            isTextFieldFocused = true
        }
    }

    private func sendMessage() {
        viewModel.sendMessage(messageText)
        messageText = ""
    }

    private var prompt: some View {
        HStack {
            if viewModel.selectedPrivateChatPeer != nil {
                Text("<@\(viewModel.nickname)> →")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.orange)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 12)
            } else if let currentChannel = viewModel.currentChannel, viewModel.passwordProtectedChannels.contains(currentChannel) {
                Text("<@\(viewModel.nickname)> →")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.orange)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 12)
            } else {
                Text("<@\(viewModel.nickname)>")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(colorPalette.textColor)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 12)
            }
        }
    }

    private var autocompleteView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(viewModel.autocompleteSuggestions.enumerated()), id: \.element) { index, suggestion in
                Button(action: {
                    _ = viewModel.completeNickname(suggestion, in: &messageText)
                }) {
                    HStack {
                        Text("@\(suggestion)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(colorPalette.textColor)
                            .fontWeight(.medium)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .background(Color.gray.opacity(0.1))
            }
        }
        .background(colorPalette.backgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(colorPalette.secondaryTextColor.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }

    private var commandSuggestionsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(viewModel.commandSuggestions, id: \.self) { command in
                if let info = viewModel.commandInfo(for: command) {
                    Button(action: {
                        messageText = command + " "
                        viewModel.clearCommandSuggestions()
                    }) {
                        HStack {
                            Text(info.commands.joined(separator: ", "))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(colorPalette.textColor)
                                .fontWeight(.medium)

                            if let syntax = info.syntax {
                                Text(syntax)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(colorPalette.secondaryTextColor.opacity(0.8))
                            }

                            Spacer()

                            Text(info.description)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(colorPalette.secondaryTextColor)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .background(Color.gray.opacity(0.1))
                }
            }
        }
        .background(colorPalette.backgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(colorPalette.secondaryTextColor.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }
}
