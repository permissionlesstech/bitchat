import Foundation
import AVFoundation
import BitLogger

/// Controls playback for a single voice note and coordinates exclusive playback across the app.
final class VoiceNotePlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var progress: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var url: URL

    init(url: URL) {
        self.url = url
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
        VoiceNotePlaybackCoordinator.shared.activate(self)
        player?.play()
        startTimer()
        updateProgress()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        stopTimer()
        updateProgress()
        isPlaying = false
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        stopTimer()
        updateProgress()
        isPlaying = false
        VoiceNotePlaybackCoordinator.shared.deactivate(self)
    }

    func seek(to fraction: Double) {
        guard ensurePlayerReady() else { return }
        let clamped = max(0, min(1, fraction))
        if let player = player {
            player.currentTime = clamped * player.duration
            if isPlaying {
                player.play()
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
            VoiceNotePlaybackCoordinator.shared.deactivate(self)
        }
    }

    // MARK: - Private Helpers

    private func preparePlayer(for url: URL) {
        // Prepare player synchronously (only called when playback is requested)
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
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
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            SecureLogger.error("Failed to activate audio session: \(error)", category: .session)
        }
        #endif
        return player != nil
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

/// Ensures only one voice note plays at a time.
final class VoiceNotePlaybackCoordinator {
    static let shared = VoiceNotePlaybackCoordinator()

    private weak var activeController: VoiceNotePlaybackController?

    private init() {}

    func activate(_ controller: VoiceNotePlaybackController) {
        if activeController === controller {
            return
        }
        activeController?.pause()
        activeController = controller
    }

    func deactivate(_ controller: VoiceNotePlaybackController) {
        if activeController === controller {
            activeController = nil
        }
    }
}
