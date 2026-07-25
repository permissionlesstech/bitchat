//
// NoiseSessionManagerStateTransitionTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import Foundation
import Testing
import BitFoundation

@testable import bitchat

/// State-transition coverage for `NoiseSessionManager.handleIncomingHandshake`.
///
/// These tests drive the incoming-session *selection* state machine — create,
/// reuse, replace, fail — through the `#if DEBUG` `sessionFactory` hook using
/// scripted `NoiseSession` doubles, so each branch can be exercised deterministically
/// without a real Noise handshake.
///
/// They characterize the invariant that used to sit behind the `existingSession!`
/// force unwrap in the reuse branch: whenever the manager decides to *reuse*, a
/// session is present; whenever it decides to *create* or *replace*, exactly one new
/// responder is minted before the message is processed. The nil case that the former
/// `!` would have trapped on is unreachable through the public API by construction,
/// so these are regression guards for the state machine, not a reproduction of a
/// live crash — a future refactor that breaks the create/reuse coupling now fails a
/// test (and, at runtime, a handshake) instead of crashing.
@Suite("Noise Session Manager State Transitions")
struct NoiseSessionManagerStateTransitionTests {
    private let keychain = MockKeychain()
    private let localStaticKey = Curve25519.KeyAgreement.PrivateKey()
    private let peerID = PeerID(str: "0011223344556677")

    // MARK: (a) No existing session -> a responder is created and processes once

    @Test("No existing session creates one responder and processes the message once")
    func createsResponderWhenNoSessionExists() throws {
        let factory = ScriptedSessionFactory(keychain: keychain, localStaticKey: localStaticKey)
        let responder = factory.enqueue(.respond(Data([0x01])))
        let manager = makeManager(factory)

        let response = try manager.handleIncomingHandshake(from: peerID, message: initiationMessage())

        #expect(response == Data([0x01]))
        #expect(factory.createdRoles == [.responder])
        #expect(responder.processCallCount == 1)
        #expect(manager.getSession(for: peerID) === responder)
    }

    // MARK: (b) Existing unfinished handshake -> reused, no second responder

    @Test("Existing unfinished handshake is reused without minting a second responder")
    func reusesExistingUnfinishedSession() throws {
        let factory = ScriptedSessionFactory(keychain: keychain, localStaticKey: localStaticKey)
        let responder = factory.enqueue(.respond(Data([0x01])), state: .handshaking, established: false)
        let manager = makeManager(factory)

        // First message creates the responder and leaves it mid-handshake.
        _ = try manager.handleIncomingHandshake(from: peerID, message: initiationMessage())
        // A continuation message (not a 32-byte re-initiation) must reuse that session.
        let response = try manager.handleIncomingHandshake(from: peerID, message: continuationMessage())

        #expect(response == Data([0x01]))
        #expect(factory.createdRoles == [.responder]) // exactly one responder ever minted
        #expect(responder.processCallCount == 2)       // the same session handled both messages
        #expect(manager.getSession(for: peerID) === responder)
    }

    // MARK: (c) Existing established session -> removed, fresh responder created before processing

    @Test("Established session is replaced by a fresh responder that processes the new handshake")
    func replacesEstablishedSession() throws {
        let factory = ScriptedSessionFactory(keychain: keychain, localStaticKey: localStaticKey)
        let established = factory.enqueue(.respond(Data([0x01])), state: .established, established: true)
        let replacement = factory.enqueue(.respond(Data([0x02])), state: .handshaking, established: false)
        let manager = makeManager(factory)

        _ = try manager.handleIncomingHandshake(from: peerID, message: initiationMessage())
        let response = try manager.handleIncomingHandshake(from: peerID, message: initiationMessage())

        #expect(response == Data([0x02]))
        #expect(factory.createdRoles == [.responder, .responder]) // old removed, new minted
        #expect(established.processCallCount == 1)                 // established did not handle the 2nd message
        #expect(replacement.processCallCount == 1)                 // the new responder handled it
        #expect(manager.getSession(for: peerID) === replacement)
    }

    // MARK: (d) Restart-style 32-byte initiation during an unfinished handshake -> replaced

    @Test("A 32-byte re-initiation during an unfinished handshake replaces the session")
    func restartInitiationReplacesUnfinishedSession() throws {
        let factory = ScriptedSessionFactory(keychain: keychain, localStaticKey: localStaticKey)
        let firstResponder = factory.enqueue(.respond(Data([0x01])), state: .handshaking, established: false)
        let replacement = factory.enqueue(.respond(Data([0x02])), state: .handshaking, established: false)
        let manager = makeManager(factory)

        _ = try manager.handleIncomingHandshake(from: peerID, message: initiationMessage())
        // A 32-byte initiation while the first session is still handshaking -> restart.
        let response = try manager.handleIncomingHandshake(from: peerID, message: initiationMessage())

        #expect(response == Data([0x02]))
        #expect(factory.createdRoles == [.responder, .responder])
        #expect(firstResponder.processCallCount == 1)
        #expect(replacement.processCallCount == 1)
        #expect(manager.getSession(for: peerID) === replacement)
    }

    // MARK: (e) Processing failure -> session removed, error propagated, onSessionFailed once

    @Test("A processing failure removes the session, propagates the error, and fires onSessionFailed once")
    func processingFailureCleansUpAndReportsOnce() async throws {
        let factory = ScriptedSessionFactory(keychain: keychain, localStaticKey: localStaticKey)
        _ = factory.enqueue(.fail(ScriptedSessionError.synthetic))
        let manager = makeManager(factory)
        let recorder = FailureRecorder()
        manager.onSessionFailed = recorder.record(peerID:error:)

        #expect(throws: ScriptedSessionError.synthetic) {
            try manager.handleIncomingHandshake(from: peerID, message: initiationMessage())
        }
        #expect(manager.getSession(for: peerID) == nil)

        let reportedOnce = await TestHelpers.waitUntil({ recorder.count == 1 }, timeout: 5.0)
        #expect(reportedOnce)
        #expect(recorder.count == 1)
        #expect(recorder.lastPeerID == peerID)
    }

    // MARK: - Helpers

    private func makeManager(_ factory: ScriptedSessionFactory) -> NoiseSessionManager {
        NoiseSessionManager(
            localStaticKey: localStaticKey,
            keychain: keychain,
            sessionFactory: factory.make(peerID:role:)
        )
    }

    /// A 32-byte payload mimics the first XX handshake message (a fresh initiation).
    private func initiationMessage() -> Data { Data(repeating: 0xAB, count: 32) }

    /// A non-32-byte payload mimics a handshake continuation, which must not restart the session.
    private func continuationMessage() -> Data { Data(repeating: 0xCD, count: 48) }
}

// MARK: - Test doubles

private enum ScriptedSessionError: Error {
    case synthetic
}

/// A `NoiseSession` double whose handshake behaviour and reported state are fixed at
/// construction, letting the manager's branch selection be driven deterministically.
/// Reads of its counters are safe after `handleIncomingHandshake` returns, because the
/// manager processes each message inside its serial barrier queue.
private final class ScriptedNoiseSession: NoiseSession {
    enum Behavior {
        case respond(Data)      // return this response from processHandshakeMessage
        case complete           // return nil (handshake finished)
        case fail(Error)        // throw from processHandshakeMessage
    }

    private let behavior: Behavior
    private let reportedState: NoiseSessionState
    private let reportedEstablished: Bool
    private(set) var processCallCount = 0

    init(
        peerID: PeerID,
        role: NoiseRole,
        keychain: KeychainManagerProtocol,
        localStaticKey: Curve25519.KeyAgreement.PrivateKey,
        behavior: Behavior,
        state: NoiseSessionState,
        established: Bool
    ) {
        self.behavior = behavior
        self.reportedState = state
        self.reportedEstablished = established
        super.init(peerID: peerID, role: role, keychain: keychain, localStaticKey: localStaticKey)
    }

    override func getState() -> NoiseSessionState { reportedState }

    override func isEstablished() -> Bool { reportedEstablished }

    // Keep establishment side effects (onSessionEstablished) out of these tests.
    override func getRemoteStaticPublicKey() -> Curve25519.KeyAgreement.PublicKey? { nil }

    override func processHandshakeMessage(_ message: Data) throws -> Data? {
        processCallCount += 1
        switch behavior {
        case .respond(let data): return data
        case .complete: return nil
        case .fail(let error): throw error
        }
    }
}

/// Vends pre-scripted `ScriptedNoiseSession`s in FIFO order and records the role of
/// every session the manager asks it to create.
private final class ScriptedSessionFactory {
    private let keychain: KeychainManagerProtocol
    private let localStaticKey: Curve25519.KeyAgreement.PrivateKey
    private var queued: [ScriptedNoiseSession] = []
    private(set) var createdRoles: [NoiseRole] = []

    init(keychain: KeychainManagerProtocol, localStaticKey: Curve25519.KeyAgreement.PrivateKey) {
        self.keychain = keychain
        self.localStaticKey = localStaticKey
    }

    /// Registers the next session the factory will hand out and returns it so the test
    /// can assert on its observations afterwards.
    @discardableResult
    func enqueue(
        _ behavior: ScriptedNoiseSession.Behavior,
        state: NoiseSessionState = .handshaking,
        established: Bool = false
    ) -> ScriptedNoiseSession {
        let session = ScriptedNoiseSession(
            peerID: PeerID(str: "0011223344556677"),
            role: .responder,
            keychain: keychain,
            localStaticKey: localStaticKey,
            behavior: behavior,
            state: state,
            established: established
        )
        queued.append(session)
        return session
    }

    func make(peerID: PeerID, role: NoiseRole) -> NoiseSession {
        createdRoles.append(role)
        guard !queued.isEmpty else {
            Issue.record("ScriptedSessionFactory asked for more sessions than were enqueued")
            return ScriptedNoiseSession(
                peerID: peerID,
                role: role,
                keychain: keychain,
                localStaticKey: localStaticKey,
                behavior: .complete,
                state: .handshaking,
                established: false
            )
        }
        return queued.removeFirst()
    }
}

/// Thread-safe recorder for the asynchronously dispatched `onSessionFailed` callback,
/// mirroring the locking pattern used by the existing Noise coverage tests.
private final class FailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(PeerID, Error)] = []

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    var lastPeerID: PeerID? {
        lock.lock(); defer { lock.unlock() }
        return entries.last?.0
    }

    func record(peerID: PeerID, error: Error) {
        lock.lock()
        entries.append((peerID, error))
        lock.unlock()
    }
}
