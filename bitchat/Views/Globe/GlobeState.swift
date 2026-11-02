//
// GlobeState.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import Foundation
import QuartzCore
#if os(iOS)
import UIKit
#endif

/// How much of the globe a moving frame draws. Detail drops while the globe moves
/// on slow devices and is fully restored once interaction settles. The geohash grid
/// (selected cell and its neighbors) and the city dots are not part of this: both
/// are cheap next to the land geometry, and making them vanish while dragging and
/// pop back on release read as a rendering bug.
enum GlobeMotionDetail: Equatable, Comparable {
    case full
    case balanced
    case fast

    struct Frame: Equatable {
        let graticuleStepDegrees: Double
        let landPointStride: Int
        let showBorders: Bool
        let showCityLabels: Bool
    }

    var frame: Frame {
        switch self {
        case .full:
            return Frame(graticuleStepDegrees: 4, landPointStride: 1, showBorders: true,
                         showCityLabels: true)
        case .balanced:
            return Frame(graticuleStepDegrees: 8, landPointStride: 2, showBorders: true,
                         showCityLabels: false)
        case .fast:
            return Frame(graticuleStepDegrees: 10, landPointStride: 2, showBorders: false,
                         showCityLabels: false)
        }
    }

    /// Ordered from least to most detailed.
    static func < (lhs: GlobeMotionDetail, rhs: GlobeMotionDetail) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .fast: return 0
        case .balanced: return 1
        case .full: return 2
        }
    }

    var moreDetailed: GlobeMotionDetail {
        switch self {
        case .fast: return .balanced
        case .balanced, .full: return .full
        }
    }

    /// The level measured frame cadence calls for. Hysteresis alone cannot stop
    /// oscillation (shedding detail is what makes frames fast again), so `GlobeState`
    /// only ever applies downgrades while the globe is moving.
    func next(averageFrameMillis: Double) -> GlobeMotionDetail {
        guard averageFrameMillis.isFinite else { return .fast }
        switch self {
        case .full:
            if averageFrameMillis > 34 { return .fast }
            if averageFrameMillis > 22 { return .balanced }
            return .full
        case .balanced:
            if averageFrameMillis > 29 { return .fast }
            if averageFrameMillis < 18.5 { return .full }
            return .balanced
        case .fast:
            return averageFrameMillis < 22 ? .balanced : .fast
        }
    }
}

/// Picks the detail level for moving frames. A motion session spans everything from
/// touch-down through any fling or animation until the globe is at rest.
///
/// Within a session detail only ever steps down: shedding layers is what makes
/// frames fast again, so letting measured cadence step back up made neighbor cells,
/// labels and the grid flash on and off while dragging. Between sessions, a smooth
/// one lets the next start a level higher, until any session has had to shed detail.
struct GlobeMotionGovernor {
    static let frameSampleCount = 8
    static let smoothFrameMillis = 18.5
    static let maxSampledFrameMillis = 50.0

    private(set) var detail: GlobeMotionDetail = .full
    private(set) var isSessionActive = false
    private var startDetail: GlobeMotionDetail = .balanced
    private var ceilingFound = false
    private var sessionDegraded = false
    private var windowMillis = 0.0
    private var windowCount = 0
    private var sessionMillis = 0.0
    private var sessionCount = 0

    mutating func beginSession() {
        guard !isSessionActive else { return }
        isSessionActive = true
        sessionDegraded = false
        windowMillis = 0
        windowCount = 0
        sessionMillis = 0
        sessionCount = 0
        detail = startDetail
    }

    mutating func recordFrame(millis: Double) {
        guard isSessionActive else { return }
        let frameMillis = min(max(millis, 1), Self.maxSampledFrameMillis)
        windowMillis += frameMillis
        windowCount += 1
        sessionMillis += frameMillis
        sessionCount += 1
        guard windowCount >= Self.frameSampleCount else { return }
        let wanted = detail.next(averageFrameMillis: windowMillis / Double(windowCount))
        if wanted < detail {
            detail = wanted
            sessionDegraded = true
        }
        windowMillis = 0
        windowCount = 0
    }

    /// Back to full detail at rest; remembers where the next session should start.
    mutating func endSession() {
        guard isSessionActive else { return }
        isSessionActive = false
        if sessionDegraded {
            ceilingFound = true
            startDetail = detail
        } else if !ceilingFound,
                  sessionCount >= Self.frameSampleCount,
                  sessionMillis / Double(sessionCount) < Self.smoothFrameMillis {
            startDetail = detail.moreDetailed
        }
        detail = .full
    }
}

/// Hoisted state for the interactive 3D globe: view center, zoom, geohash precision
/// and the current selection. All mutation funnels through this class so rendering,
/// gestures and buttons stay in sync.
@MainActor
final class GlobeState: ObservableObject {
    @Published private(set) var centerLat: Double
    @Published private(set) var centerLon: Double
    @Published private(set) var zoom: Double
    @Published private(set) var precision: Int
    @Published private(set) var selectedGeohash = ""
    @Published private(set) var isInteracting = false
    @Published private(set) var isAnimating = false
    /// Detail level for moving frames; `.full` whenever the globe is at rest.
    @Published private(set) var motionDetail: GlobeMotionDetail = .full

    private(set) var baseRadius: Double = 0
    private(set) var screenMin: Double = 0

    /// Pending cinematic intro target; consumed once the viewport is known.
    private var introTarget: (lat: Double, lon: Double, precision: Int)?

    private var motion: Motion?
    private var lastTick: CFTimeInterval?
    private var governor = GlobeMotionGovernor()
    private lazy var clock = GlobeFrameClock { [weak self] timestamp in
        self?.tick(timestamp)
    }

    private enum Motion {
        case tween(Tween)
        case fling(vx: Double, vy: Double)
    }

    private struct Tween {
        let startLat: Double
        let startLon: Double
        let endLat: Double
        let dLon: Double
        let startZoom: Double
        let endZoom: Double
        let targetPrecision: Int?
        let duration: CFTimeInterval
        var startTime: CFTimeInterval?
    }

    private enum Constants {
        // Dragging stops close to the projection limit so polar geohash cells remain
        // selectable; clamping tighter would make syncSelection() encode the wrong cell.
        // Animations may go past it to reach a target (see clampedLat).
        static let maxDragLat = 89.0
        static let minFlingPerSecond = 35.0
        static let maxFlingPerSecond = 1_200.0
        static let maxFrameDelta = 1.0 / 30
        static let maxFlingRadiusFractionPerFrame = 0.12
        static let flingFrictionPerSecond = 4.2
    }

    /// - Parameter startZoomedOut: begin from a far, offset view and fly into the
    ///   target once the viewport is laid out.
    init(targetLat: Double, targetLon: Double, initialPrecision: Int, startZoomedOut: Bool) {
        let precision = min(max(initialPrecision, 1), GlobeMath.maxPrecision)
        centerLat = startZoomedOut ? targetLat * 0.4 : targetLat
        centerLon = startZoomedOut ? GlobeMath.normalizeLon(targetLon - 70) : targetLon
        zoom = GlobeMath.minZoom
        self.precision = precision
        if startZoomedOut {
            introTarget = (targetLat, targetLon, precision)
        }
    }

    var globeRadius: Double { baseRadius * zoom }

    var isInMotion: Bool { isInteracting || isAnimating }

    /// Detail the next frame should draw.
    var frameDetail: GlobeMotionDetail.Frame {
        (isInMotion ? motionDetail : .full).frame
    }

    func setViewport(baseRadius: Double, screenMin: Double, animateIntro: Bool = true) {
        guard baseRadius > 0, screenMin > 0 else { return }
        let firstLayout = self.baseRadius <= 0
        self.baseRadius = baseRadius
        self.screenMin = screenMin
        if firstLayout, let target = introTarget {
            introTarget = nil
            let targetZoom = GlobeMath.zoomForPrecision(target.precision, baseRadius: baseRadius, screenMin: screenMin)
            if animateIntro {
                // Cinematic intro: spin and zoom from the far view into the target location.
                animateTo(lat: target.lat, lon: target.lon, zoom: targetZoom, precision: target.precision, duration: 1.4)
            } else {
                centerLat = target.lat
                centerLon = target.lon
                zoom = targetZoom
                precision = target.precision
            }
        }
        syncSelection()
    }

    // MARK: - Gestures

    func beginInteraction() {
        // Mark the touch first so catching a fling continues the same motion session.
        isInteracting = true
        motionStateChanged()
        cancelAnimations()
    }

    /// Ends a touch; a release velocity (points/second) carries on as an inertial spin
    /// within the same motion session.
    func endInteraction(flingVelocityX vx: Double = 0, flingVelocityY vy: Double = 0) {
        fling(vx: vx, vy: vy)
        isInteracting = false
        motionStateChanged()
    }

    /// Direct rotation from drag gestures. Deltas are in screen points.
    func rotateBy(dx: Double, dy: Double) {
        let r = globeRadius
        guard r > 0 else { return }
        let degPerPoint = 180 / (Double.pi * r)
        centerLon = GlobeMath.normalizeLon(centerLon - dx * degPerPoint)
        // A view already past the drag limit (a polar target) may move toward the
        // equator but not further out, and never snaps back to the limit.
        centerLat = clampedLat(centerLat + dy * degPerPoint, reaching: centerLat)
        syncSelection()
    }

    /// Continuous zoom from pinch gestures; precision follows automatically.
    func zoomBy(_ factor: Double) {
        guard factor != 1, factor.isFinite, factor > 0 else { return }
        zoom = min(max(zoom * factor, GlobeMath.minZoom), GlobeMath.maxZoom)
        syncPrecisionFromZoom()
        syncSelection()
    }

    /// Inertial spin after a fling. Velocities are in points/second.
    func fling(vx: Double, vy: Double) {
        var initialVx = min(max(vx, -Constants.maxFlingPerSecond), Constants.maxFlingPerSecond)
        var initialVy = min(max(vy, -Constants.maxFlingPerSecond), Constants.maxFlingPerSecond)
        if abs(initialVx) < Constants.minFlingPerSecond { initialVx = 0 }
        if abs(initialVy) < Constants.minFlingPerSecond { initialVy = 0 }
        guard initialVx != 0 || initialVy != 0 else { return }
        start(.fling(vx: initialVx, vy: initialVy))
    }

    /// Single tap focuses the tapped point; double tap also zooms in.
    func focus(lat: Double, lon: Double, zoomIn: Bool) {
        if zoomIn {
            animateTo(lat: lat, lon: lon, zoom: min(zoom * 1.9, GlobeMath.maxZoom), duration: 0.5)
        } else {
            animateTo(lat: lat, lon: lon, duration: 0.45)
        }
    }

    // MARK: - Animations

    /// Animate the view to a lat/lon, optionally to a zoom and precision.
    func animateTo(lat: Double, lon: Double, zoom targetZoom: Double? = nil, precision targetPrecision: Int? = nil, duration: CFTimeInterval = 0.55) {
        let endZoom = min(max(targetZoom ?? zoom, GlobeMath.minZoom), GlobeMath.maxZoom)
        start(.tween(Tween(
            startLat: centerLat,
            startLon: centerLon,
            endLat: lat,
            dLon: GlobeMath.normalizeLon(lon - centerLon),
            startZoom: zoom,
            endZoom: endZoom,
            targetPrecision: targetPrecision,
            duration: duration
        )))
    }

    /// Button-driven precision change: adjusts precision and animates zoom to frame it.
    func animatePrecision(_ newPrecision: Int) {
        let p = min(max(newPrecision, 1), GlobeMath.maxPrecision)
        guard p != precision, baseRadius > 0 else { return }
        let targetZoom = GlobeMath.zoomForPrecision(p, baseRadius: baseRadius, screenMin: screenMin)
        animateTo(lat: centerLat, lon: centerLon, zoom: targetZoom, precision: p, duration: 0.45)
    }

    func cancelAnimations() {
        motion = nil
        if isAnimating {
            isAnimating = false
            motionStateChanged()
        }
    }

    private func start(_ newMotion: Motion) {
        motion = newMotion
        if !isAnimating {
            isAnimating = true
            motionStateChanged()
        }
        clock.start()
    }

    private func finishMotion() {
        motion = nil
        isAnimating = false
        motionStateChanged()
    }

    // MARK: - Frame loop

    /// One display frame. Internal so tests can drive animations deterministically.
    func tick(_ timestamp: CFTimeInterval) {
        let previous = lastTick
        lastTick = timestamp
        let dt = previous.map { min(max(timestamp - $0, 0), Constants.maxFrameDelta) } ?? 0

        switch motion {
        case .tween(var tween):
            let startTime = tween.startTime ?? timestamp
            tween.startTime = startTime
            let progress = min(max((timestamp - startTime) / tween.duration, 0), 1)
            applyTween(tween, t: GlobeEasing.fastOutSlowIn(progress))
            if progress >= 1 {
                finishMotion()
            } else {
                motion = .tween(tween)
            }
        case .fling(var vx, var vy):
            let maxStep = globeRadius * Constants.maxFlingRadiusFractionPerFrame
            rotateBy(
                dx: min(max(vx * dt, -maxStep), maxStep),
                dy: min(max(vy * dt, -maxStep), maxStep)
            )
            let decay = exp(-Constants.flingFrictionPerSecond * dt)
            vx *= decay
            vy *= decay
            if abs(vx) >= Constants.minFlingPerSecond || abs(vy) >= Constants.minFlingPerSecond {
                motion = .fling(vx: vx, vy: vy)
            } else {
                finishMotion()
            }
        case nil:
            break
        }

        if isInMotion, let previous {
            governor.recordFrame(millis: (timestamp - previous) * 1000)
            publishMotionDetail()
        }

        if motion == nil && !isInteracting {
            clock.stop()
            lastTick = nil
        }
    }

    private func applyTween(_ tween: Tween, t: Double) {
        // The target itself is always reachable: a polar cell's center can lie past
        // the drag limit, and clamping it would end the animation on another cell.
        centerLat = clampedLat(tween.startLat + (tween.endLat - tween.startLat) * t, reaching: tween.endLat)
        centerLon = GlobeMath.normalizeLon(tween.startLon + tween.dLon * t)
        // Exponential interpolation feels natural for zoom.
        zoom = tween.startZoom * pow(tween.endZoom / tween.startZoom, t)
        if let target = tween.targetPrecision {
            precision = min(max(target, 1), GlobeMath.maxPrecision)
        } else {
            syncPrecisionFromZoom()
        }
        syncSelection()
    }

    /// Starts a motion session when the globe begins moving and ends it once both the
    /// touch and any animation are done (see `GlobeMotionGovernor`).
    private func motionStateChanged() {
        if isInMotion {
            guard !governor.isSessionActive else { return }
            governor.beginSession()
            lastTick = nil
            clock.start()
        } else {
            governor.endSession()
        }
        publishMotionDetail()
    }

    private func publishMotionDetail() {
        if motionDetail != governor.detail { motionDetail = governor.detail }
    }

    /// Clamps to the drag limit, widened (up to that pole) on `reach`'s side only.
    private func clampedLat(_ lat: Double, reaching reach: Double) -> Double {
        let lower = max(min(-Constants.maxDragLat, reach), -90)
        let upper = min(max(Constants.maxDragLat, reach), 90)
        return min(max(lat, lower), upper)
    }

    private func syncPrecisionFromZoom() {
        guard baseRadius > 0 else { return }
        let p = GlobeMath.autoPrecision(globeRadius: globeRadius, screenMin: screenMin)
        if p != precision { precision = p }
    }

    private func syncSelection() {
        guard baseRadius > 0 else { return }
        let gh = Geohash.encode(latitude: centerLat, longitude: centerLon, precision: precision)
        if gh != selectedGeohash { selectedGeohash = gh }
    }
}

/// Material's FastOutSlowIn curve, cubic-bezier(0.4, 0.0, 0.2, 1.0), which the
/// Android globe animates with.
enum GlobeEasing {
    static func fastOutSlowIn(_ t: Double) -> Double {
        cubicBezier(t, x1: 0.4, y1: 0, x2: 0.2, y2: 1)
    }

    static func cubicBezier(_ t: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        func sample(_ s: Double, _ a1: Double, _ a2: Double) -> Double {
            let inv = 1 - s
            return 3 * inv * inv * s * a1 + 3 * inv * s * s * a2 + s * s * s
        }
        // Solve x(s) = t by bisection; x is monotonic for these control points.
        var lo = 0.0
        var hi = 1.0
        var s = t
        for _ in 0..<24 {
            let x = sample(s, x1, x2)
            if abs(x - t) < 1e-6 { break }
            if x < t { lo = s } else { hi = s }
            s = (lo + hi) / 2
        }
        return sample(s, y1, y2)
    }
}

/// Per-display-frame callback driving globe animations: CADisplayLink on iOS,
/// a common-mode timer on macOS.
@MainActor
final class GlobeFrameClock {
    private let onFrame: (CFTimeInterval) -> Void
    #if os(iOS)
    private var displayLink: CADisplayLink?
    private var proxy: Proxy?

    private final class Proxy: NSObject {
        weak var clock: GlobeFrameClock?

        @objc func step(_ link: CADisplayLink) {
            MainActor.assumeIsolated {
                clock?.onFrame(link.timestamp)
            }
        }
    }
    #else
    private var timer: Timer?
    #endif

    init(onFrame: @escaping (CFTimeInterval) -> Void) {
        self.onFrame = onFrame
    }

    func start() {
        #if os(iOS)
        guard displayLink == nil else { return }
        let proxy = Proxy()
        proxy.clock = self
        let link = CADisplayLink(target: proxy, selector: #selector(Proxy.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.proxy = proxy
        displayLink = link
        #else
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onFrame(CACurrentMediaTime())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        #endif
    }

    func stop() {
        #if os(iOS)
        displayLink?.invalidate()
        displayLink = nil
        proxy = nil
        #else
        timer?.invalidate()
        timer = nil
        #endif
    }

    deinit {
        #if os(iOS)
        displayLink?.invalidate()
        #else
        timer?.invalidate()
        #endif
    }
}
