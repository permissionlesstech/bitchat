//
// InMemoryComposerDraftStore.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

@testable import bitchat

/// Parks drafts in its own map, keeping the process-wide `ComposerDraftStore`
/// out of the test, and records every load and save so a test can tell a
/// hand-over between composers from a round trip through the store.
final class InMemoryComposerDraftStore: ComposerDraftStoring {
    private(set) var drafts: [ComposerDraftStore.Key: String] = [:]
    private(set) var loads: [ComposerDraftStore.Key] = []
    private(set) var saves: [(key: ComposerDraftStore.Key, text: String)] = []

    init(_ drafts: [ComposerDraftStore.Key: String] = [:]) {
        self.drafts = drafts
    }

    func load(_ key: ComposerDraftStore.Key) -> String {
        loads.append(key)
        return drafts[key] ?? ""
    }

    /// Like the app's store: an empty text drops the draft.
    func save(_ text: String, for key: ComposerDraftStore.Key) {
        saves.append((key, text))
        drafts[key] = text.isEmpty ? nil : text
    }

    /// Forgets the recorded calls, keeping the drafts.
    func clearLog() {
        loads.removeAll()
        saves.removeAll()
    }

    /// A panic wipe, like `ComposerDraftStore.reset()`: every draft goes.
    func wipe() {
        drafts.removeAll()
    }
}
