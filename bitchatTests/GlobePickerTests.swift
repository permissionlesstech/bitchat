import CoreGraphics
import Foundation
import Testing
@testable import bitchat

struct GlobeMathTests {
    @Test func preparedProjectorMatchesReferenceProjection() {
        let centers: [(Double, Double)] = [(0, 0), (45.25, 12.5), (-72, 179.5)]
        let points: [(Double, Double)] = [(0, 0), (51.5074, -0.1278), (-33.8688, 151.2093), (89, -179.9)]
        for (centerLat, centerLon) in centers {
            let projector = GlobeMath.PreparedProjector(centerLat: centerLat, centerLon: centerLon)
            for (lat, lon) in points {
                let actual = projector.project(GlobeMath.Terms(lat: lat, lon: lon))
                let expected = GlobeMath.projectRaw(lat: lat, lon: lon, centerLat: centerLat, centerLon: centerLon)
                #expect(abs(expected.x - actual.x) < 1e-9)
                #expect(abs(expected.y - actual.y) < 1e-9)
                #expect(abs(expected.cosC - actual.cosC) < 1e-9)
            }
        }
    }

    @Test func unprojectInvertsProjection() throws {
        let p = GlobeMath.projectRaw(lat: 48.2, lon: 16.4, centerLat: 40, centerLon: 10)
        let location = try #require(GlobeMath.unproject(x: p.x, y: p.y, centerLat: 40, centerLon: 10))
        #expect(abs(location.lat - 48.2) < 1e-9)
        #expect(abs(location.lon - 16.4) < 1e-9)
        #expect(GlobeMath.unproject(x: 0.9, y: 0.9, centerLat: 0, centerLon: 0) == nil)
    }

    @Test func zoomForPrecisionStaysWithinInteractiveBounds() {
        for precision in 1...GlobeMath.maxPrecision {
            let zoom = GlobeMath.zoomForPrecision(precision, baseRadius: 400, screenMin: 900)
            #expect(zoom >= GlobeMath.minZoom)
            #expect(zoom <= GlobeMath.maxZoom)
        }
    }

    /// The +/- buttons frame a precision; the pinch-driven precision must agree, or the
    /// first pinch after a button tap would jump to another cell size.
    @Test func autoPrecisionAgreesWithFramedPrecision() {
        let base = 400.0, screen = 900.0
        for precision in 2...GlobeMath.maxPrecision {
            let zoom = GlobeMath.zoomForPrecision(precision, baseRadius: base, screenMin: screen)
            guard zoom > GlobeMath.minZoom, zoom < GlobeMath.maxZoom else { continue }
            #expect(GlobeMath.autoPrecision(globeRadius: base * zoom, screenMin: screen) == precision)
        }
    }

    @Test func cellSpansMatchGeohashBounds() {
        for precision in 1...8 {
            let b = Geohash.decodeBounds(Geohash.encode(latitude: 10, longitude: 10, precision: precision))
            #expect(abs((b.latMax - b.latMin) - GlobeMath.cellSpanLat(precision: precision)) < 1e-9)
            #expect(abs((b.lonMax - b.lonMin) - GlobeMath.cellSpanLon(precision: precision)) < 1e-9)
        }
    }
}

struct GlobeGeometryTests {
    private let square = [
        GlobeGeometry.DiscPoint(x: -0.5, y: -0.5, front: true),
        GlobeGeometry.DiscPoint(x: 0.5, y: -0.5, front: true),
        GlobeGeometry.DiscPoint(x: 0.5, y: 0.5, front: true),
        GlobeGeometry.DiscPoint(x: -0.5, y: 0.5, front: true)
    ]

    @Test func closedFullyVisibleRingConnectsLastPointToFirst() throws {
        let runs = GlobeGeometry.frontRuns(square, closed: true)
        let run = try #require(runs.first)
        #expect(runs.count == 1)
        #expect(run.count == square.count + 1)
        #expect(run.first == run.last)
    }

    @Test func openFullyVisibleLineDoesNotConnectLastPointToFirst() throws {
        let runs = GlobeGeometry.frontRuns(square, closed: false)
        let run = try #require(runs.first)
        #expect(runs.count == 1)
        #expect(run.count == square.count)
        #expect(run.first != run.last)
    }

    @Test func ringCrossingTheLimbSplitsIntoFrontRuns() {
        let pts = [
            GlobeGeometry.DiscPoint(x: -0.5, y: 0, front: true),
            GlobeGeometry.DiscPoint(x: 0, y: 0, front: true),
            GlobeGeometry.DiscPoint(x: 0.5, y: 0, front: false),
            GlobeGeometry.DiscPoint(x: 0.2, y: 0.2, front: true)
        ]
        let runs = GlobeGeometry.frontRuns(pts, closed: false)
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0.count >= 2 })
    }

    @Test func polygonContainsDistinguishesInsideAndOutsidePoints() {
        let polygon = [CGPoint(x: -10, y: -10), CGPoint(x: 10, y: -10), CGPoint(x: 10, y: 10), CGPoint(x: -10, y: 10)]
        #expect(GlobeGeometry.polygonContains(polygon, x: 0, y: 0))
        #expect(!GlobeGeometry.polygonContains(polygon, x: 20, y: 0))
    }

    @Test func ringContainsDistinguishesInsideAndOutsideCoordinates() {
        let ring = GlobeRing(lats: [-10, -10, 10, 10], lons: [-10, 10, 10, -10])
        #expect(GlobeGeometry.ringContains(ring, lat: 0, lon: 0))
        #expect(!GlobeGeometry.ringContains(ring, lat: 20, lon: 0))
    }

    @Test func ringContainsHandlesTheAntimeridian() {
        let ring = GlobeRing(lats: [-10, -10, 10, 10], lons: [170, -170, -170, 170])
        #expect(GlobeGeometry.ringContains(ring, lat: 0, lon: 180))
        #expect(GlobeGeometry.ringContains(ring, lat: 0, lon: -175))
        #expect(!GlobeGeometry.ringContains(ring, lat: 20, lon: 180))
        #expect(!GlobeGeometry.ringContains(ring, lat: 0, lon: 0))
    }

    @Test func clipSegmentClampsToRect() throws {
        let rect = GlobeGeometry.ClipRect(left: 0, top: 0, right: 10, bottom: 10)
        let clipped = try #require(GlobeGeometry.clipSegment(CGPoint(x: -10, y: 5), CGPoint(x: 20, y: 5), to: rect))
        #expect(clipped.0 == CGPoint(x: 0, y: 5))
        #expect(clipped.1 == CGPoint(x: 10, y: 5))
        #expect(GlobeGeometry.clipSegment(CGPoint(x: -10, y: -5), CGPoint(x: 20, y: -5), to: rect) == nil)
    }

    @Test func clipPolygonKeepsOnlyTheVisiblePart() {
        let rect = GlobeGeometry.ClipRect(left: 0, top: 0, right: 10, bottom: 10)
        let clipped = GlobeGeometry.clipPolygon(
            [CGPoint(x: -5, y: -5), CGPoint(x: 15, y: -5), CGPoint(x: 15, y: 15), CGPoint(x: -5, y: 15)],
            to: rect
        )
        #expect(clipped.count == 4)
        #expect(clipped.allSatisfy { $0.x >= 0 && $0.x <= 10 && $0.y >= 0 && $0.y <= 10 })
    }

    @Test func smallVisibleRingIsNotInverted() {
        let ring = GlobeRing(lats: [-10, -10, 10, 10], lons: [-10, 10, 10, -10])
        let projector = GlobeMath.PreparedProjector(centerLat: 0, centerLon: 0)
        let pts = ring.terms.map { terms -> GlobeGeometry.DiscPoint in
            let p = projector.project(terms)
            return GlobeGeometry.DiscPoint(x: p.x, y: p.y, front: p.cosC > 0.005)
        }
        let polygon = GlobeGeometry.fillPolygon(pts, cx: 100, cy: 100, r: 100)
        #expect(!GlobeGeometry.projectedFillNeedsInversion(
            polygon: polygon, ring: ring, cx: 100, cy: 100, r: 100, centerLat: 0, centerLon: 0
        ))
    }
}

struct GlobeMotionDetailTests {
    @Test func fullDetailPreservesAllGlobeFeatures() {
        let detail = GlobeMotionDetail.full.frame
        #expect(detail.landPointStride == 1)
        #expect(detail.showBorders)
        #expect(detail.showCityLabels)
    }

    @Test func balancedDetailPreservesOrientationAndSelection() {
        let detail = GlobeMotionDetail.balanced.frame
        #expect(detail.landPointStride == 2)
        #expect(detail.showBorders)
        #expect(!detail.showCityLabels)
    }

    @Test func fastDetailUsesMinimumMovingFrameWork() {
        let detail = GlobeMotionDetail.fast.frame
        #expect(detail.landPointStride == 2)
        #expect(!detail.showBorders)
        #expect(!detail.showCityLabels)
    }

    @Test func adaptiveDetailDegradesOnSlowFramesAndRecoversWithHysteresis() {
        #expect(GlobeMotionDetail.full.next(averageFrameMillis: 24) == .balanced)
        #expect(GlobeMotionDetail.balanced.next(averageFrameMillis: 32) == .fast)
        #expect(GlobeMotionDetail.fast.next(averageFrameMillis: 17) == .balanced)
        #expect(GlobeMotionDetail.balanced.next(averageFrameMillis: 17) == .full)
        #expect(GlobeMotionDetail.balanced.next(averageFrameMillis: 20) == .balanced)
        #expect(GlobeMotionDetail.full.next(averageFrameMillis: .nan) == .fast)
    }

    private func record(_ governor: inout GlobeMotionGovernor, frames: Int, millis: Double) -> [GlobeMotionDetail] {
        (0..<frames).map { _ in
            governor.recordFrame(millis: millis)
            return governor.detail
        }
    }

    /// Regression: dropping detail makes frames fast, and stepping back up mid-drag
    /// made the grid, neighbor cells and labels flash on and off.
    @Test func detailNeverStepsBackUpDuringOneMotion() {
        var governor = GlobeMotionGovernor()
        #expect(governor.detail == .full)
        governor.beginSession()
        #expect(governor.detail == .balanced)
        var seen = record(&governor, frames: 8, millis: 33)
        seen += record(&governor, frames: 64, millis: 8)
        seen += record(&governor, frames: 8, millis: 33)
        seen += record(&governor, frames: 64, millis: 8)
        #expect(seen.contains(.fast))
        // Monotonic: once a level is dropped it never returns within the session.
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $1 <= $0 })
        governor.endSession()
        #expect(governor.detail == .full)
    }

    @Test func smoothSessionsStartTheNextOneHigherUntilOneDegrades() {
        var governor = GlobeMotionGovernor()
        governor.beginSession()
        _ = record(&governor, frames: 16, millis: 8)
        governor.endSession()
        governor.beginSession()
        #expect(governor.detail == .full)
        _ = record(&governor, frames: 8, millis: 26)
        #expect(governor.detail == .balanced)
        governor.endSession()
        // Having failed once, later smooth sessions stop retrying the upgrade, so
        // detail doesn't alternate from one gesture to the next.
        for _ in 0..<3 {
            governor.beginSession()
            #expect(governor.detail == .balanced)
            _ = record(&governor, frames: 16, millis: 8)
            governor.endSession()
        }
    }

    @Test func easingRunsFromZeroToOneMonotonically() {
        #expect(GlobeEasing.fastOutSlowIn(0) == 0)
        #expect(GlobeEasing.fastOutSlowIn(1) == 1)
        var previous = 0.0
        for step in 1...20 {
            let value = GlobeEasing.fastOutSlowIn(Double(step) / 20)
            #expect(value >= previous)
            previous = value
        }
        #expect(GlobeEasing.fastOutSlowIn(0.5) > 0.7)
    }
}

@MainActor
struct GlobeStateTests {
    @Test func selectionFollowsTheViewCenterOnceLaidOut() {
        let state = GlobeState(targetLat: 48.2, targetLon: 16.4, initialPrecision: 4, startZoomedOut: false)
        #expect(state.selectedGeohash.isEmpty)
        state.setViewport(baseRadius: 170, screenMin: 390)
        #expect(state.selectedGeohash == Geohash.encode(latitude: 48.2, longitude: 16.4, precision: 4))
    }

    @Test func introWithoutAnimationJumpsStraightToTheTarget() {
        let state = GlobeState(targetLat: 37.77, targetLon: -122.42, initialPrecision: 5, startZoomedOut: true)
        state.setViewport(baseRadius: 170, screenMin: 390, animateIntro: false)
        #expect(state.precision == 5)
        #expect(state.selectedGeohash == Geohash.encode(latitude: 37.77, longitude: -122.42, precision: 5))
        #expect(!state.isAnimating)
    }

    @Test func pinchingInRaisesPrecisionAndRotationClampsNearThePoles() {
        let state = GlobeState(targetLat: 0, targetLon: 0, initialPrecision: 1, startZoomedOut: false)
        state.setViewport(baseRadius: 170, screenMin: 390)
        let before = state.precision
        state.zoomBy(64)
        #expect(state.precision > before)
        state.rotateBy(dx: 0, dy: 1_000_000)
        #expect(state.centerLat <= 89)
        #expect(state.selectedGeohash.count == state.precision)
    }

    @Test func zoomStaysWithinBounds() {
        let state = GlobeState(targetLat: 0, targetLon: 0, initialPrecision: 2, startZoomedOut: false)
        state.setViewport(baseRadius: 170, screenMin: 390)
        state.zoomBy(0.0001)
        #expect(state.zoom == GlobeMath.minZoom)
        state.zoomBy(1e12)
        #expect(state.zoom == GlobeMath.maxZoom)
        // Pinching tops out around block-sized cells; finer precision is button-only.
        #expect(state.precision == GlobeMath.autoPrecision(globeRadius: state.globeRadius, screenMin: 390))
        #expect(state.precision >= 7)
    }

    @Test func interactionCancelsAnimationsAndRestoresFullDetail() {
        let state = GlobeState(targetLat: 0, targetLon: 0, initialPrecision: 2, startZoomedOut: false)
        state.setViewport(baseRadius: 170, screenMin: 390)
        state.animatePrecision(4)
        #expect(state.isAnimating)
        #expect(state.motionDetail == .balanced)
        state.beginInteraction()
        #expect(!state.isAnimating)
        #expect(state.isInteracting)
        state.endInteraction()
        #expect(!state.isInMotion)
        #expect(state.motionDetail == .full)
        #expect(state.frameDetail == GlobeMotionDetail.full.frame)
    }

    @Test func releasingIntoAFlingKeepsTheSameMotionSession() {
        let state = GlobeState(targetLat: 0, targetLon: 0, initialPrecision: 2, startZoomedOut: false)
        state.setViewport(baseRadius: 170, screenMin: 390)
        state.beginInteraction()
        #expect(state.motionDetail == .balanced)
        state.endInteraction(flingVelocityX: 800, flingVelocityY: 0)
        #expect(!state.isInteracting)
        #expect(state.isAnimating)
        #expect(state.motionDetail == .balanced)
        state.beginInteraction()
        #expect(!state.isAnimating)
        #expect(state.motionDetail == .balanced)
        state.endInteraction()
        #expect(state.motionDetail == .full)
    }

    /// Review regression (PR #1807): `zzzz`'s center is 89.91°, past the ±89° drag
    /// limit. The animated intro used to clamp there and select `zzzf`, while the
    /// Reduce Motion path kept `zzzz`.
    @Test func polarIntroLandsOnTheRequestedCellWithAndWithoutAnimation() {
        let target = GeohashPickerView.initialTarget(initialGeohash: "zzzz", nearbyGeohashes: [])
        #expect(target.lat > 89)

        let animated = GlobeState(targetLat: target.lat, targetLon: target.lon, initialPrecision: target.precision, startZoomedOut: true)
        animated.setViewport(baseRadius: 170, screenMin: 390, animateIntro: true)
        #expect(animated.isAnimating)
        animated.tick(100)
        animated.tick(110)
        #expect(!animated.isAnimating)
        #expect(animated.selectedGeohash == "zzzz")

        let still = GlobeState(targetLat: target.lat, targetLon: target.lon, initialPrecision: target.precision, startZoomedOut: true)
        still.setViewport(baseRadius: 170, screenMin: 390, animateIntro: false)
        #expect(still.selectedGeohash == "zzzz")
        #expect(still.centerLat == animated.centerLat)
    }

    @Test func draggingFromAPolarTargetNeverSnapsBackToTheDragLimit() {
        let center = Geohash.decodeCenter("zzzz")
        let state = GlobeState(targetLat: center.lat, targetLon: center.lon, initialPrecision: 4, startZoomedOut: false)
        state.setViewport(baseRadius: 170, screenMin: 390)
        let start = state.centerLat
        state.rotateBy(dx: 0, dy: 50)
        #expect(state.centerLat == start)
        state.rotateBy(dx: 0, dy: -0.01)
        #expect(state.centerLat < start)
        #expect(state.centerLat > 89)
        state.rotateBy(dx: 0, dy: -1_000_000)
        #expect(state.centerLat == -89)
    }

    @Test func slowFlingsAreIgnored() {
        let state = GlobeState(targetLat: 0, targetLon: 0, initialPrecision: 2, startZoomedOut: false)
        state.setViewport(baseRadius: 170, screenMin: 390)
        state.fling(vx: 10, vy: -10)
        #expect(!state.isAnimating)
        state.fling(vx: 800, vy: 0)
        #expect(state.isAnimating)
        state.cancelAnimations()
    }
}

struct GlobeWorldDataTests {
    private static let landURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("bitchat/Resources/Globe/world_land.geojson")

    /// Regression: Eurasia wraps the antimeridian at Chukotka, and the old relative-
    /// longitude test counted the ±180° seam as a crossing, so open ocean read as
    /// inside Eurasia and its fill was flipped over the Pacific and Atlantic.
    @Test func bundledLandClassifiesOceansAndContinents() throws {
        let land = GlobeWorldData.parseLand(try Data(contentsOf: Self.landURL))
        #expect(land.count > 100)
        func isLand(_ lat: Double, _ lon: Double) -> Bool {
            land.contains { GlobeGeometry.ringContains($0, lat: lat, lon: lon) }
        }
        for (lat, lon) in [(0.0, -150.0), (32.3, -64.8), (40.0, -50.0), (-30.0, 80.0), (10.0, -30.0), (60.0, -85.0)] {
            #expect(!isLand(lat, lon), "ocean at \(lat),\(lon) read as land")
        }
        for (lat, lon) in [(55.75, 37.62), (64.7, 177.5), (39.9, 116.4), (39.0, -98.0), (-15.8, -47.9), (0.0, 20.0)] {
            #expect(isLand(lat, lon), "land at \(lat),\(lon) read as ocean")
        }
    }

    /// No visible ocean pixel may be painted by a land fill, from any vantage point.
    @Test func landFillsLeaveVisibleOceanUncovered() throws {
        let land = GlobeWorldData.parseLand(try Data(contentsOf: Self.landURL))
        let size = CGSize(width: 402, height: 874)
        let cx = 201.0, cy = 437.0
        let clip = GlobeGeometry.ClipRect(size: size)
        let oceans: [(Double, Double)] = [(32.3, -64.8), (40, -50), (30, -20), (0, -150), (-30, 80)]
        for centerLat in stride(from: -60.0, through: 60, by: 30) {
            for centerLon in stride(from: -180.0, to: 180, by: 30) {
                for zoom in [1.0, 3, 8] {
                    let r = 0.44 * 402 * zoom
                    let projector = GlobeMath.PreparedProjector(centerLat: centerLat, centerLon: centerLon)
                    for ocean in oceans {
                        guard let p = GlobeMath.project(lat: ocean.0, lon: ocean.1, centerLat: centerLat, centerLon: centerLon),
                              (p.x * p.x + p.y * p.y).squareRoot() < 0.98 else { continue }
                        let point = CGPoint(x: cx + p.x * r, y: cy + p.y * r)
                        guard CGRect(origin: .zero, size: size).contains(point) else { continue }
                        for ring in land {
                            let projected = ring.terms.map { projector.project($0) }
                            guard projected.contains(where: { $0.cosC >= 0 }) else { continue }
                            let pts = projected.map { GlobeGeometry.DiscPoint(x: $0.x, y: $0.y, front: $0.cosC > 0.005) }
                            let polygon = GlobeGeometry.fillPolygon(pts, cx: cx, cy: cy, r: r)
                            let invert = projected.contains(where: { $0.cosC < 0 }) && GlobeGeometry.projectedFillNeedsInversion(
                                polygon: polygon, ring: ring, cx: cx, cy: cy, r: r, centerLat: centerLat, centerLon: centerLon
                            )
                            let clipped = GlobeGeometry.clipPolygon(polygon, to: clip)
                            guard clipped.count >= 3 else { continue }
                            let path = CGMutablePath()
                            if invert { path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)) }
                            path.addLines(between: clipped)
                            path.closeSubpath()
                            #expect(
                                !path.contains(point, using: invert ? .evenOdd : .winding),
                                "ocean \(ocean) painted as land viewing \(centerLat),\(centerLon) at zoom \(zoom)"
                            )
                        }
                    }
                }
            }
        }
    }

    @Test func parsesPolygonsMultiPolygonsAndLines() {
        let land = Data("""
        {"type":"GeometryCollection","geometries":[
          {"type":"Polygon","coordinates":[[[0,0],[10,0],[10,10],[0,0]]]},
          {"type":"MultiPolygon","coordinates":[[[[20,20],[30,20],[30,30],[20,20]]],[[[1,1],[2,2]]]]}
        ]}
        """.utf8)
        let rings = GlobeWorldData.parseLand(land)
        #expect(rings.count == 2)
        // GeoJSON positions are [lon, lat].
        #expect(rings[0].lons == [0, 10, 10, 0])
        #expect(rings[0].lats == [0, 0, 10, 0])
        #expect(rings[0].terms.count == rings[0].count)

        let borders = Data("""
        {"type":"GeometryCollection","geometries":[
          {"type":"LineString","coordinates":[[0,0],[1,1]]},
          {"type":"MultiLineString","coordinates":[[[2,2],[3,3],[4,4]],[[5,5]]]}
        ]}
        """.utf8)
        let lines = GlobeWorldData.parseBorders(borders)
        #expect(lines.map(\.count) == [2, 3])
    }

    @Test func parsesCities() {
        let cities = GlobeWorldData.parseCities(Data("""
        {"cities":[{"n":"Vienna","r":1,"cap":1,"mega":0,"pop":1,"lon":16.37,"lat":48.2},{"n":"broken"}]}
        """.utf8))
        #expect(cities.count == 1)
        #expect(cities[0].name == "Vienna")
        #expect(cities[0].capital)
        #expect(!cities[0].megacity)
        #expect(abs(cities[0].terms.sinLat - sin(48.2 * .pi / 180)) < 1e-12)
        #expect(abs(cities[0].terms.sinLon - sin(16.37 * .pi / 180)) < 1e-12)
    }
}

@MainActor
struct GeohashPickerTargetTests {
    @Test func prefersTheGivenGeohash() {
        let target = GeohashPickerView.initialTarget(initialGeohash: "u2edk", nearbyGeohashes: ["u2"])
        let center = Geohash.decodeCenter("u2edk")
        #expect(target.lat == center.lat)
        #expect(target.lon == center.lon)
        #expect(target.precision == 5)
    }

    @Test func fallsBackToTheCoarsestNearbyChannel() {
        let target = GeohashPickerView.initialTarget(initialGeohash: "", nearbyGeohashes: ["u2edk", "u2e", "u2edk7q"])
        #expect(target.precision == 3)
        #expect(target.lat == Geohash.decodeCenter("u2e").lat)
    }

    @Test func defaultsToAWideWorldView() {
        let target = GeohashPickerView.initialTarget(initialGeohash: nil, nearbyGeohashes: [])
        #expect(target.lat == 20)
        #expect(target.lon == 0)
        #expect(target.precision == 2)
    }

    @Test func coverageMatchesTheChannelLevels() {
        #expect(GeohashCoverage.level(forLength: 1) == .region)
        #expect(GeohashCoverage.level(forLength: 4) == .province)
        #expect(GeohashCoverage.level(forLength: 5) == .city)
        #expect(GeohashCoverage.level(forLength: 12) == .building)
        #expect(GeohashCoverage.string(forPrecision: 5, locale: Locale(identifier: "de_DE")) == "~4.9 km")
        #expect(GeohashCoverage.string(forPrecision: 2, locale: Locale(identifier: "en_US")) == "~777 mi")
    }
}
