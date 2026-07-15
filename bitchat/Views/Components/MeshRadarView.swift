//
// MeshRadarView.swift
// bitchat
//
// Ambient sonar shown on the empty mesh timeline: expanding rings around a
// center dot make it visible that the radio is broadcasting and scanning
// even when nobody is in range. Purely decorative — hidden from
// accessibility, static under Reduce Motion.
// This is free and unencumbered software released into the public domain.
//

import SwiftUI

struct MeshRadarView: View {
    /// Full size on the empty timeline; the ambient footer under archived
    /// echoes uses a smaller one.
    var height: CGFloat = 72

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ThemedPalette private var palette

    private let ringCount = 3
    private let period: TimeInterval = 3.0

    var body: some View {
        Group {
            if reduceMotion {
                radar(at: 0.35)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                    radar(at: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func radar(at time: TimeInterval) -> some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxRadius = min(size.width, size.height) / 2 - 2

            for ring in 0..<ringCount {
                let phase = (time / period + Double(ring) / Double(ringCount))
                    .truncatingRemainder(dividingBy: 1)
                let radius = maxRadius * phase
                guard radius > 1 else { continue }
                let alpha = 0.45 * (1 - phase)
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(palette.primary.opacity(alpha)),
                    lineWidth: 1
                )
            }

            let dot = CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)
            context.fill(Path(ellipseIn: dot), with: .color(palette.primary.opacity(0.9)))
        }
    }
}
