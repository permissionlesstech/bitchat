//
// VideoStudioView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)
import AVFoundation
import BitLogger
import CoreImage
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Hands capture-queue frames to the current send session without a hop
/// through the main actor.
private final class VideoStudioFrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var session: LiveVideoSendSession?

    func attach(_ session: LiveVideoSendSession?) {
        lock.withLock { self.session = session }
    }

    func video(_ pixelBuffer: CVPixelBuffer) {
        lock.withLock { session }?.offerVideo(pixelBuffer)
    }

    func audio(_ frames: [Data]) {
        lock.withLock { session }?.offerAudio(frames)
    }
}

/// State behind the video screen: owns the camera/mic source (so the
/// viewfinder runs before and after recording) and, while recording, one
/// `LiveVideoSendSession` that streams live or records a clip.
@MainActor
final class VideoStudioModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case live, clip
        var id: String { rawValue }
    }

    enum Phase: Equatable {
        case idle
        case recording
        case finishing
        case importing
    }

    @Published var mode: Mode = .live
    @Published var quality: LiveVideoQuality = .low
    @Published var microphoneOn = true
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var stats = LiveVideoSendStats()
    @Published private(set) var syntheticPreview: CGImage?
    @Published private(set) var errorMessage: String?
    @Published private(set) var usesFrontCamera = false

    let usesSyntheticSource: Bool
    private(set) var cameraSource: LiveVideoCameraSource?
    private var source: (any LiveVideoFrameSource)?
    private var session: LiveVideoSendSession? {
        didSet { sink.attach(session) }
    }
    private let sink = VideoStudioFrameSink()
    private var clockTask: Task<Void, Never>?
    private let ciContext = CIContext()
    private var lastPreviewUptime: TimeInterval = 0

    init() {
        #if targetEnvironment(simulator)
        usesSyntheticSource = true
        #else
        usesSyntheticSource = AVCaptureDevice.default(for: .video) == nil
        #endif
    }

    func open() async {
        guard source == nil else { return }
        let source: any LiveVideoFrameSource
        if usesSyntheticSource {
            source = LiveVideoSyntheticSource(width: 480, height: 640, fps: 24, audioEnabled: microphoneOn)
        } else {
            let camera = LiveVideoCameraSource(position: .back, audioEnabled: microphoneOn)
            cameraSource = camera
            source = camera
        }
        let sink = self.sink
        let previews = usesSyntheticSource
        source.onPixelBuffer = { [weak self] pixelBuffer, _ in
            sink.video(pixelBuffer)
            if previews {
                Task { @MainActor [weak self] in self?.updateSyntheticPreview(pixelBuffer) }
            }
        }
        source.onAudioFrames = { frames, _ in
            sink.audio(frames)
        }
        self.source = source
        do {
            try await source.start()
        } catch {
            SecureLogger.error("Video: capture source failed to start: \(error)", category: .session)
            errorMessage = String(localized: "video.studio.error.camera", defaultValue: "The camera is unavailable. Check camera and microphone access in Settings.", comment: "Error on the video screen when the camera cannot start")
        }
        objectWillChange.send()
    }

    func close() {
        if phase == .recording {
            Task { await stop(canceled: true) }
        }
        source?.stop()
        source = nil
        cameraSource = nil
    }

    func flipCamera() async {
        guard let cameraSource else { return }
        do {
            try await cameraSource.switchCamera()
            usesFrontCamera = cameraSource.position == .front
        } catch {
            SecureLogger.warning("Video: camera switch failed: \(error)", category: .session)
        }
    }

    func setMicrophone(_ on: Bool) {
        microphoneOn = on
        source?.isMuted = !on
    }

    func start(target: LiveVideoTarget?, directory: URL) async {
        guard phase == .idle else { return }
        errorMessage = nil
        let isLive = mode == .live
        let quality = isLive ? self.quality : .clip
        let session = LiveVideoSendSession(
            outputDirectory: directory,
            fileName: isLive ? nil : "clip_\(Self.clipStamp()).mp4",
            target: isLive ? target : nil,
            quality: quality,
            audioEnabled: microphoneOn
        )
        do {
            try await session.start()
        } catch {
            SecureLogger.error("Video: encoder failed to start: \(error)", category: .session)
            errorMessage = String(localized: "video.studio.error.encoder", defaultValue: "Video recording could not start.", comment: "Error on the video screen when the encoder cannot start")
            return
        }
        self.session = session
        phase = .recording
        elapsed = 0
        clockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, let session = self.session else { return }
                self.elapsed = session.elapsedSeconds()
                self.stats = session.currentStats()
                if self.mode == .clip, self.elapsed * 1_000 >= Double(LiveVideoLimits.maxClipDurationMs) {
                    await self.finishRecording()
                    return
                }
            }
        }
    }

    /// Stops recording and returns the recording to send, if any.
    @discardableResult
    func stop(canceled: Bool) async -> URL? {
        guard phase == .recording, let session else { return nil }
        phase = .finishing
        clockTask?.cancel()
        clockTask = nil
        self.session = nil
        let url = await session.stop(canceled: canceled)
        phase = .idle
        return url
    }

    var onFinished: ((URL) -> Void)?

    func finishRecording() async {
        let isClip = mode == .clip
        guard let url = await stop(canceled: false) else { return }
        if isClip {
            await deliverClip(url)
        } else {
            onFinished?(url)
        }
    }

    /// Clips and gallery videos are re-encoded to fit one mesh transfer.
    func importVideo(from sourceURL: URL, directory: URL) async {
        phase = .importing
        defer { phase = .idle }
        let output = directory.appendingPathComponent("clip_\(Self.clipStamp()).mp4")
        do {
            let url = try await VideoTranscoder.transcode(source: sourceURL, output: output, maxBytes: LiveVideoLimits.maxVideoFileBytes)
            onFinished?(url)
        } catch {
            SecureLogger.warning("Video: import failed: \(error)", category: .session)
            errorMessage = String(localized: "video.studio.error.import", defaultValue: "This video could not be made small enough to send over the mesh.", comment: "Error on the video screen when a gallery video cannot be transcoded to fit")
        }
    }

    private func deliverClip(_ url: URL) async {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? Int.max
        guard size > LiveVideoLimits.maxVideoFileBytes else {
            onFinished?(url)
            return
        }
        await importVideo(from: url, directory: url.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: url)
    }

    private func updateSyntheticPreview(_ pixelBuffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPreviewUptime >= 1.0 / 12 else { return }
        lastPreviewUptime = now
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        syntheticPreview = ciContext.createCGImage(image, from: image.extent)
    }

    private static func clipStamp() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}

/// Full-screen camera with LIVE and CLIP modes. The viewfinder is cropped to
/// the stream's 3:4 frame, so the sender sees exactly what viewers get.
struct VideoStudioView: View {
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = VideoStudioModel()
    @State private var galleryItem: PhotosPickerItem?
    @State private var liveTarget: LiveVideoTarget?
    @State private var targetChecked = false

    private var isBusy: Bool { model.phase != .idle }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                topBar
                viewfinder
                    .padding(.horizontal, 12)
                if let error = model.errorMessage {
                    Text(error)
                        .bitchatFont(size: 12)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Spacer(minLength: 0)
                bottomControls
            }
            .padding(.bottom, 12)
        }
        .foregroundColor(.white)
        // Always dark, like the system camera, so controls read on black.
        .environment(\.colorScheme, .dark)
        .task {
            liveTarget = conversationUIModel.makeLiveVideoTarget()
            targetChecked = true
            if liveTarget == nil { model.mode = .clip }
            model.onFinished = { url in
                conversationUIModel.finishOutgoingVideo(at: url)
                dismiss()
            }
            await model.open()
        }
        .onDisappear { model.close() }
        .onChange(of: galleryItem) { item in
            guard let item else { return }
            galleryItem = nil
            Task { await importGalleryItem(item) }
        }
    }

    // MARK: Layout

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await model.stop(canceled: true)
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.bitchatSystem(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
            .accessibilityLabel(String(localized: "common.close", defaultValue: "Close", comment: "Close button"))

            VStack(alignment: .leading, spacing: 1) {
                Text(model.mode == .live ? "video.studio.title.live" : "video.studio.title.clip", comment: "Title of the video screen: going live, or recording a clip")
                    .bitchatFont(size: 14, weight: .semibold)
                Text(conversationUIModel.liveVideoAudienceName)
                    .bitchatFont(size: 11)
                    .foregroundColor(.white.opacity(0.7))
            }
            Spacer()
            Button { model.setMicrophone(!model.microphoneOn) } label: {
                Image(systemName: model.microphoneOn ? "mic.fill" : "mic.slash.fill")
                    .font(.bitchatSystem(size: 15))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
            .accessibilityLabel(
                model.microphoneOn
                    ? String(localized: "video.studio.accessibility.mic_off", defaultValue: "Turn microphone off", comment: "Accessibility label for turning the video microphone off")
                    : String(localized: "video.studio.accessibility.mic_on", defaultValue: "Turn microphone on", comment: "Accessibility label for turning the video microphone on")
            )
            if !model.usesSyntheticSource {
                Button { Task { await model.flipCamera() } } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.bitchatSystem(size: 15))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .disabled(isBusy)
                .accessibilityLabel(String(localized: "video.studio.accessibility.flip", defaultValue: "Switch camera", comment: "Accessibility label for switching between front and back camera"))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var viewfinder: some View {
        ZStack {
            Color(white: 0.08)
            if model.usesSyntheticSource {
                if let preview = model.syntheticPreview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            } else if let camera = model.cameraSource {
                CameraPreviewLayerView(session: camera.session)
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topLeading) {
            if model.phase == .recording {
                recordingBadge.padding(10)
            }
        }
        .overlay(alignment: .bottom) {
            if model.phase == .recording, model.mode == .live {
                Text(String(
                    format: String(localized: "video.studio.stats", defaultValue: "%1$d pkts · %2$d kbps", comment: "Live stream stats on the video screen: packets sent and current video bitrate"),
                    model.stats.packetsSent,
                    model.stats.videoBitrate / 1_000
                ))
                .bitchatFont(size: 10)
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.5)))
                .padding(8)
            }
        }
        .overlay {
            if model.phase == .finishing || model.phase == .importing {
                ZStack {
                    Color.black.opacity(0.5)
                    ProgressView().tint(.white)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var recordingBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.red).frame(width: 7, height: 7)
                .modifier(PulsingOpacityModifier(active: true))
            Text(model.mode == .live ? "media.video.live_badge" : "video.studio.recording", comment: "Badge on the viewfinder while streaming live or recording a clip")
                .bitchatFont(size: 11, weight: .bold)
            Text(timeLabel(model.elapsed))
                .bitchatFont(size: 11)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    private var bottomControls: some View {
        VStack(spacing: 16) {
            if model.mode == .live {
                Picker(String(localized: "video.studio.quality", defaultValue: "Quality", comment: "Label for the live video quality picker"), selection: $model.quality) {
                    Text("video.studio.quality.low", comment: "Live video quality preset for multi-hop Bluetooth").tag(LiveVideoQuality.low)
                    Text("video.studio.quality.medium", comment: "Live video quality preset for one or two Bluetooth hops").tag(LiveVideoQuality.medium)
                    Text("video.studio.quality.high", comment: "Live video quality preset for fast links").tag(LiveVideoQuality.high)
                }
                .pickerStyle(.segmented)
                .disabled(isBusy)
                .padding(.horizontal, 40)
            } else if model.phase == .idle {
                Text(String(
                    format: String(localized: "video.studio.clip_hint", defaultValue: "Clips are up to %d seconds and sent as one file.", comment: "Hint on the video screen in clip mode"),
                    Int(LiveVideoLimits.maxClipDurationMs / 1_000)
                ))
                .bitchatFont(size: 11)
                .foregroundColor(.white.opacity(0.7))
            }

            HStack {
                PhotosPicker(selection: $galleryItem, matching: .videos) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.bitchatSystem(size: 20))
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .disabled(isBusy)
                .accessibilityLabel(String(localized: "video.studio.accessibility.gallery", defaultValue: "Send a video from the library", comment: "Accessibility label for importing a video from the photo library"))
                Spacer()
                recordButton
                Spacer()
                Color.clear.frame(width: 48, height: 48)
            }
            .padding(.horizontal, 32)

            Picker(String(localized: "video.studio.mode", defaultValue: "Mode", comment: "Label for the live/clip mode picker"), selection: $model.mode) {
                Text("video.studio.mode.live", comment: "Video screen mode: stream live").tag(VideoStudioModel.Mode.live)
                Text("video.studio.mode.clip", comment: "Video screen mode: record a clip").tag(VideoStudioModel.Mode.clip)
            }
            .pickerStyle(.segmented)
            .disabled(isBusy || (targetChecked && liveTarget == nil))
            .padding(.horizontal, 80)

            if targetChecked, liveTarget == nil {
                Text("video.studio.live_unavailable", comment: "Shown on the video screen when nobody can watch a live stream in this conversation")
                    .bitchatFont(size: 10)
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }

    private var recordButton: some View {
        Button {
            Task { await toggleRecording() }
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 72, height: 72)
                if model.phase == .recording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 28, height: 28)
                } else {
                    Circle()
                        .fill(model.mode == .live ? Color.red : Color.white)
                        .frame(width: 58, height: 58)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(model.phase == .finishing || model.phase == .importing)
        .accessibilityLabel(
            model.phase == .recording
                ? String(localized: "video.studio.accessibility.stop", defaultValue: "Stop and send", comment: "Accessibility label for the record button while recording")
                : (model.mode == .live
                    ? String(localized: "video.studio.accessibility.go_live", defaultValue: "Go live", comment: "Accessibility label for starting a live video stream")
                    : String(localized: "video.studio.accessibility.record_clip", defaultValue: "Record clip", comment: "Accessibility label for starting a clip recording"))
        )
    }

    // MARK: Actions

    private func toggleRecording() async {
        if model.phase == .recording {
            await model.finishRecording()
            return
        }
        guard let directory = try? conversationUIModel.outgoingVideoDirectory() else { return }
        // Re-check the audience: a DM peer may have dropped since opening.
        if model.mode == .live {
            liveTarget = conversationUIModel.makeLiveVideoTarget()
            guard liveTarget != nil else {
                model.mode = .clip
                return
            }
        }
        await model.start(target: liveTarget, directory: directory)
    }

    private func importGalleryItem(_ item: PhotosPickerItem) async {
        guard let directory = try? conversationUIModel.outgoingVideoDirectory(),
              let movie = try? await item.loadTransferable(type: PickedMovie.self)
        else { return }
        await model.importVideo(from: movie.url, directory: directory)
        try? FileManager.default.removeItem(at: movie.url)
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A picked library video, copied out of the picker's temporary location.
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("import_\(UUID().uuidString)")
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// The camera's live preview, filling (and cropped to) its frame.
private struct CameraPreviewLayerView: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
    }
}
#endif
