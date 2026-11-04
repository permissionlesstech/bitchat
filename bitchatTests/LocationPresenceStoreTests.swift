//
// LocationPresenceStoreTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import Testing
@testable import bitchat

@MainActor
struct LocationPresenceStoreTests {

    @Test func setNickname_reportsWhetherTheNameChanged() {
        let store = LocationPresenceStore()

        #expect(store.setNickname("alice", for: "AA") == true)
        // Chat events repeat the sender's nickname every time.
        #expect(store.setNickname("alice", for: "aa") == false)
        #expect(store.setNickname("alicia", for: "aa") == true)
        #expect(store.geoNicknames["aa"] == "alicia")
    }

    /// Every write republishes, and the people list rebuilds on these
    /// publishers, so pruning that removes nothing must not write.
    @Test func pruningThatRemovesNothingDoesNotRepublish() {
        let store = LocationPresenceStore()
        store.markTeleported("aa")
        store.setNickname("alice", for: "aa")

        var changes = 0
        let cancellable = store.objectWillChange.sink { _ in changes += 1 }
        store.retainTeleportedGeo(keeping: ["aa", "bb"])
        store.clearTeleported("cc")
        #expect(changes == 0)

        store.retainTeleportedGeo(keeping: ["bb"])
        #expect(changes == 1)
        #expect(store.teleportedGeo.isEmpty)
        _ = cancellable
    }
}
