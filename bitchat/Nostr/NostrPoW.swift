import BitFoundation
import CryptoKit
import Foundation

/// NIP-13 proof-of-work for Nostr events.
///
/// Outgoing kind-20000 geohash messages mine a `["nonce", "<value>", "<target>"]`
/// tag so the event ID carries at least `target` leading zero bits. Inbound
/// events are scored (never hard-rejected — the network has clients that do
/// not mine): validated PoW at or above `rateLimitBypassBits` relaxes the
/// per-sender public rate limit, everything else keeps the strict limits.
enum NostrPoW {

    // MARK: - Tuning

    /// Difficulty (leading zero bits of the event ID) mined onto outgoing
    /// geohash messages. 8 bits is ~256 hash attempts — typically well under
    /// 100 ms on any supported device.
    static let targetBits = 8

    /// Inbound events whose validated NIP-13 difficulty is at least this many
    /// bits skip the per-sender rate-limit bucket (the content-flood bucket
    /// still applies). See `MessageRateLimiter.allow`.
    static let rateLimitBypassBits = 8

    /// Hard cap on mining wall-clock time. When it hits, the committed target
    /// steps down until a difficulty reachable in a small extra budget is
    /// found and the message is sent anyway — mining never blocks sending.
    static let miningTimeCap: TimeInterval = 2.0

    /// Budget for each stepped-down attempt after the main cap (or a task
    /// cancellation) hits.
    private static let fallbackTimeCap: TimeInterval = 0.15

    /// The hot loop checks the deadline and task cancellation every this many
    /// hash attempts.
    private static let checkInterval: UInt64 = 1024

    /// The nonce value is a fixed-width hex counter so the serialized event
    /// template can be mutated in place without reallocation.
    private static let nonceLength = 16

    // MARK: - Scoring

    /// Number of leading zero bits in a byte sequence (NIP-13 difficulty of
    /// an event-ID hash).
    static func leadingZeroBits<Bytes: Sequence<UInt8>>(_ bytes: Bytes) -> Int {
        var total = 0
        for byte in bytes {
            if byte == 0 {
                total += 8
            } else {
                total += byte.leadingZeroBitCount
                break
            }
        }
        return total
    }

    /// Validated NIP-13 difficulty of an inbound event.
    ///
    /// The committed target in the nonce tag is what counts: the actual
    /// leading zero bits of the ID must meet it (otherwise the claim is void
    /// and the event scores 0), and work beyond the commitment earns no extra
    /// credit — this stops spammers who mine a low target from getting lucky
    /// high scores. Events without a well-formed commitment score 0.
    static func validatedDifficulty(idHex: String, tags: [[String]]) -> Int {
        guard let nonceTag = tags.last(where: { $0.first == "nonce" }),
              nonceTag.count >= 3,
              let committed = Int(nonceTag[2]),
              committed > 0, committed <= 256,
              let idData = Data(hexString: idHex)
        else {
            return 0
        }
        return leadingZeroBits(idData) >= committed ? committed : 0
    }

    // MARK: - Mining

    /// Mine a `["nonce", value, target]` tag for the given unsigned-event
    /// fields. Nonisolated async: runs off the calling actor.
    ///
    /// Bounded by `miningTimeCap`: when the cap hits — or the surrounding
    /// task is cancelled — the committed target steps down (halving to 0,
    /// which any hash satisfies) so the event still ships promptly with an
    /// honest commitment at the difficulty actually reached. Returns nil only
    /// if canonical serialization fails; the caller then sends unmined.
    static func mineNonceTag(
        pubkey: String,
        createdAt: Int,
        kind: Int,
        tags: [[String]],
        content: String,
        targetBits: Int = NostrPoW.targetBits
    ) async -> [String]? {
        var target = min(max(targetBits, 0), 256)
        var budget = miningTimeCap
        while true {
            if let tag = mineAttempt(
                pubkey: pubkey,
                createdAt: createdAt,
                kind: kind,
                baseTags: tags,
                content: content,
                targetBits: target,
                budget: budget
            ) {
                return tag
            }
            // Target 0 succeeds on the first hash, so reaching it with nil
            // means serialization itself failed — give up on mining.
            if target == 0 { return nil }
            target /= 2
            budget = fallbackTimeCap
        }
    }

    /// One bounded mining pass at a fixed committed target. Allocation-light:
    /// the canonical serialization is built once and only the fixed-width
    /// nonce bytes are rewritten per attempt (the event ID is recomputed for
    /// every attempt, per NIP-13). Returns nil on timeout/cancellation or if
    /// the template could not be built.
    private static func mineAttempt(
        pubkey: String,
        createdAt: Int,
        kind: Int,
        baseTags: [[String]],
        content: String,
        targetBits: Int,
        budget: TimeInterval
    ) -> [String]? {
        let targetString = String(targetBits)
        guard let template = serializedTemplate(
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            baseTags: baseTags,
            content: content,
            targetString: targetString
        ) else {
            return nil
        }
        var buffer = template.buffer
        let nonceRange = template.nonceRange

        let deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(budget * 1_000_000_000)
        let hexDigits = [UInt8]("0123456789abcdef".utf8)
        var nonce = UInt64.random(in: .min ... .max)
        var attempts: UInt64 = 0

        while true {
            // Write the nonce as 16 lowercase hex chars, in place.
            var value = nonce
            var index = nonceRange.upperBound
            while index > nonceRange.lowerBound {
                index -= 1
                buffer[index] = hexDigits[Int(value & 0xF)]
                value >>= 4
            }

            if leadingZeroBits(SHA256.hash(data: buffer)) >= targetBits {
                // Identical to the bytes just written into the buffer.
                return ["nonce", String(format: "%016llx", nonce), targetString]
            }

            nonce &+= 1
            attempts &+= 1
            if attempts % checkInterval == 0,
               Task.isCancelled || DispatchTime.now().uptimeNanoseconds >= deadline {
                return nil
            }
        }
    }

    /// Canonical NIP-01 serialization of the event with a placeholder nonce,
    /// plus the byte range of the nonce value inside it.
    ///
    /// The range is located by serializing twice with two same-length
    /// placeholders and diffing the buffers — the only differing bytes are
    /// the nonce value, so this stays correct however `JSONSerialization`
    /// escapes the surrounding fields (and even if the content contains the
    /// placeholder text itself).
    private static func serializedTemplate(
        pubkey: String,
        createdAt: Int,
        kind: Int,
        baseTags: [[String]],
        content: String,
        targetString: String
    ) -> (buffer: Data, nonceRange: Range<Int>)? {
        func serialize(noncePlaceholder: String) -> Data? {
            var tags = baseTags
            tags.append(["nonce", noncePlaceholder, targetString])
            let serialized: [Any] = [0, pubkey, createdAt, kind, tags, content]
            return try? JSONSerialization.data(withJSONObject: serialized, options: [.withoutEscapingSlashes])
        }

        guard let zeros = serialize(noncePlaceholder: String(repeating: "0", count: nonceLength)),
              let effs = serialize(noncePlaceholder: String(repeating: "f", count: nonceLength)),
              zeros.count == effs.count
        else {
            return nil
        }

        var firstDiff = -1
        var lastDiff = -1
        for index in 0..<zeros.count where zeros[index] != effs[index] {
            if firstDiff < 0 { firstDiff = index }
            lastDiff = index
        }
        guard firstDiff >= 0, lastDiff - firstDiff + 1 == nonceLength else { return nil }
        return (zeros, firstDiff..<(firstDiff + nonceLength))
    }
}
