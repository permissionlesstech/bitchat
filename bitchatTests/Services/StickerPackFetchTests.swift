//
// StickerPackFetchTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

/// Fetch-path tests for `StickerPackService` with injected relay query,
/// downloader, and clock — no relay, Tor, or network access.
@Suite("Sticker Pack Fetch Tests")
struct StickerPackFetchTests {

    private final class Counter: @unchecked Sendable { var value = 0 }
    private final class MutableClock: @unchecked Sendable {
        var current = Date(timeIntervalSince1970: 1_700_000_000)
        func now() -> Date { current }
    }

    private let pubkey = String(repeating: "a", count: 64)

    @MainActor
    private func makeService(
        clock: MutableClock,
        relayQuery: @escaping StickerPackService.RelayQuery
    ) -> StickerPackService {
        StickerPackService(
            cache: StickerCache(
                baseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("sticker-pack-fetch-tests-\(UUID().uuidString)", isDirectory: true)
            ),
            relayQuery: relayQuery,
            downloader: { _ in throw URLError(.notConnectedToInternet) },
            networkActivationAllowed: { true },
            metadataURL: nil,
            now: clock.now
        )
    }

    @MainActor
    @Test("missing pack is negative-cached: repeats back off instead of re-querying relays")
    func missingPackIsNegativeCached() async {
        let clock = MutableClock()
        let calls = Counter()
        let service = makeService(clock: clock) { _ in
            calls.value += 1
            return []
        }

        await #expect(throws: StickerPackService.StickerPackError.packNotFound) {
            try await service.fetchPack(authorPubkeyHex: pubkey, identifier: "nope")
        }
        #expect(calls.value == 1)

        // Immediate retry short-circuits into backoff — no second relay query.
        // (Every retry would be a repeat read beacon to the relay set.)
        do {
            _ = try await service.fetchPack(authorPubkeyHex: pubkey, identifier: "nope")
            Issue.record("expected packFetchBackoff")
        } catch let StickerPackService.StickerPackError.packFetchBackoff(retryAfter) {
            #expect(retryAfter > clock.current)
        } catch {
            Issue.record("expected packFetchBackoff, got \(error)")
        }
        #expect(calls.value == 1)

        // After the initial 30s backoff elapses the relay is queried again,
        // and the repeated miss backs off further.
        clock.current = clock.current.addingTimeInterval(31)
        await #expect(throws: StickerPackService.StickerPackError.packNotFound) {
            try await service.fetchPack(authorPubkeyHex: pubkey, identifier: "nope")
        }
        #expect(calls.value == 2)

        // Third failure doubled the backoff: +45s is still inside the 60s window.
        clock.current = clock.current.addingTimeInterval(45)
        do {
            _ = try await service.fetchPack(authorPubkeyHex: pubkey, identifier: "nope")
            Issue.record("expected packFetchBackoff")
        } catch let StickerPackService.StickerPackError.packFetchBackoff(retryAfter) {
            #expect(retryAfter > clock.current)
        } catch {
            Issue.record("expected packFetchBackoff, got \(error)")
        }
        #expect(calls.value == 2)
    }

    @MainActor
    @Test("invalid coordinates are rejected before any relay query")
    func invalidCoordinateRejectedBeforeQuery() async {
        let clock = MutableClock()
        let calls = Counter()
        let service = makeService(clock: clock) { _ in
            calls.value += 1
            return []
        }

        await #expect(throws: StickerPackService.StickerPackError.invalidCoordinate) {
            try await service.fetchPack(authorPubkeyHex: "not-hex", identifier: "nope")
        }
        // A coordinate the wire codec could never express is refused up front.
        await #expect(throws: StickerPackService.StickerPackError.invalidCoordinate) {
            try await service.fetchPack(authorPubkeyHex: pubkey, identifier: "has spaces")
        }
        #expect(calls.value == 0)
    }
}
