//
// AudioSessionCoordinatorTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

/// Thread-safe: the coordinator invokes it on its private serial queue (that
/// the calls happen off the main thread is itself under test) while the test
/// reads from the main actor.
private final class MockAudioSession: SessionApplying, @unchecked Sendable {
    enum Call: Equatable {
        case setCategory(AudioSessionCoordinator.Category)
        case setActive(Bool, notifyOthers: Bool)
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _callsOnMainThread: [Bool] = []
    private var _nextError: Error?
    private var _nextActivationError: Error?

    var calls: [Call] { lock.withLock { _calls } }
    /// Whether each recorded call ran on the main thread — the coordinator's
    /// whole point is that none ever does (the real calls block on IPC to the
    /// audio server).
    var callsOnMainThread: [Bool] { lock.withLock { _callsOnMainThread } }
    var nextError: Error? {
        get { lock.withLock { _nextError } }
        set { lock.withLock { _nextError = newValue } }
    }
    /// Fails only the next `setActive` (so `setCategory` can succeed first).
    var nextActivationError: Error? {
        get { lock.withLock { _nextActivationError } }
        set { lock.withLock { _nextActivationError = newValue } }
    }

    func setCategory(_ category: AudioSessionCoordinator.Category) throws {
        try lock.withLock {
            if let error = _nextError {
                _nextError = nil
                throw error
            }
            _calls.append(.setCategory(category))
            _callsOnMainThread.append(Thread.isMainThread)
        }
    }

    func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws {
        try lock.withLock {
            if let error = _nextError {
                _nextError = nil
                throw error
            }
            if let error = _nextActivationError {
                _nextActivationError = nil
                throw error
            }
            _calls.append(.setActive(active, notifyOthers: notifyOthersOnDeactivation))
            _callsOnMainThread.append(Thread.isMainThread)
        }
    }

    var categoryCalls: [AudioSessionCoordinator.Category] {
        calls.compactMap { if case .setCategory(let category) = $0 { category } else { nil } }
    }

    var activationCalls: [Bool] {
        calls.compactMap { if case .setActive(let active, _) = $0 { active } else { nil } }
    }
}

private struct MockSessionError: Error {}

/// Async suspension gate used to force lifecycle races without sleeps. The
/// production operation announces that it reached the gated boundary, then
/// stays suspended until the test opens it.
private actor AsyncGate {
    private var isOpen = false
    private var hasWaiter = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasWaiter = true
        let arrivals = arrivalWaiters
        arrivalWaiters = []
        for continuation in arrivals {
            continuation.resume()
        }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            gateWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !hasWaiter else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = gateWaiters
        gateWaiters = []
        for continuation in waiters {
            continuation.resume()
        }
    }
}

@MainActor
struct AudioSessionCoordinatorTests {
    // MARK: - Reference-counted activation

    @Test func activatesOnFirstAcquireAndDeactivatesOnLastRelease() async throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        let first = try await coordinator.acquire(.playback) {}
        let second = try await coordinator.acquire(.playback) {}
        #expect(session.activationCalls == [true])

        coordinator.release(first)
        await coordinator.drain()
        #expect(session.activationCalls == [true])

        coordinator.release(second)
        await coordinator.drain()
        #expect(session.activationCalls == [true, false])
        #expect(session.calls.last == .setActive(false, notifyOthers: true))
    }

    @Test func releasingOneOfTwoClientsDoesNotDeactivate() async throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        let playback = try await coordinator.acquire(.playback) {}
        let capture = try await coordinator.acquire(.capture) {}

        coordinator.release(capture)
        await coordinator.drain()
        #expect(session.activationCalls == [true])

        coordinator.release(playback)
        await coordinator.drain()
        #expect(session.activationCalls == [true, false])
    }

    @Test func doubleReleaseIsIdempotent() async throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        let first = try await coordinator.acquire(.playback) {}
        let second = try await coordinator.acquire(.playback) {}

        coordinator.release(first)
        coordinator.release(first)
        await coordinator.drain()
        // The stale second release must not tear the session out from under
        // the remaining holder.
        #expect(session.activationCalls == [true])

        coordinator.release(second)
        coordinator.release(second)
        await coordinator.drain()
        #expect(session.activationCalls == [true, false])
    }

    // MARK: - Off-main session calls

    @Test func sessionCallsNeverRunOnTheMainThread() async throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        // The real setCategory/setActive block on IPC to the audio server
        // (>1 s observed under contention, tripping the system gesture gate
        // on PTT press) — every call must land on the coordinator's queue.
        let token = try await coordinator.acquire(.capture) {}
        coordinator.release(token)
        await coordinator.drain()

        #expect(session.calls.count == 3) // setCategory + activate + deactivate
        #expect(session.callsOnMainThread == [false, false, false])
    }

    @Test func failedActivationDoesNotRegisterAHolder() async throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        session.nextError = MockSessionError()
        await #expect(throws: MockSessionError.self) {
            try await coordinator.acquire(.playback) {}
        }

        // The failed acquire left no holder behind: the next one is 0->1
        // again and activates.
        let token = try await coordinator.acquire(.playback) {}
        #expect(session.activationCalls == [true])
        coordinator.release(token)
        await coordinator.drain()
        #expect(session.activationCalls == [true, false])
    }

    @Test func failedActivationRollsBackEscalatedCategory() async throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        // setCategory(.playAndRecord) succeeds, setActive throws (e.g. a
        // phone call owns the hardware).
        session.nextActivationError = MockSessionError()
        await #expect(throws: MockSessionError.self) {
            try await coordinator.acquire(.capture) {}
        }

        // With no holder registered the escalated category must not stick:
        // the next playback-only acquire runs under .playback, not the
        // leftover .playAndRecord.
        let token = try await coordinator.acquire(.playback) {}
        #expect(session.categoryCalls == [.playAndRecord, .playback])
        // And the failed acquire left no holder behind: this one was 0->1.
        #expect(session.activationCalls == [true])
        coordinator.release(token)
        await coordinator.drain()
        #expect(session.activationCalls == [true, false])
    }

    // MARK: - Category escalation

    @Test func captureWhilePlaybackEscalatesExactlyOnceAndNeverDowngrades() async throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        let playback = try await coordinator.acquire(.playback) {}
        #expect(session.categoryCalls == [.playback])

        let capture = try await coordinator.acquire(.capture) {}
        #expect(session.categoryCalls == [.playback, .playAndRecord])

        // More clients of either use don't touch the category again.
        let secondCapture = try await coordinator.acquire(.capture) {}
        let secondPlayback = try await coordinator.acquire(.playback) {}
        #expect(session.categoryCalls == [.playback, .playAndRecord])

        // Capture ending must not downgrade the route under live playback.
        coordinator.release(capture)
        coordinator.release(secondCapture)
        await coordinator.drain()
        #expect(session.categoryCalls == [.playback, .playAndRecord])

        // Even a fresh playback acquire stays on playAndRecord while held.
        let thirdPlayback = try await coordinator.acquire(.playback) {}
        #expect(session.categoryCalls == [.playback, .playAndRecord])

        coordinator.release(playback)
        coordinator.release(secondPlayback)
        coordinator.release(thirdPlayback)
        await coordinator.drain()
    }

    @Test func categoryResetsAfterAllHoldersRelease() async throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        let capture = try await coordinator.acquire(.capture) {}
        coordinator.release(capture)
        await coordinator.drain()
        #expect(session.categoryCalls == [.playAndRecord])

        // With no holders left the next playback-only session downgrades.
        let playback = try await coordinator.acquire(.playback) {}
        #expect(session.categoryCalls == [.playAndRecord, .playback])
        coordinator.release(playback)
        await coordinator.drain()
    }

    @Test func escalationNotifiesExistingHoldersSoEnginesCanRestart() async throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        var playbackInterruptions = 0
        var captureInterruptions = 0
        let playback = try await coordinator.acquire(.playback) { playbackInterruptions += 1 }
        let capture = try await coordinator.acquire(.capture) { captureInterruptions += 1 }

        // The pre-existing playback holder was reconfigured underneath (the
        // fan-out is delivered before acquire returns); the newly acquiring
        // capture client was not.
        #expect(playbackInterruptions == 1)
        #expect(captureInterruptions == 0)

        // A second capture doesn't change the category — nobody is notified.
        let secondCapture = try await coordinator.acquire(.capture) {}
        #expect(playbackInterruptions == 1)
        #expect(captureInterruptions == 0)

        coordinator.release(playback)
        coordinator.release(capture)
        coordinator.release(secondCapture)
        await coordinator.drain()
    }

    @Test func escalationPrefersCategoryChangeCallbackOverInterruption() async throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        var escalations = 0
        var interruptions = 0
        let playback = try await coordinator.acquire(
            .playback,
            onInterrupted: { interruptions += 1 },
            onCategoryEscalated: { escalations += 1 }
        )

        // Escalation reaches the dedicated callback (the holder restarts and
        // keeps playing) — not onInterrupted (which would stop it for good).
        let capture = try await coordinator.acquire(.capture) {}
        #expect(escalations == 1)
        #expect(interruptions == 0)

        // A real interruption still stops it.
        await coordinator.handleInterruptionBegan()
        #expect(escalations == 1)
        #expect(interruptions == 1)

        coordinator.release(playback)
        coordinator.release(capture)
        await coordinator.drain()
    }

    // MARK: - Interruptions and route changes

    @Test func interruptionDuringAcquireHandoffCancelsAcquire() async throws {
        let session = MockAudioSession()
        let handoffGate = AsyncGate()
        let coordinator = AudioSessionCoordinator(
            session: session,
            testingHooks: .init(beforeAcquireHandoff: {
                await handoffGate.wait()
            })
        )

        var interruptionCount = 0
        let acquireTask = Task { @MainActor in
            try await coordinator.acquire(.capture) {
                interruptionCount += 1
            }
        }

        // The session-queue registration is complete, but the caller has not
        // received its token. An interruption here used to invoke the callback
        // immediately, when capture clients could not release the token yet.
        await handoffGate.waitUntilEntered()
        await coordinator.handleInterruptionBegan()
        #expect(interruptionCount == 0)

        await handoffGate.open()
        await #expect(throws: CancellationError.self) {
            try await acquireTask.value
        }
        await coordinator.drain()
        #expect(interruptionCount == 0)
        // The OS already deactivated the interrupted session; removing the
        // provisional token must not issue a redundant setActive(false).
        #expect(session.activationCalls == [true])

        // The canceled acquire left no holder behind and the now-open test gate
        // does not affect a subsequent ownership handoff.
        let replacement = try await coordinator.acquire(.playback) {}
        #expect(session.activationCalls == [true, true])
        coordinator.release(replacement)
        await coordinator.drain()
        #expect(session.activationCalls == [true, true, false])
    }

    @Test func releasedSnapshotCannotInterruptReacquiredToken() async throws {
        let session = MockAudioSession()
        let deliveryGate = AsyncGate()
        let coordinator = AudioSessionCoordinator(
            session: session,
            testingHooks: .init(beforeCallbackDelivery: {
                await deliveryGate.wait()
            })
        )

        // Model a single client whose callback acts on whichever token it owns
        // now. If the old snapshot is delivered after reacquisition, it would
        // incorrectly release the new session.
        var activeToken: AudioSessionCoordinator.Token?
        var interruptionCount = 0
        let onInterrupted: @MainActor () -> Void = {
            interruptionCount += 1
            activeToken.map(coordinator.release)
        }

        let first = try await coordinator.acquire(.playback, onInterrupted: onInterrupted)
        activeToken = first
        let interruptionTask = Task {
            await coordinator.handleInterruptionBegan()
        }

        // The queue snapshot contains `first`, but main-actor delivery is held.
        await deliveryGate.waitUntilEntered()
        coordinator.release(first)
        activeToken = nil
        await coordinator.drain()

        let second = try await coordinator.acquire(.playback, onInterrupted: onInterrupted)
        activeToken = second
        #expect(session.activationCalls == [true, true])

        await deliveryGate.open()
        await interruptionTask.value
        await coordinator.drain()
        #expect(interruptionCount == 0)
        // A stale callback would have released `second` and appended false.
        #expect(session.activationCalls == [true, true])

        coordinator.release(second)
        activeToken = nil
        await coordinator.drain()
        #expect(session.activationCalls == [true, true, false])
    }

    @Test func interruptionFansOutToAllHoldersAndResetsActiveState() async throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        var playbackInterruptions = 0
        var captureInterruptions = 0
        // Capture first so no escalation fan-out muddies the counters.
        let capture = try await coordinator.acquire(.capture) { captureInterruptions += 1 }
        let playback = try await coordinator.acquire(.playback) { playbackInterruptions += 1 }
        #expect(session.activationCalls == [true])

        await coordinator.handleInterruptionBegan()
        #expect(playbackInterruptions == 1)
        #expect(captureInterruptions == 1)
        // The OS deactivated the session; the coordinator must not issue its
        // own setActive(false) on top of it.
        #expect(session.activationCalls == [true])

        // The active state was reset: the next acquire re-activates even
        // though holders never released.
        let resumed = try await coordinator.acquire(.playback) {}
        #expect(session.activationCalls == [true, true])

        coordinator.release(playback)
        coordinator.release(capture)
        coordinator.release(resumed)
        await coordinator.drain()
        #expect(session.activationCalls == [true, true, false])
    }

    @Test func interruptedHoldersReleasingDuringFanOutStaySafe() async throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        // Real clients release from within onInterrupted (stop() paths);
        // release is fire-and-forget onto the coordinator's queue, so it is
        // safe from inside the main-actor fan-out.
        var tokens: [AudioSessionCoordinator.Token] = []
        for _ in 0..<2 {
            var token: AudioSessionCoordinator.Token?
            token = try await coordinator.acquire(.playback) {
                token.map(coordinator.release)
            }
            tokens.append(token!)
        }

        await coordinator.handleInterruptionBegan()
        await coordinator.drain()
        // Every holder released mid-fan-out; the session was already
        // deactivated by the OS, so no redundant setActive(false).
        #expect(session.activationCalls == [true])

        // All holders are gone: a fresh acquire is 0->1 again.
        let token = try await coordinator.acquire(.playback) {}
        #expect(session.activationCalls == [true, true])
        coordinator.release(token)
        await coordinator.drain()
        #expect(session.activationCalls == [true, true, false])
    }

    @Test func routeDeviceUnavailableNotifiesHoldersButKeepsSessionActive() async throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        var interruptions = 0
        // Capture first so no escalation fan-out muddies the counter.
        let capture = try await coordinator.acquire(.capture) { interruptions += 1 }
        let playback = try await coordinator.acquire(.playback) { interruptions += 1 }

        await coordinator.handleRouteDeviceUnavailable()
        #expect(interruptions == 2)
        // Unlike an interruption, the session itself is still active — the
        // last holder's release performs the deactivation.
        coordinator.release(playback)
        coordinator.release(capture)
        await coordinator.drain()
        #expect(session.activationCalls == [true, false])
    }
}
