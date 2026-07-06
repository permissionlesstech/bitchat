//
// WifiBulkTransferService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import CryptoKit
import Foundation
import Network

/// Narrow environment for `WifiBulkTransferService`. All BLE-service queue
/// hops live inside the closures supplied by `BLEService`, keeping this
/// service independently testable.
struct WifiBulkTransferServiceEnvironment {
    /// Sends a typed payload inside the established Noise session with the
    /// peer. Returns false when no established session exists (the caller
    /// falls back to BLE).
    let sendNoisePayload: (_ typedPayload: Data, _ peerID: PeerID) -> Bool
    /// Whether the peer is on a direct BLE link right now.
    let isPeerConnected: (PeerID) -> Bool
    /// Delivers a fully received, hash-verified payload (encoded
    /// `BitchatFilePacket` TLV) into the normal incoming-file pipeline.
    let deliverReceivedFile: (_ payload: Data, _ peerID: PeerID, _ payloadLimit: Int) -> Void
    /// Progress bus hooks mirroring the BLE fragmentation path so the UI is
    /// unchanged (chunks report as "fragments").
    let progressStart: (_ transferId: String, _ totalChunks: Int) -> Void
    let progressChunkSent: (_ transferId: String) -> Void
    /// Silently forgets progress state ahead of a BLE fallback re-start.
    let progressReset: (_ transferId: String) -> Void
    /// Emits the cancelled event for user-cancelled transfers.
    let progressCancel: (_ transferId: String) -> Void
}

/// Knobs with test overrides; production values come from `TransportConfig`.
struct WifiBulkTransferServiceConfig {
    var serviceType: String = TransportConfig.wifiBulkServiceType
    var chunkBytes: Int = TransportConfig.wifiBulkChunkBytes
    var offerTimeout: TimeInterval = TransportConfig.wifiBulkOfferTimeoutSeconds
    var transferWindow: TimeInterval = TransportConfig.wifiBulkTransferWindowSeconds
    var maxIncomingPayloadBytes: Int = FileTransferLimits.maxWifiBulkPayloadBytes
    var maxConcurrentIncoming: Int = TransportConfig.wifiBulkMaxConcurrentIncoming
    /// Tests disable peer-to-peer so loopback interfaces stay usable.
    var usePeerToPeer: Bool = true
    /// Tests disable Bonjour publication (unit-test hosts may lack mDNS access).
    var publishBonjourService: Bool = true
}

/// Orchestrates the Wi-Fi bulk data plane: BLE/Noise carries the offer and
/// response (control plane), then the payload crosses a per-transfer TCP
/// channel over AWDL, sealed with a key both sides derived from the
/// Noise-exchanged tokens. Any failure at any stage falls back to BLE
/// fragmentation exactly once; the receiver side fails silently and lets the
/// sender's timeout drive that fallback.
final class WifiBulkTransferService {
    private let queue = DispatchQueue(label: "com.bitchat.wifi-bulk", qos: .userInitiated)
    private let environment: WifiBulkTransferServiceEnvironment
    private let config: WifiBulkTransferServiceConfig

    private final class OutgoingTransfer {
        let transferID: Data
        let transferId: String
        let peerID: PeerID
        let token: Data
        let fallback: () -> Void
        var session: WifiBulkSenderSession?
        var offerTimeout: DispatchWorkItem?
        var windowTimeout: DispatchWorkItem?
        var accepted = false
        var finished = false

        init(transferID: Data, transferId: String, peerID: PeerID, token: Data, fallback: @escaping () -> Void) {
            self.transferID = transferID
            self.transferId = transferId
            self.peerID = peerID
            self.token = token
            self.fallback = fallback
        }
    }

    private final class IncomingTransfer {
        let offer: WifiBulkOffer
        let peerID: PeerID
        let key: SymmetricKey
        var browser: NWBrowser?
        var session: WifiBulkReceiverSession?
        var windowTimeout: DispatchWorkItem?

        init(offer: WifiBulkOffer, peerID: PeerID, key: SymmetricKey) {
            self.offer = offer
            self.peerID = peerID
            self.key = key
        }
    }

    private var outgoing: [Data: OutgoingTransfer] = [:]
    private var incoming: [Data: IncomingTransfer] = [:]

    init(
        environment: WifiBulkTransferServiceEnvironment,
        config: WifiBulkTransferServiceConfig = WifiBulkTransferServiceConfig()
    ) {
        self.environment = environment
        self.config = config
    }

    // MARK: - Sender

    /// Offers `payload` over the Wi-Fi bulk channel. `fallbackToBLE` runs at
    /// most once, on decline, timeout, or any mid-transfer error.
    func sendFile(payload: Data, to peerID: PeerID, transferId: String, fallbackToBLE: @escaping () -> Void) {
        queue.async { [weak self] in
            self?.beginOutgoing(payload: payload, peerID: peerID, transferId: transferId, fallbackToBLE: fallbackToBLE)
        }
    }

    /// Handles a decrypted `bulkTransferResponse` Noise payload.
    func handleResponsePayload(_ payload: Data, from peerID: PeerID) {
        queue.async { [weak self] in
            self?.processResponse(payload, from: peerID)
        }
    }

    /// User-initiated cancel from the UI (mirrors BLE `cancelTransfer`).
    func cancelTransfer(transferId: String) {
        queue.async { [weak self] in
            guard let self,
                  let transfer = self.outgoing.values.first(where: { $0.transferId == transferId }) else { return }
            self.finishOutgoing(transfer, outcome: .cancelled, reason: "cancelled by user")
        }
    }

    /// Tears down every transfer (service shutdown / emergency disconnect).
    /// In-flight outgoing transfers do NOT fall back — the transport is going away.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            for transfer in self.outgoing.values {
                transfer.finished = true
                transfer.offerTimeout?.cancel()
                transfer.windowTimeout?.cancel()
                transfer.session?.cancel()
            }
            self.outgoing.removeAll()
            for transfer in self.incoming.values {
                self.tearDownIncomingResources(transfer)
            }
            self.incoming.removeAll()
        }
    }

    private enum OutgoingOutcome {
        case completed
        case fallback
        case cancelled
    }

    private func beginOutgoing(payload: Data, peerID: PeerID, transferId: String, fallbackToBLE: @escaping () -> Void) {
        let transferID = Self.randomData(WifiBulkWire.transferIDLength)
        let token = Self.randomData(WifiBulkWire.tokenLength)
        // Random per-transfer instance name — never the nickname or peer ID.
        let serviceName = Self.randomData(16).hexEncodedString()

        let offer = WifiBulkOffer(
            transferID: transferID,
            fileSize: UInt64(payload.count),
            payloadHash: Data(SHA256.hash(data: payload)),
            token: token,
            serviceName: serviceName
        )
        guard let offerData = offer.encode() else {
            fallbackToBLE()
            return
        }

        let transfer = OutgoingTransfer(
            transferID: transferID,
            transferId: transferId,
            peerID: peerID,
            token: token,
            fallback: fallbackToBLE
        )

        let session = WifiBulkSenderSession(
            payload: payload,
            transferID: transferID,
            chunkBytes: config.chunkBytes,
            parameters: makeParameters(),
            service: config.publishBonjourService
                ? NWListener.Service(name: serviceName, type: config.serviceType)
                : nil,
            queue: queue
        )
        if let onListenerReady = _test_onListenerReady {
            session.onListenerReady = { port in onListenerReady(transferID, port) }
        }
        session.onChunkSent = { [weak self, weak transfer] sent, total in
            guard let self, let transfer, !transfer.finished else { return }
            // Hold the final tick until the receipt confirms delivery, so the
            // progress bus only emits .completed for verified transfers.
            if sent < total {
                self.environment.progressChunkSent(transfer.transferId)
            }
        }
        session.onCompleted = { [weak self, weak transfer] in
            guard let self, let transfer, !transfer.finished else { return }
            self.environment.progressChunkSent(transfer.transferId)
            self.finishOutgoing(transfer, outcome: .completed, reason: "receipt verified")
        }
        session.onFailed = { [weak self, weak transfer] reason in
            guard let self, let transfer else { return }
            self.finishOutgoing(transfer, outcome: .fallback, reason: reason)
        }
        transfer.session = session
        outgoing[transferID] = transfer

        guard session.start() else {
            finishOutgoing(transfer, outcome: .fallback, reason: "listener unavailable")
            return
        }
        guard environment.sendNoisePayload(
            BLENoisePayloadFactory.typedPayload(.bulkTransferOffer, payload: offerData),
            peerID
        ) else {
            finishOutgoing(transfer, outcome: .fallback, reason: "no established noise session")
            return
        }

        SecureLogger.debug("WifiBulk: offered \(payload.count) bytes to \(peerID.id.prefix(8))… over \(serviceName.prefix(8))…", category: .session)
        environment.progressStart(transferId, session.totalChunks)

        let offerTimeout = DispatchWorkItem { [weak self, weak transfer] in
            guard let self, let transfer, !transfer.accepted else { return }
            self.finishOutgoing(transfer, outcome: .fallback, reason: "offer timed out")
        }
        transfer.offerTimeout = offerTimeout
        queue.asyncAfter(deadline: .now() + config.offerTimeout, execute: offerTimeout)

        let windowTimeout = DispatchWorkItem { [weak self, weak transfer] in
            guard let self, let transfer else { return }
            self.finishOutgoing(transfer, outcome: .fallback, reason: "transfer window expired")
        }
        transfer.windowTimeout = windowTimeout
        queue.asyncAfter(deadline: .now() + config.transferWindow, execute: windowTimeout)
    }

    private func processResponse(_ payload: Data, from peerID: PeerID) {
        guard let response = WifiBulkResponse.decode(payload),
              let transfer = outgoing[response.transferID],
              transfer.peerID.toShort() == peerID.toShort(),
              !transfer.accepted, !transfer.finished else {
            return
        }

        guard response.accepted, let receiverToken = response.token else {
            finishOutgoing(transfer, outcome: .fallback, reason: "offer declined")
            return
        }
        guard let key = WifiBulkCrypto.deriveKey(
            senderToken: transfer.token,
            receiverToken: receiverToken,
            transferID: transfer.transferID
        ) else {
            finishOutgoing(transfer, outcome: .fallback, reason: "key derivation failed")
            return
        }

        transfer.accepted = true
        transfer.offerTimeout?.cancel()
        transfer.offerTimeout = nil
        transfer.session?.activate(key: key)
    }

    private func finishOutgoing(_ transfer: OutgoingTransfer, outcome: OutgoingOutcome, reason: String) {
        guard !transfer.finished else { return }
        transfer.finished = true
        transfer.offerTimeout?.cancel()
        transfer.windowTimeout?.cancel()
        transfer.session?.cancel()
        outgoing.removeValue(forKey: transfer.transferID)

        switch outcome {
        case .completed:
            SecureLogger.debug("WifiBulk: transfer \(transfer.transferId.prefix(8))… completed (\(reason))", category: .session)
        case .fallback:
            SecureLogger.info("WifiBulk: transfer \(transfer.transferId.prefix(8))… falling back to BLE (\(reason))", category: .session)
            environment.progressReset(transfer.transferId)
            transfer.fallback()
        case .cancelled:
            SecureLogger.debug("WifiBulk: transfer \(transfer.transferId.prefix(8))… cancelled", category: .session)
            environment.progressCancel(transfer.transferId)
        }
    }

    // MARK: - Receiver

    /// Handles a decrypted `bulkTransferOffer` Noise payload.
    func handleOfferPayload(_ payload: Data, from peerID: PeerID) {
        queue.async { [weak self] in
            self?.processOffer(payload, from: peerID)
        }
    }

    private func processOffer(_ payload: Data, from peerID: PeerID) {
        guard let offer = WifiBulkOffer.decode(payload) else { return }
        guard incoming[offer.transferID] == nil else { return }

        guard WifiBulkPolicy.shouldAccept(
            offer: offer,
            senderIsDirectlyConnected: environment.isPeerConnected(peerID),
            activeIncomingTransfers: incoming.count,
            maxPayloadBytes: config.maxIncomingPayloadBytes,
            maxConcurrentIncoming: config.maxConcurrentIncoming
        ) else {
            decline(offer: offer, peerID: peerID)
            return
        }

        let token = Self.randomData(WifiBulkWire.tokenLength)
        guard let key = WifiBulkCrypto.deriveKey(
            senderToken: offer.token,
            receiverToken: token,
            transferID: offer.transferID
        ),
        let responseData = WifiBulkResponse.accept(transferID: offer.transferID, token: token).encode() else {
            decline(offer: offer, peerID: peerID)
            return
        }
        guard environment.sendNoisePayload(
            BLENoisePayloadFactory.typedPayload(.bulkTransferResponse, payload: responseData),
            peerID
        ) else {
            return // No session to answer on; the sender's timeout handles fallback.
        }

        let transfer = IncomingTransfer(offer: offer, peerID: peerID, key: key)
        incoming[offer.transferID] = transfer
        SecureLogger.debug("WifiBulk: accepted offer of \(offer.fileSize) bytes from \(peerID.id.prefix(8))…", category: .session)

        startBrowsing(for: transfer)

        let windowTimeout = DispatchWorkItem { [weak self, weak transfer] in
            guard let self, let transfer else { return }
            SecureLogger.info("WifiBulk: incoming transfer window expired", category: .session)
            self.tearDownIncoming(transfer)
        }
        transfer.windowTimeout = windowTimeout
        queue.asyncAfter(deadline: .now() + config.transferWindow, execute: windowTimeout)
    }

    private func decline(offer: WifiBulkOffer, peerID: PeerID) {
        SecureLogger.debug("WifiBulk: declining offer of \(offer.fileSize) bytes from \(peerID.id.prefix(8))…", category: .session)
        guard let responseData = WifiBulkResponse.decline(transferID: offer.transferID).encode() else { return }
        _ = environment.sendNoisePayload(
            BLENoisePayloadFactory.typedPayload(.bulkTransferResponse, payload: responseData),
            peerID
        )
    }

    private func startBrowsing(for transfer: IncomingTransfer) {
        let browser = NWBrowser(
            for: .bonjour(type: config.serviceType, domain: nil),
            using: makeParameters()
        )
        transfer.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak transfer] results, _ in
            guard let self, let transfer, transfer.session == nil else { return }
            let match = results.first { result in
                if case .service(let name, _, _, _) = result.endpoint {
                    return name == transfer.offer.serviceName
                }
                return false
            }
            guard let match else { return }
            self.connect(transfer, to: match.endpoint)
        }
        browser.stateUpdateHandler = { [weak self, weak transfer] state in
            guard let self, let transfer else { return }
            if case .failed(let error) = state {
                SecureLogger.warning("WifiBulk: browser failed: \(error)", category: .session)
                self.tearDownIncoming(transfer)
            }
        }
        browser.start(queue: queue)
    }

    /// Test hook: connects an accepted incoming transfer straight to an
    /// endpoint, standing in for Bonjour discovery on hosts without mDNS.
    func _test_connectIncoming(transferID: Data, to endpoint: NWEndpoint) {
        queue.async { [weak self] in
            guard let self, let transfer = self.incoming[transferID], transfer.session == nil else { return }
            self.connect(transfer, to: endpoint)
        }
    }

    private func connect(_ transfer: IncomingTransfer, to endpoint: NWEndpoint) {
        transfer.browser?.cancel()
        transfer.browser = nil

        guard let session = WifiBulkReceiverSession(
            endpoint: endpoint,
            parameters: makeParameters(),
            key: transfer.key,
            transferID: transfer.offer.transferID,
            expectedSize: transfer.offer.fileSize,
            expectedHash: transfer.offer.payloadHash,
            sizeCap: config.maxIncomingPayloadBytes,
            chunkBytes: config.chunkBytes,
            queue: queue
        ) else {
            tearDownIncoming(transfer)
            return
        }
        session.onCompleted = { [weak self, weak transfer] payload in
            guard let self, let transfer else { return }
            SecureLogger.debug("WifiBulk: received \(payload.count) bytes from \(transfer.peerID.id.prefix(8))…", category: .session)
            self.environment.deliverReceivedFile(payload, transfer.peerID, self.config.maxIncomingPayloadBytes)
            self.tearDownIncoming(transfer)
        }
        session.onFailed = { [weak self, weak transfer] reason in
            guard let self, let transfer else { return }
            SecureLogger.info("WifiBulk: incoming transfer failed (\(reason)); sender falls back to BLE", category: .session)
            self.tearDownIncoming(transfer)
        }
        transfer.session = session
        session.start()
    }

    private func tearDownIncoming(_ transfer: IncomingTransfer) {
        tearDownIncomingResources(transfer)
        incoming.removeValue(forKey: transfer.offer.transferID)
    }

    private func tearDownIncomingResources(_ transfer: IncomingTransfer) {
        transfer.windowTimeout?.cancel()
        transfer.windowTimeout = nil
        transfer.browser?.cancel()
        transfer.browser = nil
        transfer.session?.cancel()
        transfer.session = nil
    }

    // MARK: - Helpers

    private func makeParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        if config.usePeerToPeer {
            parameters.includePeerToPeer = true
            // Keep the channel off infrastructure-independent radios we never
            // want (cellular/wired); AWDL rides on the peer-to-peer flag.
            parameters.prohibitedInterfaceTypes = [.cellular, .wiredEthernet, .loopback]
        }
        return parameters
    }

    /// Cryptographically secure random bytes (Swift's default RNG is CSPRNG-backed).
    private static func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    // MARK: - Test observability

    /// Test hook: reports each outgoing listener's bound port, standing in
    /// for Bonjour resolution on hosts without mDNS. Set before `sendFile`.
    var _test_onListenerReady: ((_ transferID: Data, _ port: UInt16) -> Void)?

    var _test_activeOutgoingCount: Int {
        queue.sync { outgoing.count }
    }

    var _test_activeIncomingCount: Int {
        queue.sync { incoming.count }
    }
}
