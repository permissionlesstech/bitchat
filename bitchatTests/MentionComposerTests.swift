import BitFoundation
import Testing
@testable import bitchat

#if os(iOS)
import SwiftUI
import UIKit

@MainActor private struct MentionProbeComposer: View {
    @State var text = "hey everyone, see you tomorrow"
    @State var timer: Timer?
    @State var picker = false
    @State var source: UIImagePickerController.SourceType = .photoLibrary
    @StateObject var voice = VoiceRecordingViewModel()
    @FocusState var focus: Bool
    var body: some View {
        ContentComposerView(
            messageText: $text, isTextFieldFocused: $focus, voiceRecordingVM: voice,
            autocompleteDebounceTimer: $timer, onSendMessage: {}, showImagePicker: $picker,
            imagePickerSourceType: $source)
    }
}
extension ViewSmokeTests {
    @Test @MainActor func completesMentionAtCaretWithoutLosingTrailingText() async throws {
        let (vm, transport, _) = makeSmokeViewModel()
        transport.peerNicknames[PeerID(str: "1122334455667788")] = "alice"
        let models = makeSmokeFeatureModels(for: vm)
        let host = UIHostingController(
            rootView: MentionProbeComposer().environmentObject(models.conversationUIModel)
                .environmentObject(models.privateConversationModel).environmentObject(
                    models.locationChannelsModel))
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))
        func fields(_ v: UIView) -> [UITextField] {
            (v as? UITextField).map { [$0] } ?? v.subviews.flatMap(fields)
        }
        let field = try #require(fields(host.view).first)
        field.becomeFirstResponder()
        let start = try #require(field.position(from: field.beginningOfDocument, offset: 4))
        let end = try #require(field.position(from: start, offset: 8))
        field.selectedTextRange = field.textRange(from: start, to: end)
        field.insertText("@al")
        try await Task.sleep(for: .milliseconds(600))
        #expect(field.text == "hey @al, see you tomorrow")
        #expect(models.conversationUIModel.autocompleteSuggestions.contains("@alice"))
        _ = field.delegate?.textFieldShouldReturn?(field)
        try await Task.sleep(for: .milliseconds(300))
        #expect(field.text == "hey @alice, see you tomorrow")
        #expect(
            field.offset(from: field.beginningOfDocument, to: field.selectedTextRange!.start) == 10)
        field.selectedTextRange = field.textRange(
            from: field.beginningOfDocument, to: field.endOfDocument)
        field.insertText("hey @al")
        try await Task.sleep(for: .milliseconds(600))
        #expect(models.conversationUIModel.autocompleteSuggestions.contains("@alice"))
        for prefix in ["😀 hey ", "👨‍👩‍👧‍👦 hey ", "e\u{301} hey "] {
            field.selectedTextRange = field.textRange(
                from: field.beginningOfDocument, to: field.endOfDocument)
            field.insertText(prefix + "@al, see you tomorrow")
            let caret = field.position(
                from: field.beginningOfDocument, offset: (prefix + "@al").utf16.count)!
            field.selectedTextRange = field.textRange(from: caret, to: caret)
            try await Task.sleep(for: .milliseconds(300))
            #expect(models.conversationUIModel.autocompleteSuggestions.contains("@alice"))
            _ = field.delegate?.textFieldShouldReturn?(field)
            try await Task.sleep(for: .milliseconds(300))
            #expect(field.text == prefix + "@alice, see you tomorrow")
            #expect(
                field.offset(from: field.beginningOfDocument, to: field.selectedTextRange!.start)
                    == (prefix + "@alice").utf16.count)
        }
        field.selectedTextRange = field.textRange(
            from: field.endOfDocument, to: field.endOfDocument)
        try await Task.sleep(for: .milliseconds(300))
        #expect(models.conversationUIModel.autocompleteSuggestions.isEmpty)
        field.selectedTextRange = field.textRange(
            from: field.beginningOfDocument, to: field.endOfDocument)
        field.insertText("hey @al")
        try await Task.sleep(for: .milliseconds(300))
        field.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0))
        try await Task.sleep(for: .milliseconds(300))
        #expect(field.markedTextRange != nil)
        #expect(models.conversationUIModel.autocompleteSuggestions.isEmpty)
        field.unmarkText()
        transport.peerNicknames[PeerID(str: "2233445566778899")] = "alex"
        field.selectedTextRange = field.textRange(
            from: field.beginningOfDocument, to: field.endOfDocument)
        field.insertText("hey @al")
        try await Task.sleep(for: .milliseconds(300))
        let down = try #require(
            field.keyCommands?.first { $0.input == UIKeyCommand.inputDownArrow })
        _ = field.perform(down.action, with: down)
        try await Task.sleep(for: .milliseconds(200))
        #expect(models.conversationUIModel.selectedAutocompleteIndex == 1)
        let up = try #require(field.keyCommands?.first { $0.input == UIKeyCommand.inputUpArrow })
        _ = field.perform(up.action, with: up)
        try await Task.sleep(for: .milliseconds(200))
        #expect(models.conversationUIModel.selectedAutocompleteIndex == 0)
        let tab = try #require(field.keyCommands?.first { $0.input == "\t" })
        _ = field.perform(tab.action, with: tab)
        try await Task.sleep(for: .milliseconds(300))
        #expect(field.text == "hey @alex")
        #expect(field.isFirstResponder)
        field.selectedTextRange = field.textRange(
            from: field.beginningOfDocument, to: field.endOfDocument)
        field.insertText("hey @al")
        try await Task.sleep(for: .milliseconds(300))
        let escape = try #require(field.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })
        _ = field.perform(escape.action, with: escape)
        try await Task.sleep(for: .milliseconds(200))
        #expect(models.conversationUIModel.autocompleteSuggestions.isEmpty)
        #expect(field.text == "hey @al")
        field.resignFirstResponder()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!field.isFirstResponder)
        vm.geoNicknames = [String(repeating: "a", count: 60) + "dddd": "carol"]
        vm.activeChannel = .location(GeohashChannel(level: .city, geohash: "u4pru"))
        field.becomeFirstResponder()
        field.selectedTextRange = field.textRange(
            from: field.beginningOfDocument, to: field.endOfDocument)
        field.insertText("hello @ca, tomorrow")
        let geoCaret = try #require(field.position(from: field.beginningOfDocument, offset: 9))
        field.selectedTextRange = field.textRange(from: geoCaret, to: geoCaret)
        try await Task.sleep(for: .milliseconds(300))
        #expect(models.conversationUIModel.autocompleteSuggestions == ["@carol#dddd"])
        _ = field.delegate?.textFieldShouldReturn?(field)
        try await Task.sleep(for: .milliseconds(300))
        #expect(field.text == "hello @carol#dddd, tomorrow")
        vm.activeChannel = .mesh
        field.selectedTextRange = field.textRange(
            from: field.beginningOfDocument, to: field.endOfDocument)
        field.insertText("hello @ca")
        try await Task.sleep(for: .milliseconds(300))
        #expect(models.conversationUIModel.autocompleteSuggestions.isEmpty)

    }
}
#endif

#if os(iOS)
extension ViewSmokeTests {
    @Test @MainActor func switchingConversationsPreservesDraftsAndClearsSuggestions() async throws {
        let previous = ComposerDraftStore.replaceAllForTesting()
        defer { ComposerDraftStore.replaceAllForTesting(previous) }
        let (vm, transport, _) = makeSmokeViewModel()
        let peer = PeerID(str: "5152535455565758")
        transport.updatePeerSnapshots([
            makeSnapshot(peerID: peer, nickname: "alice", noiseByte: 0x66)
        ]
        )
        transport.peerNicknames[peer] = "alice"
        let models = makeSmokeFeatureModels(for: vm)
        try await Task.sleep(for: .milliseconds(200))
        let privateKey = ComposerDraftStore.Key.privateChat(
            stableID: vm.getFingerprint(for: peer) ?? peer.id)
        ComposerDraftStore.save("private saved draft", for: privateKey)
        let host = UIHostingController(
            rootView: installSmokeEnvironment(ContentView(), featureModels: models))
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))
        func fields(_ v: UIView) -> [UITextField] {
            (v as? UITextField).map { [$0] } ?? v.subviews.flatMap(fields)
        }
        let field = try #require(fields(host.view).first { $0.returnKeyType == .send })
        field.becomeFirstResponder()
        field.insertText("hey @al, see you tomorrow")
        let caret = try #require(field.position(from: field.beginningOfDocument, offset: 7))
        field.selectedTextRange = field.textRange(from: caret, to: caret)
        try await Task.sleep(for: .milliseconds(300))
        #expect(models.conversationUIModel.autocompleteSuggestions.contains("@alice"))
        models.privateConversationModel.startConversation(with: peer)
        try await Task.sleep(for: .milliseconds(500))
        #expect(fields(window).contains { $0.text == "private saved draft" })
        #expect(
            models.conversationUIModel.autocompleteSuggestions.isEmpty,
            "Old mention must clear when loading another draft")
        #expect(ComposerDraftStore.load(.mesh) == "hey @al, see you tomorrow")
        models.privateConversationModel.endConversation()
        try await Task.sleep(for: .milliseconds(500))
        #expect(fields(window).contains { $0.text == "hey @al, see you tomorrow" })
        #expect(ComposerDraftStore.load(privateKey) == "private saved draft")
        let group = PeerID(groupID: Data(repeating: 0x31, count: 16))
        let groupKey = ComposerDraftStore.Key.privateChat(stableID: group.id)
        ComposerDraftStore.save("group @al, later", for: groupKey)
        models.privateConversationModel.startConversation(with: group)
        try await Task.sleep(for: .milliseconds(500))
        let groupField = try #require(fields(window).first { $0.text == "group @al, later" })
        groupField.becomeFirstResponder()
        let groupCaret = try #require(
            groupField.position(from: groupField.beginningOfDocument, offset: 9))
        groupField.selectedTextRange = groupField.textRange(from: groupCaret, to: groupCaret)
        try await Task.sleep(for: .milliseconds(300))
        #expect(models.conversationUIModel.autocompleteSuggestions.contains("@alice"))
        _ = groupField.delegate?.textFieldShouldReturn?(groupField)
        try await Task.sleep(for: .milliseconds(300))
        #expect(groupField.text == "group @alice, later")
        models.privateConversationModel.endConversation()
        try await Task.sleep(for: .milliseconds(400))
        #expect(ComposerDraftStore.load(groupKey) == "group @alice, later")
        #expect(fields(window).contains { $0.text == "hey @al, see you tomorrow" })

    }
}

@MainActor
private func withBoundaryComposer(_ body: (UITextField, ConversationUIModel) async throws -> Void) async throws {
    let (vm, transport, _) = makeSmokeViewModel()
    transport.peerNicknames[PeerID(str: "1122334455667788")] = "alice"
    let models = makeSmokeFeatureModels(for: vm)
    let host = UIHostingController(rootView:
        MentionProbeComposer().environmentObject(models.conversationUIModel)
            .environmentObject(models.privateConversationModel)
            .environmentObject(models.locationChannelsModel))
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = scene.coordinateSpace.bounds
    window.rootViewController = host
    window.windowLevel = .alert + 1
    window.makeKeyAndVisible()
    defer { window.isHidden = true; withExtendedLifetime(vm) {} }
    try await Task.sleep(for: .milliseconds(500))
    func fields(_ view: UIView) -> [UITextField] {
        (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    let field = try #require(fields(host.view).first { $0.returnKeyType == .send })
    field.becomeFirstResponder()
    try await body(field, models.conversationUIModel)
}

@MainActor
private func selectBoundaryRange(_ field: UITextField, location: Int, length: Int = 0) throws {
    let start = try #require(field.position(from: field.beginningOfDocument, offset: location))
    let end = try #require(field.position(from: start, offset: length))
    field.selectedTextRange = field.textRange(from: start, to: end)
    let actual = try #require(field.selectedTextRange)
    #expect(field.offset(from: field.beginningOfDocument, to: actual.start) == location)
    #expect(field.offset(from: actual.start, to: actual.end) == length)
}

extension ViewSmokeTests {
    @Test @MainActor func mentionSelectionDismissesAndRecoversAtBoundary() async throws {
        try await withBoundaryComposer { field, model in
            field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
            field.insertText("hey @al, later")
            try selectBoundaryRange(field, location: 7)
            try await Task.sleep(for: .milliseconds(300))
            try #require(model.autocompleteSuggestions.contains("@alice"))
            // The comma isolates selection dismissal from the word-continuation check.
            try selectBoundaryRange(field, location: 7, length: 1)
            #expect(model.mentionReplacementRange == nil)
            _ = field.delegate?.textFieldShouldReturn?(field)
            try await Task.sleep(for: .milliseconds(300))
            #expect(field.text == "hey @al, later")
            #expect(model.autocompleteSuggestions.isEmpty)
            try selectBoundaryRange(field, location: 7)
            try await Task.sleep(for: .milliseconds(300))
            try #require(model.autocompleteSuggestions.contains("@alice"))
            _ = field.delegate?.textFieldShouldReturn?(field)
            try await Task.sleep(for: .milliseconds(300))
            #expect(field.text == "hey @alice, later")
            field.insertText("!")
            try await Task.sleep(for: .milliseconds(300))
            #expect(field.text == "hey @alice!, later")
        }
    }

    @Test @MainActor func mentionSuggestionsRespectFollowingNameCharacters() async throws {
        try await withBoundaryComposer { field, model in
            for suffix in ["ice", "_id", "2", "é", "e\u{301}", "中", "٢", "#abcd"] {
                let text = "hey @al" + suffix + ", later"
                field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
                field.insertText(text)
                try selectBoundaryRange(field, location: 7)
                try await Task.sleep(for: .milliseconds(300))
                #expect(model.autocompleteSuggestions.isEmpty, "Name continuation: \(suffix)")
                #expect(field.text == text)
            }
            for suffix in [", later", " later", ""] {
                field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
                field.insertText("hey @al" + suffix)
                try selectBoundaryRange(field, location: 7)
                try await Task.sleep(for: .milliseconds(300))
                try #require(model.autocompleteSuggestions.contains("@alice"))
                _ = field.delegate?.textFieldShouldReturn?(field)
                try await Task.sleep(for: .milliseconds(300))
                #expect(field.text == "hey @alice" + suffix)
            }
        }
    }
}
extension ViewSmokeTests {
    @Test @MainActor func mentionSuggestionsRejectCaretInsideCombinedCharacter() async throws {
        try await withBoundaryComposer { field, model in
            let text = "hey @al\u{301}, later"
            field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
            field.insertText(text)
            try selectBoundaryRange(field, location: 7)
            try await Task.sleep(for: .milliseconds(300))
            #expect(model.autocompleteSuggestions.isEmpty)
            #expect(field.text == text)
        }
    }
}

extension ViewSmokeTests {
    @Test @MainActor func immediateInvalidSelectionClearsPendingMention() async throws {
        try await withBoundaryComposer { field, model in
            try #require(!model.showAutocomplete)
            field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
            field.insertText("hey @al, later")
            try selectBoundaryRange(field, location: 7)
            try #require(model.mentionReplacementRange != nil)
            // Do not yield between making a candidate and invalidating its selection.
            try selectBoundaryRange(field, location: 7, length: 1)
            #expect(model.mentionReplacementRange == nil)
            try await Task.sleep(for: .milliseconds(300))
            #expect(model.autocompleteSuggestions.isEmpty)
            #expect(!model.showAutocomplete)
            #expect(field.text == "hey @al, later")
        }
    }
}

#endif

extension ViewSmokeTests {
    @Test @MainActor func dismissalClearsPendingAutocomplete() async throws {
        let (viewModel, transport, _) = makeSmokeViewModel()
        transport.peerNicknames[PeerID(str: "1122334455667788")] = "alice"
        let model = makeSmokeFeatureModels(for: viewModel).conversationUIModel
        model.updateAutocomplete(for: "@al", cursorPosition: 3)
        try #require(viewModel.showAutocomplete)
        try #require(!model.showAutocomplete)
        model.dismissAutocomplete()
        #expect(!viewModel.showAutocomplete)
        #expect(viewModel.autocompleteSuggestions.isEmpty)
        #expect(viewModel.autocompleteRange == nil)
        #expect(viewModel.selectedAutocompleteIndex == 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!model.showAutocomplete)
        #expect(model.autocompleteSuggestions.isEmpty)
    }
}
