//
// GeohashParticipantTrackerTests.swift
// bitchatTests
//
// Tests for GeohashParticipantTracker.
// This is free and unencumbered software released into the public domain.
//

import Testing
import Foundation
@testable import bitchat

/// Mock context for testing
@MainActor
final class MockParticipantContext: GeohashParticipantContext {
    var blockedPubkeys: Set<String> = []
    var nicknameMap: [String: String] = [:]
    var selfPubkey: String?

    func displayNameForPubkey(_ pubkeyHex: String) -> String {
        let suffix = String(pubkeyHex.suffix(4))
        if let self = selfPubkey, pubkeyHex.lowercased() == self.lowercased() {
            return "me#\(suffix)"
        }
        if let nick = nicknameMap[pubkeyHex.lowercased()] {
            return "\(nick)#\(suffix)"
        }
        return "anon#\(suffix)"
    }

    func isBlocked(_ pubkeyHexLowercased: String) -> Bool {
        blockedPubkeys.contains(pubkeyHexLowercased.lowercased())
    }
}

@MainActor
struct GeohashParticipantTrackerTests {

    // MARK: - Basic Recording Tests

    @Test func recordParticipant_addsToActiveGeohash() async {
        let tracker = GeohashParticipantTracker()
        let context = MockParticipantContext()
        tracker.configure(context: context)
        tracker.setActiveGeohash("abc123")

        tracker.recordParticipant(pubkeyHex: "deadbeef1234")

        #expect(tracker.participantCount(for: "abc123") == 1)
    }

    @Test func recordParticipant_noActiveGeohash_noOp() async {
        let tracker = GeohashParticipantTracker()
        let context = MockParticipantContext()
        tracker.configure(context: context)
        // No active geohash set

        tracker.recordParticipant(pubkeyHex: "deadbeef1234")

        // Should not throw or crash
        #expect(tracker.participantCount(for: "abc123") == 0)
    }

    @Test func recordParticipant_specificGeohash() async {
        let tracker = GeohashParticipantTracker()
        let context = MockParticipantContext()
        tracker.configure(context: context)

        tracker.recordParticipant(pubkeyHex: "pubkey1", geohash: "geo1")
        tracker.recordParticipant(pubkeyHex: "pubkey2", geohash: "geo2")

        #expect(tracker.participantCount(for: "geo1") == 1)
        #expect(tracker.participantCount(for: "geo2") == 1)
    }

    @Test func recordParticipant_updatesLastSeen() async {
        let tracker = GeohashParticipantTracker()
        let context = MockParticipantContext()
        tracker.configure(context: context)
        tracker.setActiveGeohash("abc123")

        tracker.recordParticipant(pubkeyHex: "pubkey1")
        // Small delay and record again
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        tracker.recordParticipant(pubkeyHex: "pubkey1")

        // Should still count as 1 participant (updated, not duplicated)
        #expect(tracker.participantCount(for: "abc123") == 1)
    }

    @Test func recordParticipant_lowercasesPubkey() async {
        let tracker = GeohashParticipantTracker()
        let context = MockParticipantContext()
        tracker.configure(context: context)
        tracker.setActiveGeohash("abc123")

        tracker.recordParticipant(pubkeyHex: "DEADBEEF")
        tracker.recordParticipant(pubkeyHex: "deadbeef")

        // Should be treated as same participant
        #expect(tracker.participantCount(for: "abc123") == 1)
    }

    // MARK: - Visible People Tests

    @Test func getVisiblePeople_returnsActiveGeohashParticipants() async {
        let tracker = GeohashParticipantTracker()
        let context = MockParticipantContext()
        tracker.configure(context: context)
        tracker.setActiveGeohash("abc123")

        tracker.recordParticipant(pubkeyHex: "pubkey1")
        tracker.recordParticipant(pubkeyHex: "pubkey2")

        let people = tracker.getVisiblePeople()
        #expect(people.count == 2)
    }

    @Test func getVisiblePeople_excludesBlockedParticipants() async {
        let tracker = GeohashParticipantTracker()
        let context = MockParticipantContext()
        context.blockedPubkeys = ["pubkey2"]
        tracker.configure(context: context)
        tracker.setActiveGeohash("abc123")

        tracker.recordParticipant(pubkeyHex: "pubkey1")
        tracker.recordParticipant(pubkeyHex: "pubkey2")

        let people = tracker.getVisiblePeople()
        #expect(people.count == 1)
        #expect(people.first?.id == "pubkey1")
    }

    @Test func getVisiblePeople_usesDisplayNameFromContext() async {
        let tracker = GeohashParticipantTracker()
        let context = MockParticipantContext()
        context.nicknameMap = ["pubkey1234": "alice"]
        tracker.configure(context: context)
        tracker.setActiveGeohash("abc123")

        tracker.recordParticipant(pubkeyHex: "pubkey1234")

        let people = tracker.getVisiblePeople()
        #expect(people.count == 1)
        #expect(people.first?.displayName == "alice#1234")
    }

    @Test func getVisiblePeople_sortedByLastSeen() async {
        let tracker = GeohashParticipantTracker()
        let context = MockParticipantContext()
        tracker.configure(context: context)
        tracker.setActiveGeohash("abc123")

        tracker.recordParticipant(pubkeyHex: "older")
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        tracker.recordParticipant(pubkeyHex: "newer")

        let people = tracker.getVisiblePeople()
        #expect(people.count == 2)
        #expect(people.first?.id == "newer")
        #expect(people.last?.id == "older")
    }

    @Test func getVisiblePeople_emptyWhenNoActiveGeohash() async {
        let tracker = GeohashParticipantTracker()
        let context = MockParticipantContext()
        tracker.configure(context: context)

        tracker.recordParticipant(pubkeyHex: "pubkey1", geohash: "abc123")

        let people = tracker.getVisiblePeople()
        #expect(people.isEmpty)
    }

    // MARK: - Activity Cutoff Tests

    @Test func participantCount_excludesExpiredEntries() async {
        // Use a very short cutoff for testing
        let tracker = GeohashParticipantTracker(activityCutoff: -0.05) // 50ms cutoff
        let context = MockParticipantContext()
        tracker.configure(context: context)
        tracker.setActiveGeohash("abc123")

        tracker.recordParticipant(pubkeyHex: "pubkey1")

        // Should be counted immediately
        #expect(tracker.participantCount(for: "abc123") == 1)

        // Wait for expiry
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Should be expired now
        #expect(tracker.participantCount(for: "abc123") == 0)
    }

    // MARK: - Remove Participant Tests

    @Test func removeParticipant_removesFromAllGeohashes() async {
        let tracker = GeohashParticipantTracker()
        let context = MockParticipantContext()
        tracker.configure(context: context)

        tracker.recordParticipant(pubkeyHex: "pubkey1", geohash: "geo1")
        tracker.recordParticipant(pubkeyHex: "pubkey1", geohash: "geo2")
        tracker.recordParticipant(pubkeyHex: "pubkey2", geohash: "geo1")

        tracker.removeParticipant(pubkeyHex: "pubkey1")

        #expect(tracker.participantCount(for: "geo1") == 1)
        #expect(tracker.participantCount(for: "geo2") == 0)
    }

    // MARK: - Clear Tests

    @Test func clear_removesAllData() async {
        let tracker = GeohashParticipantTracker()
        let context = MockParticipantContext()
        tracker.configure(context: context)
        tracker.setActiveGeohash("abc123")

        tracker.recordParticipant(pubkeyHex: "pubkey1")
        tracker.recordParticipant(pubkeyHex: "pubkey2", geohash: "other")

        tracker.clear()

        #expect(tracker.participantCount(for: "abc123") == 0)
        #expect(tracker.participantCount(for: "other") == 0)
        #expect(tracker.visiblePeople.isEmpty)
    }

    @Test func clearGeohash_removesOnlySpecificGeohash() async {
        let tracker = GeohashParticipantTracker()
        let context = MockParticipantContext()
        tracker.configure(context: context)

        tracker.recordParticipant(pubkeyHex: "pubkey1", geohash: "geo1")
        tracker.recordParticipant(pubkeyHex: "pubkey2", geohash: "geo2")

        tracker.clear(geohash: "geo1")

        #expect(tracker.participantCount(for: "geo1") == 0)
        #expect(tracker.participantCount(for: "geo2") == 1)
    }

    // MARK: - Set Active Geohash Tests

    @Test func setActiveGeohash_clearsVisiblePeopleWhenNil() async {
        let tracker = GeohashParticipantTracker()
        let context = MockParticipantContext()
        tracker.configure(context: context)
        tracker.setActiveGeohash("abc123")
        tracker.recordParticipant(pubkeyHex: "pubkey1")

        #expect(!tracker.visiblePeople.isEmpty)

        tracker.setActiveGeohash(nil)

        #expect(tracker.visiblePeople.isEmpty)
    }

    @Test func setActiveGeohash_refreshesVisiblePeople() async {
        let tracker = GeohashParticipantTracker()
        let context = MockParticipantContext()
        tracker.configure(context: context)

        // Pre-populate a geohash
        tracker.recordParticipant(pubkeyHex: "pubkey1", geohash: "abc123")

        // Set it as active
        tracker.setActiveGeohash("abc123")

        #expect(tracker.visiblePeople.count == 1)
    }

    // MARK: - GeoPerson Tests

    @Test func geoPerson_identifiable() async {
        let person1 = GeoPerson(id: "abc", displayName: "alice", lastSeen: Date())
        let person2 = GeoPerson(id: "abc", displayName: "alice", lastSeen: Date())
        let person3 = GeoPerson(id: "xyz", displayName: "bob", lastSeen: Date())

        #expect(person1.id == person2.id)
        #expect(person1.id != person3.id)
    }

    @Test func geoPerson_equatable() async {
        let date = Date()
        let person1 = GeoPerson(id: "abc", displayName: "alice", lastSeen: date)
        let person2 = GeoPerson(id: "abc", displayName: "alice", lastSeen: date)

        #expect(person1 == person2)
    }
}
