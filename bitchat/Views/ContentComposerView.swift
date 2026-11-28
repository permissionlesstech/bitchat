import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

struct ContentComposerView: View {
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @EnvironmentObject private var autocompleteModel: ComposerAutocompleteModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @ObservedObject private var bridgeService = BridgeService.shared
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette

    @ObservedObject var draftModel: ComposerDraftModel
    var isTextFieldFocused: FocusState<Bool>.Binding
    @ObservedObject var voiceRecordingVM: VoiceRecordingViewModel

    let onSendMessage: () -> Void
    @Binding var mediaPickerMode: MediaPickerMode?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if autocompleteModel.showAutocomplete && !autocompleteModel.autocompleteSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(autocompleteModel.autocompleteSuggestions.prefix(4).enumerated()), id: \.element) { index, suggestion in
                        Button(action: {
                            _ = autocompleteModel.completeNickname(suggestion, in: &draftModel.messageText)
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
                            .background(
                                index == autocompleteModel.selectedAutocompleteIndex
                                    ? palette.secondary.opacity(0.15)
                                    : Color.clear
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .themedOverlayPanel()
                .padding(.horizontal, 12)
            }

            if draftModel.messageText.hasPrefix("/") {
                CommandSuggestionsView(messageText: $draftModel.messageText)
            }

            if voiceRecordingVM.state.isActive {
                recordingIndicator
            }

            HStack(alignment: .center, spacing: 4) {
                TextField(
                    "",
                    text: $draftModel.messageText,
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
                .modifier(AutocompleteKeyboardNavigationModifier(
                    isActive: { autocompleteModel.showAutocomplete
                        && !autocompleteModel.autocompleteSuggestions.isEmpty },
                    onMove: { delta in
                        autocompleteModel.moveAutocompleteSelection(by: delta)
                    },
                    onAccept: {
                        autocompleteModel.completeSelectedSuggestion(in: &draftModel.messageText)
                    },
                    onDismiss: {
                        autocompleteModel.dismissAutocomplete()
                    }
                ))
                // Return while the mention panel is open completes the
                // highlight instead of sending — matches command suggestions
                // (#1504) and keeps Tab/Return/Escape on one convention.
                .onSubmit {
                    if autocompleteModel.showAutocomplete,
                       !autocompleteModel.autocompleteSuggestions.isEmpty,
                       autocompleteModel.completeSelectedSuggestion(in: &draftModel.messageText) {
                        return
                    }
                    onSendMessage()
                    // Only the return-key path: it steals focus on iOS, so
                    // every message would cost a tap to reopen the keyboard.
                    // The send button must not reopen a deliberately
                    // dismissed keyboard, so it stays out of this.
                    isTextFieldFocused.wrappedValue = true
                }
                .padding(.vertical, theme.usesGlassChrome ? 8 : 4)
                .padding(.horizontal, 6)
                .themedInputBackground()
                .modifier(FocusEffectDisabledModifier())
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: draftModel.messageText) { newValue in
                    draftModel.scheduleAutocompleteUpdate(for: newValue, in: autocompleteModel)
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
            draftModel.cancelAutocompleteDebounce()
        }
    }
}

private extension ContentComposerView {
    /// Static localized strings hoisted out of `body` so each keystroke in the
    /// composer doesn't perform repeated bundle lookups.
    enum Strings {
        static let nearbyOnlyOnA11y = String(localized: "content.accessibility.nearby_only_on", defaultValue: "Nearby only: messages stay within radio range", comment: "Accessibility label for the compose scope toggle when messages stay local")
        static let nearbyOnlyOffA11y = String(localized: "content.accessibility.nearby_only_off", defaultValue: "Bridged: messages also reach people across the bridge", comment: "Accessibility label for the compose scope toggle when messages cross the mesh bridge")
        static let nearbyOnlyOnHelp = String(localized: "content.composer.nearby_only_on", defaultValue: "Nearby only — this message won't cross the bridge", comment: "Tooltip for the compose scope toggle when messages stay local")
        static let nearbyOnlyOffHelp = String(localized: "content.composer.nearby_only_off", defaultValue: "Bridged — reaches people beyond radio range in this area", comment: "Tooltip for the compose scope toggle when messages cross the mesh bridge")
        static let placeholderMesh = String(localized: "content.input.placeholder.mesh", comment: "Composer placeholder for the public mesh channel")
        static let placeholderPrivateFormat = String(localized: "content.input.placeholder.private", comment: "Composer placeholder inside a private chat, naming the conversation partner")
        static let placeholderLocationFormat = String(localized: "content.input.placeholder.location", comment: "Composer placeholder for a public geohash channel, naming it")
        static let cancel = String(localized: "common.cancel", comment: "Cancel action in the voice recording HUD")
        #if os(iOS)
        static let attachPhoto = String(localized: "content.accessibility.attach_photo", comment: "Accessibility label for the photo attachment button")
        static let attachPhotoHint = String(localized: "content.accessibility.attach_photo_hint", comment: "Accessibility hint explaining the attachment button opens the photo library")
        #else
        static let choosePhoto = String(localized: "content.accessibility.choose_photo", comment: "Accessibility label for the macOS photo picker button")
        #endif
        static let recordVoice = String(localized: "content.accessibility.record_voice_note", comment: "Accessibility label for the voice note button")
        static let recording = String(localized: "content.accessibility.recording", comment: "Accessibility value announced while a voice note is recording")
        static let someoneSpeakingFormat = String(localized: "content.accessibility.someone_speaking", comment: "Accessibility value on the mic button naming who is talking live in the public channel")
        static let recordVoiceHint = String(localized: "content.accessibility.record_voice_hint", comment: "Accessibility hint explaining double-tap toggles voice recording")
        static let sendMessage = String(localized: "content.accessibility.send_message", comment: "Accessibility label for the send message button")
        static let sendHintReady = String(localized: "content.accessibility.send_hint_ready", comment: "Hint prompting the user to send the message")
        static let sendHintEmpty = String(localized: "content.accessibility.send_hint_empty", comment: "Hint prompting the user to enter a message")
    }

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
        .accessibilityLabel(bridgeService.nearbyOnly ? Strings.nearbyOnlyOnA11y : Strings.nearbyOnlyOffA11y)
        .help(bridgeService.nearbyOnly ? Strings.nearbyOnlyOnHelp : Strings.nearbyOnlyOffHelp)
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
            return String(format: Strings.placeholderPrivateFormat, locale: .current, target)
        }
        switch locationChannelsModel.selectedChannel {
        case .mesh:
            return Strings.placeholderMesh
        case .location(let channel):
            return String(format: Strings.placeholderLocationFormat, locale: .current, channel.geohash)
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
                Label(Strings.cancel, systemImage: "xmark.circle")
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
            .modifier(ComposerActionFrame())
            .contentShape(Circle())
            .onTapGesture {
                mediaPickerMode = .photoLibrary
            }
            .onLongPressGesture(minimumDuration: 0.3) {
                mediaPickerMode = .camera
            }
            .accessibilityLabel(Strings.attachPhoto)
            .accessibilityHint(Strings.attachPhotoHint)
            .accessibilityAddTraits(.isButton)
            // The long-press → camera path is unreachable for VoiceOver users;
            // mirror it as a named action.
            .accessibilityAction(named: Text(String(localized: "content.accessibility.take_photo", comment: "Accessibility action name for taking a photo with the camera"))) {
                mediaPickerMode = .camera
            }
        #else
        Button(action: { mediaPickerMode = .photoLibrary }) {
            Image(systemName: "photo.circle.fill")
                .font(.bitchatSystem(size: 24))
                .foregroundColor(composerAccentColor)
                .modifier(ComposerActionFrame())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Strings.choosePhoto)
        #endif
    }

    @ViewBuilder
    var sendOrMicButton: some View {
        let hasText = draftModel.messageText.hasNonWhitespaceContent
        if conversationUIModel.canSendMediaInCurrentContext {
            ZStack {
                micButtonView
                    .opacity(hasText ? 0 : 1)
                    .allowsHitTesting(!hasText)
                sendButtonView(enabled: hasText)
                    .opacity(hasText ? 1 : 0)
                    .allowsHitTesting(hasText)
            }
            .modifier(ComposerActionFrame())
        } else {
            sendButtonView(enabled: hasText)
                .modifier(ComposerActionFrame())
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

    var currentVoiceNoteTarget: VoiceNoteTarget {
        if let peerID = privateConversationModel.selectedPeerID {
            return .privateChat(peerID)
        }
        return .publicMesh
    }

    var micButtonView: some View {
        Image(systemName: "mic.circle.fill")
            .font(.bitchatSystem(size: 24))
            .foregroundColor(micColor)
            .modifier(PulsingOpacityModifier(active: busyTalker != nil && !voiceRecordingVM.state.isActive))
            .modifier(ComposerActionFrame())
            .contentShape(Circle())
            .overlay(
                Color.clear
                    .contentShape(Circle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                voiceRecordingVM.start(
                                    shouldShow: conversationUIModel.canSendMediaInCurrentContext,
                                    target: currentVoiceNoteTarget
                                )
                            }
                            .onEnded { _ in
                                voiceRecordingVM.finish(completion: conversationUIModel.sendVoiceNote(at:target:))
                            }
                    )
            )
            .accessibilityLabel(Strings.recordVoice)
            .accessibilityValue(
                voiceRecordingVM.state.isActive
                ? Strings.recording
                : busyTalker.map {
                    String(format: Strings.someoneSpeakingFormat, locale: .current, $0)
                } ?? ""
            )
            .accessibilityHint(Strings.recordVoiceHint)
            .accessibilityAddTraits(.isButton)
            // Press-and-hold drag gestures can't be activated by VoiceOver;
            // give it a start/stop toggle as the default action.
            .accessibilityAction {
                if voiceRecordingVM.state.isActive {
                    voiceRecordingVM.finish(completion: conversationUIModel.sendVoiceNote(at:target:))
                } else {
                    voiceRecordingVM.start(
                        shouldShow: conversationUIModel.canSendMediaInCurrentContext,
                        target: currentVoiceNoteTarget
                    )
                }
            }
    }

    func sendButtonView(enabled: Bool) -> some View {
        let activeColor = composerAccentColor
        return Button(action: onSendMessage) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.bitchatSystem(size: 24))
                .foregroundColor(enabled ? activeColor : Color.gray)
                .modifier(ComposerActionFrame())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Strings.sendMessage)
        .accessibilityHint(enabled ? Strings.sendHintReady : Strings.sendHintEmpty)
    }
}

/// Arrow/Tab/Return/Escape navigation for the mention suggestion list.
///
/// Deployment targets are iOS 16 / macOS 13, so `.onKeyPress` (iOS 17 /
/// macOS 14+) is gated and unavailable on the minimum OS. Separately, on
/// macOS the single-line field editor consumes `moveUp:`/`moveDown:` itself,
/// so arrow keys never reach SwiftUI while the composer has focus — the
/// same reason command suggestions (#1504) use an `NSEvent` local monitor.
/// Mentions follow that mechanism on macOS and keep `.onKeyPress` for iOS 17+.
private struct AutocompleteKeyboardNavigationModifier: ViewModifier {
    /// Live activity check, not a captured Bool. The macOS monitor closure is
    /// registered once for the view's lifetime; a plain `Bool` would freeze
    /// the value captured at install time (this is a value type), so a panel
    /// that opens after the monitor installs would never intercept a key.
    /// The provider closes over the reference-typed model and reads current
    /// state on every event.
    let isActive: () -> Bool
    let onMove: (Int) -> Void
    let onAccept: () -> Bool
    let onDismiss: () -> Void

    #if os(macOS)
    @State private var keyMonitor: Any?
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onAppear { installKeyMonitor() }
            .onDisappear { removeKeyMonitor() }
        #else
        if #available(iOS 17.0, *) {
            content
                .onKeyPress(.upArrow) {
                    guard isActive() else { return .ignored }
                    onMove(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard isActive() else { return .ignored }
                    onMove(1)
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard isActive() else { return .ignored }
                    return onAccept() ? .handled : .ignored
                }
                .onKeyPress(.escape) {
                    guard isActive() else { return .ignored }
                    onDismiss()
                    return .handled
                }
        } else {
            content
        }
        #endif
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

    /// Standard autocomplete navigation (aligned with #1504): arrows move
    /// the highlight, return/tab insert, escape dismisses. Returning nil
    /// consumes the event so return completes instead of sending while the
    /// list is up. Inactive monitors pass everything through.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard isActive(),
              event.modifierFlags.isDisjoint(with: [.command, .option, .control]) else {
            return event
        }

        switch event.keyCode {
        case 126: // up arrow
            onMove(-1)
            return nil
        case 125: // down arrow
            onMove(1)
            return nil
        case 36, 48: // return, tab
            return onAccept() ? nil : event
        case 53: // escape
            onDismiss()
            return nil
        default:
            return event
        }
    }
    #endif
}

struct ComposerActionFrame: ViewModifier {
    // Match the .title2 scaling used by the composer's size-24 icons.
    @ScaledMetric(relativeTo: .title2) private var scaledSize: CGFloat = 36
    func body(content: Content) -> some View {
        content.frame(width: max(36, scaledSize), height: max(36, scaledSize))
    }
}
