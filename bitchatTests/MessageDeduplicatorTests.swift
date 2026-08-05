//
// MessageDeduplicatorTests.swift
// bitchatTests
//
// Tests for MessageDeduplicator.
// This is free and unencumbered software released into the public domain.
//

import Foundation
import Testing
@testable import bitchat

@Suite("Message Deduplicator")
struct MessageDeduplicatorTests {
    @Test func markProcessed_enforcesMaximumCount() {
        let deduplicator = MessageDeduplicator(maxAge: 300, maxCount: 4)

        for id in ["a", "b", "c", "d", "e"] {
            deduplicator.markProcessed(id)
        }

        #expect(!deduplicator.contains("a"))
        #expect(!deduplicator.contains("b"))
        #expect(deduplicator.contains("c"))
        #expect(deduplicator.contains("d"))
        #expect(deduplicator.contains("e"))
    }

    @Test func markProcessed_cleansExpiredEntriesBeforeCountTrim() async {
        let deduplicator = MessageDeduplicator(maxAge: 0.1, maxCount: 4)

        deduplicator.markProcessed("expired")
        try? await Task.sleep(nanoseconds: 200_000_000)

        for id in ["b", "c", "d", "e"] {
            deduplicator.markProcessed(id)
        }

        #expect(deduplicator.contains("b"))
        #expect(deduplicator.contains("c"))
        #expect(deduplicator.contains("d"))
        #expect(deduplicator.contains("e"))
    }
}
