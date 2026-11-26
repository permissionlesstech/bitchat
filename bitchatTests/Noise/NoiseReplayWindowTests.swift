//
// NoiseReplayWindowTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import Foundation
import Testing

@testable import bitchat

/// The transport cipher accepts a nonce exactly once while it lies within
/// 1,024 of the highest nonce accepted so far, in any arrival order. These
/// tests pin that contract at every offset in the window, because a window
/// that is only right at offset 0 (and at multiples of 8) both lets recent
/// packets be replayed and drops genuine packets that arrive late.
@Suite("Noise Replay Window Tests")
struct NoiseReplayWindowTests {
    private static let windowSize: UInt64 = 1024

    private let key = SymmetricKey(size: .bits256)

    // MARK: - Replay

    @Test("A replay of the previous nonce is rejected once the window has advanced")
    func replayOfPreviousNonceIsRejected() throws {
        let receiver = makeReceiver()
        let first = try transportPayload(nonce: 0)

        #expect(deliver(first, to: receiver) == .accepted)
        #expect(deliver(try transportPayload(nonce: 1), to: receiver) == .accepted)

        #expect(deliver(first, to: receiver) == .replay)
    }

    @Test("Every nonce is rejected on replay at every offset in the window")
    func replayIsRejectedAtEveryOffset() throws {
        let receiver = makeReceiver()
        let highest: UInt64 = 1099
        let payloads = try (0...highest).map { try transportPayload(nonce: $0) }

        for payload in payloads {
            #expect(deliver(payload, to: receiver) == .accepted)
        }

        // Offsets 0...1023 are inside the window and already seen; anything
        // further back is too old. Neither may decrypt a second time.
        let acceptedAgain = payloads.indices.filter { deliver(payloads[$0], to: receiver) != .replay }
        #expect(acceptedAgain.isEmpty, "nonces accepted a second time: \(acceptedAgain)")
    }

    // MARK: - Late arrival

    @Test(
        "A never-seen nonce that arrives late is accepted once, then rejected",
        arguments: Array(1...40) + [63, 64, 65, 127, 128, 129, 255, 256, 257, 511, 512, 1000, 1022, 1023]
    )
    func lateNonceIsAcceptedOnce(lateness: Int) throws {
        let receiver = makeReceiver()
        let held: UInt64 = 3
        let highest = held + UInt64(lateness)

        // Everything around the held nonce arrives in order; the held one
        // turns up only after `lateness` newer packets.
        for nonce in 0...highest where nonce != held {
            #expect(deliver(try transportPayload(nonce: nonce), to: receiver) == .accepted)
        }

        let late = try transportPayload(nonce: held)
        #expect(deliver(late, to: receiver) == .accepted)
        #expect(deliver(late, to: receiver) == .replay)
    }

    @Test("Nonce 0 arriving after later nonces is accepted once")
    func lateNonceZeroIsAcceptedOnce() throws {
        let receiver = makeReceiver()
        #expect(deliver(try transportPayload(nonce: 1), to: receiver) == .accepted)

        let zero = try transportPayload(nonce: 0)
        #expect(deliver(zero, to: receiver) == .accepted)
        #expect(deliver(zero, to: receiver) == .replay)
    }

    // MARK: - Advancing the window

    @Test("One advance of any size keeps every earlier nonce at its offset")
    func everyAdvanceSizePreservesTheWindow() throws {
        // Nonces 0...15 arrive first with one held back, then a single jump.
        let held: UInt64 = 5
        let earlier = try (UInt64(0)...15).filter { $0 != held }.map {
            (nonce: $0, payload: try transportPayload(nonce: $0))
        }
        let heldPayload = try transportPayload(nonce: held)
        var failures: [String] = []

        for shift in UInt64(1)...1100 {
            let receiver = makeReceiver()
            for entry in earlier {
                if deliver(entry.payload, to: receiver) != .accepted {
                    failures.append("shift \(shift): nonce \(entry.nonce) refused on first delivery")
                }
            }

            let highest = 15 + shift
            let newest = try transportPayload(nonce: highest)
            if deliver(newest, to: receiver) != .accepted {
                failures.append("shift \(shift): new highest \(highest) refused")
            }

            // Seen before the jump: a replay whether the jump left it inside
            // the window or pushed it out.
            for entry in earlier {
                if deliver(entry.payload, to: receiver) != .replay {
                    failures.append("shift \(shift): nonce \(entry.nonce) accepted twice")
                }
            }

            // Never seen: accepted once while still inside the window, refused
            // once the jump has carried the window past it.
            let heldIsInside = highest - held < Self.windowSize
            if deliver(heldPayload, to: receiver) != (heldIsInside ? .accepted : .replay) {
                failures.append("shift \(shift): held nonce \(held) \(heldIsInside ? "refused" : "accepted")")
            }
            if deliver(heldPayload, to: receiver) != .replay {
                failures.append("shift \(shift): held nonce \(held) accepted twice")
            }

            // The slot just below the new highest was skipped over, not seen.
            if shift > 1 {
                let skipped = try transportPayload(nonce: highest - 1)
                if deliver(skipped, to: receiver) != .accepted {
                    failures.append("shift \(shift): skipped nonce \(highest - 1) refused")
                }
                if deliver(skipped, to: receiver) != .replay {
                    failures.append("shift \(shift): skipped nonce \(highest - 1) accepted twice")
                }
            }
            if deliver(newest, to: receiver) != .replay {
                failures.append("shift \(shift): highest \(highest) accepted twice")
            }
        }

        #expect(
            failures.isEmpty,
            "\(failures.count) failures, starting with: \(failures.prefix(10).joined(separator: "; "))"
        )
    }

    @Test("A nonce a full window behind the highest is rejected even if never seen")
    func nonceOneWindowBehindIsRejected() throws {
        let receiver = makeReceiver()
        let highest: UInt64 = 5000

        #expect(deliver(try transportPayload(nonce: highest), to: receiver) == .accepted)

        // Offset 1023 is the oldest slot still inside the window.
        #expect(deliver(try transportPayload(nonce: highest - (Self.windowSize - 1)), to: receiver) == .accepted)
        #expect(deliver(try transportPayload(nonce: highest - Self.windowSize), to: receiver) == .replay)
    }

    @Test("A jump of a whole window or more forgets the nonces it leaves behind")
    func jumpPastWindowForgetsOlderNonces() throws {
        let receiver = makeReceiver()
        for nonce in UInt64(0)...9 {
            #expect(deliver(try transportPayload(nonce: nonce), to: receiver) == .accepted)
        }

        #expect(deliver(try transportPayload(nonce: 5000), to: receiver) == .accepted)

        for nonce in UInt64(0)...9 {
            #expect(deliver(try transportPayload(nonce: nonce), to: receiver) == .replay)
        }
        // Nothing near the new highest was marked by the jump.
        #expect(deliver(try transportPayload(nonce: 4999), to: receiver) == .accepted)
        #expect(deliver(try transportPayload(nonce: 4999), to: receiver) == .replay)
        #expect(deliver(try transportPayload(nonce: 5000), to: receiver) == .replay)
    }

    // MARK: - Authentication ordering

    @Test("A forged packet does not use up the nonce it claims")
    func forgedPacketDoesNotConsumeNonce() throws {
        let receiver = makeReceiver()
        for nonce in UInt64(0)...9 where nonce != 4 {
            #expect(deliver(try transportPayload(nonce: nonce), to: receiver) == .accepted)
        }

        // Ahead of the highest, and late inside the window.
        for nonce in [UInt64(12), 4] {
            let genuine = try transportPayload(nonce: nonce)
            #expect(deliver(forged(genuine), to: receiver) == .failed)
            #expect(deliver(genuine, to: receiver) == .accepted)
            #expect(deliver(genuine, to: receiver) == .replay)
        }
    }

    @Test("A forged packet far ahead neither moves nor clears the window")
    func forgedPacketLeavesWindowUntouched() throws {
        let receiver = makeReceiver()
        #expect(deliver(try transportPayload(nonce: 0), to: receiver) == .accepted)
        #expect(deliver(try transportPayload(nonce: 2), to: receiver) == .accepted)

        let farAhead = try transportPayload(nonce: 5000)
        #expect(deliver(forged(farAhead), to: receiver) == .failed)

        // Had the forgery advanced the window, nonce 1 would now be too old
        // and nonce 0 would have been forgotten.
        #expect(deliver(try transportPayload(nonce: 1), to: receiver) == .accepted)
        #expect(deliver(try transportPayload(nonce: 0), to: receiver) == .replay)
        #expect(deliver(farAhead, to: receiver) == .accepted)
    }

    // MARK: - Reference model

    @Test(
        "The window agrees with a set-based reference model under reordering, loss and replay",
        arguments: [UInt64(0x9E37_79B9_7F4A_7C15), 0xD1B5_4A32_D192_ED03, 0x0000_0000_0000_002A]
    )
    func windowMatchesReferenceModel(seed: UInt64) throws {
        let receiver = makeReceiver()
        var model = ReferenceWindow(size: Self.windowSize)
        var random = SplitMix64(state: seed)
        var recent: [UInt64] = []
        var divergence: String?

        for step in 0..<20_000 {
            let nonce = nextNonce(highest: model.highest, recent: recent, random: &random)
            let highestBefore = model.highest
            let expected = model.accept(nonce)
            let actual = deliver(try transportPayload(nonce: nonce), to: receiver) == .accepted

            if expected != actual {
                // Model and receiver have parted ways, so later steps would
                // only report noise.
                divergence = "step \(step): nonce \(nonce) with highest \(highestBefore) "
                    + "should be \(expected ? "accepted" : "refused")"
                break
            }

            recent.append(nonce)
            if recent.count > 64 { recent.removeFirst() }
        }

        #expect(divergence == nil, "\(divergence ?? "")")
    }

    // MARK: - Helpers

    private enum Outcome: Equatable {
        case accepted
        case replay
        case failed
    }

    private func makeReceiver() -> NoiseCipherState {
        NoiseCipherState(key: key, useExtractedNonce: true)
    }

    private func deliver(_ payload: Data, to receiver: NoiseCipherState) -> Outcome {
        do {
            _ = try receiver.decrypt(ciphertext: payload)
            return .accepted
        } catch NoiseError.replayDetected {
            return .replay
        } catch {
            return .failed
        }
    }

    /// A transport payload as it travels on the wire: the 4-byte big-endian
    /// nonce followed by the ChaCha20-Poly1305 ciphertext and tag.
    private func transportPayload(nonce: UInt64) throws -> Data {
        var fullNonce = Data(count: 12)
        withUnsafeBytes(of: nonce.littleEndian) { bytes in
            fullNonce.replaceSubrange(4..<12, with: bytes)
        }
        let sealedBox = try ChaChaPoly.seal(
            Data("nonce \(nonce)".utf8),
            using: key,
            nonce: ChaChaPoly.Nonce(data: fullNonce)
        )
        let prefix = withUnsafeBytes(of: nonce.bigEndian) { Data($0.suffix(4)) }
        return prefix + sealedBox.ciphertext + sealedBox.tag
    }

    /// The same payload with one bit of its authentication tag flipped.
    private func forged(_ payload: Data) -> Data {
        var copy = payload
        copy[copy.index(before: copy.endIndex)] ^= 0x01
        return copy
    }

    /// Mixes small in-order steps, big jumps (including past the window),
    /// late and too-old nonces, and straight replays of recent deliveries.
    private func nextNonce(highest: UInt64, recent: [UInt64], random: inout SplitMix64) -> UInt64 {
        switch random.next() % 100 {
        case 0..<50:
            return highest + 1 + random.next() % 12
        case 50..<65:
            return highest + 13 + random.next() % 1088
        case 65..<90:
            let back = random.next() % 1100
            return highest >= back ? highest - back : highest
        default:
            return recent.isEmpty ? highest : recent[Int(random.next() % UInt64(recent.count))]
        }
    }
}

/// The contract in its simplest form: remember every accepted nonce.
private struct ReferenceWindow {
    let size: UInt64
    private(set) var highest: UInt64 = 0
    private var seen: Set<UInt64> = []

    init(size: UInt64) {
        self.size = size
    }

    mutating func accept(_ nonce: UInt64) -> Bool {
        if highest >= size, nonce <= highest - size { return false }
        if nonce <= highest, seen.contains(nonce) { return false }
        seen.insert(nonce)
        highest = max(highest, nonce)
        return true
    }
}

/// Deterministic generator so a failure reproduces from its seed.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
