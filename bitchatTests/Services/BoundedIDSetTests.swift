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

    @Test func evictsOldestWhenOverCapacity() {
        var set = BoundedIDSet(capacity: 2)
        set.insert("a")
        set.insert("b")
        set.insert("c")

        #expect(set.contains("a") == false)
        #expect(set.contains("b"))
        #expect(set.contains("c"))
    }

    @Test func evictedIDCanBeReinserted() {
        var set = BoundedIDSet(capacity: 1)
        set.insert("a")
        set.insert("b") // evicts "a"

        #expect(set.insert("a") == true)
        #expect(set.contains("a"))
        #expect(set.contains("b") == false)
    }


}
