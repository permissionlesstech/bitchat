//
// WifiBulkPolicyTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("WifiBulk policy")
struct WifiBulkPolicyTests {
    private func candidate(
        payloadBytes: Int = 300_000,
        capabilities: PeerCapabilities = [.wifiBulk],
        direct: Bool = true,
        session: Bool = true
    ) -> WifiBulkPolicy.SendCandidate {
        WifiBulkPolicy.SendCandidate(
            payloadBytes: payloadBytes,
            peerCapabilities: capabilities,
            isDirectlyConnected: direct,
            hasEstablishedNoiseSession: session
        )
    }

    @Test("Eligible large transfer to a direct wifiBulk peer is offered")
    func eligibleTransferOffered() {
        #expect(WifiBulkPolicy.shouldOffer(candidate(), enabled: true))
    }

    @Test("Fallback matrix: every failed gate keeps the transfer on BLE")
    func fallbackMatrix() {
        // Feature disabled.
        #expect(!WifiBulkPolicy.shouldOffer(candidate(), enabled: false))
        // Small file: negotiation overhead not worth it.
        #expect(!WifiBulkPolicy.shouldOffer(candidate(payloadBytes: 64 * 1024), enabled: true))
        // Peer doesn't advertise the capability.
        #expect(!WifiBulkPolicy.shouldOffer(candidate(capabilities: []), enabled: true))
        #expect(!WifiBulkPolicy.shouldOffer(candidate(capabilities: [.prekeys, .gateway]), enabled: true))
        // Multi-hop recipient (reachable but not directly connected).
        #expect(!WifiBulkPolicy.shouldOffer(candidate(direct: false), enabled: true))
        // No established Noise session to carry the offer.
        #expect(!WifiBulkPolicy.shouldOffer(candidate(session: false), enabled: true))
        // Payload beyond even the Wi-Fi ceiling.
        #expect(!WifiBulkPolicy.shouldOffer(
            candidate(payloadBytes: FileTransferLimits.maxWifiBulkPayloadBytes + 1),
            enabled: true
        ))
    }

    @Test("Offer threshold is strictly greater than the minimum")
    func offerThresholdBoundary() {
        #expect(!WifiBulkPolicy.shouldOffer(
            candidate(payloadBytes: TransportConfig.wifiBulkMinPayloadBytes),
            enabled: true
        ))
        #expect(WifiBulkPolicy.shouldOffer(
            candidate(payloadBytes: TransportConfig.wifiBulkMinPayloadBytes + 1),
            enabled: true
        ))
    }

    private func offer(fileSize: UInt64) -> WifiBulkOffer {
        WifiBulkOffer(
            transferID: Data(repeating: 1, count: WifiBulkWire.transferIDLength),
            fileSize: fileSize,
            payloadHash: Data(repeating: 2, count: WifiBulkWire.hashLength),
            token: Data(repeating: 3, count: WifiBulkWire.tokenLength),
            serviceName: "0011223344556677"
        )
    }

    @Test("Receiver accepts an in-cap offer from a direct peer")
    func receiverAccepts() {
        #expect(WifiBulkPolicy.shouldAccept(
            offer: offer(fileSize: 1_000_000),
            senderIsDirectlyConnected: true,
            activeIncomingTransfers: 0,
            enabled: true
        ))
    }

    @Test("Receiver enforces its own size cap, not the sender's word")
    func receiverSizeCap() {
        #expect(!WifiBulkPolicy.shouldAccept(
            offer: offer(fileSize: UInt64(FileTransferLimits.maxWifiBulkPayloadBytes) + 1),
            senderIsDirectlyConnected: true,
            activeIncomingTransfers: 0,
            enabled: true
        ))
        #expect(WifiBulkPolicy.shouldAccept(
            offer: offer(fileSize: UInt64(FileTransferLimits.maxWifiBulkPayloadBytes)),
            senderIsDirectlyConnected: true,
            activeIncomingTransfers: 0,
            enabled: true
        ))
        #expect(!WifiBulkPolicy.shouldAccept(
            offer: offer(fileSize: 0),
            senderIsDirectlyConnected: true,
            activeIncomingTransfers: 0,
            enabled: true
        ))
    }

    @Test("Receiver declines when disabled, indirect, or saturated")
    func receiverDeclines() {
        #expect(!WifiBulkPolicy.shouldAccept(
            offer: offer(fileSize: 1000),
            senderIsDirectlyConnected: true,
            activeIncomingTransfers: 0,
            enabled: false
        ))
        #expect(!WifiBulkPolicy.shouldAccept(
            offer: offer(fileSize: 1000),
            senderIsDirectlyConnected: false,
            activeIncomingTransfers: 0,
            enabled: true
        ))
        #expect(!WifiBulkPolicy.shouldAccept(
            offer: offer(fileSize: 1000),
            senderIsDirectlyConnected: true,
            activeIncomingTransfers: TransportConfig.wifiBulkMaxConcurrentIncoming,
            enabled: true
        ))
    }

    @Test("This build advertises the wifiBulk capability when enabled")
    func localCapabilityAdvertised() {
        #expect(PeerCapabilities.localSupported.contains(.wifiBulk) == TransportConfig.wifiBulkEnabled)
    }

    @Test("File packets above the BLE cap encode/decode only with the Wi-Fi limit")
    func filePacketWifiLimit() throws {
        let content = Data(repeating: 0x5A, count: 2 * 1024 * 1024) // 2 MiB
        let packet = BitchatFilePacket(fileName: "big.jpg", fileSize: UInt64(content.count), mimeType: "image/jpeg", content: content)

        // BLE cap unchanged.
        #expect(packet.encode() == nil)

        let encoded = try #require(packet.encode(limit: FileTransferLimits.maxWifiBulkPayloadBytes))
        #expect(BitchatFilePacket.decode(encoded) == nil) // BLE-cap decode still rejects
        let decoded = try #require(BitchatFilePacket.decode(encoded, limit: FileTransferLimits.maxWifiBulkPayloadBytes))
        #expect(decoded.content == content)
        #expect(decoded.fileName == "big.jpg")
    }
}
