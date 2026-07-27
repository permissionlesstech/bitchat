//
// LiveVoiceBadge.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Slow opacity pulse for live-voice indicators (composer HUD, bubble badge).
struct PulsingOpacityModifier: ViewModifier {
    let active: Bool
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dimmed ? 0.35 : 1)
            .animation(active ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: dimmed)
            .onAppear {
                if active { dimmed = true }
            }
            .onChange(of: active) { nowActive in
                dimmed = nowActive
            }
    }
}

/// The red pulsing "LIVE" chip shown on a voice bubble while its burst is
/// still streaming in.
struct LiveVoiceBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
            Text("media.voice.live_badge", comment: "Badge on a voice message that is currently streaming in live")
                .bitchatFont(size: 10, weight: .bold)
                .foregroundColor(.red)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.red.opacity(0.15))
        )
        .modifier(PulsingOpacityModifier(active: true))
        .accessibilityLabel(
            String(localized: "media.voice.accessibility.live", comment: "Accessibility label announcing a live incoming voice message")
        )
    }
}
