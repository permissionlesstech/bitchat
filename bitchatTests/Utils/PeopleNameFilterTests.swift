import Testing
@testable import bitchat

struct PeopleNameFilterTests {
    @Test func emptyQueryMatchesEverything() {
        #expect(PeopleNameFilter.matches("alice", query: ""))
        #expect(PeopleNameFilter.matches("alice", query: "   "))
    }

    @Test func matchesAreCaseInsensitive() {
        #expect(PeopleNameFilter.matches("Alice#abcd", query: "ali"))
        #expect(PeopleNameFilter.matches("Bob", query: "BOB"))
    }

    @Test func nonMatchingQueryRejects() {
        #expect(!PeopleNameFilter.matches("alice", query: "bob"))
    }

    @Test func matchesSubstringInsideNickname() {
        #expect(PeopleNameFilter.matches("cool_alice", query: "ali"))
    }
}
