//
// ConversationStoreLastActiveTests.swift
// bitchatTests
//
// Tests for #1064 last-active persistence: ConversationStore records the
// foreground conversation on every switch and, at the next launch, decides
// what to present — a persisted DM or a first-ever launch presents the
// conversation list, and a public channel defers to the existing
// GeoChannelCoordinator restore.
//
// Launch never re-opens the DM itself. The tests below pin that as a
// property, not an implementation detail: it is what keeps startup from
// disclosing a contact's name and message history to whoever is holding
// the phone.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import XCTest
@testable import bitchat

@MainActor
final class ConversationStoreLastActiveTests: XCTestCase {
    /// A structurally valid short (16-hex) peer id.
    private let peerID = PeerID(str: "0123456789abcdef")

    func test_persistsLastActiveOnEverySwitch() {
        let storage = makeStorage()

        // Open a DM: the next launch presents the list.
        let session1 = ConversationStore(storage: storage)
        session1.setSelectedPrivatePeer(peerID)
        XCTAssertEqual(
            ConversationStore(storage: storage).restoreLastActiveConversation(),
            .conversationList
        )

        // Close the DM back to the mesh channel: the write must happen again,
        // so the next launch now defers to the channel restore.
        session1.setSelectedPrivatePeer(nil)
        XCTAssertEqual(
            ConversationStore(storage: storage).restoreLastActiveConversation(),
            .deferToChannelRestore
        )
    }

    func test_persistedDirectChatPresentsTheListAndNeverTheChat() {
        // The security property this design turns on: whatever was persisted,
        // a DM never re-opens itself at launch. There is deliberately no
        // "restorable peer" branch to take — a favorite, a merely-known peer
        // and a stale one all land on the list — so no addressability check
        // can put a name and a history on screen before anyone asked.
        let storage = makeStorage()
        ConversationStore(storage: storage).setSelectedPrivatePeer(peerID)

        XCTAssertEqual(
            ConversationStore(storage: storage).restoreLastActiveConversation(),
            .conversationList
        )
    }

    func test_launchDefersToChannelRestore_forAPersistedPublicChannel() {
        // A public-channel restore is owned by GeoChannelCoordinator; the
        // launch decision must not present the list on top of it.
        let storage = makeStorage()
        let session = ConversationStore(storage: storage)
        session.setSelectedPrivatePeer(peerID)
        session.setSelectedPrivatePeer(nil)

        XCTAssertEqual(
            ConversationStore(storage: storage).restoreLastActiveConversation(),
            .deferToChannelRestore
        )
    }

    func test_failedDirectRestoreDoesNotEraseDirectRecord() {
        // #1064: a redundant channel re-apply must not clobber a persisted DM.
        let storage = makeStorage()

        // Session 1: the user is in a DM — persists a `.direct` record.
        ConversationStore(storage: storage).setSelectedPrivatePeer(peerID)

        // Session 2 (launch): a fresh store starts with no private peer
        // selected, and GeoChannelCoordinator re-asserts the SAME (default
        // mesh) active channel. Because the channel does not actually change,
        // the persist is guarded out — so the `.direct` record on disk must
        // survive rather than be overwritten with `.mesh`. The distinction
        // still matters with the DM no longer re-opening: `.direct` presents
        // the list, `.mesh` would defer to the channel restore instead.
        let launch = ConversationStore(storage: storage)
        launch.setActiveChannel(launch.activeChannel)

        // Session 3: the DM record is intact, so launch still presents the list.
        XCTAssertEqual(
            ConversationStore(storage: storage).restoreLastActiveConversation(),
            .conversationList
        )
    }

    func test_clearPersistedLastActiveErasesRestoreRecord() {
        // #1064 panic wipe: clearing the persisted last-active pointer means a
        // wiped DM/channel cannot be restored on the next launch.
        let storage = makeStorage()

        // A channel record is persisted and would otherwise defer.
        let session = ConversationStore(storage: storage)
        session.setSelectedPrivatePeer(peerID)
        session.setSelectedPrivatePeer(nil)
        XCTAssertEqual(
            ConversationStore(storage: storage).restoreLastActiveConversation(),
            .deferToChannelRestore
        )

        // The panic path erases the pointer through the store's own storage.
        session.clearPersistedLastActive()

        // The next launch has nothing to restore and falls back to the list.
        XCTAssertEqual(
            ConversationStore(storage: storage).restoreLastActiveConversation(),
            .conversationList
        )
    }

    func test_panicWipeOrderLeavesNoRestoreRecord() {
        // #1064 panic wipe, FULL ORDER: `clearPersistedLastActive()` alone is
        // insufficient because `panicClearAllData()` also runs
        // `selectedPrivateChatPeer = nil` and `activeChannel = .mesh` AFTER it —
        // both route through the store's setters, whose guarded
        // `persistLastActive()` re-writes a `.mesh` record on a real state
        // change, resurrecting the pointer. The begin/finish suppression window
        // fixes that. This test mirrors panicClearAllData's exact order:
        //   beginPanicWipe → setSelectedPrivatePeer(nil) → setActiveChannel(.mesh) → finishPanicWipe
        // Without the fix those resets re-persist a `.mesh` record, and the next
        // launch would `.deferToChannelRestore` instead of `.conversationList`.
        //
        // The presentation assertion alone is NOT enough, and the earlier
        // version of this comment overclaimed. `.conversationList` is the
        // answer for an absent record AND for a surviving `.direct` one, so a
        // regression where `finishPanicWipe` stopped removing the key while
        // suppression still worked would leave the peer id on disk and this
        // test would stay green. For a panic wipe that is the whole point of
        // the feature, so assert the stored key is gone, not just that launch
        // looks right.
        let storage = makeStorage()

        let session = ConversationStore(storage: storage)
        session.setSelectedPrivatePeer(peerID)

        // Reproduce panicClearAllData's order on the SAME store.
        session.beginPanicWipe()
        session.setSelectedPrivatePeer(nil)   // re-persist trigger #1 (suppressed)
        session.setActiveChannel(.mesh)       // re-persist trigger #2 (suppressed)
        session.finishPanicWipe()             // removes the pointer once

        // The pointer is truly absent, not rewritten as `.mesh` and not left
        // behind as `.direct`. This is the only assertion that separates
        // "erased" from "still on disk", since both present as
        // `.conversationList` at launch. Asked through the store rather than
        // by key literal: a literal here would go quietly vacuous the day the
        // key is renamed, checking a string nothing writes.
        XCTAssertFalse(ConversationStore(storage: storage)._test_hasPersistedLastActive)

        // And launch presents the list rather than deferring to a resurrected
        // `.mesh` record — the suppression half of the same fix.
        XCTAssertEqual(
            ConversationStore(storage: storage).restoreLastActiveConversation(),
            .conversationList
        )
    }

    // MARK: - Launch decision

    func test_launchPresentsTheListForAConversationListPresentation() {
        XCTAssertTrue(AppRuntime.shouldPresentConversationList(for: .conversationList))
    }

    func test_launchLeavesAPublicChannelRestoreAlone() {
        // Inverting this is how a geohash restore would end up buried under the
        // people sheet, or a DM launch would land on the public timeline.
        XCTAssertFalse(AppRuntime.shouldPresentConversationList(for: .deferToChannelRestore))
    }

    func test_firstLaunchPresentsConversationList() {
        let storage = makeStorage()

        XCTAssertEqual(
            ConversationStore(storage: storage).restoreLastActiveConversation(),
            .conversationList
        )
    }

    // MARK: - Helpers

    private func makeStorage() -> UserDefaults {
        let suiteName = "ConversationStoreLastActiveTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        storage.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            storage.removePersistentDomain(forName: suiteName)
        }
        return storage
    }
}
