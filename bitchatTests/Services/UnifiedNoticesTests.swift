//
// UnifiedNoticesTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

struct UnifiedNoticesTests {

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    private var baseMs: UInt64 { UInt64(baseDate.timeIntervalSince1970 * 1000) }

    private func makePost(
        content: String,
        nickname: String = "alice",
        createdAt: UInt64? = nil,
        urgent: Bool = false
    ) -> BoardPostPacket {
        BoardPostPacket(
            postID: Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
            geohash: "9q8yy",
            content: content,
            authorSigningKey: Data(repeating: 1, count: 32),
            authorNickname: nickname,
            createdAt: createdAt ?? baseMs,
            expiresAt: (createdAt ?? baseMs) + 24 * 60 * 60 * 1000,
            flags: urgent ? BoardPostPacket.urgentFlag : 0,
            signature: Data(repeating: 2, count: 64)
        )
    }

    private func makeNote(
        content: String,
        nickname: String? = "alice",
        createdAt: Date? = nil,
        geohash: String = "9q8yy"
    ) -> LocationNotesManager.Note {
        LocationNotesManager.Note(
            id: UUID().uuidString,
            pubkey: "ab" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            content: content,
            createdAt: createdAt ?? baseDate,
            nickname: nickname,
            geohash: geohash
        )
    }

    @Test
    func merge_dropsBridgedCopyOfBoardPost() {
        let post = makePost(content: "free couch on 5th")
        let bridged = makeNote(content: "free couch on 5th", createdAt: baseDate.addingTimeInterval(30))

        let merged = UnifiedNotices.merge(posts: [post], notes: [bridged])

        #expect(merged.count == 1)
        #expect(merged[0].isBoardPost)
    }

    @Test
    func merge_keepsNoteWithSameContentOutsideWindow() {
        let post = makePost(content: "water station here")
        let oldNote = makeNote(
            content: "water station here",
            createdAt: baseDate.addingTimeInterval(-UnifiedNotices.bridgeDedupeWindow - 60)
        )

        let merged = UnifiedNotices.merge(posts: [post], notes: [oldNote])

        #expect(merged.count == 2)
    }

    @Test
    func merge_keepsSameTextNoteFromNeighborCell() {
        // The notes subscription covers the center cell plus 8 neighbors; a
        // matching note posted to a *neighbor* is not the bridged copy.
        let post = makePost(content: "free couch on 5th")
        let neighborNote = makeNote(content: "free couch on 5th", createdAt: baseDate.addingTimeInterval(30), geohash: "9q8yz")

        let merged = UnifiedNotices.merge(posts: [post], notes: [neighborNote])

        #expect(merged.count == 2)
    }

    @Test
    func merge_keepsNoteFromDifferentAuthor() {
        let post = makePost(content: "meetup at 6", nickname: "alice")
        let note = makeNote(content: "meetup at 6", nickname: "bob")

        let merged = UnifiedNotices.merge(posts: [post], notes: [note])

        #expect(merged.count == 2)
    }

    @Test
    func merge_sortsUrgentFirstThenNewest() {
        let urgent = makePost(content: "road closed", createdAt: baseMs - 60_000, urgent: true)
        let newerPost = makePost(content: "later post", createdAt: baseMs)
        let note = makeNote(content: "a note", nickname: "carol", createdAt: baseDate.addingTimeInterval(30))

        let merged = UnifiedNotices.merge(posts: [newerPost, urgent], notes: [note])

        #expect(merged.map(\.content) == ["road closed", "a note", "later post"])
        #expect(merged[0].isUrgent)
    }

    @Test
    func merge_anonNicknamesMatchForDedupe() {
        // Bridged posts from an empty nickname arrive as anon notes with no
        // "n" tag; they must still dedupe against the anon board copy.
        let post = makePost(content: "hello", nickname: "")
        let bridged = makeNote(content: "hello", nickname: nil)

        let merged = UnifiedNotices.merge(posts: [post], notes: [bridged])

        #expect(merged.count == 1)
        #expect(merged[0].isBoardPost)
        #expect(merged[0].author == "anon")
    }

    @Test
    func noticeItem_normalizesNoteDisplayName() {
        let note = LocationNotesManager.Note(
            id: "e1",
            pubkey: "deadbeef",
            content: "hi",
            createdAt: baseDate,
            nickname: "dave",
            geohash: "9q8yy"
        )

        let item = NoticeItem(note: note)

        #expect(item.author == "dave")
        #expect(!item.isBoardPost)
        #expect(!item.isUrgent)
    }
}
