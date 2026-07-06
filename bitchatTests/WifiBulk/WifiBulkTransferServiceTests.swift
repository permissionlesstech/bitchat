//
// WifiBulkTransferServiceTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Network
import Testing
@testable import bitchat

/// Thread-safe capture box for closures invoked on service queues.
final class WifiBulkTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int { values.count }
}

func wifiBulkWait(
    timeout: TimeInterval = 5.0,
    _ condition: @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// Negotiation/fallback decisions exercised through the real service with the
/// network kept on loopback and Bonjour publication disabled.
@Suite("WifiBulk transfer service negotiation", .serialized)
struct WifiBulkTransferServiceTests {
    private static let peer = PeerID(str: "aabbccddeeff0011")

    private func makeConfig() -> WifiBulkTransferServiceConfig {
        var config = WifiBulkTransferServiceConfig()
        config.usePeerToPeer = false
        config.publishBonjourService = false
        config.offerTimeout = 0.25
        config.transferWindow = 2.0
        return config
    }

    private func makeEnvironment(
        sendNoisePayload: @escaping (Data, PeerID) -> Bool,
        deliver: @escaping (Data, PeerID, Int) -> Void = { _, _, _ in },
        progressEvents: WifiBulkTestBox<String>? = nil
    ) -> WifiBulkTransferServiceEnvironment {
        WifiBulkTransferServiceEnvironment(
            sendNoisePayload: sendNoisePayload,
            isPeerConnected: { _ in true },
            deliverReceivedFile: deliver,
            progressStart: { id, total in progressEvents?.append("start:\(id):\(total)") },
            progressChunkSent: { id in progressEvents?.append("chunk:\(id)") },
            progressReset: { id in progressEvents?.append("reset:\(id)") },
            progressCancel: { id in progressEvents?.append("cancel:\(id)") }
        )
    }

    private var payload: Data { Data(repeating: 0x42, count: 100_000) }

    @Test("No established Noise session falls straight back to BLE")
    func noSessionFallsBack() async {
        let fallbacks = WifiBulkTestBox<Bool>()
        let service = WifiBulkTransferService(
            environment: makeEnvironment(sendNoisePayload: { _, _ in false }),
            config: makeConfig()
        )
        service.sendFile(payload: payload, to: Self.peer, transferId: "t-nosession") {
            fallbacks.append(true)
        }
        #expect(await wifiBulkWait { fallbacks.count == 1 })
        #expect(service._test_activeOutgoingCount == 0)
    }

    @Test("Unanswered offer times out and falls back exactly once")
    func offerTimeoutFallsBackOnce() async {
        let fallbacks = WifiBulkTestBox<Bool>()
        let progress = WifiBulkTestBox<String>()
        let service = WifiBulkTransferService(
            environment: makeEnvironment(sendNoisePayload: { _, _ in true }, progressEvents: progress),
            config: makeConfig()
        )
        service.sendFile(payload: payload, to: Self.peer, transferId: "t-timeout") {
            fallbacks.append(true)
        }
        #expect(await wifiBulkWait { fallbacks.count == 1 })
        // Wait past the transfer window: the expiry must not double-fire.
        try? await Task.sleep(nanoseconds: 2_300_000_000)
        #expect(fallbacks.count == 1)
        #expect(service._test_activeOutgoingCount == 0)
        // Progress state was silently reset ahead of the BLE re-start.
        #expect(progress.values.contains("reset:t-timeout"))
        #expect(!progress.values.contains("cancel:t-timeout"))
    }

    @Test("Declined offer falls back exactly once, even on duplicate declines")
    func declineFallsBackOnce() async {
        let fallbacks = WifiBulkTestBox<Bool>()
        let offers = WifiBulkTestBox<Data>()
        var service: WifiBulkTransferService?
        let environment = makeEnvironment(sendNoisePayload: { typed, peer in
            guard typed.first == NoisePayloadType.bulkTransferOffer.rawValue,
                  let offer = WifiBulkOffer.decode(typed.dropFirst()) else { return true }
            offers.append(offer.transferID)
            guard let decline = WifiBulkResponse.decline(transferID: offer.transferID).encode() else { return true }
            // Deliver the decline twice; the fallback must still fire once.
            service?.handleResponsePayload(decline, from: peer)
            service?.handleResponsePayload(decline, from: peer)
            return true
        })
        let sut = WifiBulkTransferService(environment: environment, config: makeConfig())
        service = sut
        sut.sendFile(payload: payload, to: Self.peer, transferId: "t-decline") {
            fallbacks.append(true)
        }
        #expect(await wifiBulkWait { fallbacks.count == 1 })
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(fallbacks.count == 1)
        #expect(sut._test_activeOutgoingCount == 0)
    }

    @Test("Responses from the wrong peer are ignored")
    func wrongPeerResponseIgnored() async {
        let fallbacks = WifiBulkTestBox<Bool>()
        var service: WifiBulkTransferService?
        let environment = makeEnvironment(sendNoisePayload: { typed, _ in
            guard typed.first == NoisePayloadType.bulkTransferOffer.rawValue,
                  let offer = WifiBulkOffer.decode(typed.dropFirst()),
                  let decline = WifiBulkResponse.decline(transferID: offer.transferID).encode() else { return true }
            // Decline arrives from an unrelated peer: must be ignored, so the
            // transfer ends via offer timeout instead.
            service?.handleResponsePayload(decline, from: PeerID(str: "1122334455667788"))
            return true
        })
        let sut = WifiBulkTransferService(environment: environment, config: makeConfig())
        service = sut
        sut.sendFile(payload: payload, to: Self.peer, transferId: "t-wrongpeer") {
            fallbacks.append(true)
        }
        // Not fallen back before the offer timeout window…
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fallbacks.count == 0)
        // …but the timeout still cleans up.
        #expect(await wifiBulkWait { fallbacks.count == 1 })
    }

    @Test("User cancel tears down without BLE fallback")
    func userCancelDoesNotFallBack() async {
        let fallbacks = WifiBulkTestBox<Bool>()
        let progress = WifiBulkTestBox<String>()
        let service = WifiBulkTransferService(
            environment: makeEnvironment(sendNoisePayload: { _, _ in true }, progressEvents: progress),
            config: makeConfig()
        )
        service.sendFile(payload: payload, to: Self.peer, transferId: "t-cancel") {
            fallbacks.append(true)
        }
        #expect(await wifiBulkWait { service._test_activeOutgoingCount == 1 })
        service.cancelTransfer(transferId: "t-cancel")
        #expect(await wifiBulkWait { service._test_activeOutgoingCount == 0 })
        try? await Task.sleep(nanoseconds: 400_000_000) // past the offer timeout
        #expect(fallbacks.count == 0)
        #expect(progress.values.contains("cancel:t-cancel"))
    }

    @Test("Receiver declines an offer that exceeds its size cap")
    func receiverDeclinesOversizedOffer() async {
        let responses = WifiBulkTestBox<Data>()
        let service = WifiBulkTransferService(
            environment: makeEnvironment(sendNoisePayload: { typed, _ in
                if typed.first == NoisePayloadType.bulkTransferResponse.rawValue {
                    responses.append(Data(typed.dropFirst()))
                }
                return true
            }),
            config: makeConfig()
        )
        let offer = WifiBulkOffer(
            transferID: Data(repeating: 7, count: WifiBulkWire.transferIDLength),
            fileSize: UInt64(FileTransferLimits.maxWifiBulkPayloadBytes) + 1,
            payloadHash: Data(repeating: 8, count: WifiBulkWire.hashLength),
            token: Data(repeating: 9, count: WifiBulkWire.tokenLength),
            serviceName: "0011223344556677"
        )
        if let encoded = offer.encode() {
            service.handleOfferPayload(encoded, from: Self.peer)
        }
        #expect(await wifiBulkWait { responses.count == 1 })
        let response = WifiBulkResponse.decode(responses.values[0])
        #expect(response?.accepted == false)
        #expect(response?.transferID == offer.transferID)
        #expect(service._test_activeIncomingCount == 0)
    }

    @Test("Malformed offers are dropped without a response")
    func malformedOfferDropped() async {
        let responses = WifiBulkTestBox<Data>()
        let service = WifiBulkTransferService(
            environment: makeEnvironment(sendNoisePayload: { typed, _ in
                responses.append(typed)
                return true
            }),
            config: makeConfig()
        )
        service.handleOfferPayload(Data([0x01, 0x02, 0x03]), from: Self.peer)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(responses.count == 0)
        #expect(service._test_activeIncomingCount == 0)
    }

    @Test("stop() tears down active transfers without falling back")
    func stopTearsDownWithoutFallback() async {
        let fallbacks = WifiBulkTestBox<Bool>()
        let service = WifiBulkTransferService(
            environment: makeEnvironment(sendNoisePayload: { _, _ in true }),
            config: makeConfig()
        )
        service.sendFile(payload: payload, to: Self.peer, transferId: "t-stop") {
            fallbacks.append(true)
        }
        #expect(await wifiBulkWait { service._test_activeOutgoingCount == 1 })
        service.stop()
        #expect(await wifiBulkWait { service._test_activeOutgoingCount == 0 })
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(fallbacks.count == 0)
    }
}
