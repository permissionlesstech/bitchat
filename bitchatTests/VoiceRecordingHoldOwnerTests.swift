//
// VoiceRecordingHoldOwnerTests.swift
// bitchatTests
//
// One microphone, two composers: a hold belongs to the composer that
// started it. The other composer's presses can neither start a second hold
// nor end, finish or redirect this one, and ownership ends with the hold.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

@MainActor
struct VoiceRecordingHoldOwnerTests {
    private func waitUntil(
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(TestConstants.settleTimeout))
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    private func isRecording(_ state: VoiceRecordingViewModel.State) -> Bool {
        if case .recording = state { return true }
        return false
    }

    private func makeVoiceNoteFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hold-owner-\(UUID().uuidString).m4a")
        try Data([0x01]).write(to: url)
        return url
    }

    /// Counts how often a composer's factory was asked for a session.
    @MainActor
    private final class Factory {
        private var queued: [MockVoiceCaptureSession]
        private(set) var made = 0

        init(_ sessions: MockVoiceCaptureSession...) {
            queued = sessions
        }

        func make() -> VoiceCaptureSession {
            made += 1
            return queued.isEmpty ? MockVoiceCaptureSession() : queued.removeFirst()
        }
    }

    @Test func aHoldBelongsToTheComposerThatStartedIt() async {
        let session = MockVoiceCaptureSession()
        let viewModel = VoiceRecordingViewModel()

        viewModel.pressChanged(shouldShow: true, owner: .secondary, session: { session })
        await waitUntil { self.isRecording(viewModel.state) }

        #expect(viewModel.holdOwner == .secondary)
        #expect(viewModel.isHolding(.secondary))
        #expect(!viewModel.isHolding(.primary))
    }

    @Test func theOtherComposerCannotStartEndOrRedirectAHold() async {
        let ownerSession = MockVoiceCaptureSession()
        let other = Factory()
        let viewModel = VoiceRecordingViewModel()

        viewModel.pressChanged(shouldShow: true, owner: .primary, session: { ownerSession })
        await waitUntil { self.isRecording(viewModel.state) }

        // A second finger on the other composer's mic: no second session,
        // and its end, its removal and its cancels leave the hold running.
        viewModel.pressChanged(shouldShow: true, owner: .secondary, session: { other.make() })
        viewModel.start(shouldShow: true, owner: .secondary, session: { other.make() })
        viewModel.pressEnded(owner: .secondary) { _ in Issue.record("Another composer's release must not finish this hold") }
        viewModel.finish(owner: .secondary) { _ in Issue.record("Another composer's toggle must not finish this hold") }
        viewModel.cancel(owner: .secondary)
        viewModel.controlRemoved(owner: .secondary)

        #expect(other.made == 0)
        #expect(isRecording(viewModel.state))
        #expect(viewModel.holdOwner == .primary)
        #expect(!ownerSession.finishStarted)
        #expect(ownerSession.cancelCount == 0)
    }

    @Test func aPressThatBeganOnABusyMicStaysInertUntilItLifts() async {
        let ownerSession = MockVoiceCaptureSession()
        let other = Factory()
        let viewModel = VoiceRecordingViewModel()

        viewModel.pressChanged(shouldShow: true, owner: .primary, session: { ownerSession })
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.pressChanged(shouldShow: true, owner: .secondary, session: { other.make() })

        // The owner's hold ends; the other finger is still down and moves.
        viewModel.cancel(owner: .primary)
        await waitUntil { ownerSession.cancelCount == 1 }
        viewModel.pressChanged(shouldShow: true, owner: .secondary, session: { other.make() })
        #expect(other.made == 0)
        #expect(viewModel.state == .idle)

        // A fresh press on that mic starts a hold.
        viewModel.pressReleased(owner: .secondary)
        viewModel.pressChanged(shouldShow: true, owner: .secondary, session: { other.make() })
        await waitUntil { self.isRecording(viewModel.state) }
        #expect(other.made == 1)
        #expect(viewModel.holdOwner == .secondary)
    }

    @Test func theOwnersReleaseDeliversThroughItsOwnSender() async throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let session = MockVoiceCaptureSession()
        let viewModel = VoiceRecordingViewModel(now: { clock })
        let url = try makeVoiceNoteFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var delivered: [URL] = []

        viewModel.pressChanged(shouldShow: true, owner: .secondary, session: { session })
        await waitUntil { self.isRecording(viewModel.state) }
        clock = clock.addingTimeInterval(3)
        viewModel.pressEnded(owner: .secondary) { delivered.append($0) }
        #expect(viewModel.holdOwner == nil)

        await waitUntil { session.finishStarted }
        session.resolveFinish(with: url)
        await waitUntil { delivered == [url] }
    }

    /// The other composer may start the next hold while the released note
    /// finalizes; the note still goes out through its own sender.
    @Test func aReleasedNoteSurvivesTheOtherComposersNextHold() async throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let first = MockVoiceCaptureSession()
        let second = MockVoiceCaptureSession()
        let viewModel = VoiceRecordingViewModel(now: { clock })
        let url = try makeVoiceNoteFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var delivered: [URL] = []

        viewModel.pressChanged(shouldShow: true, owner: .primary, session: { first })
        await waitUntil { self.isRecording(viewModel.state) }
        clock = clock.addingTimeInterval(3)
        viewModel.pressEnded(owner: .primary) { delivered.append($0) }
        await waitUntil { first.finishStarted }

        viewModel.pressChanged(shouldShow: true, owner: .secondary, session: { second })
        await waitUntil { self.isRecording(viewModel.state) }
        #expect(viewModel.holdOwner == .secondary)

        first.resolveFinish(with: url)
        await waitUntil { delivered == [url] }
        #expect(isRecording(viewModel.state))
        #expect(viewModel.holdOwner == .secondary)
    }

    @Test func ownershipEndsWithEveryWayAHoldEnds() async {
        let viewModel = VoiceRecordingViewModel()

        // The owner's cancel.
        viewModel.start(shouldShow: true, owner: .secondary, session: { MockVoiceCaptureSession() })
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.cancel(owner: .secondary)
        #expect(viewModel.holdOwner == nil)

        // A layout change ends whichever hold is in flight.
        viewModel.start(shouldShow: true, owner: .secondary, session: { MockVoiceCaptureSession() })
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.cancelAnyHold()
        #expect(viewModel.holdOwner == nil)

        // The owning composer's mic goes away.
        viewModel.start(shouldShow: true, owner: .primary, session: { MockVoiceCaptureSession() })
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.controlRemoved(owner: .primary)
        #expect(viewModel.holdOwner == nil)

        // A panic.
        viewModel.start(shouldShow: true, owner: .secondary, session: { MockVoiceCaptureSession() })
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.panicWipe()
        #expect(viewModel.holdOwner == nil)

        // A refused microphone permission.
        let denied = MockVoiceCaptureSession()
        denied.grantsPermission = false
        viewModel.start(shouldShow: true, owner: .secondary, session: { denied })
        await waitUntil { viewModel.state == .permissionDenied }
        #expect(viewModel.holdOwner == nil)
        viewModel.showAlert = false

        // A capture that fails to start.
        struct StartFailed: Error {}
        viewModel.start(shouldShow: true, owner: .primary, session: { MockVoiceCaptureSession(startError: StartFailed()) })
        await waitUntil { viewModel.showAlert }
        #expect(viewModel.holdOwner == nil)
        viewModel.showAlert = false

        // Either composer can start again afterwards.
        viewModel.start(shouldShow: true, owner: .secondary, session: { MockVoiceCaptureSession() })
        await waitUntil { self.isRecording(viewModel.state) }
        #expect(viewModel.holdOwner == .secondary)
    }

    /// A start that stood down while the previous note finalizes stays its
    /// composer's: that press may retry, the other composer's may not.
    @Test func aDeferredStartStaysWithItsOwner() async {
        let releasing = MockVoiceCaptureSession()
        let deferred = MockVoiceCaptureSession(startError: VoiceRecorder.RecorderError.recordingInProgress)
        let retry = MockVoiceCaptureSession()
        let primary = Factory()
        let secondary = Factory(deferred, retry)
        let viewModel = VoiceRecordingViewModel()

        viewModel.pressChanged(shouldShow: true, owner: .primary, session: { releasing })
        await waitUntil { self.isRecording(viewModel.state) }
        viewModel.pressEnded(owner: .primary, completion: { _ in })
        await waitUntil { releasing.finishStarted }

        viewModel.pressChanged(shouldShow: true, owner: .secondary, session: { secondary.make() })
        await waitUntil { deferred.cancelCount == 1 && viewModel.isStartDeferred }
        #expect(viewModel.holdOwner == .secondary)

        viewModel.pressChanged(shouldShow: true, owner: .primary, session: { primary.make() })
        #expect(primary.made == 0)

        viewModel.pressChanged(shouldShow: true, owner: .secondary, session: { secondary.make() })
        await waitUntil { self.isRecording(viewModel.state) }
        #expect(secondary.made == 2)
        #expect(viewModel.holdOwner == .secondary)
        releasing.resolveFinish(with: nil)
    }

    /// The pressing composer's factory decides the backend, so a hold never
    /// streams to another conversation's audience.
    @Test func theHoldUsesThePressingComposersSession() async {
        let live = MockVoiceCaptureSession(isLive: true)
        let viewModel = VoiceRecordingViewModel()
        var providerCalls = 0
        viewModel.sessionProvider = {
            providerCalls += 1
            return MockVoiceCaptureSession()
        }

        viewModel.pressChanged(shouldShow: true, owner: .secondary, session: { live })
        await waitUntil { self.isRecording(viewModel.state) }

        #expect(viewModel.isLiveStreaming)
        #expect(live.startCount == 1)
        #expect(providerCalls == 0)
    }
}
