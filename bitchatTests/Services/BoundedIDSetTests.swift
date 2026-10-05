//
// BoundedIDSetTests.swift
// bitchatTests
//
// Tests for BoundedIDSet insertion-ordered eviction
//

import Testing
@testable import bitchat

struct BoundedIDSetTests {

    @Test func insertReturnsFalseForAlreadyPresentID() {
        var set = BoundedIDSet(capacity: 3)
        set.insert("a")
        #expect(set.insert("a") == false)
    }




}
