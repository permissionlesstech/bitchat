//
// ContentViewObservationTests.swift
// bitchatTests
//
// The root view observes no model that publishes per message or per roster
// change (I6): it passes the selection's timeline, the private inbox and the
// people lists on to its sheets as plain references, and the views that
// render them observe them. Observing them at the root would re-render the
// root, and both panes of the split layout, on every message. Read off the
// root's own observing properties by reflection.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import Testing
@testable import bitchat

/// The `ObservableObject` types `view` observes through its own stored
/// properties: `@EnvironmentObject`, `@ObservedObject`, `@StateObject`.
private func observedTypes(of view: Any) -> Set<String> {
    let wrappers = ["EnvironmentObject<", "ObservedObject<", "StateObject<"]
    var types = Set<String>()
    for child in Mirror(reflecting: view).children {
        let typeName = String(describing: type(of: child.value))
        for wrapper in wrappers where typeName.hasPrefix(wrapper) {
            types.insert(String(typeName.dropFirst(wrapper.count).dropLast()))
        }
    }
    return types
}

@Suite("ContentView observation")
@MainActor
struct ContentViewObservationTests {
    @Test("the root observes no per-message model")
    func rootObservesNoPerMessageModel() {
        let observed = observedTypes(of: ContentView())

        #expect(!observed.contains("PublicChatModel"), "\(observed)")
        #expect(!observed.contains("PrivateInboxModel"), "\(observed)")
        #expect(!observed.contains("PeerListModel"), "\(observed)")
        // The reflection does see what the root observes.
        #expect(observed.contains("AppChromeModel"), "\(observed)")
    }
}
