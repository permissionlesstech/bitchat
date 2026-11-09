//
// GlobeView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Color palette for the globe, derived from the app theme by the caller.
struct GlobeColors: Equatable {
    let accent: Color
    let land: Color
    let coastline: Color
    let border: Color
    let oceanCenter: Color
    let oceanEdge: Color
    let atmosphere: Color
    let graticule: Color
    let grid: Color
    let label: Color
    let labelHalo: Color
    let star: Color
}

/// Interactive orthographic globe: drag to spin (with inertia), pinch to zoom, tap to
/// focus, double tap to zoom in. The selected geohash is always the cell under the
/// crosshair at the screen center.
struct GlobeView: View {
    @ObservedObject var state: GlobeState
    let colors: GlobeColors
    let world: GlobeWorldData

    @Environment(\.displayScale) private var displayScale
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if os(iOS)
    @State private var selectionFeedback = UISelectionFeedbackGenerator()
    #endif

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Static background lives in its own layer and is not redrawn by globe movement.
                GlobeStarfield(color: colors.star)
                    .equatable()

                let renderer = GlobeRenderer(
                    centerLat: state.centerLat,
                    centerLon: state.centerLon,
                    radius: state.globeRadius,
                    zoom: state.zoom,
                    selectedGeohash: state.selectedGeohash,
                    detail: state.frameDetail,
                    colors: colors,
                    world: world,
                    pixel: 1 / max(displayScale, 1),
                    fontDesign: theme.bodyFontDesign
                )
                Canvas(rendersAsynchronously: false) { context, size in
                    renderer.draw(in: &context, size: size)
                }

                GlobeTouchLayer(state: state)

                // Isolated so its pulse does not redraw the globe geometry.
                GlobeCrosshair(color: colors.accent, isInMotion: state.isInMotion)
                    .allowsHitTesting(false)
            }
            .onAppear { updateViewport(proxy.size) }
            .onChange(of: proxy.size) { updateViewport($0) }
        }
        .onChange(of: state.selectedGeohash) { [previous = state.selectedGeohash] _ in
            guard !previous.isEmpty else { return }
            #if os(iOS)
            selectionFeedback.selectionChanged()
            #endif
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: state.selectedGeohash.isEmpty ? "" : "#\(state.selectedGeohash)"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: state.animatePrecision(state.precision + 1)
            case .decrement: state.animatePrecision(state.precision - 1)
            @unknown default: break
            }
        }
    }

    private func updateViewport(_ size: CGSize) {
        let minDim = Double(min(size.width, size.height))
        state.setViewport(baseRadius: minDim * 0.44, screenMin: minDim, animateIntro: !reduceMotion)
    }
}

// MARK: - Background and crosshair

private struct GlobeStarfield: View, Equatable {
    let color: Color

    private struct Star {
        let x: Double
        let y: Double
        let radius: Double
        let alpha: Double
    }

    private static let stars: [Star] = {
        var rng = SeededGenerator(seed: 42)
        return (0..<160).map { _ in
            Star(
                x: rng.nextUnit(),
                y: rng.nextUnit(),
                radius: 0.6 + rng.nextUnit() * 1.5,
                alpha: 0.15 + rng.nextUnit() * 0.55
            )
        }
    }()

    var body: some View {
        Canvas { context, size in
            for star in Self.stars {
                let center = CGPoint(x: star.x * size.width, y: star.y * size.height)
                let rect = CGRect(x: center.x - star.radius, y: center.y - star.radius, width: star.radius * 2, height: star.radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(star.alpha)))
            }
        }
        .allowsHitTesting(false)
    }

    /// Deterministic SplitMix64 so the sky is the same every time the picker opens.
    private struct SeededGenerator {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func nextUnit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }
}

private struct GlobeCrosshair: View {
    let color: Color
    let isInMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: isInMotion)) { timeline in
            Canvas { context, size in
                let alpha = isInMotion ? 0.9 : Self.pulse(at: timeline.date)
                let shading = GraphicsContext.Shading.color(color.opacity(alpha))
                let cx = size.width / 2
                let cy = size.height / 2
                let gap: CGFloat = 5
                let len: CGFloat = 9
                var path = Path()
                path.move(to: CGPoint(x: cx - gap - len, y: cy))
                path.addLine(to: CGPoint(x: cx - gap, y: cy))
                path.move(to: CGPoint(x: cx + gap, y: cy))
                path.addLine(to: CGPoint(x: cx + gap + len, y: cy))
                path.move(to: CGPoint(x: cx, y: cy - gap - len))
                path.addLine(to: CGPoint(x: cx, y: cy - gap))
                path.move(to: CGPoint(x: cx, y: cy + gap))
                path.addLine(to: CGPoint(x: cx, y: cy + gap + len))
                context.stroke(path, with: shading, lineWidth: 1.6)
                context.fill(Path(ellipseIn: CGRect(x: cx - 1.8, y: cy - 1.8, width: 3.6, height: 3.6)), with: shading)
            }
        }
    }

    /// 0.45 → 1 → 0.45 over 2.2s, eased like the Android picker's reversing tween.
    private static func pulse(at date: Date) -> Double {
        let period = 1.1
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period * 2) / period
        let t = phase <= 1 ? phase : 2 - phase
        return 0.45 + 0.55 * GlobeEasing.fastOutSlowIn(t)
    }
}

// MARK: - Renderer

/// Draws one globe frame. Built fresh per frame from a snapshot of `GlobeState`.
private struct GlobeRenderer {
    let centerLat: Double
    let centerLon: Double
    let radius: Double
    let zoom: Double
    let selectedGeohash: String
    let detail: GlobeMotionDetail.Frame
    let colors: GlobeColors
    let world: GlobeWorldData
    /// One device pixel in points; hairline widths are specified in pixels.
    let pixel: Double
    let fontDesign: Font.Design

    private typealias DiscPoint = GlobeGeometry.DiscPoint

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard radius > 0, size.width > 0, size.height > 0 else { return }
        let cx = Double(size.width) / 2
        let cy = Double(size.height) / 2
        let r = radius
        let center = CGPoint(x: cx, y: cy)
        let projector = GlobeMath.PreparedProjector(centerLat: centerLat, centerLon: centerLon)
        let clip = GlobeGeometry.ClipRect(size: size)
        let screenRect = CGRect(origin: .zero, size: size)
        // Once the disc covers the screen, the sphere-wide gradients are constant across
        // it (and their huge coordinates would only cost precision), so draw flat fills.
        let coverRadius = (cx * cx + cy * cy).squareRoot() + 2
        let discCoversScreen = r > coverRadius
        let gradientsMatter = r < Double(min(size.width, size.height)) * 10

        func disc(_ discRadius: Double) -> Path {
            if discRadius > coverRadius { return Path(screenRect) }
            return Path(ellipseIn: CGRect(x: cx - discRadius, y: cy - discRadius, width: discRadius * 2, height: discRadius * 2))
        }

        // Atmosphere glow
        if !discCoversScreen {
            context.fill(disc(r * 1.22), with: .radialGradient(
                Gradient(stops: [
                    .init(color: colors.atmosphere.opacity(0.30), location: 0),
                    .init(color: colors.atmosphere.opacity(0.12), location: 0.75),
                    .init(color: colors.atmosphere.opacity(0), location: 1)
                ]),
                center: center,
                startRadius: 0,
                endRadius: r * 1.22
            ))
        }

        // Ocean sphere
        if gradientsMatter {
            context.fill(disc(r), with: .radialGradient(
                Gradient(stops: [
                    .init(color: colors.oceanCenter, location: 0),
                    .init(color: colors.oceanCenter, location: 0.7),
                    .init(color: colors.oceanEdge, location: 1)
                ]),
                center: CGPoint(x: cx - r * 0.32, y: cy - r * 0.38),
                startRadius: 0,
                endRadius: r * 1.5
            ))
        } else {
            context.fill(Path(screenRect), with: .color(colors.oceanCenter))
        }

        drawGraticule(in: &context, cx: cx, cy: cy, r: r, clip: clip)

        // Fill every landmass first. Coastlines are drawn in a separate final pass so a
        // large continent fill can never cover an island outline drawn earlier.
        var coastlines = Path()
        for ring in world.land {
            drawLand(ring, in: &context, projector: projector, cx: cx, cy: cy, r: r, clip: clip, coastlines: &coastlines)
        }
        context.stroke(coastlines, with: .color(colors.coastline), lineWidth: 1.4 * pixel)

        // Country borders are restored when interaction settles.
        if detail.showBorders {
            var borders = Path()
            for line in world.borders {
                let pts = line.terms.map { terms -> (DiscPoint, Bool) in
                    let p = projector.project(terms)
                    return (DiscPoint(x: p.x, y: p.y, front: p.cosC > 0.005), p.cosC >= 0)
                }
                guard pts.contains(where: { $0.1 }) else { continue }
                appendRuns(GlobeGeometry.frontRuns(pts.map(\.0), closed: false), to: &borders, cx: cx, cy: cy, r: r, clip: clip)
            }
            context.stroke(borders, with: .color(colors.border), lineWidth: 1.2 * pixel)
        }

        // Sphere shading: dark limb + night side for 3D depth
        if gradientsMatter {
            context.fill(disc(r + 1), with: .radialGradient(
                Gradient(stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0), location: 0.62),
                    .init(color: .black.opacity(0.34), location: 0.88),
                    .init(color: .black.opacity(0.72), location: 1)
                ]),
                center: CGPoint(x: cx - r * 0.25, y: cy - r * 0.3),
                startRadius: 0,
                endRadius: r * 1.35
            ))
            context.fill(disc(r + 1), with: .linearGradient(
                Gradient(stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0), location: 0.55),
                    .init(color: .black.opacity(0.42), location: 1)
                ]),
                startPoint: CGPoint(x: cx - r * 0.7, y: cy - r * 0.7),
                endPoint: CGPoint(x: cx + r * 0.75, y: cy + r * 0.8)
            ))
        }

        // Dots follow the zoom at every detail level; only their labels wait for rest.
        drawCities(in: &context, projector: projector, cx: cx, cy: cy, r: r, size: size)

        // The grid is drawn at every detail level, including while dragging.
        if !selectedGeohash.isEmpty {
            let cells = visibleCells
            drawGeohashGrid(cells, in: &context, cx: cx, cy: cy, r: r, clip: clip)
            drawGeohashLabels(cells, in: &context, cx: cx, cy: cy, r: r)
        }
    }

    private var visibleCells: [String] {
        var cells = [selectedGeohash]
        for neighbor in Geohash.neighbors(of: selectedGeohash) where !cells.contains(neighbor) {
            cells.append(neighbor)
        }
        return cells
    }

    private func screen(_ p: CGPoint, cx: Double, cy: Double, r: Double) -> CGPoint {
        CGPoint(x: cx + Double(p.x) * r, y: cy + Double(p.y) * r)
    }

    private func appendRuns(_ runs: [[CGPoint]], to path: inout Path, cx: Double, cy: Double, r: Double, clip: GlobeGeometry.ClipRect) {
        for run in runs where run.count >= 2 {
            for k in 1..<run.count {
                guard let segment = GlobeGeometry.clipSegment(
                    screen(run[k - 1], cx: cx, cy: cy, r: r),
                    screen(run[k], cx: cx, cy: cy, r: r),
                    to: clip
                ) else { continue }
                path.move(to: segment.0)
                path.addLine(to: segment.1)
            }
        }
    }

    private func drawGraticule(in context: inout GraphicsContext, cx: Double, cy: Double, r: Double, clip: GlobeGeometry.ClipRect) {
        let step = detail.graticuleStepDegrees
        var path = Path()
        func trace(_ points: [(lat: Double, lon: Double)]) {
            var prev: GlobeMath.Projection?
            for point in points {
                if let p = GlobeMath.project(lat: point.lat, lon: point.lon, centerLat: centerLat, centerLon: centerLon), p.cosC > 0.02 {
                    if let pp = prev, let segment = GlobeGeometry.clipSegment(
                        CGPoint(x: cx + pp.x * r, y: cy + pp.y * r),
                        CGPoint(x: cx + p.x * r, y: cy + p.y * r),
                        to: clip
                    ) {
                        path.move(to: segment.0)
                        path.addLine(to: segment.1)
                    }
                    prev = p
                } else {
                    prev = nil
                }
            }
        }
        // Latitude lines
        for lat in stride(from: -75.0, through: 75.0, by: 15) {
            trace(stride(from: -180.0, through: 180.0, by: step).map { (lat, $0) })
        }
        // Longitude lines
        for lon in stride(from: -180.0, to: 180.0, by: 15) {
            trace(stride(from: -90.0, through: 90.0, by: step).map { ($0, lon) })
        }
        context.stroke(path, with: .color(colors.graticule), lineWidth: pixel)
    }

    private func drawLand(
        _ ring: GlobeRing,
        in context: inout GraphicsContext,
        projector: GlobeMath.PreparedProjector,
        cx: Double, cy: Double, r: Double,
        clip: GlobeGeometry.ClipRect,
        coastlines: inout Path
    ) {
        let pointStride = ring.count >= 64 ? detail.landPointStride : 1
        let n = (ring.count - 1) / pointStride + 1
        guard n >= 3 else { return }

        var anyFront = false
        var anyBack = false
        var pts: [DiscPoint] = []
        pts.reserveCapacity(n)
        for i in 0..<n {
            let p = projector.project(ring.terms[min(i * pointStride, ring.count - 1)])
            if p.cosC >= 0 { anyFront = true } else { anyBack = true }
            pts.append(DiscPoint(x: p.x, y: p.y, front: p.cosC > 0.005))
        }
        guard anyFront else { return }

        appendRuns(GlobeGeometry.frontRuns(pts), to: &coastlines, cx: cx, cy: cy, r: r, clip: clip)
        let polygon = GlobeGeometry.fillPolygon(pts, cx: cx, cy: cy, r: r)
        let invert = anyBack && GlobeGeometry.projectedFillNeedsInversion(
            polygon: polygon, ring: ring, cx: cx, cy: cy, r: r, centerLat: centerLat, centerLon: centerLon
        )
        fill(pts, polygon: polygon, color: colors.land, in: &context, cx: cx, cy: cy, r: r, clip: clip, invert: invert)
    }

    private func fill(
        _ pts: [DiscPoint],
        polygon: [CGPoint]? = nil,
        color: Color,
        in context: inout GraphicsContext,
        cx: Double, cy: Double, r: Double,
        clip: GlobeGeometry.ClipRect,
        invert: Bool = false
    ) {
        guard pts.contains(where: \.front) else { return }
        let poly = polygon ?? GlobeGeometry.fillPolygon(pts, cx: cx, cy: cy, r: r)
        guard poly.count >= 3 else { return }
        let clipped = GlobeGeometry.clipPolygon(poly, to: clip)
        guard clipped.count >= 3 else { return }
        var path = Path()
        if invert {
            // Even-odd filling with the globe disc flips the one ring whose horizon
            // closure the projection put on the wrong side.
            let clipBounds = CGRect(x: clip.left, y: clip.top, width: clip.right - clip.left, height: clip.bottom - clip.top)
            let discRect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            if discRect.contains(clipBounds) {
                path.addRect(clipBounds)
            } else {
                path.addEllipse(in: discRect)
            }
        }
        path.addLines(clipped)
        path.closeSubpath()
        context.fill(path, with: .color(color), style: FillStyle(eoFill: invert))
    }

    private func drawCities(
        in context: inout GraphicsContext,
        projector: GlobeMath.PreparedProjector,
        cx: Double, cy: Double, r: Double,
        size: CGSize
    ) {
        let maxRank: Int
        if zoom < 2 {
            maxRank = 1
        } else if zoom < 8 {
            maxRank = 3
        } else if zoom < 40 {
            maxRank = 4
        } else {
            maxRank = 10
        }
        let width = Double(size.width)
        let height = Double(size.height)
        for city in world.cities where city.rank <= maxRank {
            let p = projector.project(city.terms)
            guard p.cosC >= 0.03 else { continue }
            let sx = cx + p.x * r
            let sy = cy + p.y * r
            guard sx >= -50, sx <= width + 50, sy >= -50, sy <= height + 50 else { continue }

            let alpha = min(max(p.cosC, 0.25), 1)
            let important = city.capital || city.megacity
            let dotRadius = important ? 2.6 : 1.8
            let dotColor = city.capital ? colors.accent.opacity(alpha) : colors.label.opacity(alpha * 0.85)
            context.fill(
                Path(ellipseIn: CGRect(x: sx - dotRadius, y: sy - dotRadius, width: dotRadius * 2, height: dotRadius * 2)),
                with: .color(dotColor)
            )

            if detail.showCityLabels && (zoom >= 6 || (important && zoom >= 2.5)) {
                drawLabel(
                    city.name,
                    at: CGPoint(x: sx + dotRadius + 3, y: sy),
                    anchor: .leading,
                    size: 10,
                    weight: .medium,
                    color: colors.label.opacity(200 / 255 * alpha),
                    halo: colors.labelHalo.opacity(140 / 255 * alpha),
                    in: &context
                )
            }
        }
    }

    private func drawGeohashGrid(_ cells: [String], in context: inout GraphicsContext, cx: Double, cy: Double, r: Double, clip: GlobeGeometry.ClipRect) {
        for cell in cells {
            let isSelected = cell == selectedGeohash
            let b = Geohash.decodeBounds(cell)
            let spanLat = b.latMax - b.latMin
            let spanLon = b.lonMax - b.lonMin
            let steps = min(max(Int((spanLat / 1.5).rounded(.up)), 4), 48)

            // Sample the cell boundary: N edge l->r, E edge t->b, S edge r->l, W edge b->t
            var pts: [DiscPoint] = []
            pts.reserveCapacity(steps * 4 + 4)
            func add(_ lat: Double, _ rawLon: Double) {
                // Keep the boundary continuous across the antimeridian relative to the view.
                var lon = rawLon
                while lon - centerLon > 180 { lon -= 360 }
                while lon - centerLon < -180 { lon += 360 }
                let p = GlobeMath.projectRaw(lat: lat, lon: lon, centerLat: centerLat, centerLon: centerLon)
                pts.append(DiscPoint(x: p.x, y: p.y, front: p.cosC >= 0.005))
            }
            for s in 0...steps { add(b.latMax, b.lonMin + spanLon * Double(s) / Double(steps)) }
            for s in 1...steps { add(b.latMax - spanLat * Double(s) / Double(steps), b.lonMax) }
            for s in 1...steps { add(b.latMin, b.lonMax - spanLon * Double(s) / Double(steps)) }
            for s in 1..<steps { add(b.latMin + spanLat * Double(s) / Double(steps), b.lonMin) }

            guard pts.contains(where: \.front) else { continue }
            var outline = Path()
            appendRuns(GlobeGeometry.frontRuns(pts), to: &outline, cx: cx, cy: cy, r: r, clip: clip)

            if isSelected {
                fill(pts, color: colors.accent.opacity(0.20), in: &context, cx: cx, cy: cy, r: r, clip: clip)
                context.stroke(outline, with: .color(colors.accent.opacity(0.35)), lineWidth: 7 * pixel)
                context.stroke(outline, with: .color(colors.accent), lineWidth: 3.2 * pixel)
            } else {
                fill(pts, color: colors.grid.opacity(0.05), in: &context, cx: cx, cy: cy, r: r, clip: clip)
                context.stroke(outline, with: .color(colors.grid), lineWidth: 1.6 * pixel)
            }
        }
    }

    private func drawGeohashLabels(_ cells: [String], in context: inout GraphicsContext, cx: Double, cy: Double, r: Double) {
        for cell in cells {
            let isSelected = cell == selectedGeohash
            let c = Geohash.decodeCenter(cell)
            guard let p = GlobeMath.project(lat: c.lat, lon: c.lon, centerLat: centerLat, centerLon: centerLon),
                  p.cosC >= 0.08 else { continue }
            drawLabel(
                cell,
                at: CGPoint(x: cx + p.x * r, y: cy + p.y * r),
                anchor: .center,
                size: isSelected ? 12.5 : 10,
                weight: isSelected ? .semibold : .medium,
                color: isSelected ? colors.accent : colors.label.opacity(160 / 255 * min(max(p.cosC, 0.4), 1)),
                halo: colors.labelHalo.opacity(isSelected ? 200 / 255 : 120 / 255),
                in: &context
            )
        }
    }

    /// Text with a thin halo in the background color so labels stay legible over land,
    /// grid lines and the limb shading.
    private func drawLabel(
        _ string: String,
        at point: CGPoint,
        anchor: UnitPoint,
        size: CGFloat,
        weight: Font.Weight,
        color: Color,
        halo: Color,
        in context: inout GraphicsContext
    ) {
        var resolved = context.resolve(
            Text(verbatim: string).font(.system(size: size, weight: weight, design: fontDesign))
        )
        resolved.shading = .color(halo)
        let w = size * 0.09
        for (dx, dy) in [(-w, 0), (w, 0), (0, -w), (0, w), (-w, -w), (w, -w), (-w, w), (w, w)] {
            context.draw(resolved, at: CGPoint(x: point.x + dx, y: point.y + dy), anchor: anchor)
        }
        resolved.shading = .color(color)
        context.draw(resolved, at: point, anchor: anchor)
    }
}

// MARK: - Touch handling

/// Gesture surface over the globe. A single raw-touch handler (rather than stacked
/// recognizers) mirrors the Android picker: centroid pan rotates, pinch zooms in the
/// same gesture, a quick tap focuses immediately and a second tap zooms in.
#if os(iOS)
private struct GlobeTouchLayer: UIViewRepresentable {
    let state: GlobeState

    func makeUIView(context: Context) -> GlobeTouchSurface {
        let view = GlobeTouchSurface()
        view.state = state
        return view
    }

    func updateUIView(_ view: GlobeTouchSurface, context: Context) {
        view.state = state
    }
}

private final class GlobeTouchSurface: UIView {
    weak var state: GlobeState?

    private static let touchSlop: CGFloat = 8
    private var touches: Set<UITouch> = []
    private var downTime: TimeInterval = 0
    private var downPosition: CGPoint = .zero
    private var moved: CGVector = .zero
    private var dragStarted = false
    private var hadMultipleTouches = false
    private var lastCentroid: CGPoint?
    private var lastSpan: CGFloat?
    private var samples: [(time: TimeInterval, position: CGPoint)] = []
    private var lastTapTime: TimeInterval = 0
    private var lastTapPosition: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ began: Set<UITouch>, with event: UIEvent?) {
        if touches.isEmpty, let first = began.first {
            state?.beginInteraction()
            downTime = first.timestamp
            downPosition = first.location(in: self)
            moved = .zero
            dragStarted = false
            hadMultipleTouches = false
            samples = [(first.timestamp, downPosition)]
        }
        touches.formUnion(began)
        if touches.count > 1 {
            hadMultipleTouches = true
            samples.removeAll()
        }
        resetBaseline()
    }

    override func touchesMoved(_ movedTouches: Set<UITouch>, with event: UIEvent?) {
        guard let state, let previousCentroid = lastCentroid else { return }
        let centroid = currentCentroid()
        let pan = CGVector(dx: centroid.x - previousCentroid.x, dy: centroid.y - previousCentroid.y)
        if pan != .zero {
            moved.dx += pan.dx
            moved.dy += pan.dy
            if !dragStarted && hypot(moved.dx, moved.dy) >= Self.touchSlop {
                dragStarted = true
            }
            if dragStarted { state.rotateBy(dx: Double(pan.dx), dy: Double(pan.dy)) }
        }
        if touches.count > 1, let previousSpan = lastSpan, previousSpan > 0 {
            let span = currentSpan(around: centroid)
            if span > 0 { state.zoomBy(Double(span / previousSpan)) }
            lastSpan = span
        }
        lastCentroid = centroid
        if !hadMultipleTouches, touches.count == 1, let touch = touches.first {
            samples.append((touch.timestamp, touch.location(in: self)))
            if samples.count > 20 { samples.removeFirst(samples.count - 20) }
        }
    }

    override func touchesEnded(_ ended: Set<UITouch>, with event: UIEvent?) {
        if !hadMultipleTouches, touches.count == 1, let touch = ended.first {
            samples.append((touch.timestamp, touch.location(in: self)))
        }
        finish(ended, upTime: ended.first?.timestamp ?? downTime, cancelled: false)
    }

    override func touchesCancelled(_ cancelled: Set<UITouch>, with event: UIEvent?) {
        finish(cancelled, upTime: cancelled.first?.timestamp ?? downTime, cancelled: true)
    }

    private func finish(_ lifted: Set<UITouch>, upTime: TimeInterval, cancelled: Bool) {
        touches.subtract(lifted)
        guard touches.isEmpty else {
            resetBaseline()
            return
        }
        lastCentroid = nil
        lastSpan = nil
        guard let state else { return }
        guard !cancelled else {
            state.endInteraction()
            return
        }

        let isTap = !hadMultipleTouches
            && !dragStarted
            && upTime - downTime < 0.4
            && hypot(moved.dx, moved.dy) < Self.touchSlop
        let r = state.globeRadius
        let tapLocation = r > 0 ? GlobeMath.unproject(
            x: Double((downPosition.x - bounds.midX) / r),
            y: Double((downPosition.y - bounds.midY) / r),
            centerLat: state.centerLat,
            centerLon: state.centerLon
        ) : nil
        if isTap, let location = tapLocation {
            let isDouble = upTime - lastTapTime < 0.35
                && hypot(downPosition.x - lastTapPosition.x, downPosition.y - lastTapPosition.y) < Self.touchSlop * 4
            lastTapTime = upTime
            lastTapPosition = downPosition
            state.focus(lat: location.lat, lon: location.lon, zoomIn: isDouble)
            state.endInteraction()
        } else if dragStarted && !hadMultipleTouches {
            let velocity = releaseVelocity(at: upTime)
            state.endInteraction(flingVelocityX: Double(velocity.dx), flingVelocityY: Double(velocity.dy))
        } else {
            state.endInteraction()
        }
    }

    /// Average velocity over the last 100ms of movement; zero when the finger rested
    /// before lifting.
    private func releaseVelocity(at upTime: TimeInterval) -> CGVector {
        guard let last = samples.last, upTime - last.time < 0.04 else { return .zero }
        let window = samples.filter { last.time - $0.time <= 0.1 }
        guard let first = window.first, last.time - first.time > 0.005 else { return .zero }
        let dt = CGFloat(last.time - first.time)
        return CGVector(dx: (last.position.x - first.position.x) / dt, dy: (last.position.y - first.position.y) / dt)
    }

    private func resetBaseline() {
        let centroid = currentCentroid()
        lastCentroid = centroid
        lastSpan = touches.count > 1 ? currentSpan(around: centroid) : nil
    }

    private func currentCentroid() -> CGPoint {
        guard !touches.isEmpty else { return .zero }
        var x: CGFloat = 0
        var y: CGFloat = 0
        for touch in touches {
            let p = touch.location(in: self)
            x += p.x
            y += p.y
        }
        return CGPoint(x: x / CGFloat(touches.count), y: y / CGFloat(touches.count))
    }

    private func currentSpan(around centroid: CGPoint) -> CGFloat {
        guard !touches.isEmpty else { return 0 }
        let total = touches.reduce(CGFloat(0)) { sum, touch in
            let p = touch.location(in: self)
            return sum + hypot(p.x - centroid.x, p.y - centroid.y)
        }
        return total / CGFloat(touches.count)
    }
}
#else
private struct GlobeTouchLayer: NSViewRepresentable {
    let state: GlobeState

    func makeNSView(context: Context) -> GlobeTouchSurface {
        let view = GlobeTouchSurface()
        view.state = state
        return view
    }

    func updateNSView(_ view: GlobeTouchSurface, context: Context) {
        view.state = state
    }
}

/// macOS: click-drag spins, trackpad pinch or scroll zooms, click focuses,
/// double click zooms in.
private final class GlobeTouchSurface: NSView {
    weak var state: GlobeState?

    private var lastDrag: CGPoint?
    private var dragDistance: CGFloat = 0
    private var samples: [(time: TimeInterval, position: CGPoint)] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        state?.beginInteraction()
        let p = convert(event.locationInWindow, from: nil)
        lastDrag = p
        dragDistance = 0
        samples = [(event.timestamp, p)]
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let last = lastDrag {
            dragDistance += hypot(p.x - last.x, p.y - last.y)
            state?.rotateBy(dx: Double(p.x - last.x), dy: Double(p.y - last.y))
        }
        lastDrag = p
        samples.append((event.timestamp, p))
        if samples.count > 20 { samples.removeFirst(samples.count - 20) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let state else { return }
        lastDrag = nil
        let p = convert(event.locationInWindow, from: nil)
        let r = state.globeRadius
        if dragDistance < 4 {
            if r > 0, let location = GlobeMath.unproject(
                x: Double((p.x - bounds.midX) / r),
                y: Double((p.y - bounds.midY) / r),
                centerLat: state.centerLat,
                centerLon: state.centerLon
            ) {
                state.focus(lat: location.lat, lon: location.lon, zoomIn: event.clickCount >= 2)
            }
            state.endInteraction()
        } else if let last = samples.last, event.timestamp - last.time < 0.04,
                  let first = samples.first(where: { last.time - $0.time <= 0.1 }),
                  last.time - first.time > 0.005 {
            let dt = CGFloat(last.time - first.time)
            state.endInteraction(
                flingVelocityX: Double((last.position.x - first.position.x) / dt),
                flingVelocityY: Double((last.position.y - first.position.y) / dt)
            )
        } else {
            state.endInteraction()
        }
    }

    override func magnify(with event: NSEvent) {
        state?.cancelAnimations()
        state?.zoomBy(Double(1 + event.magnification))
    }

    override func scrollWheel(with event: NSEvent) {
        state?.cancelAnimations()
        state?.zoomBy(Double(exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1))))
    }
}
#endif
