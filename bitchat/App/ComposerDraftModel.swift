import Combine
import Foundation

/// Owns the composer's live text draft and autocomplete debounce task outside
/// `ContentView`, `MessageListView`, and the people/DM sheet shells.
///
/// Only `ContentComposerView` subscribes to this object via `@ObservedObject`;
/// parent shells and timelines access it through the non-observing
/// `appEnvironmentModels` environment container so typing never triggers
/// full-tree or message-list diffs.
@MainActor
final class ComposerDraftModel: ObservableObject {
    @Published var messageText = ""

    private(set) var activeDraftKey: ComposerDraftStore.Key = .mesh
    private var autocompleteDebounceTask: Task<Void, Never>?

    init() {}

    func loadInitialDraft(for key: ComposerDraftStore.Key) {
        activeDraftKey = key
        let loaded = ComposerDraftStore.load(key)
        if messageText != loaded {
            messageText = loaded
        }
    }

    func switchDraft(to newKey: ComposerDraftStore.Key) {
        guard newKey != activeDraftKey else { return }
        ComposerDraftStore.save(messageText, for: activeDraftKey)
        activeDraftKey = newKey
        let loaded = ComposerDraftStore.load(newKey)
        if messageText != loaded {
            messageText = loaded
        }
    }

    func saveCurrentDraft() {
        ComposerDraftStore.save(messageText, for: activeDraftKey)
    }

    func replaceText(_ text: String) {
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

    /// Returns the trimmed message if non-empty, clearing the draft and
    /// persisted draft store before sending.
    func takeMessageToSend() -> String? {
        guard let trimmed = messageText.trimmedOrNilIfEmpty else { return nil }
        messageText = ""
        ComposerDraftStore.save("", for: activeDraftKey)
        return trimmed
    }

    func resetForPanic() {
        cancelAutocompleteDebounce()
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
        let cursorPosition = text.count
        autocompleteDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            autocompleteModel.updateAutocomplete(for: text, cursorPosition: cursorPosition)
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

    private let chatViewModel: ChatViewModel

    init(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel
        self.showAutocomplete = chatViewModel.showAutocomplete
        self.autocompleteSuggestions = chatViewModel.autocompleteSuggestions
        self.selectedAutocompleteIndex = chatViewModel.selectedAutocompleteIndex

        bind()
    }

    func updateAutocomplete(for text: String, cursorPosition: Int) {
        chatViewModel.updateAutocomplete(for: text, cursorPosition: cursorPosition)
    }

    func completeNickname(_ nickname: String, in text: inout String) -> Int {
        chatViewModel.completeNickname(nickname, in: &text)
    }

    /// Accept the currently highlighted mention suggestion, if any.
    func completeSelectedSuggestion(in text: inout String) -> Bool {
        guard showAutocomplete,
              autocompleteSuggestions.indices.contains(selectedAutocompleteIndex)
        else { return false }
        _ = completeNickname(autocompleteSuggestions[selectedAutocompleteIndex], in: &text)
        return true
    }

    /// Dismiss the mention suggestion panel without inserting (Escape).
    func dismissAutocomplete() {
        guard showAutocomplete else { return }
        chatViewModel.showAutocomplete = false
        chatViewModel.autocompleteSuggestions = []
        chatViewModel.autocompleteRange = nil
        chatViewModel.selectedAutocompleteIndex = 0
    }

    func moveAutocompleteSelection(by delta: Int) {
        guard showAutocomplete, !autocompleteSuggestions.isEmpty else { return }
        let count = min(4, autocompleteSuggestions.count)
        let next = (selectedAutocompleteIndex + delta + count) % count
        chatViewModel.selectedAutocompleteIndex = next
    }

    private func bind() {
        chatViewModel.$showAutocomplete
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .assign(to: &$showAutocomplete)

        chatViewModel.$autocompleteSuggestions
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .assign(to: &$autocompleteSuggestions)

        chatViewModel.$selectedAutocompleteIndex
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .assign(to: &$selectedAutocompleteIndex)
    }
}
