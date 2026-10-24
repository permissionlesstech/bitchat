import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// A composer: the text field, its suggestions, the mic and the photo
/// button. Everything it does goes to its session's target, the
/// conversation of the timeline it sits under, never to whatever is
/// selected: its text through `onSend` (which takes the session's text and
/// target), a photo through `onPickMedia`, a voice note or a live hold
/// through the mic. Its slot is its session's too.
struct ContentComposerView: View {
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @ObservedObject private var bridgeService = BridgeService.shared
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette

    /// This composer's text, suggestions and conversation; observed here
    /// only.
    @ObservedObject var session: ComposerSession
    /// The composer with the keyboard, shared by every composer on screen.
    var focus: FocusState<ComposerSlot?>.Binding
    @ObservedObject var voiceRecordingVM: VoiceRecordingViewModel
    /// The mic press itself. A drag gesture never reports a cancelled touch
    /// through onEnded, but this resets either way.
    @GestureState private var isMicPressed = false

    /// Sends this slot's text (`ComposerSessions.takeOutgoing(from:)`).
    let onSend: () -> Void
    /// The photo button: the owner records the session's target with the
    /// source and presents the picker.
    #if os(iOS)
    let onPickMedia: (UIImagePickerController.SourceType) -> Void
    #else
    let onPickMedia: () -> Void
    #endif

    private var slot: ComposerSlot { session.slot }
    /// Where this composer sends; nil while it has no conversation, when it
    /// can only hold text.
    private var target: ConversationTarget? { session.target }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsMentionSuggestions {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.autocomplete.suggestions.prefix(ComposerSession.visibleSuggestionCount).enumerated()), id: \.element) { index, suggestion in
                        Button(action: {
                            complete(with: suggestion)
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
                                index == session.autocomplete.selectedIndex
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

            if showsSuggestions {
                CommandSuggestionsView(messageText: $session.text, target: target)
            }

            if isRecordingHere {
                recordingIndicator
            }

            HStack(alignment: .center, spacing: 4) {
                TextField(
                    "",
                    text: editableText,
                    prompt: Text(placeholderText)
                        .foregroundColor(palette.secondary.opacity(0.6))
                )
                .textFieldStyle(.plain)
                .bitchatFont(size: 15)
                .foregroundColor(palette.primary)
                .focused(focus, equals: slot)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.sentences)
                #endif
                .submitLabel(.send)
                .modifier(AutocompleteKeyboardNavigationModifier(
                    isActive: { [session] in session.autocomplete.isShowing },
                    onMove: { [session] delta in
                        session.moveSuggestionSelection(by: delta)
                    },
                    onAccept: {
                        completeWithHighlightedSuggestion()
                    },
                    onDismiss: { [session] in
                        session.dismissSuggestions()
                    }
                ))
                // Return while the mention panel is open completes the
                // highlight instead of sending — matches command suggestions
                // (#1504) and keeps Tab/Return/Escape on one convention.
                .onSubmit {
                    if showsMentionSuggestions, completeWithHighlightedSuggestion() {
                        return
                    }
                    onSend()
                    // Only the return-key path: it steals focus on iOS, so
                    // every message would cost a tap to reopen the keyboard.
                    // The send button must not reopen a deliberately
                    // dismissed keyboard, so it stays out of this.
                    focus.wrappedValue = slot
                }
                .padding(.vertical, theme.usesGlassChrome ? 8 : 4)
                .padding(.horizontal, 6)
                .themedInputBackground()
                .modifier(FocusEffectDisabledModifier())
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: session.text) { _ in
                    scheduleAutocomplete()
                }
                // A new conversation under the same text (a DM's scope
                // following the channel, say) has its own people to suggest.
                .onChange(of: session.target) { _ in
                    scheduleAutocomplete()
                }

                HStack(alignment: .center, spacing: 4) {
                    if showsNearbyOnlyToggle {
                        nearbyOnlyToggle
                    }

                    if allowsMedia {
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
    }
}

private extension ContentComposerView {
    /// The field's text. The field writes only what the person edits, so
    /// its writes are the session's edits (`ComposerSession.edit`).
    var editableText: Binding<String> {
        Binding(
            get: { session.text },
            set: { session.edit($0) }
        )
    }

    /// Only the composer being typed in shows suggestions: while the other
    /// one has the keyboard, this one's stay hidden.
    var showsSuggestions: Bool {
        focus.wrappedValue == nil || focus.wrappedValue == slot
    }

    var showsMentionSuggestions: Bool {
        showsSuggestions && session.autocomplete.isShowing
    }

    /// Photos and voice: #mesh and mesh DMs.
    var allowsMedia: Bool {
        target?.allowsMedia == true
    }

    /// The hold in flight is this composer's: the recording HUD and the red
    /// mic show here only.
    var isRecordingHere: Bool {
        voiceRecordingVM.isHolding(slot) && voiceRecordingVM.state.isActive
    }

    /// Recomputes this composer's mention suggestions for its own text and
    /// conversation once typing pauses.
    func scheduleAutocomplete() {
        session.scheduleAutocomplete { [conversationUIModel] text, target in
            conversationUIModel.autocomplete(for: text, cursorPosition: text.count, in: target)
        }
    }

    /// Puts `suggestion` in place of the @-token the suggestions were made
    /// for, and hides them.
    func complete(with suggestion: String) {
        var text = session.text
        _ = conversationUIModel.complete(suggestion, in: &text, state: session.autocomplete)
        session.dismissSuggestions()
        session.text = text
    }

    /// Completes with the highlighted suggestion, if one shows.
    func completeWithHighlightedSuggestion() -> Bool {
        guard let suggestion = session.highlightedSuggestion else { return false }
        complete(with: suggestion)
        return true
    }

    /// The nearby-only scope toggle appears only where it means something:
    /// the public mesh channel with the bridge on.
    var showsNearbyOnlyToggle: Bool {
        bridgeService.isEnabled && target == .mesh
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
        guard let target else { return "" }
        // A DM composer's conversation is the open DM, whose header names it.
        if let peer = target.privatePeer,
           let header = privateConversationModel.selectedHeaderState {
            // A geohash-DM display name already carries its own "#geohash/@name"
            // form, so it must not get another "@" prefix; a mesh nickname does.
            let partner = peer.isGeoDM ? header.displayName : "@\(header.displayName)"
            return String(
                format: String(localized: "content.input.placeholder.private", comment: "Composer placeholder inside a private chat, naming the conversation partner"),
                locale: .current,
                partner
            )
        }
        switch target.channel {
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
            Button(action: { voiceRecordingVM.cancel(owner: slot) }) {
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
        target?.isPrivate == true ? Color.orange : palette.accent
    }

    var attachmentButton: some View {
        #if os(iOS)
        Image(systemName: "camera.circle.fill")
            .font(.bitchatSystem(size: 24))
            .foregroundColor(composerAccentColor)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .onTapGesture {
                onPickMedia(.photoLibrary)
            }
            .onLongPressGesture(minimumDuration: 0.3) {
                // The simulator and camera-less devices have no camera
                // source; the picker raises on an unavailable one.
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
                onPickMedia(.camera)
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
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
                onPickMedia(.camera)
            }
        #else
        Button(action: { onPickMedia() }) {
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
        let hasText = !session.text.trimmed.isEmpty
        if allowsMedia {
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
        guard target == .mesh else { return nil }
        return conversationUIModel.activeLiveVoiceTalker
    }

    /// Recording > floor-busy > default accent. Whether the hold streams
    /// live or records a classic note is signaled by the recording HUD's
    /// LIVE treatment, not the idle button color.
    var micColor: Color {
        if isRecordingHere { return .red }
        if busyTalker != nil { return Color.red.opacity(0.6) }
        return composerAccentColor
    }

    var micButtonView: some View {
        Image(systemName: "mic.circle.fill")
            .font(.bitchatSystem(size: 24))
            .foregroundColor(micColor)
            .modifier(PulsingOpacityModifier(active: busyTalker != nil && !isRecordingHere))
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .overlay(
                Color.clear
                    .contentShape(Circle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($isMicPressed) { _, isPressed, _ in
                                isPressed = true
                            }
                            .onChanged { _ in
                                // Every movement lands here; the model
                                // starts at most one hold per press, and none
                                // while the other composer holds the mic.
                                pressMic()
                            }
                            .onEnded { _ in
                                // The sender is made now, so the note goes
                                // where it was recorded even if the person
                                // leaves before the file is finalized.
                                voiceRecordingVM.pressEnded(owner: slot, completion: makeVoiceNoteSender())
                            }
                    )
            )
            .onChange(of: isMicPressed) { isPressed in
                guard !isPressed else { return }
                voiceRecordingVM.pressReleased(owner: slot)
                // A lift already ran finish() in onEnded, which leaves the
                // recorder idle synchronously. Still in flight a hop later
                // means the touch was cancelled instead (a fold, a call, a
                // system alert): nothing would ever end this hold, leaving
                // the mic, or a live push-to-talk stream, open.
                DispatchQueue.main.async {
                    guard !isMicPressed, voiceRecordingVM.isHolding(slot) else { return }
                    voiceRecordingVM.cancel(owner: slot)
                }
            }
            .onDisappear {
                // Text only hides the mic, so it goes away only with its
                // composer or once media isn't allowed here (#mesh to a
                // geohash channel, say). A VoiceOver toggle or a second
                // finger can get there with a hold live.
                voiceRecordingVM.controlRemoved(owner: slot)
            }
            .accessibilityLabel(
                String(localized: "content.accessibility.record_voice_note", comment: "Accessibility label for the voice note button")
            )
            .accessibilityValue(
                isRecordingHere
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
                if isRecordingHere {
                    voiceRecordingVM.finish(owner: slot, completion: makeVoiceNoteSender())
                } else {
                    voiceRecordingVM.start(shouldShow: allowsMedia, owner: slot, session: captureSessionFactory)
                }
            }
    }

    /// A press on this composer's mic: a hold for this composer's
    /// conversation, made for it when the hold starts.
    func pressMic() {
        voiceRecordingVM.pressChanged(shouldShow: allowsMedia, owner: slot, session: captureSessionFactory)
    }

    /// Makes the capture backend for a hold here: live only to this
    /// composer's own conversation, a classic note otherwise.
    var captureSessionFactory: (() -> VoiceCaptureSession)? {
        guard let target else { return nil }
        return { [conversationUIModel] in
            conversationUIModel.makeVoiceCaptureSession(for: target)
        }
    }

    /// The release's completion: the note goes to this composer's
    /// conversation as of the release. Nil without one, which drops the
    /// recording rather than sending it anywhere else.
    func makeVoiceNoteSender() -> ((URL) -> Void)? {
        target.map { conversationUIModel.makeVoiceNoteSender(for: $0) }
    }

    func sendButtonView(enabled: Bool) -> some View {
        let activeColor = composerAccentColor
        return Button(action: onSend) {
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
