//
// WifiBulkChannel.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import CryptoKit
import Foundation
import Network

/// Shared frame-stream reading over an `NWConnection`. All callbacks fire on
/// the connection's dispatch queue.
enum WifiBulkStream {
    /// Largest sealed frame body on the wire: one plaintext chunk plus AEAD overhead.
    static func maxFrameBodyBytes(chunkBytes: Int) -> Int {
        chunkBytes + WifiBulkCrypto.frameOverhead
    }

    /// Reads frames until `onFrame` returns false (stop) or the stream
    /// errors/closes. `onFrame` returning true keeps the loop alive.
    static func readFrames(
        on connection: NWConnection,
        buffer: WifiBulkFrameBuffer,
        maxFrameBodyBytes: Int,
        onFrame: @escaping (Data) -> Bool,
        onError: @escaping (String) -> Void
    ) {
        // Drain any frames already buffered before touching the socket.
        do {
            while let body = try buffer.nextFrameBody() {
                guard onFrame(body) else { return }
            }
        } catch {
            onError("frame decode failed: \(error)")
            return
        }

        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: maxFrameBodyBytes + WifiBulkCrypto.framePrefixLength
        ) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            if let error {
                onError("receive failed: \(error)")
                return
            }
            if isComplete {
                // Peer closed: hand over whatever complete frames remain, then
                // report the close (sessions that already got what they need
                // will have stopped the loop from inside onFrame).
                do {
                    while let body = try buffer.nextFrameBody() {
                        guard onFrame(body) else { return }
                    }
                } catch {
                    onError("frame decode failed: \(error)")
                    return
                }
                onError("connection closed by peer")
                return
            }
            readFrames(
                on: connection,
                buffer: buffer,
                maxFrameBodyBytes: maxFrameBodyBytes,
                onFrame: onFrame,
                onError: onError
            )
        }
    }
}

/// Sender side of the bulk channel: publishes the per-transfer Bonjour
/// listener, requires the first inbound frame to prove knowledge of the
/// Noise-exchanged channel key, then streams sealed chunks and waits for the
/// receiver's verified receipt.
///
/// The listener starts at offer time (Bonjour registration takes a moment)
/// but data can only flow after `activate(key:)` supplies the channel key
/// derived from the accepted response.
final class WifiBulkSenderSession {
    private let queue: DispatchQueue
    private let payload: Data
    private let transferID: Data
    private let payloadHash: Data
    private let chunkBytes: Int
    private let parameters: NWParameters
    private let service: NWListener.Service?
    private let maxCandidateConnections = 4

    private var key: SymmetricKey?
    private var listener: NWListener?
    /// Connections that have not yet produced a valid auth frame.
    private var candidates: [NWConnection] = []
    private var authenticated: NWConnection?
    private var finished = false

    let totalChunks: Int

    /// Test hook: fires once the listener is ready, with its bound port.
    var onListenerReady: ((UInt16) -> Void)?
    var onChunkSent: ((_ sent: Int, _ total: Int) -> Void)?
    var onCompleted: (() -> Void)?
    var onFailed: ((String) -> Void)?

    init(
        payload: Data,
        transferID: Data,
        chunkBytes: Int,
        parameters: NWParameters,
        service: NWListener.Service?,
        queue: DispatchQueue
    ) {
        self.payload = payload
        self.transferID = transferID
        self.payloadHash = Data(SHA256.hash(data: payload))
        self.chunkBytes = chunkBytes
        self.parameters = parameters
        self.service = service
        self.queue = queue
        self.totalChunks = (payload.count + chunkBytes - 1) / chunkBytes
    }

    deinit {
        cancelNetworkResources()
    }

    /// Starts the listener. Returns false when the listener cannot be created
    /// (caller falls back to BLE immediately).
    func start() -> Bool {
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            SecureLogger.error("[WIFI] listener creation failed: \(error)", category: .transport)
            return false
        }
        listener.service = service
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    self.onListenerReady?(port)
                }
            case .failed(let error):
                self.fail("listener failed: \(error)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.acceptCandidate(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
        return true
    }

    /// Supplies the channel key once the receiver accepted the offer; begins
    /// authenticating any connections that raced ahead of the response.
    func activate(key: SymmetricKey) {
        guard !finished, self.key == nil else { return }
        self.key = key
        for candidate in candidates {
            beginAuthentication(on: candidate, key: key)
        }
    }

    func cancel() {
        finished = true
        cancelNetworkResources()
    }

    // MARK: - Connection handling

    private func acceptCandidate(_ connection: NWConnection) {
        guard !finished, authenticated == nil, candidates.count < maxCandidateConnections else {
            connection.cancel()
            return
        }
        candidates.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .failed = state {
                self.dropCandidate(connection)
            }
        }
        connection.start(queue: queue)
        if let key {
            beginAuthentication(on: connection, key: key)
        }
    }

    private func dropCandidate(_ connection: NWConnection) {
        if let index = candidates.firstIndex(where: { $0 === connection }) {
            candidates.remove(at: index)
            connection.cancel()
        }
    }

    private func beginAuthentication(on connection: NWConnection, key: SymmetricKey) {
        let buffer = WifiBulkFrameBuffer(maxBodyBytes: WifiBulkStream.maxFrameBodyBytes(chunkBytes: chunkBytes))
        WifiBulkStream.readFrames(
            on: connection,
            buffer: buffer,
            maxFrameBodyBytes: WifiBulkStream.maxFrameBodyBytes(chunkBytes: chunkBytes),
            onFrame: { [weak self, weak connection] body in
                guard let self, let connection, !self.finished, self.authenticated == nil else { return false }
                guard WifiBulkCrypto.validateClientAuthFrameBody(body, transferID: self.transferID, key: key) else {
                    // Bonjour-level gatecrasher: no channel key, no service.
                    SecureLogger.warning("[WIFI] AWDL connect rejected (invalid auth frame)", category: .security)
                    self.dropCandidate(connection)
                    return false
                }
                self.promoteAuthenticated(connection, key: key, residualBuffer: buffer)
                return false
            },
            onError: { [weak self, weak connection] _ in
                guard let self, let connection, self.authenticated !== connection else { return }
                self.dropCandidate(connection)
            }
        )
    }

    private func promoteAuthenticated(_ connection: NWConnection, key: SymmetricKey, residualBuffer: WifiBulkFrameBuffer) {
        authenticated = connection
        // One authenticated peer is all a transfer needs: stop advertising and
        // shed the other candidates.
        listener?.cancel()
        listener = nil
        for candidate in candidates where candidate !== connection {
            candidate.cancel()
        }
        candidates.removeAll()
        SecureLogger.info("[WIFI] AWDL connected (sender), streaming \(totalChunks) chunk(s)", category: .transport)
        streamChunk(at: 0, over: connection, key: key, receiptBuffer: residualBuffer)
    }

    // MARK: - Streaming

    private func streamChunk(at index: Int, over connection: NWConnection, key: SymmetricKey, receiptBuffer: WifiBulkFrameBuffer) {
        guard !finished else { return }
        guard index < totalChunks else {
            awaitReceipt(on: connection, key: key, buffer: receiptBuffer)
            return
        }

        let start = payload.index(payload.startIndex, offsetBy: index * chunkBytes)
        let end = payload.index(start, offsetBy: min(chunkBytes, payload.distance(from: start, to: payload.endIndex)))
        let chunk = Data(payload[start..<end])

        let body: Data
        do {
            body = try WifiBulkCrypto.sealFrameBody(chunk, direction: .senderToReceiver, counter: UInt64(index), key: key)
        } catch {
            fail("chunk seal failed: \(error)")
            return
        }

        connection.send(content: WifiBulkCrypto.frameData(body: body), completion: .contentProcessed { [weak self] error in
            guard let self, !self.finished else { return }
            if let error {
                self.fail("send failed: \(error)")
                return
            }
            self.onChunkSent?(index + 1, self.totalChunks)
            self.streamChunk(at: index + 1, over: connection, key: key, receiptBuffer: receiptBuffer)
        })
    }

    private func awaitReceipt(on connection: NWConnection, key: SymmetricKey, buffer: WifiBulkFrameBuffer) {
        WifiBulkStream.readFrames(
            on: connection,
            buffer: buffer,
            maxFrameBodyBytes: WifiBulkStream.maxFrameBodyBytes(chunkBytes: chunkBytes),
            onFrame: { [weak self] body in
                guard let self, !self.finished else { return false }
                guard WifiBulkCrypto.validateReceiptFrameBody(body, payloadHash: self.payloadHash, key: key) else {
                    self.fail("invalid receipt frame")
                    return false
                }
                self.finished = true
                self.cancelNetworkResources()
                self.onCompleted?()
                return false
            },
            onError: { [weak self] reason in
                self?.fail("receipt wait failed: \(reason)")
            }
        )
    }

    // MARK: - Teardown

    private func fail(_ reason: String) {
        guard !finished else { return }
        finished = true
        cancelNetworkResources()
        onFailed?(reason)
    }

    private func cancelNetworkResources() {
        listener?.cancel()
        listener = nil
        authenticated?.cancel()
        authenticated = nil
        for candidate in candidates {
            candidate.cancel()
        }
        candidates.removeAll()
    }
}

/// Receiver side of the bulk channel: connects to the sender's per-transfer
/// endpoint, proves knowledge of the channel key with the first frame, then
/// reassembles sealed chunks, verifies the offer hash, and returns a receipt.
final class WifiBulkReceiverSession {
    private let queue: DispatchQueue
    private let connection: NWConnection
    private let key: SymmetricKey
    private let transferID: Data
    private let payloadHash: Data
    private let chunkBytes: Int
    private let assembler: WifiBulkPayloadAssembler

    private var finished = false

    var onCompleted: ((Data) -> Void)?
    var onFailed: ((String) -> Void)?

    /// Fails (returns nil) when the offer exceeds `sizeCap` — the receiver
    /// enforces the cap it advertised, not the sender's word.
    init?(
        endpoint: NWEndpoint,
        parameters: NWParameters,
        key: SymmetricKey,
        transferID: Data,
        expectedSize: UInt64,
        expectedHash: Data,
        sizeCap: Int,
        chunkBytes: Int,
        queue: DispatchQueue
    ) {
        guard let assembler = WifiBulkPayloadAssembler(
            key: key,
            expectedSize: expectedSize,
            expectedHash: expectedHash,
            sizeCap: sizeCap
        ) else {
            return nil
        }
        self.assembler = assembler
        self.connection = NWConnection(to: endpoint, using: parameters)
        self.key = key
        self.transferID = transferID
        self.payloadHash = expectedHash
        self.chunkBytes = chunkBytes
        self.queue = queue
    }

    deinit {
        connection.cancel()
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                SecureLogger.info("[WIFI] AWDL connect established (receiver)", category: .transport)
                self.sendAuthFrameAndReceive()
            case .failed(let error):
                SecureLogger.info("[WIFI] AWDL connect failed: \(error)", category: .transport)
                self.fail("connect failed: \(error)")
            case .waiting(let error):
                // .waiting can resolve on its own, but a per-transfer channel
                // has a peer actively listening; treat unreachable as fatal so
                // the sender's fallback isn't left to the window timeout alone.
                self.fail("connection waiting: \(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        finished = true
        connection.cancel()
    }

    private func sendAuthFrameAndReceive() {
        guard !finished else { return }
        let authBody: Data
        do {
            authBody = try WifiBulkCrypto.makeClientAuthFrameBody(transferID: transferID, key: key)
        } catch {
            fail("auth frame seal failed: \(error)")
            return
        }
        connection.send(content: WifiBulkCrypto.frameData(body: authBody), completion: .contentProcessed { [weak self] error in
            guard let self, !self.finished else { return }
            if let error {
                self.fail("auth frame send failed: \(error)")
                return
            }
            self.receiveChunks()
        })
    }

    private func receiveChunks() {
        let buffer = WifiBulkFrameBuffer(maxBodyBytes: WifiBulkStream.maxFrameBodyBytes(chunkBytes: chunkBytes))
        WifiBulkStream.readFrames(
            on: connection,
            buffer: buffer,
            maxFrameBodyBytes: WifiBulkStream.maxFrameBodyBytes(chunkBytes: chunkBytes),
            onFrame: { [weak self] body in
                guard let self, !self.finished else { return false }
                do {
                    guard let payload = try self.assembler.consume(frameBody: body) else {
                        return true // keep reading
                    }
                    self.sendReceiptAndComplete(payload)
                    return false
                } catch {
                    self.fail("chunk rejected: \(error)")
                    return false
                }
            },
            onError: { [weak self] reason in
                self?.fail(reason)
            }
        )
    }

    private func sendReceiptAndComplete(_ payload: Data) {
        let receiptBody: Data
        do {
            receiptBody = try WifiBulkCrypto.makeReceiptFrameBody(payloadHash: payloadHash, key: key)
        } catch {
            fail("receipt seal failed: \(error)")
            return
        }
        connection.send(content: WifiBulkCrypto.frameData(body: receiptBody), completion: .contentProcessed { [weak self] _ in
            // Receipt is best-effort from the receiver's perspective: the
            // payload is already verified. Close the channel either way.
            guard let self, !self.finished else { return }
            self.finished = true
            self.connection.cancel()
            self.onCompleted?(payload)
        })
    }

    private func fail(_ reason: String) {
        guard !finished else { return }
        finished = true
        connection.cancel()
        onFailed?(reason)
    }
}
