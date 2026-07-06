//
// WifiBulkLoopbackTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import BitFoundation
import Foundation
import Network
import Testing
@testable import bitchat

/// End-to-end integration over real Network.framework sockets on localhost:
/// two `WifiBulkTransferService` instances negotiate through an in-process
/// "Noise" pipe, then move the payload over a genuine TCP connection using
/// the production listener/browser-free test hooks (peer-to-peer and Bonjour
/// are disabled — unit-test hosts have no AWDL or mDNS access).
@Suite("WifiBulk loopback integration", .serialized)
struct WifiBulkLoopbackTests {
    private static let senderPeer = PeerID(str: "00112233aabbccdd")
    private static let receiverPeer = PeerID(str: "ddccbbaa33221100")

    private func makeConfig() -> WifiBulkTransferServiceConfig {
        var config = WifiBulkTransferServiceConfig()
        config.usePeerToPeer = false
        config.publishBonjourService = false
        config.offerTimeout = 5.0
        config.transferWindow = 10.0
        return config
    }

    @Test("Payload crosses a real TCP loopback channel and lands verified")
    func loopbackTransferSucceeds() async throws {
        let payload = Data((0..<300_000).map { UInt8($0 % 249) })

        let delivered = WifiBulkTestBox<Data>()
        let progress = WifiBulkTestBox<String>()
        let fallbacks = WifiBulkTestBox<Bool>()
        let ports = WifiBulkTestBox<(Data, UInt16)>()
        let offers = WifiBulkTestBox<Data>()

        var senderService: WifiBulkTransferService?
        var receiverService: WifiBulkTransferService?

        // Once the receiver has accepted AND the listener port is known,
        // connect the receiver straight to 127.0.0.1 (Bonjour stand-in).
        let accepted = WifiBulkTestBox<Data>()
        let connectIfReady: () -> Void = {
            guard let (transferID, port) = ports.values.first,
                  accepted.values.contains(transferID),
                  let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            receiverService?._test_connectIncoming(
                transferID: transferID,
                to: NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
            )
        }

        let senderEnv = WifiBulkTransferServiceEnvironment(
            sendNoisePayload: { typed, _ in
                // Sender → receiver control plane (offer).
                guard typed.first == NoisePayloadType.bulkTransferOffer.rawValue else { return true }
                offers.append(Data(typed.dropFirst()))
                receiverService?.handleOfferPayload(Data(typed.dropFirst()), from: Self.senderPeer)
                return true
            },
            isPeerConnected: { _ in true },
            deliverReceivedFile: { _, _, _ in },
            progressStart: { id, total in progress.append("start:\(id):\(total)") },
            progressChunkSent: { id in progress.append("chunk:\(id)") },
            progressReset: { id in progress.append("reset:\(id)") },
            progressCancel: { id in progress.append("cancel:\(id)") }
        )
        let receiverEnv = WifiBulkTransferServiceEnvironment(
            sendNoisePayload: { typed, _ in
                // Receiver → sender control plane (response).
                guard typed.first == NoisePayloadType.bulkTransferResponse.rawValue else { return true }
                let body = Data(typed.dropFirst())
                if let response = WifiBulkResponse.decode(body), response.accepted {
                    accepted.append(response.transferID)
                }
                senderService?.handleResponsePayload(body, from: Self.receiverPeer)
                connectIfReady()
                return true
            },
            isPeerConnected: { _ in true },
            deliverReceivedFile: { data, peer, limit in
                #expect(peer == Self.senderPeer)
                #expect(limit == FileTransferLimits.maxWifiBulkPayloadBytes)
                delivered.append(data)
            },
            progressStart: { _, _ in },
            progressChunkSent: { _ in },
            progressReset: { _ in },
            progressCancel: { _ in }
        )

        let sender = WifiBulkTransferService(environment: senderEnv, config: makeConfig())
        sender._test_onListenerReady = { transferID, port in
            ports.append((transferID, port))
            connectIfReady()
        }
        let receiver = WifiBulkTransferService(environment: receiverEnv, config: makeConfig())
        senderService = sender
        receiverService = receiver

        sender.sendFile(payload: payload, to: Self.receiverPeer, transferId: "t-loopback") {
            fallbacks.append(true)
        }

        #expect(await wifiBulkWait(timeout: 10.0) { delivered.count == 1 })
        #expect(delivered.values.first == payload)
        #expect(fallbacks.count == 0)

        // Deterministic teardown: both sides drop all transfer state.
        #expect(await wifiBulkWait { sender._test_activeOutgoingCount == 0 })
        #expect(await wifiBulkWait { receiver._test_activeIncomingCount == 0 })

        // Progress mirrored the BLE contract: start with the chunk total,
        // then exactly `total` chunk ticks (the last one gated on the receipt).
        let totalChunks = (payload.count + TransportConfig.wifiBulkChunkBytes - 1) / TransportConfig.wifiBulkChunkBytes
        #expect(await wifiBulkWait { progress.values.filter { $0 == "chunk:t-loopback" }.count == totalChunks })
        #expect(progress.values.first == "start:t-loopback:\(totalChunks)")
        #expect(!progress.values.contains("reset:t-loopback"))
    }

    @Test("A gatecrasher without the channel key is disconnected and the real peer still succeeds")
    func gatecrasherIsRejected() async throws {
        let payload = Data((0..<150_000).map { UInt8($0 % 241) })

        let delivered = WifiBulkTestBox<Data>()
        let fallbacks = WifiBulkTestBox<Bool>()
        let ports = WifiBulkTestBox<(Data, UInt16)>()
        let accepted = WifiBulkTestBox<Data>()

        var senderService: WifiBulkTransferService?
        var receiverService: WifiBulkTransferService?

        let gatecrashed = WifiBulkTestBox<Bool>()
        let connectIfReady: () -> Void = {
            guard let (transferID, port) = ports.values.first,
                  accepted.values.contains(transferID),
                  gatecrashed.count > 0,
                  let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            receiverService?._test_connectIncoming(
                transferID: transferID,
                to: NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
            )
        }

        let senderEnv = WifiBulkTransferServiceEnvironment(
            sendNoisePayload: { typed, _ in
                guard typed.first == NoisePayloadType.bulkTransferOffer.rawValue else { return true }
                receiverService?.handleOfferPayload(Data(typed.dropFirst()), from: Self.senderPeer)
                return true
            },
            isPeerConnected: { _ in true },
            deliverReceivedFile: { _, _, _ in },
            progressStart: { _, _ in },
            progressChunkSent: { _ in },
            progressReset: { _ in },
            progressCancel: { _ in }
        )
        let receiverEnv = WifiBulkTransferServiceEnvironment(
            sendNoisePayload: { typed, _ in
                guard typed.first == NoisePayloadType.bulkTransferResponse.rawValue else { return true }
                let body = Data(typed.dropFirst())
                if let response = WifiBulkResponse.decode(body), response.accepted {
                    accepted.append(response.transferID)
                }
                senderService?.handleResponsePayload(body, from: Self.receiverPeer)
                connectIfReady()
                return true
            },
            isPeerConnected: { _ in true },
            deliverReceivedFile: { data, _, _ in delivered.append(data) },
            progressStart: { _, _ in },
            progressChunkSent: { _ in },
            progressReset: { _ in },
            progressCancel: { _ in }
        )

        let sender = WifiBulkTransferService(environment: senderEnv, config: makeConfig())
        let gateQueue = DispatchQueue(label: "test.gatecrasher")
        sender._test_onListenerReady = { transferID, port in
            ports.append((transferID, port))
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            // A stranger who saw the Bonjour advertisement connects first and
            // sends garbage that cannot carry a valid MAC.
            let crasher = NWConnection(
                to: NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort),
                using: .tcp
            )
            crasher.stateUpdateHandler = { state in
                if case .ready = state {
                    let junkBody = Data(repeating: 0xAA, count: 60)
                    crasher.send(
                        content: WifiBulkCrypto.frameData(body: junkBody),
                        completion: .contentProcessed { _ in
                            gatecrashed.append(true)
                            connectIfReady()
                        }
                    )
                }
            }
            crasher.start(queue: gateQueue)
        }
        let receiver = WifiBulkTransferService(environment: receiverEnv, config: makeConfig())
        senderService = sender
        receiverService = receiver

        sender.sendFile(payload: payload, to: Self.receiverPeer, transferId: "t-gatecrash") {
            fallbacks.append(true)
        }

        #expect(await wifiBulkWait(timeout: 10.0) { delivered.count == 1 })
        #expect(delivered.values.first == payload)
        #expect(fallbacks.count == 0)
        #expect(await wifiBulkWait { sender._test_activeOutgoingCount == 0 })
    }

    @Test("Receiver vanishing mid-negotiation leaves the sender to time out into BLE")
    func vanishedReceiverFallsBack() async {
        var config = makeConfig()
        config.offerTimeout = 0.3

        let fallbacks = WifiBulkTestBox<Bool>()
        let environment = WifiBulkTransferServiceEnvironment(
            sendNoisePayload: { _, _ in true }, // offer sent, receiver never answers
            isPeerConnected: { _ in true },
            deliverReceivedFile: { _, _, _ in },
            progressStart: { _, _ in },
            progressChunkSent: { _ in },
            progressReset: { _ in },
            progressCancel: { _ in }
        )
        let sender = WifiBulkTransferService(environment: environment, config: config)
        sender.sendFile(payload: Data(repeating: 1, count: 100_000), to: Self.receiverPeer, transferId: "t-vanish") {
            fallbacks.append(true)
        }
        #expect(await wifiBulkWait { fallbacks.count == 1 })
        #expect(sender._test_activeOutgoingCount == 0)
    }
}
