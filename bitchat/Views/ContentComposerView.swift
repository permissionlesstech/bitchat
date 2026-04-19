import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ContentComposerView: View {
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @Environment(\.colorScheme) private var colorScheme

    @Binding var messageText: String
    var isTextFieldFocused: FocusState<Bool>.Binding
    @ObservedObject var voiceRecordingVM: VoiceRecordingViewModel
    @Binding var autocompleteDebounceTimer: Timer?

    let backgroundColor: Color
    let textColor: Color
    let secondaryTextColor: Color
    let onSendMessage: () -> Void

    #if os(iOS)
    @Binding var showImagePicker: Bool
    @Binding var imagePickerSourceType: UIImagePickerController.SourceType
    #else
    @Binding var showMacImagePicker: Bool
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if conversationUIModel.showAutocomplete && !conversationUIModel.autocompleteSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(conversationUIModel.autocompleteSuggestions.prefix(4)), id: \.self) { suggestion in
                        Button(action: {
                            _ = conversationUIModel.completeNickname(suggestion, in: &messageText)
                        }) {
                            HStack {
                                Text(suggestion)
                                    .font(.bitchatSystem(size: 11, design: .monospaced))
                                    .foregroundColor(textColor)
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
                .background(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(secondaryTextColor.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal, 12)
            }

            CommandSuggestionsView(
                messageText: $messageText,
                textColor: textColor,
                backgroundColor: backgroundColor,
                secondaryTextColor: secondaryTextColor
            )

            if voiceRecordingVM.state.isActive {
                recordingIndicator
            }

            HStack(alignment: .center, spacing: 4) {
                TextField(
                    "",
                    text: $messageText,
                    prompt: Text(
                        String(localized: "content.input.message_placeholder", comment: "Placeholder shown in the chat composer")
                    )
                    .foregroundColor(secondaryTextColor.opacity(0.6))
                )
                .textFieldStyle(.plain)
                .font(.bitchatSystem(size: 15, design: .monospaced))
                .foregroundColor(textColor)
                .focused(isTextFieldFocused)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.sentences)
                #endif
                .submitLabel(.send)
                .onSubmit(onSendMessage)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(colorScheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.7))
                )
                .modifier(FocusEffectDisabledModifier())
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: messageText) { newValue in
                    autocompleteDebounceTimer?.invalidate()
                    autocompleteDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
                        let cursorPosition = newValue.count
                        Task { @MainActor in
                            conversationUIModel.updateAutocomplete(for: newValue, cursorPosition: cursorPosition)
                        }
                    }
                }

                HStack(alignment: .center, spacing: 4) {
                    if conversationUIModel.canSendMediaInCurrentContext {
                        attachmentButton
                    }

                    sendOrMicButton
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(backgroundColor.opacity(0.95))
        .onDisappear {
            autocompleteDebounceTimer?.invalidate()
        }
    }
}

private extension ContentComposerView {
    var recordingIndicator: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .foregroundColor(.red)
                .font(.bitchatSystem(size: 20))
            TimelineView(.periodic(from: .now, by: 0.05)) { context in
                Text(
                    "recording \(voiceRecordingVM.formattedDuration(for: context.date))",
                    comment: "Voice note recording duration indicator"
                )
                .font(.bitchatSystem(size: 13, design: .monospaced))
                .foregroundColor(.red)
            }
            Spacer()
            Button(action: voiceRecordingVM.cancel) {
                Label("Cancel", systemImage: "xmark.circle")
                    .labelStyle(.iconOnly)
                    .font(.bitchatSystem(size: 18))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.red.opacity(0.15))
        )
    }

    var composerAccentColor: Color {
        privateConversationModel.selectedPeerID != nil ? Color.orange : textColor
    }

    var attachmentButton: some View {
        #if os(iOS)
        Image(systemName: "camera.circle.fill")
            .font(.bitchatSystem(size: 24))
            .foregroundColor(composerAccentColor)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .onTapGesture {
                imagePickerSourceType = .photoLibrary
                showImagePicker = true
            }
            .onLongPressGesture(minimumDuration: 0.3) {
                imagePickerSourceType = .camera
                showImagePicker = true
            }
            .accessibilityLabel("Tap for library, long press for camera")
        #else
        Button(action: { showMacImagePicker = true }) {
            Image(systemName: "photo.circle.fill")
                .font(.bitchatSystem(size: 24))
                .foregroundColor(composerAccentColor)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose photo")
        #endif
    }

    @ViewBuilder
    var sendOrMicButton: some View {
        let hasText = !messageText.trimmed.isEmpty
        if conversationUIModel.canSendMediaInCurrentContext {
            ZStack {
                micButtonView
                    .opacity(hasText ? 0 : 1)
                    .allowsHitTesting(!hasText)
                sendButtonView(enabled: hasText)
                    .opacity(hasText ? 1 : 0)
                    .allowsHitTesting(hasText)
            }
            .frame(width: 36, height: 36)
        } else {
            sendButtonView(enabled: hasText)
                .frame(width: 36, height: 36)
        }
    }

    var micButtonView: some View {
        Image(systemName: "mic.circle.fill")
            .font(.bitchatSystem(size: 24))
            .foregroundColor(voiceRecordingVM.state.isActive ? Color.red : composerAccentColor)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .overlay(
                Color.clear
                    .contentShape(Circle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                voiceRecordingVM.start(shouldShow: conversationUIModel.canSendMediaInCurrentContext)
                            }
                            .onEnded { _ in
                                voiceRecordingVM.finish(completion: conversationUIModel.sendVoiceNote)
                            }
                    )
            )
            .accessibilityLabel("Hold to record a voice note")
    }

    func sendButtonView(enabled: Bool) -> some View {
        let activeColor = composerAccentColor
        return Button(action: onSendMessage) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.bitchatSystem(size: 24))
                .foregroundColor(enabled ? activeColor : Color.gray)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(
            String(localized: "content.accessibility.send_message", comment: "Accessibility label for the send message button")
        )
        .accessibilityHint(
            enabled
            ? String(localized: "content.accessibility.send_hint_ready", comment: "Hint prompting the user to send the message")
            : String(localized: "content.accessibility.send_hint_empty", comment: "Hint prompting the user to enter a message")
        )
    }
}
