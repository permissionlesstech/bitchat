//
// VideoMessageView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import AVKit
import BitFoundation
import SwiftUI

/// A video bubble: the live picture while its stream is still coming in,
/// otherwise the finished file's poster frame.
struct VideoMessageView: View {
    let message: BitchatMessage
    let url: URL
    let isSending: Bool
    let sendProgress: Double?
    let onCancel: (() -> Void)?

    @EnvironmentObject private var conversationUIModel: ConversationUIModel

    var body: some View {
        if let model = conversationUIModel.liveVideoStream(for: message), !model.hasEnded {
            LiveVideoBubbleView(model: model)
        } else {
            VideoFileBubbleView(url: url, isSending: isSending, sendProgress: sendProgress, onCancel: onCancel)
        }
    }
}

// MARK: - Shared pieces

private enum VideoBubbleMetrics {
    static let maxWidth: CGFloat = 220
    static let cornerRadius: CGFloat = 14

    static func size(width: Int, height: Int) -> CGSize {
        let aspect = width > 0 && height > 0 ? CGFloat(width) / CGFloat(height) : 3.0 / 4.0
        if aspect >= 1 {
            return CGSize(width: maxWidth, height: maxWidth / aspect)
        }
        let height = min(maxWidth / aspect, 300)
        return CGSize(width: height * aspect, height: height)
    }
}

private func durationLabel(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// The red "LIVE" chip with the stream's running time.
private struct LiveVideoTimerChip: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .modifier(PulsingOpacityModifier(active: true))
                Text("media.video.live_badge", comment: "Badge on a video that is currently streaming in live")
                    .bitchatFont(size: 10, weight: .bold)
                Text(durationLabel(timeline.date.timeIntervalSince(startedAt)))
                    .bitchatFont(size: 10)
                    .monospacedDigit()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.red.opacity(0.85)))
        }
        .accessibilityElement(children: .combine)
    }
}

/// Three-bar meter of recent packet loss before FEC.
private struct LiveVideoSignalMeter: View {
    let bars: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < bars ? Color.white : Color.white.opacity(0.3))
                    .frame(width: 3, height: CGFloat(5 + index * 3))
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .accessibilityLabel(
            String(localized: "media.video.accessibility.signal", defaultValue: "Signal \(bars) of 3", comment: "Accessibility label for the live video signal meter")
        )
    }
}

/// The decoded picture, or a placeholder until the first keyframe.
private struct LiveVideoPicture: View {
    @ObservedObject var model: LiveVideoStreamModel
    var fill = true

    var body: some View {
        ZStack {
            Color.black
            if let frame = model.frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                VStack(spacing: 6) {
                    ProgressView()
                        .tint(.white)
                    Text("media.video.waiting_for_picture", comment: "Shown on a live video until its first keyframe arrives")
                        .bitchatFont(size: 11)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            if model.reconnecting {
                Color.black.opacity(0.45)
                Label {
                    Text("media.video.reconnecting", comment: "Shown on a live video whose packets stopped arriving; it resumes when they return")
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                }
                .bitchatFont(size: 12, weight: .semibold)
                .foregroundColor(.white)
            }
        }
    }
}

// MARK: - Live bubble

struct LiveVideoBubbleView: View {
    @ObservedObject var model: LiveVideoStreamModel
    @State private var showsViewer = false

    var body: some View {
        let size = VideoBubbleMetrics.size(width: model.width, height: model.height)
        LiveVideoPicture(model: model)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: VideoBubbleMetrics.cornerRadius))
            .overlay(alignment: .topLeading) {
                LiveVideoTimerChip(startedAt: model.startedAt)
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                LiveVideoSignalMeter(bars: model.signalBars)
                    .padding(6)
            }
            .overlay(alignment: .bottomTrailing) {
                if model.hasAudio {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.bitchatSystem(size: 11))
                        .foregroundColor(.white)
                        .padding(5)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { showsViewer = true }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(
                String(localized: "media.video.accessibility.live", defaultValue: "Live video from \(model.senderNickname)", comment: "Accessibility label for a live video bubble")
            )
            .accessibilityHint(
                String(localized: "media.video.accessibility.open_hint", defaultValue: "Opens the video full screen", comment: "Accessibility hint for opening a video full screen")
            )
            #if os(iOS)
            .fullScreenCover(isPresented: $showsViewer) {
                LiveVideoFullScreenView(model: model)
            }
            #else
            .sheet(isPresented: $showsViewer) {
                LiveVideoFullScreenView(model: model)
                    .frame(minWidth: 480, minHeight: 560)
            }
            #endif
    }
}

/// Distraction-free live viewer: controls fade after a few seconds, a tap
/// brings them back, a double tap switches between fit and fill, and once
/// the stream ends it offers the replay.
struct LiveVideoFullScreenView: View {
    @ObservedObject var model: LiveVideoStreamModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @Environment(\.dismiss) private var dismiss
    @State private var fill = false
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var replayURL: URL?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let replayURL {
                VideoPlayerScreen(url: replayURL)
            } else {
                LiveVideoPicture(model: model, fill: fill)
                    .ignoresSafeArea()
                    .onTapGesture(count: 2) { fill.toggle() }
                    .onTapGesture { showControls() }
                if model.hasEnded {
                    endedOverlay
                }
            }
        }
        .overlay(alignment: .top) {
            if controlsVisible || model.hasEnded || replayURL != nil {
                controls
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .onAppear { showControls() }
        .onDisappear { hideTask?.cancel() }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.bitchatSystem(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
            .accessibilityLabel(String(localized: "common.close", defaultValue: "Close", comment: "Close button"))
            if replayURL == nil, !model.hasEnded {
                LiveVideoTimerChip(startedAt: model.startedAt)
            }
            Text(model.senderNickname)
                .bitchatFont(size: 13, weight: .semibold)
                .lineLimit(1)
            Spacer()
            if replayURL == nil, !model.hasEnded {
                LiveVideoSignalMeter(bars: model.signalBars)
                if model.hasAudio {
                    Button {
                        conversationUIModel.setLiveVideoMuted(!model.isMuted, messageID: model.id)
                        showControls()
                    } label: {
                        Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.bitchatSystem(size: 15))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    .accessibilityLabel(
                        model.isMuted
                            ? String(localized: "media.video.accessibility.unmute", defaultValue: "Unmute", comment: "Accessibility label to unmute a live video")
                            : String(localized: "media.video.accessibility.mute", defaultValue: "Mute", comment: "Accessibility label to mute a live video")
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var endedOverlay: some View {
        VStack(spacing: 12) {
            Text("media.video.stream_ended", comment: "Shown in the live viewer once the stream has ended")
                .bitchatFont(size: 15, weight: .semibold)
                .foregroundColor(.white)
            if let url = model.endedFileURL {
                Button {
                    replayURL = url
                } label: {
                    Label {
                        Text("media.video.watch_replay", comment: "Button in the live viewer that plays the recording of a stream that just ended")
                    } icon: {
                        Image(systemName: "play.fill")
                    }
                    .bitchatFont(size: 14, weight: .semibold)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.white.opacity(0.2)))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.6)))
    }

    private func showControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }
}

// MARK: - Finished video

struct VideoFileBubbleView: View {
    let url: URL
    let isSending: Bool
    let sendProgress: Double?
    let onCancel: (() -> Void)?

    @State private var poster: CGImage?
    @State private var duration: Double = .nan
    @State private var showsPlayer = false

    var body: some View {
        let size = poster.map { VideoBubbleMetrics.size(width: $0.width, height: $0.height) }
            ?? VideoBubbleMetrics.size(width: 3, height: 4)
        ZStack {
            Color.black
            if let poster {
                Image(decorative: poster, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            Image(systemName: "play.fill")
                .font(.bitchatSystem(size: 20))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.black.opacity(0.5)))
            if isSending, let sendProgress {
                VStack {
                    Spacer()
                    ProgressView(value: sendProgress)
                        .tint(.white)
                        .padding(8)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: VideoBubbleMetrics.cornerRadius))
        .overlay(alignment: .bottomLeading) {
            Text(durationLabel(duration))
                .bitchatFont(size: 10)
                .monospacedDigit()
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.5)))
                .padding(6)
        }
        .overlay(alignment: .topTrailing) {
            if let onCancel, isSending {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.bitchatSystem(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.red.opacity(0.9)))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel(
                    String(localized: "media.accessibility.cancel_send", comment: "Accessibility label for the cancel button on an in-flight media send")
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showsPlayer = true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(
            String(localized: "media.video.accessibility.video", defaultValue: "Video, \(durationLabel(duration))", comment: "Accessibility label for a finished video bubble")
        )
        .task(id: url) {
            let loaded = await VideoPosterLoader.load(url: url)
            poster = loaded.poster
            duration = loaded.durationSeconds
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showsPlayer) {
            VideoPlayerFullScreenView(url: url)
        }
        #else
        .sheet(isPresented: $showsPlayer) {
            VideoPlayerFullScreenView(url: url)
                .frame(minWidth: 480, minHeight: 560)
        }
        #endif
    }
}

/// Full-screen player with the system's scrubbing controls.
struct VideoPlayerFullScreenView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VideoPlayerScreen(url: url)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.bitchatSystem(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .accessibilityLabel(String(localized: "common.close", defaultValue: "Close", comment: "Close button"))
        }
    }
}

private struct VideoPlayerScreen: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear {
                let player = AVPlayer(url: url)
                self.player = player
                player.play()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
    }
}
