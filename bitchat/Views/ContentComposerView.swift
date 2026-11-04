import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
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

    @State private var mentionSelection = NSRange(location: 0, length: 0)
    @State private var mentionInputText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if conversationUIModel.showAutocomplete && !conversationUIModel.autocompleteSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(conversationUIModel.autocompleteSuggestions.prefix(4).enumerated()), id: \.element) { index, suggestion in
                        Button(action: {
                            completeMention(suggestion)
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
                                index == conversationUIModel.selectedAutocompleteIndex
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

            CommandSuggestionsView(messageText: $messageText)

            if voiceRecordingVM.state.isActive {
                recordingIndicator
            }

            HStack(alignment: .center, spacing: 4) {
                composerField
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
                    isActive: { conversationUIModel.showAutocomplete
                        && !conversationUIModel.autocompleteSuggestions.isEmpty },
                    onMove: { delta in
                        conversationUIModel.moveAutocompleteSelection(by: delta)
                    },
                    onAccept: {
                        completeHighlightedMention()
                    },
                    onDismiss: {
                        conversationUIModel.dismissAutocomplete()
                    }
                ))
                // Return while the mention panel is open completes the
                // highlight instead of sending — matches command suggestions
                // (#1504) and keeps Tab/Return/Escape on one convention.
                .onSubmit {
                    if conversationUIModel.showAutocomplete,
                       !conversationUIModel.autocompleteSuggestions.isEmpty,
                       completeHighlightedMention() {
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
                .onChange(of: messageText) { newValue in
                    #if os(iOS)
                    if newValue != mentionInputText {
                        mentionSelection = NSRange(location: newValue.utf16.count, length: 0)
                        conversationUIModel.dismissAutocomplete()
                    }
                    #else
                    autocompleteDebounceTimer?.invalidate()
                    autocompleteDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
                        let cursorPosition = mentionCursor(in: newValue)
                        Task { @MainActor in
                            conversationUIModel.updateAutocomplete(for: newValue, cursorPosition: cursorPosition)
                        }
                    }
                    #endif
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
        .onAppear {
            #if os(iOS)
            mentionSelection = NSRange(location: messageText.utf16.count, length: 0)
            conversationUIModel.dismissAutocomplete()
            #endif
        }
        .onChange(of: locationChannelsModel.selectedChannel) { _ in
            #if os(iOS)
            conversationUIModel.dismissAutocomplete()
            #endif
        }
        .onChange(of: privateConversationModel.selectedPeerID) { _ in
            #if os(iOS)
            conversationUIModel.dismissAutocomplete()
            #endif
        }
        .onDisappear {
            autocompleteDebounceTimer?.invalidate()
            #if os(iOS)
            conversationUIModel.dismissAutocomplete()
            #endif
        }
    }
}

private extension ContentComposerView {
    @ViewBuilder
    var composerField: some View {
        #if os(iOS)
        MentionTextField(text: $messageText, selection: $mentionSelection,
                         focused: Binding(get: { isTextFieldFocused.wrappedValue }, set: { isTextFieldFocused.wrappedValue = $0 }),
                         placeholder: placeholderText, placeholderColor: UIColor(palette.secondary.opacity(0.6)),
                         color: UIColor(palette.primary), monospaced: !theme.usesGlassChrome,
                         hasSuggestions: { conversationUIModel.showAutocomplete },
                         moveSuggestion: { conversationUIModel.moveAutocompleteSelection(by: $0) },
                         acceptSuggestion: { _ = completeHighlightedMention() },
                         dismissSuggestions: { conversationUIModel.dismissAutocomplete() },
                         onSelection: { text, cursor in
                             mentionInputText = text
                             if cursor < 0 { conversationUIModel.dismissAutocomplete() }
                             else { conversationUIModel.updateAutocomplete(for: text, cursorPosition: cursor) }
                         }, onReturn: {
                             if !completeHighlightedMention() { onSendMessage() }
                         })
        #else
        TextField("", text: $messageText, prompt: Text(placeholderText).foregroundColor(palette.secondary.opacity(0.6)))
        #endif
    }

    func mentionCursor(in text: String) -> Int {
        #if os(iOS)
        let offset = min(mentionSelection.location, text.utf16.count)
        let index = String.Index(utf16Offset: offset, in: text)
        return text.distance(from: text.startIndex, to: index)
        #else
        return text.count
        #endif
    }

    func completeMention(_ suggestion: String) {
        let range = conversationUIModel.mentionReplacementRange
        _ = conversationUIModel.completeNickname(suggestion, in: &messageText)
        mentionInputText = messageText
        if let range { mentionSelection = NSRange(location: range.location + suggestion.utf16.count, length: 0) }
    }

    func completeHighlightedMention() -> Bool {
        guard conversationUIModel.showAutocomplete,
              conversationUIModel.autocompleteSuggestions.indices.contains(conversationUIModel.selectedAutocompleteIndex) else { return false }
        completeMention(conversationUIModel.autocompleteSuggestions[conversationUIModel.selectedAutocompleteIndex])
        return true
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
                Label(String(localized: "common.cancel", comment: "Cancel action in the voice recording HUD"), systemImage: "xmark.circle")
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

#if os(iOS)
/// Selection is supplied by UIKit on the minimum supported iOS version.
private struct MentionTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var focused: Bool
    let placeholder: String
    let placeholderColor: UIColor
    let color: UIColor
    let monospaced: Bool
    let hasSuggestions: () -> Bool
    let moveSuggestion: (Int) -> Void
    let acceptSuggestion: () -> Void
    let dismissSuggestions: () -> Void
    let onSelection: (String, Int) -> Void
    let onReturn: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = MentionNativeField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.edit(_:)), for: .editingChanged)
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .sentences
        field.returnKeyType = .send
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? max(0, uiView.intrinsicContentSize.width),
               height: uiView.intrinsicContentSize.height)
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if let native = field as? MentionNativeField {
            native.hasSuggestions = hasSuggestions
            native.moveSuggestion = moveSuggestion
            native.acceptSuggestion = acceptSuggestion
            native.dismissSuggestions = dismissSuggestions
        }
        field.textColor = color
        let descriptor = UIFont.preferredFont(forTextStyle: .subheadline).fontDescriptor
        field.font = UIFont(descriptor: monospaced ? (descriptor.withDesign(.monospaced) ?? descriptor) : descriptor, size: 0)
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder, attributes: [.foregroundColor: placeholderColor]
        )
        if field.text != text {
            if field.markedTextRange != nil { field.unmarkText() }
            field.text = text
        }
        if field.markedTextRange == nil {
            if let a = field.position(from: field.beginningOfDocument, offset: min(selection.location, text.utf16.count)),
               let b = field.position(from: a, offset: min(selection.length, text.utf16.count - min(selection.location, text.utf16.count))) {
                field.selectedTextRange = field.textRange(from: a, to: b)
            }
        }

    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: MentionTextField
        var updating = false
        init(_ parent: MentionTextField) { self.parent = parent }
        @objc func edit(_ field: UITextField) { publish(field) }
        func textFieldDidChangeSelection(_ field: UITextField) { publish(field) }
        func publish(_ field: UITextField) {
            guard !updating else { return }
            if field.markedTextRange != nil {
                parent.text = field.text ?? ""
                parent.onSelection(parent.text, -1)
                return
            }
            guard let range = field.selectedTextRange else { return }
            parent.selection = NSRange(location: field.offset(from: field.beginningOfDocument, to: range.start), length: field.offset(from: range.start, to: range.end))
            parent.text = field.text ?? ""
            // Completion replaces the fragment before the caret, not selected text or a name suffix.
            guard parent.selection.length == 0,
                  let caret = Range(parent.selection, in: parent.text)?.lowerBound else {
                parent.onSelection(parent.text, -1)
                return
            }
            if let next = parent.text[caret...].first,
               next.isLetter || next.isNumber || next == "_" || next == "#" {
                parent.onSelection(parent.text, -1)
                return
            }
            parent.onSelection(parent.text, parent.text[..<caret].count)
        }
        func textFieldDidBeginEditing(_ field: UITextField) { if !updating { parent.focused = true } }
        func textFieldDidEndEditing(_ field: UITextField) { if !updating { parent.focused = false } }
        func textFieldShouldReturn(_ field: UITextField) -> Bool { parent.onReturn(); return false }
    }
}
#endif

#if os(iOS)
private final class MentionNativeField: UITextField {
    var hasSuggestions: () -> Bool = { false }
    var moveSuggestion: (Int) -> Void = { _ in }
    var acceptSuggestion: () -> Void = {}
    var dismissSuggestions: () -> Void = {}
    override var keyCommands: [UIKeyCommand]? {
        guard hasSuggestions(), markedTextRange == nil else { return super.keyCommands }
        let keys = [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\t", UIKeyCommand.inputEscape]
        return keys.map {
            let command = UIKeyCommand(input: $0, modifierFlags: [], action: #selector(mentionKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }
    @objc private func mentionKey(_ command: UIKeyCommand) {
        guard hasSuggestions(), markedTextRange == nil else { return }
        switch command.input {
        case UIKeyCommand.inputUpArrow: moveSuggestion(-1)
        case UIKeyCommand.inputDownArrow: moveSuggestion(1)
        case "\t": acceptSuggestion()
        case UIKeyCommand.inputEscape: dismissSuggestions()
        default: break
        }
    }
}
#endif
