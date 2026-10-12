//
// BoardAlertsModelTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import Foundation
import Testing
@testable import bitchat

@MainActor
struct BoardAlertsModelTests {

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    private var baseMs: UInt64 { UInt64(baseDate.timeIntervalSince1970 * 1000) }
    private let ownKey = Data(repeating: 7, count: 32)

    private final class Harness {
        var lines: [(content: String, geohash: String)] = []
        var pendingFlushes: [@MainActor () -> Void] = []

        @MainActor
        func flushAll() {
            let flushes = pendingFlushes
            pendingFlushes = []
            for flush in flushes { flush() }
        }
    }

    private func makeModel(
        harness: Harness,
        now: Date? = nil,
        confirmation: @escaping @MainActor (BoardEndorsementPacket) -> (post: BoardPostPacket, trustedCount: Int)? = { _ in nil }
    ) -> BoardAlertsModel {
        let fixedNow = now ?? baseDate
        return BoardAlertsModel(
            arrivals: Empty(completeImmediately: false).eraseToAnyPublisher(),
            dependencies: BoardAlertsModel.Dependencies(
                isOwnPost: { [ownKey] in $0.authorSigningKey == ownKey },
                emitSystemLine: { content, geohash in
                    harness.lines.append((content, geohash))
                },
                confirmation: confirmation,
                now: { fixedNow },
                scheduleFlush: { flush in
                    harness.pendingFlushes.append(flush)
                }
            )
        )
    }

    private func makePost(
        content: String = "hello",
        geohash: String = "9q8yy",
        nickname: String = "alice",
        createdAt: UInt64? = nil,
        urgent: Bool = false,
        authorKey: Data = Data(repeating: 1, count: 32),
        postID: Data? = nil
    ) -> BoardPostPacket {
        BoardPostPacket(
            postID: postID ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
            geohash: geohash,
            content: content,
            authorSigningKey: authorKey,
            authorNickname: nickname,
            createdAt: createdAt ?? baseMs,
            expiresAt: (createdAt ?? baseMs) + 24 * 60 * 60 * 1000,
            flags: urgent ? BoardPostPacket.urgentFlag : 0,
            signature: Data(repeating: 2, count: 64)
        )
    }

    @Test
    func ownPosts_neverBadgeOrAlert() {
        let harness = Harness()
        let model = makeModel(harness: harness)

        model.handleArrival(makePost(urgent: true, authorKey: ownKey))
        harness.flushAll()

        #expect(model.unseenCount(forGeohash: "9q8yy") == 0)
        #expect(harness.lines.isEmpty)
    }

    @Test
    func routinePost_badgesWithoutChatLine() {
        let harness = Harness()
        let model = makeModel(harness: harness)

        model.handleArrival(makePost(geohash: ""))
        harness.flushAll()

        #expect(model.unseenCount(forGeohash: "") == 1)
        #expect(model.unseenCount(forGeohash: "9q8yy") == 0)
        #expect(harness.lines.isEmpty)
    }

    @Test
    func urgentRecentPost_emitsLineInMatchingScope() {
        let harness = Harness()
        let model = makeModel(harness: harness)

        model.handleArrival(makePost(content: "road closed", geohash: "9q8yy", urgent: true))
        #expect(harness.lines.isEmpty)
        harness.flushAll()

        #expect(harness.lines.count == 1)
        #expect(harness.lines[0].geohash == "9q8yy")
        #expect(harness.lines[0].content.contains("road closed"))
        #expect(harness.lines[0].content.contains("@alice"))
    }

    @Test
    func urgentBackfilledPost_badgesOnly() {
        let harness = Harness()
        let arrivalTime = baseDate.addingTimeInterval(BoardAlertsModel.inlineRecencyWindow + 120)
        let model = makeModel(harness: harness, now: arrivalTime)

        model.handleArrival(makePost(createdAt: baseMs, urgent: true))
        harness.flushAll()

        #expect(model.unseenCount(forGeohash: "9q8yy") == 1)
        #expect(harness.lines.isEmpty)
    }

    @Test
    func simultaneousUrgentPosts_collapseIntoOneLine() {
        let harness = Harness()
        let model = makeModel(harness: harness)

        model.handleArrival(makePost(content: "one", urgent: true))
        model.handleArrival(makePost(content: "two", urgent: true))
        model.handleArrival(makePost(content: "three", urgent: true))
        harness.flushAll()

        #expect(harness.lines.count == 1)
        #expect(harness.lines[0].content.contains("3"))
        #expect(harness.pendingFlushes.isEmpty)
    }

    @Test
    func urgentPostsInDifferentScopes_alertEachScope() {
        let harness = Harness()
        let model = makeModel(harness: harness)

        model.handleArrival(makePost(content: "geo pin", geohash: "9q8yy", urgent: true))
        model.handleArrival(makePost(content: "mesh pin", geohash: "", urgent: true))
        harness.flushAll()

        #expect(harness.lines.count == 2)
        #expect(Set(harness.lines.map(\.geohash)) == ["9q8yy", ""])
    }

    @Test
    func duplicateArrival_isHandledOnce() {
        let harness = Harness()
        let model = makeModel(harness: harness)
        let id = Data(repeating: 3, count: 16)

        model.handleArrival(makePost(urgent: true, postID: id))
        model.handleArrival(makePost(urgent: true, postID: id))
        harness.flushAll()

        #expect(model.unseenCount(forGeohash: "9q8yy") == 1)
        #expect(harness.lines.count == 1)
        #expect(!harness.lines[0].content.contains("2"))
    }

    @Test
    func markSeen_clearsOnlyVisibleScopes() {
        let harness = Harness()
        let model = makeModel(harness: harness)

        model.handleArrival(makePost(geohash: ""))
        model.handleArrival(makePost(geohash: "9q8yy"))
        model.handleArrival(makePost(geohash: "u4pruyd"))

        // Opening the sheet on mesh + 9q8yy must not eat the badge for the
        // never-shown u4pruyd channel.
        model.markSeen(forScopes: ["", "9q8yy"])

        #expect(model.unseenCount(forGeohash: "") == 0)
        #expect(model.unseenCount(forGeohash: "9q8yy") == 0)
        #expect(model.unseenCount(forGeohash: "u4pruyd") == 1)
    }

    @Test
    func reset_dropsPendingUrgentLinesAndBadges() {
        let harness = Harness()
        let model = makeModel(harness: harness)

        model.handleArrival(makePost(content: "pre-wipe secret", urgent: true))
        #expect(harness.pendingFlushes.count == 1)

        // Panic wipe lands before the collapse flush fires.
        model.reset()
        harness.flushAll()

        #expect(harness.lines.isEmpty)
        #expect(model.unseenCount(forGeohash: "9q8yy") == 0)
    }

    @Test
    func longUrgentContent_isTruncatedInLine() {
        let harness = Harness()
        let model = makeModel(harness: harness)
        let long = String(repeating: "a", count: 400)

        model.handleArrival(makePost(content: long, urgent: true))
        harness.flushAll()

        #expect(harness.lines.count == 1)
        #expect(harness.lines[0].content.count < 200)
        #expect(harness.lines[0].content.contains("…"))
    }

    // MARK: - Trusted confirmations

    private func endorsement(of post: BoardPostPacket) -> BoardEndorsementPacket {
        BoardEndorsementPacket(
            postID: post.postID,
            postAuthorSigningKey: post.authorSigningKey,
            postDigest: post.digest,
            endorserSigningKey: Data(repeating: 9, count: 32),
            endorsedAt: baseMs + 1,
            signature: Data(repeating: 2, count: 64)
        )
    }

    @Test
    func trustedEndorsementOfRecentUrgentPost_emitsOneConfirmedLine() {
        let harness = Harness()
        let post = makePost(content: "road closed", geohash: "9q8yy", urgent: true)
        var count = 1
        let model = makeModel(harness: harness) { _ in (post, count) }

        model.handleEndorsement(endorsement(of: post))
        count = 2
        model.handleEndorsement(endorsement(of: post))

        #expect(harness.lines.count == 1)
        #expect(harness.lines[0].geohash == "9q8yy")
        #expect(harness.lines[0].content.contains("road closed"))
        #expect(harness.lines[0].content.contains("@alice"))
        #expect(harness.lines[0].content.contains("1"))
    }

    @Test
    func untrustedEndorsement_staysSilent() {
        let harness = Harness()
        let post = makePost(urgent: true)
        let model = makeModel(harness: harness) { _ in (post, 0) }

        model.handleEndorsement(endorsement(of: post))
        #expect(harness.lines.isEmpty)
    }

    @Test
    func endorsementOfCalmPost_staysSilent() {
        let harness = Harness()
        let post = makePost(urgent: false)
        let model = makeModel(harness: harness) { _ in (post, 3) }

        model.handleEndorsement(endorsement(of: post))
        #expect(harness.lines.isEmpty)
    }

    @Test
    func endorsementOfOwnPost_staysSilent() {
        let harness = Harness()
        let post = makePost(urgent: true, authorKey: ownKey)
        let model = makeModel(harness: harness) { _ in (post, 2) }

        model.handleEndorsement(endorsement(of: post))
        #expect(harness.lines.isEmpty)
    }

    @Test
    func endorsementOfStaleUrgentPost_staysSilent() {
        let harness = Harness()
        let post = makePost(createdAt: baseMs, urgent: true)
        let later = baseDate.addingTimeInterval(BoardAlertsModel.inlineRecencyWindow + 60)
        let model = makeModel(harness: harness, now: later) { _ in (post, 2) }

        model.handleEndorsement(endorsement(of: post))
        #expect(harness.lines.isEmpty)
    }

    @Test
    func endorsementOfUnknownPost_staysSilent() {
        let harness = Harness()
        let model = makeModel(harness: harness)

        model.handleEndorsement(endorsement(of: makePost(urgent: true)))
        #expect(harness.lines.isEmpty)
    }

    @Test
    func reset_allowsConfirmationAgainAfterWipe() {
        let harness = Harness()
        let post = makePost(urgent: true)
        let model = makeModel(harness: harness) { _ in (post, 1) }

        model.handleEndorsement(endorsement(of: post))
        model.reset()
        model.handleEndorsement(endorsement(of: post))
        #expect(harness.lines.count == 2)
    }
}
