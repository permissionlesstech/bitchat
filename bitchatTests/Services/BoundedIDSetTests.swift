//
// BoundedIDSetTests.swift
// bitchatTests
//
// Tests for BoundedIDSet insertion-ordered eviction
//

import Testing
@testable import bitchat

struct BoundedIDSetTests {

    @Test func insertReturnsTrueForNewID() {
        var set = BoundedIDSet(capacity: 3)
        #expect(set.insert("a") == true)
        #expect(set.contains("a"))
    }

    @Test func insertReturnsFalseForAlreadyPresentID() {
        var set = BoundedIDSet(capacity: 3)
        set.insert("a")
        #expect(set.insert("a") == false)
    }

    @Test func containsIsFalseForUnknownID() {
        let set = BoundedIDSet(capacity: 3)
        #expect(set.contains("missing") == false)
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

    @Test func stayingUnderCapacityKeepsEverything() {
        var set = BoundedIDSet(capacity: 5)
        for id in ["a", "b", "c"] {
            set.insert(id)
        }

        #expect(set.contains("a"))
        #expect(set.contains("b"))
        #expect(set.contains("c"))
    }

    @Test func capacityOneKeepsOnlyMostRecentID() {
        var set = BoundedIDSet(capacity: 1)
        set.insert("a")
        set.insert("b")
        set.insert("c")

        #expect(set.contains("a") == false)
        #expect(set.contains("b") == false)
        #expect(set.contains("c"))
    }

    @Test func duplicateInsertDoesNotDisturbEvictionOrder() {
        // Re-inserting an already-present ID is a no-op (returns false) and
        // must not move it in the eviction queue or add a second entry.
        var set = BoundedIDSet(capacity: 2)
        set.insert("a")
        set.insert("b")
        set.insert("a") // no-op: "a" is already present

        set.insert("c") // over capacity: should evict "a" (still the oldest)

        #expect(set.contains("a") == false)
        #expect(set.contains("b"))
        #expect(set.contains("c"))
    }
}
