//
// LANConnection.swift
// bitchat
//
// One framed TCP link to a remote peer on the local network.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Network

/// A framed byte-stream link to one remote peer.
///
/// The class owns the `NWConnection` and the framing layer: callers hand it
/// packet payloads and receive complete packet payloads back. It knows
/// nothing about Noise, peers or the app protocol — that lives in
/// `LANTransport`.
final class LANConnection {
    /// Lifecycle of a LAN link.
    enum State: Equatable {
        case connecting
        case ready
        case failed
        case cancelled
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let decoder = LANFrameDecoder()
    private var currentState: State = .connecting
    private var isSending = false
    private var pendingFrames: [Data] = []

    /// Called for every complete packet payload received on the link.
    var onFrame: ((Data) -> Void)?
    /// Called when the link state changes.
    var onStateChange: ((State) -> Void)?

    var state: State { queue.sync { currentState } }

    /// Create a link to a remote endpoint.
    init(
        endpoint: NWEndpoint,
        parameters: NWParameters = .tcp,
        queue: DispatchQueue
    ) {
        self.connection = NWConnection(to: endpoint, using: parameters)
        self.queue = queue
    }

    /// Adopt an inbound connection handed over by the listener.
    init(
        connection: NWConnection,
        queue: DispatchQueue
    ) {
        self.connection = connection
        self.queue = queue
    }

    /// Start the link and begin receiving.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                self.handle(state: state)
            }
        }
        connection.start(queue: queue)
        receiveNextChunk()
    }

    /// Cancel the link.
    func cancel() {
        connection.cancel()
        transition(to: .cancelled)
    }

    /// Send one packet payload. Payloads are framed and written in order.
    func send(payload: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.currentState == .ready else { return }
            guard let frame = try? LANFrameCodec.encode(payload: payload) else { return }
            self.pendingFrames.append(frame)
            self.flushFrames()
        }
    }

    // MARK: - Private

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            transition(to: .ready)
        case .failed:
            transition(to: .failed)
        case .cancelled:
            transition(to: .cancelled)
        case .setup, .preparing, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func transition(to newState: State) {
        guard currentState != newState else { return }
        currentState = newState
        onStateChange?(newState)
    }

    private func flushFrames() {
        guard !isSending, let next = pendingFrames.first else { return }
        pendingFrames.removeFirst()
        isSending = true
        connection.send(
            content: next,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    self.isSending = false
                    if error != nil {
                        self.pendingFrames.removeAll()
                        self.transition(to: .failed)
                        return
                    }
                    self.flushFrames()
                }
            }
        )
    }

    private func receiveNextChunk() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let content, !content.isEmpty {
                    do {
                        for payload in try self.decoder.append(content) {
                            self.onFrame?(payload)
                        }
                    } catch {
                        // A malformed or oversized frame desynchronises the
                        // stream: the link is dropped instead of resynced.
                        self.transition(to: .failed)
                        self.connection.cancel()
                        return
                    }
                }
                if isComplete || error != nil {
                    self.transition(to: .cancelled)
                    return
                }
                self.receiveNextChunk()
            }
        }
    }
}
