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

@MainActor
private final class MockAudioSession: SessionApplying {
    enum Call: Equatable {
        case setCategory(AudioSessionCoordinator.Category)
        case setActive(Bool, notifyOthers: Bool)
    }

    private(set) var calls: [Call] = []
    var nextError: Error?
    /// Fails only the next `setActive` (so `setCategory` can succeed first).
    var nextActivationError: Error?

    func setCategory(_ category: AudioSessionCoordinator.Category) throws {
        try throwIfRequested()
        calls.append(.setCategory(category))
    }

    func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws {
        try throwIfRequested()
        if let error = nextActivationError {
            nextActivationError = nil
            throw error
        }
        calls.append(.setActive(active, notifyOthers: notifyOthersOnDeactivation))
    }

    var categoryCalls: [AudioSessionCoordinator.Category] {
        calls.compactMap { if case .setCategory(let category) = $0 { category } else { nil } }
    }

    var activationCalls: [Bool] {
        calls.compactMap { if case .setActive(let active, _) = $0 { active } else { nil } }
    }

    private func throwIfRequested() throws {
        if let error = nextError {
            nextError = nil
            throw error
        }
    }
}

private struct MockSessionError: Error {}

@MainActor
struct AudioSessionCoordinatorTests {
    // MARK: - Reference-counted activation

    @Test func activatesOnFirstAcquireAndDeactivatesOnLastRelease() throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        let first = try coordinator.acquire(.playback) {}
        let second = try coordinator.acquire(.playback) {}
        #expect(session.activationCalls == [true])

        coordinator.release(first)
        #expect(session.activationCalls == [true])

        coordinator.release(second)
        #expect(session.activationCalls == [true, false])
        #expect(session.calls.last == .setActive(false, notifyOthers: true))
    }

    @Test func releasingOneOfTwoClientsDoesNotDeactivate() throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        let playback = try coordinator.acquire(.playback) {}
        let capture = try coordinator.acquire(.capture) {}

        coordinator.release(capture)
        #expect(session.activationCalls == [true])

        coordinator.release(playback)
        #expect(session.activationCalls == [true, false])
    }

    @Test func doubleReleaseIsIdempotent() throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        let first = try coordinator.acquire(.playback) {}
        let second = try coordinator.acquire(.playback) {}

        coordinator.release(first)
        coordinator.release(first)
        // The stale second release must not tear the session out from under
        // the remaining holder.
        #expect(session.activationCalls == [true])

        coordinator.release(second)
        coordinator.release(second)
        #expect(session.activationCalls == [true, false])
    }

    @Test func failedActivationDoesNotRegisterAHolder() throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        session.nextError = MockSessionError()
        #expect(throws: MockSessionError.self) {
            try coordinator.acquire(.playback) {}
        }

        // The failed acquire left no holder behind: the next one is 0->1
        // again and activates.
        let token = try coordinator.acquire(.playback) {}
        #expect(session.activationCalls == [true])
        coordinator.release(token)
        #expect(session.activationCalls == [true, false])
    }

    @Test func failedActivationRollsBackEscalatedCategory() throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        // setCategory(.playAndRecord) succeeds, setActive throws (e.g. a
        // phone call owns the hardware).
        session.nextActivationError = MockSessionError()
        #expect(throws: MockSessionError.self) {
            try coordinator.acquire(.capture) {}
        }

        // With no holder registered the escalated category must not stick:
        // the next playback-only acquire runs under .playback, not the
        // leftover .playAndRecord.
        let token = try coordinator.acquire(.playback) {}
        #expect(session.categoryCalls == [.playAndRecord, .playback])
        // And the failed acquire left no holder behind: this one was 0->1.
        #expect(session.activationCalls == [true])
        coordinator.release(token)
        #expect(session.activationCalls == [true, false])
    }

    // MARK: - Category escalation

    @Test func captureWhilePlaybackEscalatesExactlyOnceAndNeverDowngrades() throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        let playback = try coordinator.acquire(.playback) {}
        #expect(session.categoryCalls == [.playback])

        let capture = try coordinator.acquire(.capture) {}
        #expect(session.categoryCalls == [.playback, .playAndRecord])

        // More clients of either use don't touch the category again.
        let secondCapture = try coordinator.acquire(.capture) {}
        let secondPlayback = try coordinator.acquire(.playback) {}
        #expect(session.categoryCalls == [.playback, .playAndRecord])

        // Capture ending must not downgrade the route under live playback.
        coordinator.release(capture)
        coordinator.release(secondCapture)
        #expect(session.categoryCalls == [.playback, .playAndRecord])

        // Even a fresh playback acquire stays on playAndRecord while held.
        let thirdPlayback = try coordinator.acquire(.playback) {}
        #expect(session.categoryCalls == [.playback, .playAndRecord])

        coordinator.release(playback)
        coordinator.release(secondPlayback)
        coordinator.release(thirdPlayback)
    }

    @Test func categoryResetsAfterAllHoldersRelease() throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        let capture = try coordinator.acquire(.capture) {}
        coordinator.release(capture)
        #expect(session.categoryCalls == [.playAndRecord])

        // With no holders left the next playback-only session downgrades.
        let playback = try coordinator.acquire(.playback) {}
        #expect(session.categoryCalls == [.playAndRecord, .playback])
        coordinator.release(playback)
    }

    @Test func escalationNotifiesExistingHoldersSoEnginesCanRestart() throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        var playbackInterruptions = 0
        var captureInterruptions = 0
        let playback = try coordinator.acquire(.playback) { playbackInterruptions += 1 }
        let capture = try coordinator.acquire(.capture) { captureInterruptions += 1 }

        // The pre-existing playback holder was reconfigured underneath; the
        // newly acquiring capture client was not.
        #expect(playbackInterruptions == 1)
        #expect(captureInterruptions == 0)

        // A second capture doesn't change the category — nobody is notified.
        let secondCapture = try coordinator.acquire(.capture) {}
        #expect(playbackInterruptions == 1)
        #expect(captureInterruptions == 0)

        coordinator.release(playback)
        coordinator.release(capture)
        coordinator.release(secondCapture)
    }

    @Test func escalationPrefersCategoryChangeCallbackOverInterruption() throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        var escalations = 0
        var interruptions = 0
        let playback = try coordinator.acquire(
            .playback,
            onInterrupted: { interruptions += 1 },
            onCategoryEscalated: { escalations += 1 }
        )

        // Escalation reaches the dedicated callback (the holder restarts and
        // keeps playing) — not onInterrupted (which would stop it for good).
        let capture = try coordinator.acquire(.capture) {}
        #expect(escalations == 1)
        #expect(interruptions == 0)

        // A real interruption still stops it.
        coordinator.handleInterruptionBegan()
        #expect(escalations == 1)
        #expect(interruptions == 1)

        coordinator.release(playback)
        coordinator.release(capture)
    }

    // MARK: - Interruptions and route changes

    @Test func interruptionFansOutToAllHoldersAndResetsActiveState() throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        var playbackInterruptions = 0
        var captureInterruptions = 0
        // Capture first so no escalation fan-out muddies the counters.
        let capture = try coordinator.acquire(.capture) { captureInterruptions += 1 }
        let playback = try coordinator.acquire(.playback) { playbackInterruptions += 1 }
        #expect(session.activationCalls == [true])

        coordinator.handleInterruptionBegan()
        #expect(playbackInterruptions == 1)
        #expect(captureInterruptions == 1)
        // The OS deactivated the session; the coordinator must not issue its
        // own setActive(false) on top of it.
        #expect(session.activationCalls == [true])

        // The active state was reset: the next acquire re-activates even
        // though holders never released.
        let resumed = try coordinator.acquire(.playback) {}
        #expect(session.activationCalls == [true, true])

        coordinator.release(playback)
        coordinator.release(capture)
        coordinator.release(resumed)
        #expect(session.activationCalls == [true, true, false])
    }

    @Test func interruptedHoldersReleasingDuringFanOutStaySafe() throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        // Real clients release from within onInterrupted (stop() paths).
        var tokens: [AudioSessionCoordinator.Token] = []
        for _ in 0..<2 {
            var token: AudioSessionCoordinator.Token?
            token = try coordinator.acquire(.playback) {
                token.map(coordinator.release)
            }
            tokens.append(token!)
        }

        coordinator.handleInterruptionBegan()
        // Every holder released mid-fan-out; the session was already
        // deactivated by the OS, so no redundant setActive(false).
        #expect(session.activationCalls == [true])

        // All holders are gone: a fresh acquire is 0->1 again.
        let token = try coordinator.acquire(.playback) {}
        #expect(session.activationCalls == [true, true])
        coordinator.release(token)
        #expect(session.activationCalls == [true, true, false])
    }

    @Test func routeDeviceUnavailableNotifiesHoldersButKeepsSessionActive() throws {
        let session = MockAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)

        var interruptions = 0
        // Capture first so no escalation fan-out muddies the counter.
        let capture = try coordinator.acquire(.capture) { interruptions += 1 }
        let playback = try coordinator.acquire(.playback) { interruptions += 1 }

        coordinator.handleRouteDeviceUnavailable()
        #expect(interruptions == 2)
        // Unlike an interruption, the session itself is still active — the
        // last holder's release performs the deactivation.
        coordinator.release(playback)
        coordinator.release(capture)
        #expect(session.activationCalls == [true, false])
    }
}
