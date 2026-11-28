import Combine
import Foundation

/// Non-observing per-window owner for `ComposerDraftModel`.
///
/// `ContentView` holds this via `@StateObject` so each macOS `WindowGroup`
/// window owns its own live draft buffer and panic-preparation registration
/// ID without subscribing `ContentView` to `ComposerDraftModel.objectWillChange`.
@MainActor
final class ComposerDraftHost: ObservableObject {
    let model = ComposerDraftModel()
    var id: UUID { model.id }
}

/// Owns the composer's live text draft and autocomplete debounce task outside
/// `ContentView`, `MessageListView`, and the people/DM sheet shells.
///
/// Only `ContentComposerView` subscribes to this object via `@ObservedObject`;
/// parent shells and timelines access it per window through `ComposerDraftHost`
/// and `@Environment(\.composerDraftModel)` so typing never triggers
/// full-tree or message-list diffs and macOS windows keep independent drafts.
@MainActor
final class ComposerDraftModel: ObservableObject {
    @Published var messageText = ""
    @Published var replyTarget: MessageReplyTarget?

    let id: UUID
    private(set) var activeDraftKey: ComposerDraftStore.Key = .mesh
    private var autocompleteDebounceTask: Task<Void, Never>?
    private let autocompleteDebounceDuration: Duration

    init(
        id: UUID = UUID(),
        autocompleteDebounceDuration: Duration = .milliseconds(150)
    ) {
        self.id = id
        self.autocompleteDebounceDuration = autocompleteDebounceDuration
    }

    deinit {
        ComposerDraftStore.clear(scope: id)
    }

    func setReplyTarget(_ target: MessageReplyTarget?) {
        if replyTarget != target {
            replyTarget = target
        }
    }

    func clearReplyTarget() {
        if replyTarget != nil {
            replyTarget = nil
        }
    }

    func loadInitialDraft(for key: ComposerDraftStore.Key) {
        cancelAutocompleteDebounce()
        activeDraftKey = key
        let loaded = ComposerDraftStore.load(key, scope: id)
        if messageText != loaded {
            messageText = loaded
        }
    }

    func switchDraft(to newKey: ComposerDraftStore.Key) {
        guard newKey != activeDraftKey else { return }
        cancelAutocompleteDebounce()
        ComposerDraftStore.save(messageText, for: activeDraftKey, scope: id)
        activeDraftKey = newKey
        clearReplyTarget()
        let loaded = ComposerDraftStore.load(newKey, scope: id)
        if messageText != loaded {
            messageText = loaded
        }
    }

    func saveCurrentDraft() {
        ComposerDraftStore.save(messageText, for: activeDraftKey, scope: id)
    }

    func replaceText(_ text: String) {
        cancelAutocompleteDebounce()
        messageText = text
    }

    /// Appends an @mention to the composer draft without overwriting existing text.
    func insertMention(_ sender: String) {
        let mention = "@\(sender) "
        if messageText.isEmpty {
            messageText = mention
        } else if messageText.hasSuffix(" ") {
            messageText += mention
        } else {
            messageText += " " + mention
        }
    }

    /// Returns the trimmed message (with quoted reply prefix if replying) when
    /// non-empty, clearing the draft, reply target, and persisted draft store before sending.
    func takeMessageToSend() -> String? {
        guard let trimmed = messageText.trimmedOrNilIfEmpty else { return nil }
        let activeReply = replyTarget
        cancelAutocompleteDebounce()
        messageText = ""
        replyTarget = nil
        ComposerDraftStore.save("", for: activeDraftKey, scope: id)
        if let activeReply, !trimmed.hasPrefix("/") {
            return MessageInteractionCodec.encodeReply(to: activeReply, body: trimmed)
        }
        return trimmed
    }

    func resetForPanic() {
        cancelAutocompleteDebounce()
        clearReplyTarget()
        ComposerDraftStore.clear(scope: id)
        if !messageText.isEmpty {
            messageText = ""
        }
        activeDraftKey = .mesh
    }

    func scheduleAutocompleteUpdate(
        for text: String,
        in autocompleteModel: ComposerAutocompleteModel
    ) {
        autocompleteDebounceTask?.cancel()
        autocompleteDebounceTask = nil
        // Ordinary typing without `@` can never open mention autocomplete; skip
        // spawning a debounce Task on every keystroke once this window's panel is closed.
        guard text.contains("@") || autocompleteModel.hasActiveAutocomplete(for: id) else { return }
        let cursorPosition = text.count
        let debounceDuration = autocompleteDebounceDuration
        let ownerID = id
        autocompleteDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: debounceDuration)
            } catch {
                return
            }
            autocompleteModel.updateAutocomplete(
                for: text,
                cursorPosition: cursorPosition,
                ownerID: ownerID
            )
        }
    }

    func cancelAutocompleteDebounce() {
        autocompleteDebounceTask?.cancel()
        autocompleteDebounceTask = nil
    }
}

/// Focused observable model for `@mention` autocomplete state.
///
/// Split out of `ConversationUIModel` so typing and cycling mention suggestions
/// only re-evaluates `ContentComposerView` instead of every `TextMessageView`
/// and `MediaMessageView` row in the timeline.
@MainActor
final class ComposerAutocompleteModel: ObservableObject {
    @Published private(set) var showAutocomplete = false
    @Published private(set) var autocompleteSuggestions: [String] = []
    @Published private(set) var selectedAutocompleteIndex = 0
    @Published private(set) var activeOwnerID: UUID?

    private let chatViewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()

    init(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel
        self.showAutocomplete = chatViewModel.showAutocomplete
        self.autocompleteSuggestions = chatViewModel.autocompleteSuggestions
        self.selectedAutocompleteIndex = chatViewModel.selectedAutocompleteIndex

        bind()
    }

    func isShowingAutocomplete(for ownerID: UUID? = nil) -> Bool {
        guard showAutocomplete, !autocompleteSuggestions.isEmpty else { return false }
        return ownsAutocomplete(ownerID: ownerID)
    }

    func hasActiveAutocomplete(for ownerID: UUID) -> Bool {
        guard showAutocomplete || chatViewModel.showAutocomplete else { return false }
        return ownsAutocomplete(ownerID: ownerID)
    }

    func updateAutocomplete(for text: String, cursorPosition: Int, ownerID: UUID? = nil) {
        // Another window editing plain text without an `@` token must not
        // dismiss or overwrite the owning window's active mention panel.
        if let ownerID,
           let currentOwner = activeOwnerID,
           currentOwner != ownerID,
           AutocompleteService.mentionPrefix(in: text, cursorPosition: cursorPosition) == nil {
            return
        }
        chatViewModel.updateAutocomplete(for: text, cursorPosition: cursorPosition)
        if chatViewModel.showAutocomplete && !chatViewModel.autocompleteSuggestions.isEmpty {
            if activeOwnerID != ownerID {
                activeOwnerID = ownerID
            }
        } else if activeOwnerID != nil {
            activeOwnerID = nil
        }
    }

    func completeNickname(_ nickname: String, in text: inout String, ownerID: UUID? = nil) -> Int {
        guard ownsAutocomplete(ownerID: ownerID) else { return text.count }
        let cursor = chatViewModel.completeNickname(nickname, in: &text)
        if activeOwnerID != nil {
            activeOwnerID = nil
        }
        return cursor
    }

    /// Accept the currently highlighted mention suggestion, if any.
    func completeSelectedSuggestion(in text: inout String, ownerID: UUID? = nil) -> Bool {
        guard isShowingAutocomplete(for: ownerID),
              autocompleteSuggestions.indices.contains(selectedAutocompleteIndex)
        else { return false }
        _ = completeNickname(
            autocompleteSuggestions[selectedAutocompleteIndex],
            in: &text,
            ownerID: ownerID
        )
        return true
    }

    /// Dismiss the mention suggestion panel without inserting (Escape).
    func dismissAutocomplete(ownerID: UUID? = nil) {
        guard ownsAutocomplete(ownerID: ownerID) else { return }
        if activeOwnerID != nil {
            activeOwnerID = nil
        }
        guard showAutocomplete || chatViewModel.showAutocomplete else { return }
        chatViewModel.showAutocomplete = false
        chatViewModel.autocompleteSuggestions = []
        chatViewModel.autocompleteRange = nil
        chatViewModel.selectedAutocompleteIndex = 0
    }

    func moveAutocompleteSelection(by delta: Int, ownerID: UUID? = nil) {
        guard isShowingAutocomplete(for: ownerID) else { return }
        let count = min(4, autocompleteSuggestions.count)
        let next = (selectedAutocompleteIndex + delta + count) % count
        chatViewModel.selectedAutocompleteIndex = next
    }

    private func ownsAutocomplete(ownerID: UUID?) -> Bool {
        guard let ownerID, let activeOwnerID else { return true }
        return activeOwnerID == ownerID
    }

    private func bind() {
        chatViewModel.$showAutocomplete
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                guard let self else { return }
                if self.showAutocomplete != show {
                    self.showAutocomplete = show
                }
                if !show, self.activeOwnerID != nil {
                    self.activeOwnerID = nil
                }
            }
            .store(in: &cancellables)
        mirror(chatViewModel.$autocompleteSuggestions, to: &$autocompleteSuggestions)
        mirror(chatViewModel.$selectedAutocompleteIndex, to: &$selectedAutocompleteIndex)
    }

    private func mirror<Value: Equatable>(
        _ publisher: Published<Value>.Publisher,
        to target: inout Published<Value>.Publisher
    ) {
        publisher
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .assign(to: &target)
    }
}
