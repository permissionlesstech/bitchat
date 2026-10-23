//
// MessageListViewTests.swift
// bitchatTests
//
// Each message list observes exactly one timeline model, the one it renders,
// so a message in another timeline never re-renders it: the open DM beside
// the split layout's #mesh pane, or #mesh under a DM. Read off the views'
// own observing properties by reflection; rendering stays per pane only if
// no list holds the other timeline's model.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import SwiftUI
import Testing
@testable import bitchat

/// The `ObservableObject` types `view` observes through its own stored
/// properties: `@EnvironmentObject`, `@ObservedObject`, `@StateObject`.
private func observedModelTypes(of view: Any) -> Set<String> {
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

/// The first value under `root` (itself included) whose type name starts
/// with `prefix`, searched breadth-first through stored properties and enum
/// payloads.
private func firstValue(under root: Any, typeNamePrefix prefix: String) -> Any? {
    var level: [Any] = [root]
    for _ in 0..<4 {
        if let match = level.first(where: { String(describing: type(of: $0)).hasPrefix(prefix) }) {
            return match
        }
        level = level.flatMap { Mirror(reflecting: $0).children.map(\.value) }
    }
    return nil
}

@MainActor
private func makeList(privatePeer: PeerID?, focus: FocusState<Bool>) -> MessageListView {
    MessageListView(
        privatePeer: privatePeer,
        isAtBottom: .constant(true),
        messageText: .constant(""),
        selectedMessageSender: .constant(nil),
        selectedMessageSenderID: .constant(nil),
        imagePreviewURL: .constant(nil),
        windowCountPublic: .constant(TransportConfig.uiWindowInitialCountPublic),
        windowCountPrivate: .constant([:]),
        showSidebar: .constant(false),
        isTextFieldFocused: focus.projectedValue
    )
}

@Suite("MessageListView")
@MainActor
struct MessageListViewTests {
    @Test("a public list observes its public timeline and not the private inbox")
    func publicList_observesOnlyItsPublicTimeline() throws {
        let list = makeList(privatePeer: nil, focus: FocusState<Bool>())
        // The list itself decides which timeline to render; it observes none.
        #expect(observedModelTypes(of: list).isEmpty)

        let content = try #require(firstValue(under: list.body, typeNamePrefix: "MessageListContent<"))
        let observed = observedModelTypes(of: content)
        #expect(observed.contains("PublicChatModel"), "\(observed)")
        #expect(!observed.contains("PrivateInboxModel"), "\(observed)")
    }

    @Test("a DM list observes the private inbox and not a public timeline")
    func privateList_observesOnlyThePrivateInbox() throws {
        let list = makeList(privatePeer: PeerID(str: "0102030405060708"), focus: FocusState<Bool>())
        #expect(observedModelTypes(of: list).isEmpty)

        let content = try #require(firstValue(under: list.body, typeNamePrefix: "MessageListContent<"))
        let observed = observedModelTypes(of: content)
        #expect(observed.contains("PrivateInboxModel"), "\(observed)")
        #expect(!observed.contains("PublicChatModel"), "\(observed)")
    }
}
