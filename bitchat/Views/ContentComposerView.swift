import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ContentComposerView: View {
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @ObservedObject private var bridgeService = BridgeService.shared
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette

    @Binding var messageText: String
    var isTextFieldFocused: FocusState<Bool>.Binding
    @ObservedObject var voiceRecordingVM: VoiceRecordingViewModel
    @Binding var autocompleteDebounceTimer: Timer?

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
                                    .bitchatFont(size: 11)
                                    .foregroundColor(palette.primary)
                                    .fontWeight(.medium)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .themedOverlayPanel()
                .padding(.horizontal, 12)
            }

            CommandSuggestionsView(messageText: $messageText)

            if voiceRecordingVM.state.isActive {
                recordingIndicator
            }

            HStack(alignment: .center, spacing: 4) {
                TextField(
                    "",
                    text: $messageText,
                    prompt: Text(placeholderText)
                        .foregroundColor(palette.secondary.opacity(0.6))
                )
                .textFieldStyle(.plain)
                .bitchatFont(size: 15)
                .foregroundColor(palette.primary)
                .focused(isTextFieldFocused)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.sentences)
                #endif
                .submitLabel(.send)
                .onSubmit(onSendMessage)
                .padding(.vertical, theme.usesGlassChrome ? 8 : 4)
                .padding(.horizontal, 6)
                .themedInputBackground()
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
                    if showsNearbyOnlyToggle {
                        nearbyOnlyToggle
                    }

                    if conversationUIModel.canSendMediaInCurrentContext {
                        attachmentButton
                    }

                    sendOrMicButton
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, theme.usesGlassChrome ? 8 : 6)
        .padding(.bottom, 8)
        .themedChromePanel(edge: .bottom)
        .onDisappear {
            autocompleteDebounceTimer?.invalidate()
        }
    }
}

private extension ContentComposerView {
    /// The nearby-only scope toggle appears only where it means something:
    /// the public mesh channel with the bridge on.
    var showsNearbyOnlyToggle: Bool {
        guard bridgeService.isEnabled,
              privateConversationModel.selectedHeaderState == nil,
              case .mesh = locationChannelsModel.selectedChannel else {
            return false
        }
        return true
    }

    /// Scope control for outgoing messages: bridged (default, crosses to
    /// other islands in this area) vs nearby-only (radio range, no internet
    /// copy exists for any gateway to carry).
    var nearbyOnlyToggle: some View {
        Button(action: { bridgeService.nearbyOnly.toggle() }) {
            Image(systemName: bridgeService.nearbyOnly ? "antenna.radiowaves.left.and.right" : "network")
                .font(.bitchatSystem(size: 16))
                .foregroundColor(bridgeService.nearbyOnly ? palette.secondary : Color.cyan.opacity(0.9))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            bridgeService.nearbyOnly
            ? String(localized: "content.accessibility.nearby_only_on", defaultValue: "Nearby only: messages stay within radio range", comment: "Accessibility label for the compose scope toggle when messages stay local")
            : String(localized: "content.accessibility.nearby_only_off", defaultValue: "Bridged: messages also reach people across the bridge", comment: "Accessibility label for the compose scope toggle when messages cross the mesh bridge")
        )
        .help(
            bridgeService.nearbyOnly
            ? String(localized: "content.composer.nearby_only_on", defaultValue: "Nearby only — this message won't cross the bridge", comment: "Tooltip for the compose scope toggle when messages stay local")
            : String(localized: "content.composer.nearby_only_off", defaultValue: "Bridged — reaches people beyond radio range in this area", comment: "Tooltip for the compose scope toggle when messages cross the mesh bridge")
        )
    }

    /// States where a message will land: the DM partner's name for private
    /// chats, the channel (and its public nature) otherwise — so a stressed
    /// user never has to guess who can read what they're typing.
    var placeholderText: String {
        if let header = privateConversationModel.selectedHeaderState {
            // A geohash-DM display name already carries its own "#geohash/@name"
            // form, so it must not get another "@" prefix; a mesh nickname does.
            let isGeoDM = privateConversationModel.selectedPeerID?.isGeoDM == true
            let target = isGeoDM ? header.displayName : "@\(header.displayName)"
            return String(
                format: String(localized: "content.input.placeholder.private", comment: "Composer placeholder inside a private chat, naming the conversation partner"),
                locale: .current,
                target
            )
        }
        switch locationChannelsModel.selectedChannel {
        case .mesh:
            return String(localized: "content.input.placeholder.mesh", comment: "Composer placeholder for the public mesh channel")
        case .location(let channel):
            return String(
                format: String(localized: "content.input.placeholder.location", comment: "Composer placeholder for a public geohash channel, naming it"),
                locale: .current,
                channel.geohash
            )
        }
    }

    var recordingIndicator: some View {
        HStack(spacing: 12) {
            Image(systemName: voiceRecordingVM.isLiveStreaming ? "dot.radiowaves.left.and.right" : "waveform.circle.fill")
                .foregroundColor(.red)
                .font(.bitchatSystem(size: 20))
                .modifier(PulsingOpacityModifier(active: voiceRecordingVM.isLiveStreaming))
            TimelineView(.periodic(from: .now, by: 0.05)) { context in
                // Live streaming means audio is heard as you speak — the HUD
                // must make that unmistakable, not just show a timer.
                if voiceRecordingVM.isLiveStreaming {
                    Text(
                        "live \(voiceRecordingVM.formattedDuration(for: context.date))",
                        comment: "Recording HUD label while a voice message streams live to the recipient"
                    )
                    .bitchatFont(size: 13, weight: .bold)
                    .foregroundColor(.red)
                } else {
                    Text(
                        "recording \(voiceRecordingVM.formattedDuration(for: context.date))",
                        comment: "Voice note recording duration indicator"
                    )
                    .bitchatFont(size: 13)
                    .foregroundColor(.red)
                }
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
        privateConversationModel.selectedPeerID != nil ? Color.orange : palette.accent
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
            .accessibilityLabel(
                String(localized: "content.accessibility.attach_photo", comment: "Accessibility label for the photo attachment button")
            )
            .accessibilityHint(
                String(localized: "content.accessibility.attach_photo_hint", comment: "Accessibility hint explaining the attachment button opens the photo library")
            )
            .accessibilityAddTraits(.isButton)
            // The long-press → camera path is unreachable for VoiceOver users;
            // mirror it as a named action.
            .accessibilityAction(named: Text("content.accessibility.take_photo", comment: "Accessibility action name for taking a photo with the camera")) {
                imagePickerSourceType = .camera
                showImagePicker = true
            }
        #else
        Button(action: { showMacImagePicker = true }) {
            Image(systemName: "photo.circle.fill")
                .font(.bitchatSystem(size: 24))
                .foregroundColor(composerAccentColor)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(localized: "content.accessibility.choose_photo", comment: "Accessibility label for the macOS photo picker button")
        )
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

    /// Floor courtesy: someone else is talking live in the public channel.
    /// Only advisory — a decentralized mesh has no floor arbiter, so holding
    /// the mic still works; the tint just discourages talk-over.
    var busyTalker: String? {
        guard privateConversationModel.selectedPeerID == nil else { return nil }
        return conversationUIModel.activeLiveVoiceTalker
    }

    /// Recording > floor-busy > default accent. Whether the hold streams
    /// live or records a classic note is signaled by the recording HUD's
    /// LIVE treatment, not the idle button color.
    var micColor: Color {
        if voiceRecordingVM.state.isActive { return .red }
        if busyTalker != nil { return Color.red.opacity(0.6) }
        return composerAccentColor
    }

    var micButtonView: some View {
        Image(systemName: "mic.circle.fill")
            .font(.bitchatSystem(size: 24))
            .foregroundColor(micColor)
            .modifier(PulsingOpacityModifier(active: busyTalker != nil && !voiceRecordingVM.state.isActive))
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
            .accessibilityLabel(
                String(localized: "content.accessibility.record_voice_note", comment: "Accessibility label for the voice note button")
            )
            .accessibilityValue(
                voiceRecordingVM.state.isActive
                ? String(localized: "content.accessibility.recording", comment: "Accessibility value announced while a voice note is recording")
                : busyTalker.map {
                    String(
                        format: String(localized: "content.accessibility.someone_speaking", comment: "Accessibility value on the mic button naming who is talking live in the public channel"),
                        locale: .current,
                        $0
                    )
                } ?? ""
            )
            .accessibilityHint(
                String(localized: "content.accessibility.record_voice_hint", comment: "Accessibility hint explaining double-tap toggles voice recording")
            )
            .accessibilityAddTraits(.isButton)
            // Press-and-hold drag gestures can't be activated by VoiceOver;
            // give it a start/stop toggle as the default action.
            .accessibilityAction {
                if voiceRecordingVM.state.isActive {
                    voiceRecordingVM.finish(completion: conversationUIModel.sendVoiceNote)
                } else {
                    voiceRecordingVM.start(shouldShow: conversationUIModel.canSendMediaInCurrentContext)
                }
            }
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
