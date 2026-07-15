//
// PTTBurstPlayerTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import AVFoundation
import Foundation
@testable import bitchat

/// Thread-safe: the coordinator invokes it on its private serial queue.
private final class StubAudioSession: SessionApplying, @unchecked Sendable {
    private let lock = NSLock()
    private var _setCategoryError: Error?

    var setCategoryError: Error? {
        get { lock.withLock { _setCategoryError } }
        set { lock.withLock { _setCategoryError = newValue } }
    }

    func setCategory(_ category: AudioSessionCoordinator.Category) throws {
        try lock.withLock {
            if let error = _setCategoryError {
                _setCategoryError = nil
                throw error
            }
        }
    }

    func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws {}
}

private struct StubSessionError: Error {}

private final class StubExclusivePlayback: ExclusivePlayback {
    private(set) var pauseCount = 0

    func pauseForExclusivity() {
        pauseCount += 1
    }
}

/// Blocks activation until released, so a test can land events inside the
/// window where the (off-main) session acquire is still in flight.
private final class GatedAudioSession: SessionApplying, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _categoryCallCount = 0
    private var _activationCalls: [Bool] = []

    /// Non-zero once the acquire has reached the session queue (setCategory
    /// runs just before the gated setActive).
    var categoryCallCount: Int { lock.withLock { _categoryCallCount } }
    var activationCalls: [Bool] { lock.withLock { _activationCalls } }

    func open() { gate.signal() }

    func setCategory(_ category: AudioSessionCoordinator.Category) throws {
        lock.withLock { _categoryCallCount += 1 }
    }

    func setActive(_ active: Bool, notifyOthersOnDeactivation: Bool) throws {
        if active { gate.wait() }
        lock.withLock { _activationCalls.append(active) }
    }
}

@MainActor
private final class MockPlaybackEngine: PTTPlaybackEngine {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var scheduledBuffers: [AVAudioPCMBuffer] = []
    private struct HeldCompletion {
        let type: PTTPlaybackCompletionType
        let callback: @Sendable (PTTPlaybackCompletionEvent) -> Void
    }
    private var heldCompletions: [HeldCompletion] = []
    private(set) var requestedCompletionTypes: [PTTPlaybackCompletionType] = []
    var startError: Error?

    // No object -> the player registers no configuration-change observer.
    var configChangeObject: AnyObject? { nil }

    func start() throws {
        if let error = startError { throw error }
        startCount += 1
    }

    func play() {}

    func stop() {
        stopCount += 1
    }

    func schedule(
        _ buffer: AVAudioPCMBuffer,
        completionType: PTTPlaybackCompletionType,
        completionHandler: @escaping @Sendable (PTTPlaybackCompletionEvent) -> Void
    ) {
        // Completions are held, not fired automatically: most tests exercise
        // lifecycle, not drain-out. The mock models the important distinction
        // between the node consuming bytes and audio actually playing out.
        scheduledBuffers.append(buffer)
        requestedCompletionTypes.append(completionType)
        heldCompletions.append(HeldCompletion(type: completionType, callback: completionHandler))
    }

    /// Advances the node only to the point where it has consumed each
    /// buffer. A `.dataPlayedBack` request must remain pending here.
    func fireDataConsumedCallbacks() {
        for completion in heldCompletions {
            completion.callback(.dataConsumed)
        }
    }

    /// Advances all scheduled audio through audible playback.
    func fireDataPlayedBackCallbacks() {
        let completions = heldCompletions
        heldCompletions = []
        for completion in completions {
            completion.callback(.dataPlayedBack)
        }
    }

    /// Models AVAudioPlayerNode flushing its callbacks because an external
    /// engine reconfiguration stopped the node before MainActor rebuilt it.
    func firePlaybackStoppedCallbacks() {
        let completions = heldCompletions
        heldCompletions = []
        for completion in completions {
            completion.callback(.playbackStopped)
        }
    }

    /// Plays only the oldest scheduled buffer, leaving the rest as an
    /// audible tail that an engine rebuild must preserve.
    func fireNextDataPlayedBackCallback() {
        guard let index = heldCompletions.firstIndex(where: { $0.type == .dataPlayedBack }) else { return }
        let completion = heldCompletions.remove(at: index)
        completion.callback(.dataPlayedBack)
    }
}

@MainActor
struct PTTBurstPlayerTests {
    private func makePlayer(
        coordinator: AudioSessionCoordinator
    ) throws -> (player: PTTBurstPlayer, engines: () -> [MockPlaybackEngine]) {
        final class EngineBox { var engines: [MockPlaybackEngine] = [] }
        let box = EngineBox()
        // Fresh exclusivity slot: parallel tests must not steal this player's
        // app-wide playback slot mid-test (the async session acquire opens
        // suspension windows the old synchronous start never had).
        let player = try #require(PTTBurstPlayer(
            coordinator: coordinator,
            exclusivity: VoiceNotePlaybackCoordinator(),
            makeEngine: {
                let engine = MockPlaybackEngine()
                box.engines.append(engine)
                return engine
            }
        ))
        return (player, { box.engines })
    }

    /// Enough encoded audio to cross `TransportConfig.pttJitterBufferSeconds`
    /// so playback starts without waiting for the deadline task.
    private func encodeSineFrames(seconds: Double = 1.0) throws -> [Data] {
        let encoder = try #require(PTTFrameEncoder())
        let format = try #require(PTTAudioFormat.pcmFormat)
        let totalFrames = AVAudioFrameCount(seconds * PTTAudioFormat.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames))
        buffer.frameLength = totalFrames
        let channel = try #require(buffer.floatChannelData?[0])
        for i in 0..<Int(totalFrames) {
            channel[i] = sinf(2 * .pi * 440 * Float(i) / Float(PTTAudioFormat.sampleRate)) * 0.5
        }
        return encoder.encode(buffer)
    }

    /// The jitter-buffered start now acquires the session asynchronously
    /// (its blocking IPC runs off the main actor), so tests await the
    /// condition instead of asserting right after `enqueue`.
    private func waitUntil(
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    // MARK: - Talk-over (bidirectional)

    @Test func burstDrainWaitsForAudiblePlaybackNotDataConsumption() async throws {
        let coordinator = AudioSessionCoordinator(session: StubAudioSession())
        let (player, engines) = try makePlayer(coordinator: coordinator)

        player.enqueue(try encodeSineFrames())
        await waitUntil { player.isPlaying }
        let engine = try #require(engines().first)
        #expect(engine.requestedCompletionTypes.allSatisfy { $0 == .dataPlayedBack })

        player.finishAfterDrain()
        engine.fireDataConsumedCallbacks()
        await Task.yield()
        #expect(!player.stopped)
        #expect(player.isPlaying)

        engine.fireDataPlayedBackCallbacks()
        await waitUntil { player.stopped }
        #expect(!player.isPlaying)
    }

    @Test func olderPTTSessionAcquireCannotStealNewerPlaybackReservation() async throws {
        let session = GatedAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)
        let exclusivity = VoiceNotePlaybackCoordinator()
        final class EngineBox { var engines: [MockPlaybackEngine] = [] }
        let box = EngineBox()
        let player = try #require(PTTBurstPlayer(
            coordinator: coordinator,
            exclusivity: exclusivity,
            makeEngine: {
                let engine = MockPlaybackEngine()
                box.engines.append(engine)
                return engine
            }
        ))

        player.enqueue(try encodeSineFrames())
        await waitUntil { session.categoryCallCount == 1 }

        // A user taps a voice note while the older inbound burst is blocked
        // in audio-session activation. Its immediate play intent is newer.
        let voiceNote = StubExclusivePlayback()
        exclusivity.activate(voiceNote)
        session.open()

        await waitUntil { player.stopped }
        #expect(box.engines.count == 1)
        #expect(box.engines[0].startCount == 0)
        #expect(voiceNote.pauseCount == 0)
        #expect(!player.isPlaying)
    }

    @Test func categoryEscalationRestartsEngineAndKeepsStreaming() async throws {
        let coordinator = AudioSessionCoordinator(session: StubAudioSession())
        let (player, engines) = try makePlayer(coordinator: coordinator)

        let frames = try encodeSineFrames()
        player.enqueue(frames)
        await waitUntil { player.isPlaying }
        #expect(engines().count == 1)
        #expect(engines()[0].startCount == 1)
        #expect(!engines()[0].scheduledBuffers.isEmpty)

        // Push-to-talk pressed while the burst plays: capture escalates the
        // session category. The playback engine must restart under the new
        // configuration, not die. (Escalation fan-out is delivered before
        // acquire returns, so no waiting is needed here.)
        let capture = try await coordinator.acquire(.capture) {}
        #expect(engines().count == 2)
        #expect(engines()[0].stopCount == 1)
        #expect(engines()[1].startCount == 1)
        #expect(player.isPlaying)

        // Frames arriving after the restart keep playing on the new engine.
        player.enqueue(frames)
        #expect(!engines()[1].scheduledBuffers.isEmpty)

        coordinator.release(capture)
        player.stop()
        #expect(!player.isPlaying)
    }

    @Test func categoryEscalationReplaysOnlyUnfinishedTailAfterBurstEnd() async throws {
        let coordinator = AudioSessionCoordinator(session: StubAudioSession())
        let (player, engines) = try makePlayer(coordinator: coordinator)

        let frames = try encodeSineFrames()
        player.enqueue(frames)
        await waitUntil { player.isPlaying }

        let originalEngine = engines()[0]
        let originallyScheduled = originalEngine.scheduledBuffers.count
        try #require(originallyScheduled > 1)

        // One buffer has played, but deliberately do not yield for its
        // MainActor completion task. The completion latch itself must keep
        // the rebuild from replaying this already-completed prefix.
        originalEngine.fireNextDataPlayedBackCallback()
        player.finishAfterDrain()

        // A real AVAudioPlayerNode also invokes requested callbacks when its
        // engine is stopped by a configuration change. Those callbacks must
        // leave the unheard tail pending for the fresh engine.
        originalEngine.firePlaybackStoppedCallbacks()

        // Capture joins after END while the remaining tail is still handed
        // to the old engine. The fresh engine must replay that tail instead
        // of looking empty and stopping immediately.
        let capture = try await coordinator.acquire(.capture) {}
        try #require(engines().count == 2)
        let restartedEngine = engines()[1]
        #expect(restartedEngine.scheduledBuffers.count == originallyScheduled - 1)
        #expect(player.isPlaying)
        #expect(!player.stopped)

        // Only the fresh engine's audible completions may stop this finished
        // burst; the stop callbacks above did not drain it.
        #expect(player.isPlaying)
        #expect(!player.stopped)

        restartedEngine.fireDataPlayedBackCallbacks()
        await waitUntil { player.stopped }
        #expect(!player.isPlaying)

        coordinator.release(capture)
    }

    @Test func realInterruptionStillStopsPlayback() async throws {
        let coordinator = AudioSessionCoordinator(session: StubAudioSession())
        let (player, engines) = try makePlayer(coordinator: coordinator)

        let frames = try encodeSineFrames()
        player.enqueue(frames)
        await waitUntil { player.isPlaying }

        // A system interruption (phone call) is not an escalation: stop.
        await coordinator.handleInterruptionBegan()
        #expect(!player.isPlaying)
        #expect(engines().count == 1)
        #expect(engines()[0].stopCount == 1)

        // A stopped burst stays stopped.
        let before = engines()[0].scheduledBuffers.count
        player.enqueue(frames)
        #expect(engines()[0].scheduledBuffers.count == before)
    }

    // MARK: - Burst END racing the async session acquire

    /// Models production ownership (`ChatLiveVoiceCoordinator.finalize`): the
    /// assembly — the player's sole strong owner — is discarded on burst END,
    /// and only the parked draining reference keeps the player alive. The
    /// audio must still play out and the session token must come back once
    /// the drain finishes.
    @Test func burstEndDuringSessionAcquireStillPlaysWithOnlyDrainOwner() async throws {
        let session = GatedAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)
        final class EngineBox { var engines: [MockPlaybackEngine] = [] }
        let box = EngineBox()
        var owner: PTTBurstPlayer? = PTTBurstPlayer(
            coordinator: coordinator,
            exclusivity: VoiceNotePlaybackCoordinator(),
            makeEngine: {
                let engine = MockPlaybackEngine()
                box.engines.append(engine)
                return engine
            }
        )
        try #require(owner != nil)
        let weakPlayer = { [weak owner] in owner }

        let frames = try encodeSineFrames()
        owner?.enqueue(frames)
        // END lands while activation is still blocked on the session queue.
        // With nothing scheduled yet, the drain check must not mistake the
        // not-yet-started burst for a played-out one and drop all its audio.
        var draining: PTTBurstPlayer? = owner
        owner?.onStopped = { draining = nil }
        owner?.finishAfterDrain()
        #expect(owner?.stopped == false)
        owner = nil

        session.open()
        await waitUntil { weakPlayer()?.isPlaying == true }
        #expect(box.engines.count == 1)
        #expect(box.engines[0].startCount == 1)
        #expect(!box.engines[0].scheduledBuffers.isEmpty)

        // Play the tail out: the drain must stop the player, hand the token
        // back (deactivation reaches the mock), and unpark the drain owner.
        box.engines[0].fireDataPlayedBackCallbacks()
        await waitUntil { session.activationCalls == [true, false] }
        #expect(draining == nil)
        #expect(weakPlayer() == nil)
    }

    /// Backstop: if every owner drops the player before it stopped, `deinit`
    /// must hand the registered session token back — the coordinator retains
    /// tokens strongly, so a leaked one would keep the session active (and
    /// pin any escalated category) for the app's lifetime.
    @Test func ownerlessPlayerDeinitReleasesSessionToken() async throws {
        let session = GatedAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)
        var player: PTTBurstPlayer? = PTTBurstPlayer(
            coordinator: coordinator,
            exclusivity: VoiceNotePlaybackCoordinator(),
            makeEngine: { MockPlaybackEngine() }
        )
        try #require(player != nil)

        let frames = try encodeSineFrames()
        player?.enqueue(frames)
        // Make sure the acquire is in flight (holding the player alive
        // through its call frame) before the last external reference drops.
        await waitUntil { session.categoryCallCount == 1 }
        player?.finishAfterDrain()
        player = nil

        session.open()
        // The acquire task keeps the player alive just long enough to start;
        // when it deallocates, deinit must release the freshly stored token.
        await waitUntil { session.activationCalls == [true, false] }
    }

    // MARK: - Session acquire failure

    @Test func sessionAcquireFailureDoesNotStartUnregisteredPlayback() async throws {
        let session = StubAudioSession()
        let coordinator = AudioSessionCoordinator(session: session)
        let (player, engines) = try makePlayer(coordinator: coordinator)

        // Playing without a registered holder would leave the engine exposed
        // to another holder's last-release deactivating the session under it.
        session.setCategoryError = StubSessionError()
        let frames = try encodeSineFrames()
        player.enqueue(frames)
        await waitUntil { player.stopped }

        #expect(engines().count == 1)
        #expect(engines()[0].startCount == 0)
        #expect(!player.isPlaying)

        // The failed start latched the player off; later frames are ignored.
        player.enqueue(frames)
        #expect(engines()[0].scheduledBuffers.isEmpty)
        #expect(!player.isPlaying)
    }

    // MARK: - Engine start failure

    @Test func engineStartFailureRebuildsOnceBeforeGivingUp() async throws {
        let coordinator = AudioSessionCoordinator(session: StubAudioSession())
        let (player, engines) = try makePlayer(coordinator: coordinator)

        // A capture racing the start can reconfigure the session while the
        // engine spins up (its escalation fan-out no-ops on a never-started
        // player): the player must rebuild once against the settled
        // configuration instead of latching off.
        engines()[0].startError = StubSessionError()
        let frames = try encodeSineFrames()
        player.enqueue(frames)

        await waitUntil { player.isPlaying }
        #expect(engines().count == 2)
        #expect(engines()[0].startCount == 0)
        #expect(engines()[1].startCount == 1)
        #expect(!engines()[1].scheduledBuffers.isEmpty)
        player.stop()
    }
}
