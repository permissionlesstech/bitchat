//
// GlobeGeometry.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CoreGraphics
import Foundation

/// Polygon/polyline helpers that turn projected geometry into drawable screen paths:
/// splitting at the limb, closing fills along the horizon, and clipping to the viewport.
enum GlobeGeometry {
    /// A projected point in disc units (radius 1, screen y down).
    struct DiscPoint: Equatable {
        let x: Double
        let y: Double
        let front: Bool
    }

    /// Core Graphics loses precision with path coordinates far outside the view, which
    /// happens at high globe zoom. All geometry is clipped to an expanded viewport rect
    /// in screen space before it becomes a path.
    struct ClipRect {
        let left: Double
        let top: Double
        let right: Double
        let bottom: Double

        init(size: CGSize) {
            left = -Double(size.width)
            top = -Double(size.height)
            right = Double(size.width) * 2
            bottom = Double(size.height) * 2
        }

        init(left: Double, top: Double, right: Double, bottom: Double) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
        }
    }

    private static func limbPoint(behind: DiscPoint, front: DiscPoint) -> CGPoint {
        var lo = 0.0
        var hi = 1.0
        for _ in 0..<14 {
            let t = (lo + hi) / 2
            let x = behind.x + (front.x - behind.x) * t
            let y = behind.y + (front.y - behind.y) * t
            if x * x + y * y < 1 { lo = t } else { hi = t }
        }
        let t = (lo + hi) / 2
        return CGPoint(x: behind.x + (front.x - behind.x) * t, y: behind.y + (front.y - behind.y) * t)
    }

    /// Splits a projected polygon into front-facing runs (disc units). Runs that touch the
    /// limb are padded with the horizon intersection point so they can be closed along the
    /// horizon. Pass `closed = false` for open polylines (border lines).
    static func frontRuns(_ pts: [DiscPoint], closed: Bool = true) -> [[CGPoint]] {
        guard let first = pts.first, let last = pts.last else { return [] }
        var runs: [[CGPoint]] = []
        var run: [CGPoint] = []
        var prev: DiscPoint? = closed ? last : nil
        for cur in pts {
            if cur.front {
                if run.isEmpty, let p = prev, !p.front { run.append(limbPoint(behind: p, front: cur)) }
                // Antimeridian wrap: consecutive front points can jump across the whole
                // disc when a polygon crosses ±180° — break the run instead of drawing
                // a chord through the view.
                if let tail = run.last {
                    let dx = cur.x - Double(tail.x)
                    let dy = cur.y - Double(tail.y)
                    if dx * dx + dy * dy > 1.2 {
                        runs.append(run)
                        run = []
                    }
                }
                run.append(CGPoint(x: cur.x, y: cur.y))
            } else if !run.isEmpty, let p = prev {
                run.append(limbPoint(behind: p, front: cur))
                runs.append(run)
                run = []
            }
            prev = cur
        }
        if !run.isEmpty {
            if closed, !runs.isEmpty, first.front, last.front {
                runs[0] = run + runs[0]
            } else {
                // A fully front-facing ring has no limb transition to terminate its run.
                // Close it explicitly; cell boundary sampling intentionally omits the
                // duplicated final corner.
                if closed, runs.isEmpty, first.front, last.front, let head = run.first {
                    run.append(head)
                }
                runs.append(run)
            }
        }
        return runs
    }

    /// Builds a fill polygon (screen units) for a projected ring by clamping back-facing
    /// points onto the limb and inserting horizon arc steps between consecutive limb
    /// points, so the result approximates (polygon ∩ visible disc) without
    /// self-intersecting chords.
    static func fillPolygon(_ pts: [DiscPoint], cx: Double, cy: Double, r: Double) -> [CGPoint] {
        var out: [CGPoint] = []
        out.reserveCapacity(pts.count + 128)
        var prevLimbAngle: Double?
        var firstLimbAngle: Double?

        func addArc(from: Double, to: Double) {
            var d = to - from
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            let steps = min(max(Int(abs(d) / 0.04), 1), 64)
            for s in 1..<steps {
                let a = from + d * Double(s) / Double(steps)
                out.append(CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r))
            }
        }

        for p in pts {
            if p.front {
                out.append(CGPoint(x: cx + p.x * r, y: cy + p.y * r))
                prevLimbAngle = nil
            } else {
                let len = (p.x * p.x + p.y * p.y).squareRoot()
                let lx = len > 1e-6 ? p.x / len : 0
                let ly = len > 1e-6 ? p.y / len : -1
                let angle = atan2(ly, lx)
                if let prev = prevLimbAngle { addArc(from: prev, to: angle) }
                if firstLimbAngle == nil { firstLimbAngle = angle }
                out.append(CGPoint(x: cx + lx * r, y: cy + ly * r))
                prevLimbAngle = angle
            }
        }
        // Wrap-around arc if the ring ends and starts on the limb.
        if let lastAngle = prevLimbAngle, let firstAngle = firstLimbAngle, let head = pts.first, !head.front {
            addArc(from: lastAngle, to: firstAngle)
        }
        return out
    }

    /// Sutherland–Hodgman clip of a polygon to the rect.
    static func clipPolygon(_ pts: [CGPoint], to rect: ClipRect) -> [CGPoint] {
        guard let first = pts.first else { return pts }
        let left = CGFloat(rect.left), right = CGFloat(rect.right)
        let top = CGFloat(rect.top), bottom = CGFloat(rect.bottom)

        // Fast bounding-box pre-check avoids 4 edge passes and allocations when
        // a polygon is fully inside or fully outside the expanded clip rect.
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for p in pts.dropFirst() {
            if p.x < minX { minX = p.x } else if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y } else if p.y > maxY { maxY = p.y }
        }
        if maxX < left || minX > right || maxY < top || minY > bottom {
            return []
        }
        if minX >= left && maxX <= right && minY >= top && maxY <= bottom {
            return pts
        }

        func clipEdge(
            _ input: [CGPoint],
            inside: (CGPoint) -> Bool,
            intersect: (CGPoint, CGPoint) -> CGPoint
        ) -> [CGPoint] {
            guard var s = input.last else { return input }
            var result: [CGPoint] = []
            result.reserveCapacity(input.count + 4)
            for e in input {
                let eIn = inside(e)
                if eIn {
                    if !inside(s) { result.append(intersect(s, e)) }
                    result.append(e)
                } else if inside(s) {
                    result.append(intersect(s, e))
                }
                s = e
            }
            return result
        }
        var out = pts
        out = clipEdge(out, inside: { $0.x >= left }) { a, b in
            CGPoint(x: left, y: a.y + (left - a.x) / (b.x - a.x) * (b.y - a.y))
        }
        out = clipEdge(out, inside: { $0.x <= right }) { a, b in
            CGPoint(x: right, y: a.y + (right - a.x) / (b.x - a.x) * (b.y - a.y))
        }
        out = clipEdge(out, inside: { $0.y >= top }) { a, b in
            CGPoint(x: a.x + (top - a.y) / (b.y - a.y) * (b.x - a.x), y: top)
        }
        out = clipEdge(out, inside: { $0.y <= bottom }) { a, b in
            CGPoint(x: a.x + (bottom - a.y) / (b.y - a.y) * (b.x - a.x), y: bottom)
        }
        return out
    }

    /// Liang–Barsky clip of a segment to the rect; returns the clipped endpoints or nil.
    static func clipSegment(_ a: CGPoint, _ b: CGPoint, to rect: ClipRect) -> (CGPoint, CGPoint)? {
        let x0 = Double(a.x), y0 = Double(a.y)
        let dx = Double(b.x) - x0
        let dy = Double(b.y) - y0
        var u1 = 0.0
        var u2 = 1.0
        func test(_ p: Double, _ q: Double) -> Bool {
            if p == 0 { return q >= 0 }
            let r = q / p
            if p < 0 {
                if r > u2 { return false }
                if r > u1 { u1 = r }
            } else {
                if r < u1 { return false }
                if r < u2 { u2 = r }
            }
            return true
        }
        guard test(-dx, x0 - rect.left),
              test(dx, rect.right - x0),
              test(-dy, y0 - rect.top),
              test(dy, rect.bottom - y0) else { return nil }
        return (
            CGPoint(x: x0 + u1 * dx, y: y0 + u1 * dy),
            CGPoint(x: x0 + u2 * dx, y: y0 + u2 * dy)
        )
    }

    /// Precomputed disc probe point and its geographic coordinates for one frame's camera,
    /// avoiding redundant `GlobeMath.unproject` calls for every back-crossing land ring.
    struct UnprojectedSample {
        let nx: Double
        let ny: Double
        let lat: Double
        let lon: Double
    }

    private static let inversionProbeCoords: [(Double, Double)] = [
        (0, 0), (-0.5, 0), (0.5, 0), (0, -0.5), (0, 0.5),
        (-0.35, -0.35), (0.35, -0.35), (-0.35, 0.35), (0.35, 0.35)
    ]

    /// Unprojects the 9 fixed disc probes once per frame for `projectedFillNeedsInversion`.
    static func unprojectInversionSamples(centerLat: Double, centerLon: Double) -> [UnprojectedSample] {
        var out: [UnprojectedSample] = []
        out.reserveCapacity(inversionProbeCoords.count)
        for (nx, ny) in inversionProbeCoords {
            guard let location = GlobeMath.unproject(x: nx, y: ny, centerLat: centerLat, centerLon: centerLon) else { continue }
            out.append(UnprojectedSample(nx: nx, ny: ny, lat: location.lat, lon: location.lon))
        }
        return out
    }

    /// Orthographic projection can choose the wrong side of the horizon closure for very
    /// large rings. A single center-point check is ambiguous for a large polygon and
    /// caused an occasional whole-disc fill, so compare several visible points with the
    /// original geographic ring and invert only when the opposite fill wins clearly.
    static func projectedFillNeedsInversion(
        polygon: [CGPoint],
        ring: GlobeRing,
        cx: Double,
        cy: Double,
        r: Double,
        centerLat: Double,
        centerLon: Double,
        samples: [UnprojectedSample]? = nil
    ) -> Bool {
        let resolvedSamples = samples ?? unprojectInversionSamples(centerLat: centerLat, centerLon: centerLon)
        var normalErrors = 0
        var invertedErrors = 0
        for sample in resolvedSamples {
            let geographicInside = ringContains(ring, lat: sample.lat, lon: sample.lon)
            let projectedInside = polygonContains(polygon, x: cx + sample.nx * r, y: cy + sample.ny * r)
            if projectedInside != geographicInside { normalErrors += 1 }
            if !projectedInside != geographicInside { invertedErrors += 1 }
        }
        return invertedErrors < normalErrors
    }

    /// Even-odd point-in-polygon test in screen space.
    static func polygonContains(_ polygon: [CGPoint], x: Double, y: Double) -> Bool {
        guard polygon.count >= 3, var previous = polygon.last else { return false }
        var inside = false
        for current in polygon {
            let cy = Double(current.y), py = Double(previous.y)
            if (cy > y) != (py > y) {
                let intersectionX = (Double(previous.x) - Double(current.x)) * (y - cy) / (py - cy) + Double(current.x)
                if x < intersectionX { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    /// Point-in-ring test in geographic space: counts the ring edges that cross the
    /// probe's meridian north of it. Each edge is followed the short way around, so a
    /// ring that wraps the antimeridian (Eurasia at Chukotka) has no false crossing at
    /// the ±180° seam. Comparing raw relative longitudes there misjudged whole oceans
    /// as inside Eurasia, which flipped its fill over the Pacific and Atlantic.
    static func ringContains(_ ring: GlobeRing, lat: Double, lon: Double) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var previousIndex = ring.count - 1
        for index in 0..<ring.count {
            let startLat = ring.lats[previousIndex]
            let endLat = ring.lats[index]
            let start = GlobeMath.normalizeLon(ring.lons[previousIndex] - lon)
            // Unbounded on purpose: the end only changes sign relative to the start
            // when the edge crosses the probe meridian, never when it crosses ±180°.
            let end = start + GlobeMath.normalizeLon(ring.lons[index] - ring.lons[previousIndex])
            if (start > 0) != (end > 0) {
                let t = start / (start - end)
                if startLat + (endLat - startLat) * t > lat { inside.toggle() }
            }
            previousIndex = index
        }
        return inside
    }
}
