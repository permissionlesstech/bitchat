import Foundation
import AVFoundation
import BitLogger

/// Controls playback for a single voice note and coordinates exclusive playback across the app.
final class VoiceNotePlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var progress: Double = 0

    /// Internal lifecycle visibility for deterministic acquisition tests.
    var isPlaybackStartPending: Bool { sessionAcquireInFlight }

    /// rounded so 4.9s shows "00:05"
    var roundedDuration: Int {
        guard duration.isFinite else { return 0 }
        return Int(duration.rounded())
    }

    /// ceil so "00:01" stays visible until playback ends, capped to rounded duration
    var remainingSeconds: Int {
        let remaining = max(0, duration - currentTime)
        return min(roundedDuration, Int(ceil(remaining)))
    }

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var url: URL
    /// Test seam; `AudioSessionCoordinator.shared` when nil.
    private let sessionCoordinatorOverride: AudioSessionCoordinator?
    /// Injectable so tests don't fight over the app-wide exclusive-playback
    /// slot (a parallel test's `play()` would pause this controller mid-test).
    private let exclusivity: VoiceNotePlaybackCoordinator
    private var sessionToken: AudioSessionCoordinator.Token?
    /// A session acquire is in flight (it suspends off-main for the blocking
    /// session IPC); gates against double acquisition on rapid play taps.
    private var sessionAcquireInFlight = false

    init(
        url: URL,
        sessionCoordinator: AudioSessionCoordinator? = nil,
        exclusivity: VoiceNotePlaybackCoordinator? = nil
    ) {
        self.url = url
        self.sessionCoordinatorOverride = sessionCoordinator
        self.exclusivity = exclusivity ?? .shared
        super.init()
        // Don't load anything eagerly - wait until user interaction or view is fully displayed
    }

    func loadDuration() {
        guard duration == 0 else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            do {
                let player = try AVAudioPlayer(contentsOf: self.url)
                let loadedDuration = player.duration
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.duration == 0 else { return }
                    self.duration = loadedDuration
                }
            } catch {
                SecureLogger.error("Failed to load audio duration: \(error)", category: .session)
            }
        }
    }

    deinit {
        timer?.invalidate()
        player?.stop()
        // A per-row @StateObject can be discarded mid-playback (navigating
        // away). Leaking the token here would hold the session forever —
        // never deactivating it, and pinning any escalated category for the
        // app's lifetime. `release` is fire-and-forget onto the coordinator's
        // queue, so it is deinit-safe: only the Sendable token crosses.
        if let token = sessionToken {
            sessionToken = nil
            (sessionCoordinatorOverride ?? .shared).release(token)
        }
    }

    func replaceURL(_ url: URL) {
        guard url != self.url else { return }
        stop()
        self.url = url
        player = nil
        duration = 0
        // Duration will be loaded on demand when needed
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard ensurePlayerReady() else { return }
        exclusivity.activate(self)
        isPlaying = true
        startTimer()
        updateProgress()
        // Acquired here (not in ensurePlayerReady): scrubbing a paused note
        // must not hold the session while nothing is audible. The session
        // calls block on audio-server IPC, so they run off the main thread;
        // the player starts once the session is configured.
        startPlayerAfterAcquiringSession()
    }

    func pause() {
        player?.pause()
        stopTimer()
        updateProgress()
        isPlaying = false
        releaseSession()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        stopTimer()
        updateProgress()
        isPlaying = false
        releaseSession()
        exclusivity.deactivate(self)
    }

    func seek(to fraction: Double) {
        guard ensurePlayerReady() else { return }
        let clamped = max(0, min(1, fraction))
        if let player = player {
            player.currentTime = clamped * player.duration
            // While the session acquire is still in flight, don't start
            // audio pre-activation — the pending acquire's completion starts
            // playback (from the new position) once the session resolves.
            if isPlaying, !sessionAcquireInFlight {
                startPreparedPlayer()
            }
            updateProgress()
        }
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Delegate callback may be on background thread - ensure main thread for UI updates
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stopTimer()
            self.updateProgress()
            self.isPlaying = false
            self.releaseSession()
            self.exclusivity.deactivate(self)
        }
    }

    // MARK: - Private Helpers

    private func preparePlayer(for url: URL) {
        // Load metadata synchronously, but do not call prepareToPlay here:
        // paused scrubbing reaches this path and must not acquire playback
        // hardware outside the AudioSessionCoordinator token lifetime.
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            self.player = player
            duration = player.duration
            currentTime = player.currentTime
            progress = duration > 0 ? currentTime / duration : 0
        } catch {
            SecureLogger.error("Voice note playback failed for \(url.lastPathComponent): \(error)", category: .session)
            player = nil
            duration = 0
            currentTime = 0
            progress = 0
        }
    }

    private func ensurePlayerReady() -> Bool {
        if player == nil {
            preparePlayer(for: url)
        }
        return player != nil
    }

    /// All entry points (SwiftUI actions, `pauseForExclusivity`, the
    /// delegate's main-queue hop) run on the main thread; the acquire itself
    /// suspends while the blocking session IPC runs on the coordinator's
    /// queue, and the player starts when it resolves. An acquire failure
    /// leaves playback stopped: starting without a registered token would
    /// bypass interruption fan-out and the coordinator's refcount. A
    /// pause/stop landing mid-acquire hands the token straight back.
    private func startPlayerAfterAcquiringSession() {
        if sessionToken != nil {
            startPreparedPlayer()
            return
        }
        guard !sessionAcquireInFlight else { return }
        sessionAcquireInFlight = true
        let coordinator = sessionCoordinatorOverride ?? AudioSessionCoordinator.shared
        Task { @MainActor [weak self] in
            var token: AudioSessionCoordinator.Token?
            do {
                token = try await coordinator.acquire(.playback) { [weak self] in
                    self?.pause()
                }
            } catch {
                SecureLogger.error("Failed to activate audio session: \(error)", category: .session)
            }
            guard let self else {
                // The row was discarded while acquiring; deinit had no token
                // to release yet.
                token.map(coordinator.release)
                return
            }
            self.sessionAcquireInFlight = false
            guard self.isPlaying else {
                // Paused/stopped while the session was activating.
                token.map(coordinator.release)
                return
            }
            guard let token else {
                self.failPlaybackStart()
                return
            }
            self.sessionToken = token
            self.startPreparedPlayer()
        }
    }

    @discardableResult
    private func startPreparedPlayer() -> Bool {
        guard let player,
              player.prepareToPlay(),
              player.play()
        else {
            SecureLogger.error("Voice note player refused to start " + url.lastPathComponent, category: .session)
            failPlaybackStart()
            return false
        }
        return true
    }

    private func failPlaybackStart() {
        player?.pause()
        stopTimer()
        updateProgress()
        isPlaying = false
        releaseSession()
        exclusivity.deactivate(self)
    }

    private func releaseSession() {
        sessionToken.map((sessionCoordinatorOverride ?? .shared).release)
        sessionToken = nil
    }

    private func startTimer() {
        if timer != nil { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateProgress()
        }
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateProgress() {
        guard let player = player else {
            currentTime = 0
            duration = 0
            progress = 0
            return
        }
        currentTime = player.currentTime
        duration = player.duration
        progress = duration > 0 ? currentTime / duration : 0
    }
}

/// Something that can hold the app's single audio-playback slot and yield it
/// when another playback starts (voice notes pause; live bursts stop).
protocol ExclusivePlayback: AnyObject {
    func pauseForExclusivity()
}

extension VoiceNotePlaybackController: ExclusivePlayback {
    func pauseForExclusivity() {
        pause()
    }
}

/// Ensures only one voice playback (note or live burst) runs at a time.
final class VoiceNotePlaybackCoordinator {
    static let shared = VoiceNotePlaybackCoordinator()

    struct Reservation: Equatable {
        fileprivate let generation: UInt64
    }

    private weak var activeController: (any ExclusivePlayback)?
    private weak var latestReservedController: (any ExclusivePlayback)?
    private var latestReservation = Reservation(generation: 0)

    /// Internal so tests can isolate their own exclusivity slot; the app
    /// uses `shared`.
    init() {}

    /// Records playback intent without interrupting audio that is already
    /// audible. Async starters reserve before suspension, then activate only
    /// after their audio resource is ready.
    func reserve(_ controller: any ExclusivePlayback) -> Reservation {
        latestReservation = Reservation(generation: latestReservation.generation &+ 1)
        latestReservedController = controller
        return latestReservation
    }

    /// Immediate activation for synchronous/user-initiated playback.
    @discardableResult
    func activate(_ controller: any ExclusivePlayback) -> Reservation {
        let reservation = reserve(controller)
        _ = activate(controller, reservation: reservation)
        return reservation
    }

    /// Commits an earlier reservation only when it is still the newest
    /// playback request. This prevents an older async acquire from stealing
    /// the floor after a newer play gesture.
    @discardableResult
    func activate(_ controller: any ExclusivePlayback, reservation: Reservation) -> Bool {
        guard isCurrent(reservation, for: controller) else { return false }
        if activeController === controller {
            return true
        }
        activeController?.pauseForExclusivity()
        activeController = controller
        return true
    }

    func isCurrent(_ reservation: Reservation, for controller: any ExclusivePlayback) -> Bool {
        latestReservation == reservation && latestReservedController === controller
    }

    func deactivate(_ controller: any ExclusivePlayback) {
        if activeController === controller {
            activeController = nil
        }
        if latestReservedController === controller {
            latestReservedController = nil
        }
    }
}
