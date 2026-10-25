//
// SpamFilterTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// Ported from bitchat-android's `SpamFilterTest`, so both apps hide the same messages.
@Suite struct SpamFilterTests {

    /// Deterministic clock and word source shared by one test.
    private final class Harness {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var nextID = 0
        var rng = SplitMix64(seed: 7)
        lazy var filter = SpamFilter(clock: { [unowned self] in self.now })

        func send(
            _ content: String? = nil,
            sender: String = "alice",
            timestamp: Date? = nil,
            id: String? = nil
        ) -> SpamVerdict {
            defer { nextID += 1 }
            return filter.check(
                senderKey: sender,
                messageID: id ?? "m\(nextID)",
                content: content ?? prose(),
                timestamp: timestamp ?? now
            )
        }

        /// Unrelated synthetic words, so only the rule under test can fire.
        func prose(_ length: Int = 40) -> String {
            var text = ""
            while text.count < length {
                if !text.isEmpty { text.append(" ") }
                for _ in 0..<Int.random(in: 2..<8, using: &rng) {
                    text.append(randomLetter())
                }
            }
            return String(text.prefix(length))
        }

        func randomLetter() -> Character {
            let offset: Int = Int.random(in: 0..<26, using: &rng)
            return Character(Unicode.Scalar(UInt8(97 + offset)))
        }

        func advance(seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }

        func ago(_ seconds: TimeInterval) -> Date {
            now.addingTimeInterval(-seconds)
        }
    }

    // MARK: - Message bucket

    @Test func sixthMessageInABurstIsShownAndSeventhIsHidden() {
        let h = Harness()
        for _ in 0..<6 { #expect(h.send() == .allowed) }
        #expect(h.send() == .messageRate)
    }

    @Test func messageBudgetRefillsOneTokenEveryTenSeconds() {
        let h = Harness()
        for _ in 0..<6 { _ = h.send() }
        h.advance(seconds: 9)
        #expect(h.send() == .messageRate)
        h.advance(seconds: 1)
        #expect(h.send() == .allowed)
        #expect(h.send() == .messageRate)
    }

    @Test func hiddenMessagesDoNotDrainTheBudgetOfAFloodingSender() {
        let h = Harness()
        var shown = 0
        for _ in 0..<120 {
            if h.send() == .allowed { shown += 1 }
            h.advance(seconds: 1)
        }
        // A burst of 6, then one every 10 seconds for the remaining two minutes.
        #expect(shown == 6 + 11)
    }

    // MARK: - Character bucket

    @Test func characterBudgetAllowsTwelveHundredCharactersPerMinute() {
        let h = Harness()
        #expect(h.send(h.prose(600)) == .allowed)
        #expect(h.send(h.prose(600)) == .allowed)
        #expect(h.send(h.prose(20)) == .characterRate)
        h.advance(seconds: 2)
        #expect(h.send(h.prose(20)) == .allowed)
    }

    @Test func messageLongerThanTheCharacterBudgetIsHidden() {
        let h = Harness()
        #expect(h.send(h.prose(1201)) == .characterRate)
    }

    @Test func charactersAreCountedAsScalars() {
        let h = Harness()
        let sentence = (0..<1200).map { i -> String in
            i % 3 == 0 ? "😀" : String(h.randomLetter())
        }.joined()
        #expect(h.send(sentence) == .allowed)
    }

    // MARK: - Link bucket

    @Test func thirdLinkWithinAMinuteIsHidden() {
        let h = Harness()
        #expect(h.send("see https://example.org/a for details") == .allowed)
        #expect(h.send("mirror at www.example.net too") == .allowed)
        #expect(h.send("and example.com/promo as well") == .linkRate)
        #expect(h.send("no link in this one at all") == .allowed)
        h.advance(seconds: 30)
        #expect(h.send("ok one more https://example.org/b") == .allowed)
    }

    @Test func messageWithThreeLinksIsHiddenEvenForAFreshSender() {
        let h = Harness()
        #expect(h.send("https://alpha.example/one and bravo.example plus www.charlie.example/three") == .linkRate)
    }

    @Test func linkCounterIgnoresEmailAddressesAndAbbreviations() {
        #expect(LinkCounter.count("mail me at someone@example.com e.g. today") == 0)
        #expect(LinkCounter.count("pi is 3.14, version v1.2.3") == 0)
        #expect(LinkCounter.count("https://a.example/x, www.b.example and c.example.") == 3)
    }

    // MARK: - Repeated messages

    @Test func thirdCopyOfAMessageWithinTenMinutesIsHidden() {
        let h = Harness()
        let text = "anyone near the north gate tonight?"
        #expect(h.send(text) == .allowed)
        h.advance(seconds: 60)
        #expect(h.send(text) == .allowed)
        h.advance(seconds: 60)
        #expect(h.send(text) == .repeatedMessage)
    }

    @Test func nearCopiesWithAChangingSuffixCountAsRepeats() {
        let h = Harness()
        #expect(h.send("FREE SATS at the link below 101") == .allowed)
        h.advance(seconds: 20)
        #expect(h.send("free sats at the link below 202") == .allowed)
        h.advance(seconds: 20)
        #expect(h.send("free  sats at the link below 303") == .repeatedMessage)
    }

    @Test func repeatsSpreadBeyondTheHistoryWindowAreAllowed() {
        let h = Harness()
        let text = "good morning everyone, coffee anyone?"
        _ = h.send(text)
        h.advance(seconds: 11 * 60)
        _ = h.send(text)
        h.advance(seconds: 11 * 60)
        #expect(h.send(text) == .allowed)
    }

    @Test func shortRepliesMayRepeatFreely() {
        let h = Harness()
        for _ in 0..<5 {
            #expect(h.send("lol yes") == .allowed)
            h.advance(seconds: 10)
        }
    }

    // MARK: - Repeated characters

    @Test func messageRepeatingACharacterIsHidden() {
        let h = Harness()
        #expect(h.send(String(repeating: "A", count: 40)) == .repeatedCharacters)
        #expect(h.send("hey " + String(repeating: "!", count: 60)) == .repeatedCharacters)
    }

    @Test func messageRepeatingAPhraseIsHidden() {
        let h = Harness()
        #expect(h.send(String(repeating: "buy now ", count: 6)) == .repeatedCharacters)
    }

    @Test func ordinaryLongSentenceIsNotMistakenForRepetition() {
        let h = Harness()
        let text = "The market by the old bridge opens at nine, bring cash because the card reader is flaky."
        #expect(RepetitionDetector.selfSimilarity(RepetitionDetector.normalize(text, maxLength: 1000)) < 0.3)
        #expect(h.send(text) == .allowed)
    }

    // MARK: - Senders, duplicates, timestamps

    @Test func sendersHaveIndependentBudgets() {
        let h = Harness()
        for _ in 0..<6 { _ = h.send(sender: "alice") }
        #expect(h.send(sender: "alice") == .messageRate)
        #expect(h.send(sender: "bob") == .allowed)
    }

    @Test func sameMessageIDArrivingTwiceIsJudgedOnce() {
        let h = Harness()
        for _ in 0..<5 { _ = h.send() }
        #expect(h.send(id: "dup") == .allowed)
        #expect(h.send(id: "dup") == .allowed)
        #expect(h.send() == .messageRate)
    }

    @Test func backfilledHistoryDeliveredNewestFirstIsShown() {
        let h = Harness()
        // Ten messages, one per minute over the last ten minutes, arriving in one burst.
        let verdicts = (0..<10).map { minutesAgo in h.send(timestamp: h.ago(Double(minutesAgo) * 60)) }
        #expect(verdicts.allSatisfy { $0 == .allowed })
    }

    @Test func backfilledBurstIsStillRateLimitedOnItsOwnTimestamps() {
        let h = Harness()
        let start = h.ago(5 * 60)
        let verdicts = (0..<10).map { h.send(timestamp: start.addingTimeInterval(Double($0))) }
        #expect(verdicts.filter { $0 == .allowed }.count == 6)
    }

    @Test func backfillCannotBeSqueezedInBetweenAlreadyShownMessages() {
        let h = Harness()
        for _ in 0..<6 { _ = h.send(timestamp: h.ago(60)) }
        // A message claiming to be from just before the burst would overdraw the bucket.
        #expect(h.send(timestamp: h.ago(61)) == .messageRate)
    }

    @Test func timestampsOlderThanTheBackdateWindowAreClamped() {
        let h = Harness()
        // Spreading fake timestamps over days must not buy extra budget.
        let verdicts = (0..<10).map { h.send(timestamp: h.ago(Double(10 - $0) * 86_400)) }
        #expect(verdicts.filter { $0 == .allowed }.count == 6)
    }

    @Test func futureTimestampsAreClampedToNow() {
        let h = Harness()
        let verdicts = (0..<10).map { h.send(timestamp: h.now.addingTimeInterval(Double($0) * 60)) }
        #expect(verdicts.filter { $0 == .allowed }.count == 6)
    }

    // MARK: - Settings

    @Test func disabledFilterAllowsEverything() {
        let h = Harness()
        h.filter.enabled = false
        for _ in 0..<20 { #expect(h.send(String(repeating: "A", count: 40)) == .allowed) }
    }

    @Test func limitsAreConfigurable() {
        let h = Harness()
        var config = SpamFilterConfig()
        config.messageBucket = TokenBucketConfig(capacity: 2, refillPerSecond: 1)
        let strict = SpamFilter(config: config, clock: { h.now })
        #expect(strict.check(senderKey: "a", messageID: "1", content: h.prose(), timestamp: h.now) == .allowed)
        #expect(strict.check(senderKey: "a", messageID: "2", content: h.prose(), timestamp: h.now) == .allowed)
        #expect(strict.check(senderKey: "a", messageID: "3", content: h.prose(), timestamp: h.now) == .messageRate)
        h.advance(seconds: 1)
        #expect(strict.check(senderKey: "a", messageID: "4", content: h.prose(), timestamp: h.now) == .allowed)
    }

    @Test func spamIsHidden() {
        let h = Harness()
        let messages = (1...7).map {
            BitchatMessage(id: "h\($0)", sender: "flooder", content: "hi \($0)", timestamp: h.now, isRelay: false)
        }
        #expect(messages.map { h.filter.shouldHide($0, senderKey: "flooder") } == [false, false, false, false, false, false, true])
    }

    @Test func changingLimitsStartsEverySenderWithAFullBudget() {
        let h = Harness()
        for _ in 0..<6 { _ = h.send() }
        #expect(h.send() == .messageRate)

        var config = SpamFilterConfig()
        config.messageBucket.capacity = 10
        h.filter.config = config

        for _ in 0..<10 { #expect(h.send() == .allowed) }
        #expect(h.send() == .messageRate)
    }

    @Test func resetForgetsEverySender() {
        let h = Harness()
        for _ in 0..<6 { _ = h.send() }
        #expect(h.send() == .messageRate)
        h.filter.reset()
        #expect(h.send() == .allowed)
    }

    @Test func forgetsLeastRecentlyActiveSendersBeyondTheLimit() {
        let h = Harness()
        var config = SpamFilterConfig()
        config.maxTrackedSenders = 4
        let filter = SpamFilter(config: config, clock: { h.now })
        for i in 0..<6 {
            _ = filter.check(senderKey: "alice", messageID: "a\(i)", content: h.prose(), timestamp: h.now)
        }
        #expect(filter.check(senderKey: "alice", messageID: "a6", content: h.prose(), timestamp: h.now) == .messageRate)
        // Five other senders push alice out; she comes back with a full budget.
        for i in 0..<5 {
            _ = filter.check(senderKey: "user\(i)", messageID: "u\(i)", content: h.prose(), timestamp: h.now)
        }
        #expect(filter.check(senderKey: "alice", messageID: "a7", content: h.prose(), timestamp: h.now) == .allowed)
    }

    // MARK: - Attachments

    private func attachment(_ content: String, id: String, from peerID: PeerID, at now: Date) -> BitchatMessage {
        BitchatMessage(id: id, sender: "alice", content: content, timestamp: now, isRelay: false, senderPeerID: peerID)
    }

    @Test func meshAttachmentFilenamesAreNotJudgedAsText() {
        let h = Harness()
        let peer = PeerID(str: "aabbccddeeff0011")
        // Numbered names would be near-copies, plain names would count as links.
        let names = ["[image] photo1.jpg", "[image] photo2.jpg", "[image] photo3.jpg", "[voice] beach.m4a", "[file] notes.pdf"]
        for (i, name) in names.enumerated() {
            #expect(h.filter.check(attachment(name, id: "a\(i)", from: peer, at: h.now), senderKey: "mesh:a") == .allowed, "\(name)")
        }
    }

    @Test func meshAttachmentFloodIsStillRateLimited() {
        let h = Harness()
        let peer = PeerID(str: "aabbccddeeff0011")
        let verdicts = (0..<7).map {
            h.filter.check(attachment("[image] img_\($0).jpg", id: "f\($0)", from: peer, at: h.now), senderKey: "mesh:a")
        }
        #expect(verdicts.last == .messageRate)
        #expect(verdicts.dropLast().allSatisfy { $0 == .allowed })
    }

    @Test func attachmentPrefixInAGeohashMessageIsStillText() {
        let h = Harness()
        let geo = PeerID(nostr: String(repeating: "ab", count: 32))
        let message = attachment("[image] " + String(repeating: "A", count: 80), id: "g", from: geo, at: h.now)
        #expect(!SpamFilter.isMeshAttachment(message))
        #expect(h.filter.check(message, senderKey: "nostr:ab") == .repeatedCharacters)
    }

    // MARK: - Across users

    @Test func sameTextFromManyThrowawayIdentitiesIsHiddenAfterThreeCopies() {
        let h = Harness()
        let text = "Free sats for everyone at freesats dot example"
        let verdicts = (1...6).map { h.send(text, sender: "npub\($0)") }
        #expect(verdicts == [.allowed, .allowed, .allowed, .repeatedAcrossUsers, .repeatedAcrossUsers, .repeatedAcrossUsers])
    }

    @Test func nearCopiesWithSmallChangesFromDifferentIdentitiesAreHidden() {
        let h = Harness()
        // Each variant is one small edit (a suffix, an insertion, a substitution) off the first.
        let variants = [
            "Free sats for everyone, claim yours now",
            "free sats for everyone, claim yours now 1",
            "Free sats for everyone!! claim yours now",
            "free sats 4 everyone, claim yours now",
            "free  sats for everyone, claim yours now 55"
        ]
        let verdicts = variants.enumerated().map { h.send($1, sender: "npub\($0)") }
        #expect(verdicts == [.allowed, .allowed, .allowed, .allowed, .repeatedAcrossUsers])
    }

    @Test func shortCommonRepliesFromManyUsersAreNotCompared() {
        let h = Harness()
        for i in 0..<8 { #expect(h.send("good morning!", sender: "user\(i)") == .allowed) }
    }

    @Test func differentMessagesOnTheSameTopicFromManyUsersAreAllowed() {
        let h = Harness()
        let messages = [
            "is the bakery on the corner still open?",
            "the bakery closes at eight I think",
            "bakery was still open when I walked by",
            "anyone know if the bakery has bread left?",
            "the corner bakery is open until eight"
        ]
        for (i, text) in messages.enumerated() { #expect(h.send(text, sender: "user\(i)") == .allowed) }
    }

    @Test func copiesFromOtherUsersOutsideTheWindowDoNotCount() {
        let h = Harness()
        let text = "anyone up for chess at the tables later?"
        for i in 0..<3 {
            _ = h.send(text, sender: "user\(i)")
            h.advance(seconds: 4 * 60)
        }
        // Only the copy from 4 minutes ago and the one from 8 minutes ago are in the window.
        #expect(h.send(text, sender: "late") == .allowed)
    }

    @Test func aSendersOwnCopiesDoNotCountTowardTheCrossUserLimit() {
        let h = Harness()
        let text = "anyone near the north gate tonight?"
        _ = h.send(text, sender: "alice")
        h.advance(seconds: 60)
        _ = h.send(text, sender: "alice")
        #expect(h.send(text, sender: "bob") == .allowed)
        #expect(h.send(text, sender: "carol") == .repeatedAcrossUsers)
    }

    // MARK: - Alignment

    @Test func bestAlignmentReportsWhereTheTextsLineUp() {
        let a = RepetitionDetector.normalize("xx hello world", maxLength: 1000)
        let b = RepetitionDetector.normalize("hello world", maxLength: 1000)
        let alignment = RepetitionDetector.align(a, b)
        #expect(alignment.peaks.first?.shift == 3)
        #expect(alignment.matches == 11)
    }

    @Test func anInsertedCharacterDoesNotBreakTheMatch() {
        let a = RepetitionDetector.normalize("free sats for everyone, claim yours now", maxLength: 1000)
        let b = RepetitionDetector.normalize("free sats for everyone!!, claim yours now", maxLength: 1000)
        #expect(RepetitionDetector.align(a, b, maxPeaks: 1).score < 0.8)
        #expect(RepetitionDetector.align(a, b).score > 0.9)
    }

    @Test func unrelatedSentencesStayFarBelowTheNearCopyThreshold() {
        let a = RepetitionDetector.normalize("the bakery closes at eight I think", maxLength: 1000)
        let b = RepetitionDetector.normalize("the corner bakery is open until eight", maxLength: 1000)
        #expect(RepetitionDetector.align(a, b).score < 0.6)
    }

    @Test func alignmentUpperBoundNeverUnderestimates() {
        var rng = SplitMix64(seed: 11)
        for alphabet in [2, 3, 5, 26] {
            for _ in 0..<60 {
                func text() -> [Int] {
                    let length: Int = Int.random(in: 1...80, using: &rng)
                    return (0..<length).map { _ -> Int in 97 + Int.random(in: 0..<alphabet, using: &rng) }
                }
                let a = text()
                var b = Bool.random(using: &rng) ? text() : a
                if !b.isEmpty, Bool.random(using: &rng) { b.insert(98, at: Int.random(in: 0..<b.count, using: &rng)) }
                let exact = RepetitionDetector.align(a, b).matches
                let bound = RepetitionDetector.alignmentUpperBound(a, b, positionsInB: RepetitionDetector.positions(b), maxPeaks: 3)
                #expect(bound >= exact)
            }
        }
    }

    @Test func bucketShortcutForInOrderMessagesMatchesAFullReplay() {
        // Reference: replay every admitted message from full buckets each time.
        let configs = [TokenBucketConfig(capacity: 3, refillPerSecond: 0.2), TokenBucketConfig(capacity: 50, refillPerSecond: 2)]
        func replayAdmits(_ admitted: [(TimeInterval, [Double])], _ time: TimeInterval, _ costs: [Double]) -> Int? {
            let timeline = (admitted + [(time, costs)]).enumerated().sorted { a, b in
                a.element.0 != b.element.0 ? a.element.0 < b.element.0 : a.offset < b.offset
            }.map(\.element)
            var tokens = configs.map(\.capacity)
            var last: TimeInterval?
            for (t, c) in timeline {
                if let last, t > last {
                    for b in configs.indices { tokens[b] = min(configs[b].capacity, tokens[b] + (t - last) * configs[b].refillPerSecond) }
                }
                last = t
                for b in configs.indices {
                    tokens[b] -= c[b]
                    if tokens[b] < -1e-9 { return b }
                }
            }
            return nil
        }
        var rng = SplitMix64(seed: 9)
        for _ in 0..<40 {
            var schedule = TokenBucketSchedule(buckets: configs)
            var admitted: [(TimeInterval, [Double])] = []
            var clock: TimeInterval = 0
            for _ in 0..<40 {
                clock += Double(Int.random(in: 0...6, using: &rng))
                // Mostly live traffic, sometimes a backfilled message from earlier.
                let time = Bool.random(using: &rng) && Int.random(in: 0..<4, using: &rng) == 0
                    ? max(0, clock - Double(Int.random(in: 1...20, using: &rng)))
                    : clock
                let costs: [Double] = [1, Double(Int.random(in: 1...30, using: &rng))]
                let expected = replayAdmits(admitted, time, costs)
                #expect(schedule.tryAdmit(at: time, costs: costs) == expected)
                if expected == nil { admitted.append((time, costs)) }
            }
        }
    }

    @Test func earlyExitSelfSimilarityAgreesWithTheFullScore() {
        var rng = SplitMix64(seed: 5)
        for alphabet in [1, 2, 3, 26] {
            for _ in 0..<80 {
                let length: Int = Int.random(in: 0...90, using: &rng)
                let text: [Int] = (0..<length).map { _ -> Int in 97 + Int.random(in: 0..<alphabet, using: &rng) }
                for threshold in [0.5, 0.85, 1.0] {
                    let full = RepetitionDetector.selfSimilarity(text) >= threshold
                    #expect(RepetitionDetector.selfSimilarity(text, reaches: threshold) == full)
                }
            }
        }
    }

    @Test func recentCopiesAreCaughtBehindAFloodOfLookAlikes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var config = SpamFilterConfig()
        config.repetition.crossUserMaxComparisons = 8
        // Enough to confirm the copies that hide the next one, and no more.
        config.repetition.crossUserMaxAlignments = config.repetition.crossUserAllowedRepeats + 1
        let filter = SpamFilter(config: config, clock: { now })
        var rng = SplitMix64(seed: 3)
        // Texts over a two-letter alphabet pass every cheap check against each
        // other, so they spend the comparison budget without being near-copies.
        for i in 0..<30 {
            let junk = String((0..<120).map { _ in Bool.random(using: &rng) ? "a" : "b" })
            _ = filter.check(senderKey: "junk\(i)", messageID: "j\(i)", content: junk, timestamp: now)
        }
        let text = "Free sats for everyone at freesats dot example"
        let verdicts = (1...4).map {
            filter.check(senderKey: "npub\($0)", messageID: "c\($0)", content: text, timestamp: now)
        }
        #expect(verdicts == [.allowed, .allowed, .allowed, .repeatedAcrossUsers])
    }

    // MARK: - Disguised copies

    private static let disguiseBase = "Free sats for everyone, claim yours now"

    /// The same text a reader sees, written so that a plain comparison would miss it.
    private static let disguises: [(String, String)] = {
        let base = disguiseBase
        func mapScalars(_ transform: (Unicode.Scalar) -> String) -> String {
            base.unicodeScalars.map(transform).joined()
        }
        let invisibles = ["\u{200C}", "\u{200D}", "\u{2060}", "\u{00AD}", "\u{200E}"]
        // One typed binding per disguise keeps each closure cheap to type-check.
        let zeroWidth: String = mapScalars { (c: Unicode.Scalar) -> String in "\(c)\u{200B}" }
        var mixed = ""
        for (i, c) in base.unicodeScalars.enumerated() {
            mixed += String(c) + invisibles[i % invisibles.count]
        }
        let accented: String = mapScalars { (c: Unicode.Scalar) -> String in
            c.properties.isAlphabetic ? "\(c)\u{0301}" : "\(c)"
        }
        let bold: String = mapScalars { (c: Unicode.Scalar) -> String in
            switch c.value {
            case 0x61...0x7A: return String(Unicode.Scalar(0x1D41A + c.value - 0x61)!)
            case 0x41...0x5A: return String(Unicode.Scalar(0x1D400 + c.value - 0x41)!)
            default: return "\(c)"
            }
        }
        let fullwidth: String = mapScalars { (c: Unicode.Scalar) -> String in
            guard (0x21...0x7E).contains(c.value) else { return "\(c)" }
            return String(Unicode.Scalar(c.value + 0xFEE0)!)
        }
        let nonBreaking: String = base.replacingOccurrences(of: " ", with: "\u{00A0}")
        return [
            ("zero-width spaces", zeroWidth),
            ("mixed invisible characters", mixed),
            ("an accent on every letter", accented),
            ("math bold letters", bold),
            ("fullwidth letters", fullwidth),
            ("non-breaking spaces", nonBreaking)
        ]
    }()

    @Test func normalizationFoldsDisguisesToTheTextAReaderSees() {
        let plain = RepetitionDetector.normalize(Self.disguiseBase, maxLength: 1000)
        for (label, text) in Self.disguises {
            #expect(RepetitionDetector.normalize(text, maxLength: 1000) == plain, "\(label)")
        }
    }

    @Test func disguisedCopiesFromOtherUsersAreStillCaught() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        for (label, text) in Self.disguises {
            let fresh = SpamFilter(clock: { now })
            for i in 0..<3 {
                _ = fresh.check(senderKey: "npub\(i)", messageID: "\(label)-\(i)", content: Self.disguiseBase, timestamp: now)
            }
            #expect(fresh.check(senderKey: "npub9", messageID: "\(label)-x", content: text, timestamp: now) == .repeatedAcrossUsers, "\(label)")
        }
    }

    @Test func disguisedCopiesFromTheSameUserAreStillCaught() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        for (label, text) in Self.disguises {
            let fresh = SpamFilter(clock: { now })
            _ = fresh.check(senderKey: "alice", messageID: "\(label)-1", content: Self.disguiseBase, timestamp: now)
            _ = fresh.check(senderKey: "alice", messageID: "\(label)-2", content: Self.disguiseBase, timestamp: now)
            #expect(fresh.check(senderKey: "alice", messageID: "\(label)-3", content: text, timestamp: now) == .repeatedMessage, "\(label)")
        }
    }

    @Test func invisibleCharactersCannotBreakUpARepeatedCharacterRun() {
        let h = Harness()
        #expect(h.send(String(repeating: "A\u{200B}", count: 40)) == .repeatedCharacters)
    }

    @Test func ordinaryTextWithAccentsAndOtherScriptsIsStillAllowed() {
        let h = Harness()
        let texts = [
            "Tiếng Việt có dấu, chúng tôi đang ở quán cà phê gần chợ",
            "क्या कोई पास में चाय की दुकान जानता है? मैं स्टेशन के पास हूँ",
            "Café au lait, crème brûlée, s'il vous plaît",
            "家族と一緒に駅の近くのカフェにいます、誰か来ますか"
        ]
        for (i, text) in texts.enumerated() { #expect(h.send(text, sender: "user\(i)") == .allowed, "\(text)") }
    }

    @Test func differentSentencesInAnotherScriptAreNotMistakenForCopies() {
        let h = Harness()
        #expect(h.send("क्या कोई पास में चाय की दुकान जानता है?", sender: "a") == .allowed)
        #expect(h.send("मैं स्टेशन के पास हूँ, बारिश हो रही है", sender: "b") == .allowed)
        #expect(h.send("आज बाज़ार कितने बजे बंद होगा?", sender: "c") == .allowed)
        #expect(h.send("क्या किसी के पास छाता है जो मैं ले सकूँ?", sender: "d") == .allowed)
    }
}

@Suite struct SpamFilterSettingsTests {

    private static let words = ["apple", "bridge", "candle", "dolphin", "engine", "forest", "garden", "harbor"]

    private func makeDefaults() -> UserDefaults {
        let suite = "SpamFilterSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func filterIsOnByDefault() {
        #expect(SpamFilterSettings.isEnabled(in: makeDefaults()))
    }

    @Test func turningTheFilterOffPersistsAndAppliesImmediately() {
        let defaults = makeDefaults()
        let filter = SpamFilter()
        SpamFilterSettings.setEnabled(false, in: defaults, filter: filter)
        #expect(!SpamFilterSettings.isEnabled(in: defaults))
        #expect(!filter.enabled)
    }

    @Test func togglingStartsEverySenderWithAFullBudget() {
        let defaults = makeDefaults()
        let now = Date()
        let filter = SpamFilter(clock: { now })
        let verdicts = (0..<7).map {
            filter.check(senderKey: "a", messageID: "\($0)", content: Self.words[$0], timestamp: now)
        }
        #expect(verdicts.last == .messageRate)

        SpamFilterSettings.setEnabled(false, in: defaults, filter: filter)
        SpamFilterSettings.setEnabled(true, in: defaults, filter: filter)

        #expect(filter.check(senderKey: "a", messageID: "7", content: Self.words[7], timestamp: now) == .allowed)
    }

    @Test func panicResetRestoresTheDefaultAndForgetsHistory() {
        let defaults = makeDefaults()
        let now = Date()
        let filter = SpamFilter(clock: { now })
        for i in 0..<7 {
            _ = filter.check(senderKey: "a", messageID: "\(i)", content: Self.words[i], timestamp: now)
        }
        #expect(filter.wasHidden(messageID: "6"))
        SpamFilterSettings.setEnabled(false, in: defaults, filter: filter)

        SpamFilterSettings.reset(in: defaults, filter: filter)

        #expect(SpamFilterSettings.isEnabled(in: defaults))
        #expect(filter.enabled)
        #expect(!filter.wasHidden(messageID: "6"))
    }
}

/// Small seeded generator so the synthetic prose is the same on every run.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
