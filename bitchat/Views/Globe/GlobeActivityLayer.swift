//
// GlobeActivityLayer.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Marker colors, derived from the app theme by the caller.
struct GlobeActivityColors: Equatable {
    /// Heartbeats only: people have the app open here but nobody wrote this hour.
    let quiet: GlobeRGB
    /// Some chat this hour.
    let active: GlobeRGB
    /// Busy chat; markers blend toward this as messages climb.
    let hot: GlobeRGB
    /// Count on a translucent heartbeat-only marker.
    let quietText: Color
    let selection: Color

    /// Marker fill: quiet for heartbeats, then green through yellow to hot as chat
    /// picks up.
    func fill(messages: Int) -> GlobeRGB {
        messages <= 0 ? quiet : active.hueBlend(to: hot, t: GlobeMarker.heat(messages: messages))
    }
}

/// An sRGB color whose components the marker layer can blend and measure.
struct GlobeRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// Relative luminance, for picking a legible count color.
    var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

    /// Interpolates around the hue wheel, so green to orange passes yellow instead
    /// of mud.
    func hueBlend(to other: GlobeRGB, t: Double) -> GlobeRGB {
        let t = min(max(t, 0), 1)
        let a = hsv
        let b = other.hsv
        var dh = b.h - a.h
        if dh > 180 { dh -= 360 }
        if dh < -180 { dh += 360 }
        return GlobeRGB(
            hue: (a.h + dh * t + 360).truncatingRemainder(dividingBy: 360),
            saturation: a.s + (b.s - a.s) * t,
            value: a.v + (b.v - a.v) * t
        )
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hue: Double, saturation: Double, value: Double) {
        let c = value * saturation
        let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = value - c
        let (r, g, b): (Double, Double, Double)
        switch hue {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        self.init(red: r + m, green: g + m, blue: b + m)
    }

    private var hsv: (h: Double, s: Double, v: Double) {
        let maxC = max(red, green, blue)
        let minC = min(red, green, blue)
        let delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == red {
                h = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == green {
                h = 60 * ((blue - red) / delta + 2)
            } else {
                h = 60 * ((red - green) / delta + 4)
            }
        }
        if h < 0 { h += 360 }
        return (h, maxC == 0 ? 0 : delta / maxC, maxC)
    }
}

/// One marker on screen: a single channel, or overlapping channels merged into a
/// cluster.
struct GlobeMarker {
    let x: Double
    let y: Double
    let radius: Double
    /// Busiest first.
    let channels: [GeohashChannelActivity]
    /// Estimated distinct people; see `GeohashActivitySnapshot.estimateDistinctPeople`.
    let people: Int
    let messages: Int
    /// Newest activity across `channels`.
    let lastActiveAt: Date
    /// How far the marker faces the viewer: 1 at the view center, 0 at the limb.
    let depth: Double

    var isCluster: Bool { channels.count > 1 }
    /// Nobody wrote this hour: only heartbeats. Drawn small and quiet.
    var isAmbient: Bool { messages == 0 }
    var primary: GeohashChannelActivity { channels[0] }

    /// People-weighted center of the merged channels, for zooming into a cluster.
    var centroid: (lat: Double, lon: Double) {
        var vx = 0.0, vy = 0.0, vz = 0.0
        for channel in channels {
            let lat = channel.latitude * .pi / 180
            let lon = channel.longitude * .pi / 180
            let w = Double(max(channel.people, 1))
            vx += w * cos(lat) * cos(lon)
            vy += w * cos(lat) * sin(lon)
            vz += w * sin(lat)
        }
        return (atan2(vz, (vx * vx + vy * vy).squareRoot()) * 180 / .pi, atan2(vy, vx) * 180 / .pi)
    }

    // MARK: Sizing

    static let recentActivity: TimeInterval = 180
    static let maxRadius = 17.0
    static let labelMinRadius = 8.5

    /// Radius in points. Area tracks headcount (square root), and chat markers
    /// outrank heartbeat-only ones so conversations stand out from people who
    /// merely have the app open.
    static func radius(people: Int, chatting: Bool, cluster: Bool) -> Double {
        let root = Double(max(people, 1)).squareRoot()
        if chatting {
            let base = 5 + 2.4 * root
            return min(cluster ? max(base, 9) : base, maxRadius)
        }
        return min(2.5 + 1.3 * root, 9.5)
    }

    /// 0 when nobody wrote, rising toward 1 around a message a minute.
    static func heat(messages: Int) -> Double {
        guard messages > 0 else { return 0 }
        return min(max(log(1 + Double(messages)) / log(61), 0), 1)
    }

    /// "7", "842", "1.2k", "12k".
    static func compactCount(_ count: Int) -> String {
        if count < 1_000 { return String(count) }
        if count < 10_000 {
            let text = String(format: "%.1fk", locale: Locale(identifier: "en_US_POSIX"), Double(count) / 1_000)
            return text.replacingOccurrences(of: ".0k", with: "k")
        }
        return "\(count / 1_000)k"
    }
}

/// Projects channels onto the visible hemisphere and greedily merges markers that
/// would overlap, busiest first, so a crowded region reads as one labelled cluster
/// until the user zooms in.
enum GlobeMarkerLayoutEngine {
    static func layout(
        _ channels: [GeohashChannelActivity],
        centerLat: Double,
        centerLon: Double,
        radius r: Double,
        size: CGSize
    ) -> [GlobeMarker] {
        guard r > 0 else { return [] }
        struct Group {
            let x: Double
            let y: Double
            let depth: Double
            var members: [GeohashChannelActivity]
            var messages: Int
            var radius: Double
        }

        let projector = GlobeMath.PreparedProjector(centerLat: centerLat, centerLon: centerLon)
        let cx = Double(size.width) / 2
        let cy = Double(size.height) / 2
        let margin = GlobeMarker.maxRadius
        var groups: [Group] = []
        for channel in channels {
            let p = projector.project(GlobeMath.Terms(lat: channel.latitude, lon: channel.longitude))
            // Markers fade out toward the limb (see `limbFade`), so they stay laid out until it.
            guard p.cosC >= 0 else { continue }
            let x = cx + p.x * r
            let y = cy + p.y * r
            guard x > -margin, x < Double(size.width) + margin, y > -margin, y < Double(size.height) + margin else { continue }

            let radius = GlobeMarker.radius(people: channel.people, chatting: channel.messages > 0, cluster: false)
            let host = groups.firstIndex { group in
                let dx = group.x - x
                let dy = group.y - y
                let reach = (group.radius + radius) * 0.85 + 1.5
                return dx * dx + dy * dy < reach * reach
            }
            if let host {
                groups[host].members.append(channel)
                groups[host].messages += channel.messages
                groups[host].radius = GlobeMarker.radius(
                    people: GeohashActivitySnapshot.estimateDistinctPeople(groups[host].members),
                    chatting: groups[host].messages > 0,
                    cluster: true
                )
            } else {
                groups.append(Group(x: x, y: y, depth: p.cosC, members: [channel], messages: channel.messages, radius: radius))
            }
        }
        return groups.map { group in
            GlobeMarker(
                x: group.x,
                y: group.y,
                radius: group.radius,
                channels: group.members,
                people: GeohashActivitySnapshot.estimateDistinctPeople(group.members),
                messages: group.messages,
                lastActiveAt: group.members.map(\.lastActiveAt).max() ?? .distantPast,
                depth: group.depth
            )
        }
    }
}

/// One marker as drawn this frame: the laid-out marker at its animated size and
/// opacity.
struct GlobeMarkerFrame {
    let marker: GlobeMarker
    let x: Double
    let y: Double
    let radius: Double
    let alpha: Double
}

/// Fades activity markers in and out between frames so they never pop.
///
/// Markers are tracked by their busiest channel and always stay where the globe puts
/// them: a new marker fades in while growing slightly to full size, a vanished one
/// fades out while shrinking slightly. Size changes (a cluster gaining members) ease
/// rather than jump, and markers fade as they turn over the globe's limb. `instant`
/// (Reduce Motion) makes every change immediate.
final class GlobeMarkerAnimator {
    private struct Track {
        let born: CFTimeInterval
        var radius: Double
    }

    private struct Ghost {
        let frame: GlobeMarkerFrame
        let died: CFTimeInterval
    }

    static let enterDuration: CFTimeInterval = 0.2
    static let exitDuration: CFTimeInterval = 0.15
    private static let enterFromScale = 0.6
    private static let exitToScale = 0.7
    private static let resizeTimeConstant: CFTimeInterval = 0.07
    private static let maxStep: CFTimeInterval = 0.1
    private static let settledPoints = 0.3
    private static let limbMinScale = 0.55

    private var tracks: [String: Track] = [:]
    private var lastFrames: [String: GlobeMarkerFrame] = [:]
    private var ghosts: [Ghost] = []
    private var lastFrame: CFTimeInterval?

    /// True while any marker is still appearing, leaving or resizing.
    private(set) var isAnimating = false

    func frame(_ markers: [GlobeMarker], now: CFTimeInterval, instant: Bool) -> [GlobeMarkerFrame] {
        let dt = lastFrame.map { min(max(now - $0, 0), Self.maxStep) } ?? 0
        lastFrame = now

        var current: [String: GlobeMarker] = [:]
        for marker in markers { current[marker.primary.geohash] = marker }

        // Leaving: fade out exactly where the marker was last drawn.
        for key in tracks.keys where current[key] == nil {
            tracks.removeValue(forKey: key)
            guard let last = lastFrames.removeValue(forKey: key), !instant else { continue }
            ghosts.append(Ghost(frame: last, died: now))
        }

        var animating = false
        var out: [GlobeMarkerFrame] = []
        out.reserveCapacity(markers.count + ghosts.count)

        for marker in markers {
            let key = marker.primary.geohash
            var track = tracks[key] ?? Track(born: instant ? -.infinity : now, radius: marker.radius)
            let p = instant ? 1 : Self.progress(now - track.born, Self.enterDuration)
            if p < 1 {
                animating = true
                track.radius = marker.radius
            } else if instant {
                track.radius = marker.radius
            } else {
                // Ease size changes instead of jumping.
                track.radius += (marker.radius - track.radius) * (1 - exp(-dt / Self.resizeTimeConstant))
                if abs(track.radius - marker.radius) > Self.settledPoints { animating = true }
            }
            tracks[key] = track
            let t = Self.easeOutCubic(p)
            let fade = Self.limbFade(marker.depth)
            let frame = GlobeMarkerFrame(
                marker: marker,
                x: marker.x,
                y: marker.y,
                radius: track.radius * (Self.enterFromScale + (1 - Self.enterFromScale) * t)
                    * (Self.limbMinScale + (1 - Self.limbMinScale) * fade),
                alpha: t * fade
            )
            lastFrames[key] = frame
            out.append(frame)
        }

        ghosts.removeAll { now - $0.died >= Self.exitDuration }
        for ghost in ghosts {
            animating = true
            let t = Self.easeOutCubic(Self.progress(now - ghost.died, Self.exitDuration))
            let last = ghost.frame
            out.append(GlobeMarkerFrame(
                marker: last.marker,
                x: last.x,
                y: last.y,
                radius: last.radius * (1 - (1 - Self.exitToScale) * t),
                alpha: last.alpha * (1 - t)
            ))
        }

        isAnimating = animating
        return out
    }

    /// 0 at the limb, 1 once a marker has turned a little toward the viewer.
    static func limbFade(_ depth: Double) -> Double {
        let t = min(max(depth / 0.22, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func easeOutCubic(_ t: Double) -> Double {
        let u = 1 - t
        return 1 - u * u * u
    }

    private static func progress(_ elapsed: CFTimeInterval, _ duration: CFTimeInterval) -> Double {
        duration <= 0 ? 1 : min(max(elapsed / duration, 0), 1)
    }
}

/// Lays out, animates and hit-tests the activity markers. One per globe; the touch
/// layer reads the markers the most recent frame laid out. Used on the main thread
/// only (the overlay canvas draws synchronously).
final class GlobeMarkerLayer {
    private let animator = GlobeMarkerAnimator()
    private(set) var markers: [GlobeMarker] = []
    private var layoutKey: LayoutKey?

    private struct LayoutKey: Equatable {
        let centerLat: Double
        let centerLon: Double
        let radius: Double
        let size: CGSize
        let channels: [GeohashChannelActivity]
    }

    var isAnimating: Bool { animator.isAnimating }

    /// The marker under `point`, preferring the one whose edge is closest.
    func hitTest(_ point: CGPoint, slop: Double = 10) -> GlobeMarker? {
        var best: GlobeMarker?
        var bestDistance = Double.greatestFiniteMagnitude
        for marker in markers {
            let edge = hypot(marker.x - Double(point.x), marker.y - Double(point.y)) - marker.radius
            if edge <= slop && edge < bestDistance {
                best = marker
                bestDistance = edge
            }
        }
        return best
    }

    func frame(
        channels: [GeohashChannelActivity],
        centerLat: Double,
        centerLon: Double,
        radius: Double,
        size: CGSize,
        now: CFTimeInterval,
        instant: Bool
    ) -> [GlobeMarkerFrame] {
        let key = LayoutKey(centerLat: centerLat, centerLon: centerLon, radius: radius, size: size, channels: channels)
        if key != layoutKey {
            layoutKey = key
            markers = GlobeMarkerLayoutEngine.layout(channels, centerLat: centerLat, centerLon: centerLon, radius: radius, size: size)
        }
        return animator.frame(markers, now: now, instant: instant)
    }
}

/// Draws the activity markers above the globe. Isolated from the globe canvas so
/// the pulse and marker animations never redraw globe geometry.
struct GlobeActivityOverlay: View {
    @ObservedObject var state: GlobeState
    let channels: [GeohashChannelActivity]
    let colors: GlobeActivityColors
    let layer: GlobeMarkerLayer

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appTheme) private var theme

    private static let pulsePeriod: TimeInterval = 1.6

    var body: some View {
        // Ticks drive the pulse and the pop/merge animations; the globe itself
        // re-renders this view on every move.
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: channels.isEmpty && !layer.isAnimating)) { timeline in
            Canvas(rendersAsynchronously: false) { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let frames = layer.frame(
                    channels: channels,
                    centerLat: state.centerLat,
                    centerLon: state.centerLon,
                    radius: state.globeRadius,
                    size: size,
                    now: now,
                    instant: reduceMotion
                )
                let pulse = reduceMotion ? nil : now.truncatingRemainder(dividingBy: Self.pulsePeriod) / Self.pulsePeriod
                draw(frames, in: &context, pulse: pulse, now: timeline.date)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ frames: [GlobeMarkerFrame], in context: inout GraphicsContext, pulse: Double?, now: Date) {
        // Heartbeat-only markers first so conversations always sit on top.
        let ordered = frames.sorted { ($0.marker.messages, $0.marker.people) < ($1.marker.messages, $1.marker.people) }
        for frame in ordered {
            let marker = frame.marker
            let radius = frame.radius
            let a = min(max(frame.alpha, 0), 1)
            guard radius >= 0.5, a > 0.01 else { continue }
            let center = CGPoint(x: frame.x, y: frame.y)
            let rgb = colors.fill(messages: marker.messages)
            let color = rgb.color
            let selected = marker.channels.contains { $0.geohash == state.selectedGeohash }

            func circle(_ r: Double) -> Path {
                Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            }

            if marker.isAmbient {
                let glow = radius * 1.8
                context.fill(circle(glow), with: .radialGradient(
                    Gradient(colors: [color.opacity(0.22 * a), color.opacity(0)]),
                    center: center, startRadius: 0, endRadius: glow
                ))
                context.fill(circle(radius), with: .color(color.opacity(0.30 * a)))
                context.stroke(circle(radius), with: .color(color.opacity(0.85 * a)), lineWidth: 1.2)
            } else {
                let glow = radius * 2.3
                context.fill(circle(glow), with: .radialGradient(
                    Gradient(stops: [
                        .init(color: color.opacity(0.45 * a), location: 0),
                        .init(color: color.opacity(0.16 * a), location: 0.45),
                        .init(color: color.opacity(0), location: 1)
                    ]),
                    center: center, startRadius: 0, endRadius: glow
                ))
                if let pulse, now.timeIntervalSince(marker.lastActiveAt) < GlobeMarker.recentActivity {
                    context.stroke(
                        circle(radius * (1 + 1.1 * pulse)),
                        with: .color(color.opacity(0.6 * (1 - pulse) * a)),
                        lineWidth: 1.6
                    )
                }
                if marker.isCluster {
                    context.fill(circle(radius + 3), with: .color(color.opacity(0.28 * a)))
                }
                context.fill(circle(radius), with: .color(color.opacity(a)))
                context.stroke(circle(radius - 0.5), with: .color(.white.opacity(0.5 * a)), lineWidth: 1)
            }

            if selected {
                context.stroke(circle(radius + 4.5), with: .color(colors.selection.opacity(a)), lineWidth: 2)
            }

            // Whether a count fits is decided at full size; the text then scales with the animation.
            guard marker.radius >= GlobeMarker.labelMinRadius else { continue }
            let label = GlobeMarker.compactCount(marker.people)
            let scale = radius / marker.radius
            let fontSize = min(max(marker.radius * 0.95, 9), 12.5) * (label.count >= 3 ? 0.84 : 1) * scale
            guard fontSize >= 2 else { continue }
            let textColor: Color = marker.isAmbient
                ? colors.quietText
                : (rgb.luminance > 0.62 ? Color.black.opacity(0.82) : .white)
            context.draw(
                Text(verbatim: label)
                    .font(.system(size: fontSize, weight: .semibold, design: theme.bodyFontDesign == .monospaced ? .monospaced : .rounded))
                    .foregroundColor(textColor.opacity(a)),
                at: center
            )
        }
    }
}
