//
// SpamFilter.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

enum SpamVerdict: Equatable {
    case allowed
    case messageRate
    case characterRate
    case linkRate
    case repeatedMessage
    case repeatedAcrossUsers
    case repeatedCharacters

    var isSpam: Bool { self != .allowed }
}

/// Decides whether an incoming public message should be hidden.
///
/// Each sender gets three token buckets (messages, characters, links; see
/// `SpamFilterConfig`) plus three repetition checks: a message that repeats
/// itself internally, a near-copy of the sender's own recent history, and a
/// near-copy of what *other* senders posted recently. The last one catches spam
/// spread over many throwaway identities, which per-sender limits cannot see.
/// Hidden messages never spend tokens, but they do enter the repetition history
/// so a spammer cannot cycle the same text.
///
/// Verdicts are remembered by message ID, so the same message arriving over
/// several links or relays is judged once and counted once.
///
/// Mirrors bitchat-android's `spam` package, with the same defaults.
final class SpamFilter: @unchecked Sendable {

    /// Process-wide filter shared by the mesh and geohash intake, starting
    /// from the user's saved choice.
    static let shared: SpamFilter = {
        let filter = SpamFilter()
        filter.enabled = SpamFilterSettings.isEnabled(in: .standard)
        return filter
    }()

    /// A message prepared for comparison: its leading characters and their trigrams.
    private struct Fingerprint {
        let time: TimeInterval
        let text: [Int]
        let trigrams: [Int]
        let positions: [Int: [Int]]
    }

    private struct SharedEntry {
        let senderKey: String
        let fingerprint: Fingerprint
    }

    private struct SenderState {
        var rate: TokenBucketSchedule
        var history: [Fingerprint] = []
        var lastActive: UInt64
    }

    private let lock = NSLock()
    private let clock: () -> Date
    private var _enabled = true
    private var _config: SpamFilterConfig
    private var senders: [String: SenderState] = [:]
    private var activity: UInt64 = 0
    /// Recent texts from every sender, for the cross-user repeat check.
    private var recentTexts: [SharedEntry] = []
    private var verdicts: [String: SpamVerdict] = [:]
    private var verdictOrder: [String] = []
    private var verdictHead = 0

    init(config: SpamFilterConfig = SpamFilterConfig(), clock: @escaping () -> Date = Date.init) {
        self._config = config
        self.clock = clock
    }

    var enabled: Bool {
        get { lock.withLock { _enabled } }
        set { lock.withLock { _enabled = newValue } }
    }

    /// Changing the limits forgets every sender, so new budgets start full.
    var config: SpamFilterConfig {
        get { lock.withLock { _config } }
        set {
            lock.withLock {
                _config = newValue
                clearLocked()
            }
        }
    }

    /// Returns true when the message must be kept out of the chat.
    /// `senderKey` must identify the author stably within a transport.
    func shouldHide(_ message: BitchatMessage, senderKey: String) -> Bool {
        check(message, senderKey: senderKey).isSpam
    }

    func check(_ message: BitchatMessage, senderKey: String) -> SpamVerdict {
        check(
            senderKey: senderKey,
            messageID: message.id,
            content: message.content,
            timestamp: message.timestamp,
            isText: !Self.isMeshAttachment(message)
        )
    }

    /// A received image, voice note or file, which the timeline shows as
    /// `[image] <filename>`. Its filename is not text someone wrote, so only
    /// the message rate applies. Like the timeline's media detection, only
    /// mesh senders can attach files: the same line in a geohash or bridged
    /// message stays text, so the prefix can't dodge the text checks there.
    static func isMeshAttachment(_ message: BitchatMessage) -> Bool {
        if let peerID = message.senderPeerID, peerID.isGeoChat || peerID.isGeoDM || peerID.isBridge {
            return false
        }
        let categories: [MimeType.Category] = [.image, .audio, .file]
        return categories.contains { category in
            guard message.content.hasPrefix(category.messagePrefix) else { return false }
            let filename = String(message.content.dropFirst(category.messagePrefix.count))
            return BitchatMessage.isSafeMediaFilename(filename)
        }
    }

    func check(
        senderKey: String,
        messageID: String,
        content: String,
        timestamp: Date,
        isText: Bool = true
    ) -> SpamVerdict {
        lock.lock()
        defer { lock.unlock() }
        guard _enabled else { return .allowed }
        if let verdict = verdicts[messageID] { return verdict }

        let config = _config
        let now = clock().timeIntervalSince1970
        let oldestTrusted = now - config.maxBackdate
        let time = min(max(timestamp.timeIntervalSince1970, oldestTrusted), now)
        var state = senders[senderKey] ?? SenderState(
            rate: TokenBucketSchedule(buckets: [config.messageBucket, config.characterBucket, config.linkBucket]),
            lastActive: 0
        )
        activity += 1
        state.lastActive = activity
        state.rate.prune(before: oldestTrusted)

        let repetition = config.repetition
        let text = isText ? RepetitionDetector.normalize(content, maxLength: repetition.maxAnalyzedLength) : nil
        var fingerprint: Fingerprint?
        if let text { fingerprint = makeFingerprint(text, time: time, config: repetition) }

        let verdict: SpamVerdict
        if let text, let fingerprint {
            if hasRepeatedCharacters(text, config: repetition) {
                verdict = .repeatedCharacters
            } else if repeatsHistory(state, length: text.count, message: fingerprint, config: repetition) {
                verdict = .repeatedMessage
            } else if repeatsOtherSenders(senderKey, length: text.count, message: fingerprint, config: repetition) {
                verdict = .repeatedAcrossUsers
            } else {
                verdict = admitRate(&state, content: content, time: time, isText: isText)
            }
            state.history.append(fingerprint)
            if state.history.count > repetition.historySize {
                state.history.removeFirst(state.history.count - repetition.historySize)
            }
            if text.count >= repetition.crossUserMinLength {
                recentTexts.append(SharedEntry(senderKey: senderKey, fingerprint: fingerprint))
                if recentTexts.count > repetition.crossUserHistorySize {
                    recentTexts.removeFirst(recentTexts.count - repetition.crossUserHistorySize)
                }
            }
        } else {
            verdict = admitRate(&state, content: content, time: time, isText: isText)
        }

        senders[senderKey] = state
        evictSendersIfNeeded(limit: config.maxTrackedSenders)
        remember(verdict, for: messageID, limit: config.maxRememberedVerdicts)
        return verdict
    }

    /// Whether a message already checked was hidden, without judging or
    /// counting it again. Lets mention notifications and haptics, which run
    /// after intake, skip what intake dropped.
    func wasHidden(messageID: String) -> Bool {
        lock.withLock { _enabled && verdicts[messageID]?.isSpam == true }
    }

    /// Forgets all senders, e.g. when the filter is toggled or the app is wiped.
    func reset() {
        lock.withLock { clearLocked() }
    }

    /// Key for geohash messages, by the sender's per-geohash Nostr pubkey.
    /// Matches the public intake's sender key, so both geohash paths share
    /// one budget per sender.
    static func nostrSenderKey(pubkeyHex: String) -> String {
        "nostr:" + pubkeyHex.lowercased()
    }

    // MARK: - Checks

    private func clearLocked() {
        senders.removeAll()
        recentTexts.removeAll()
        verdicts.removeAll()
        verdictOrder.removeAll()
        verdictHead = 0
        activity = 0
    }

    private func hasRepeatedCharacters(_ text: [Int], config: RepetitionConfig) -> Bool {
        text.count >= config.minRepeatedCharactersLength &&
            RepetitionDetector.selfSimilarity(text) >= config.repeatedCharactersThreshold
    }

    private func makeFingerprint(_ text: [Int], time: TimeInterval, config: RepetitionConfig) -> Fingerprint {
        let compared = text.count > config.maxComparedLength ? Array(text.prefix(config.maxComparedLength)) : text
        return Fingerprint(
            time: time,
            text: compared,
            trigrams: RepetitionDetector.trigrams(compared),
            positions: RepetitionDetector.positions(compared)
        )
    }

    private func repeatsHistory(_ state: SenderState, length: Int, message: Fingerprint, config: RepetitionConfig) -> Bool {
        guard length >= config.minRepeatedMessageLength else { return false }
        // At most `historySize` comparisons, so no budget is needed.
        var budget = ComparisonBudget(comparisons: .max, alignments: .max)
        let copies = state.history.filter { isNearCopy($0, message, config: config, budget: &budget) }.count
        return copies > config.allowedRepeats
    }

    /// Scans newest first, so the comparison budget falls on the oldest texts
    /// if a burst of look-alikes ever exhausts it.
    private func repeatsOtherSenders(_ senderKey: String, length: Int, message: Fingerprint, config: RepetitionConfig) -> Bool {
        guard length >= config.crossUserMinLength else { return false }
        var copies = 0
        var budget = ComparisonBudget(
            comparisons: config.crossUserMaxComparisons,
            alignments: config.crossUserMaxAlignments
        )
        for entry in recentTexts.reversed() where entry.senderKey != senderKey {
            guard !budget.isSpent else { break }
            guard isNearCopy(entry.fingerprint, message, config: config, budget: &budget) else { continue }
            copies += 1
            if copies > config.crossUserAllowedRepeats { return true }
        }
        return false
    }

    /// Work left for comparing one message: pairs that get past the trigram
    /// check, and of those, pairs that need the full alignment.
    private struct ComparisonBudget {
        var comparisons: Int
        var alignments: Int

        var isSpent: Bool { comparisons <= 0 || alignments <= 0 }
    }

    /// The cheap checks (time, length, shared trigrams) cost nothing from
    /// `budget`; the diagonal bound spends a comparison and `align` an alignment.
    private func isNearCopy(
        _ earlier: Fingerprint,
        _ message: Fingerprint,
        config: RepetitionConfig,
        budget: inout ComparisonBudget
    ) -> Bool {
        let longer = max(earlier.text.count, message.text.count)
        guard abs(earlier.time - message.time) <= config.historyWindow,
              lengthsCanMatch(earlier.text.count, message.text.count, config: config),
              RepetitionDetector.trigramOverlap(earlier.trigrams, message.trigrams) >= config.minSharedTrigrams
        else { return false }
        budget.comparisons -= 1
        guard Double(RepetitionDetector.alignmentUpperBound(
                  message.text,
                  earlier.text,
                  positionsInB: earlier.positions,
                  maxPeaks: config.maxAlignmentPeaks
              )) / Double(longer) >= config.repeatedMessageSimilarity
        else { return false }
        budget.alignments -= 1
        return RepetitionDetector.crossSimilarity(
            earlier.text,
            message.text,
            maxPeaks: config.maxAlignmentPeaks,
            minRun: config.minPeakRun
        ) >= config.repeatedMessageSimilarity
    }

    // Cross-similarity is bounded by shorter/longer, so skip pairs that can never reach it.
    private func lengthsCanMatch(_ a: Int, _ b: Int, config: RepetitionConfig) -> Bool {
        guard max(a, b) > 0 else { return false }
        return Double(min(a, b)) / Double(max(a, b)) >= config.repeatedMessageSimilarity
    }

    private func admitRate(_ state: inout SenderState, content: String, time: TimeInterval, isText: Bool) -> SpamVerdict {
        let characters = isText ? Double(content.unicodeScalars.count) : 0
        let links = isText ? Double(LinkCounter.count(content)) : 0
        switch state.rate.tryAdmit(at: time, costs: [1, characters, links]) {
        case nil: return .allowed
        case 0: return .messageRate
        case 1: return .characterRate
        default: return .linkRate
        }
    }

    // MARK: - Bookkeeping

    /// Drops the least recently active senders once over `limit`, in one pass
    /// down to 3/4 of it so the sort runs rarely.
    private func evictSendersIfNeeded(limit: Int) {
        guard senders.count > limit else { return }
        let keep = max(1, (limit * 3) / 4)
        let evicted = senders
            .sorted { $0.value.lastActive < $1.value.lastActive }
            .prefix(senders.count - keep)
        for (key, _) in evicted { senders.removeValue(forKey: key) }
    }

    private func remember(_ verdict: SpamVerdict, for messageID: String, limit: Int) {
        verdicts[messageID] = verdict
        verdictOrder.append(messageID)
        while verdictOrder.count - verdictHead > limit {
            verdicts.removeValue(forKey: verdictOrder[verdictHead])
            verdictHead += 1
        }
        // Compact once the consumed prefix dominates, keeping appends amortized O(1).
        if verdictHead > limit {
            verdictOrder.removeFirst(verdictHead)
            verdictHead = 0
        }
    }
}
