//
// GlobeMath.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Orthographic globe projection and geohash zoom math for the 3D globe picker.
///
/// The globe is rendered as a disc of radius R centered on screen. Points are
/// projected with an orthographic projection around a view center lat/lon.
enum GlobeMath {
    static let minZoom: Double = 1
    static let maxZoom: Double = 120_000
    static let maxPrecision = 12

    struct Projection: Equatable {
        /// Disc coordinates in units of globe radius, screen y down.
        let x: Double
        let y: Double
        /// Cosine of the angular distance from the view center; negative on the far side.
        let cosC: Double
    }

    /// Per-point sin/cos of latitude and longitude. Preparing these once removes
    /// nearly all trigonometry from animated frames.
    struct Terms: Sendable {
        let sinLat: Double
        let cosLat: Double
        let sinLon: Double
        let cosLon: Double

        init(lat: Double, lon: Double) {
            let latRadians = lat * .pi / 180
            let lonRadians = lon * .pi / 180
            sinLat = sin(latRadians)
            cosLat = cos(latRadians)
            sinLon = sin(lonRadians)
            cosLon = cos(lonRadians)
        }
    }

    /// Frame-local projector for prepared static geometry: center terms are calculated once.
    struct PreparedProjector {
        private let sinCenterLat: Double
        private let cosCenterLat: Double
        private let sinCenterLon: Double
        private let cosCenterLon: Double

        init(centerLat: Double, centerLon: Double) {
            let latRadians = centerLat * .pi / 180
            let lonRadians = centerLon * .pi / 180
            sinCenterLat = sin(latRadians)
            cosCenterLat = cos(latRadians)
            sinCenterLon = sin(lonRadians)
            cosCenterLon = cos(lonRadians)
        }

        func project(_ terms: Terms) -> Projection {
            let sinDeltaLon = terms.sinLon * cosCenterLon - terms.cosLon * sinCenterLon
            let cosDeltaLon = terms.cosLon * cosCenterLon + terms.sinLon * sinCenterLon
            return Projection(
                x: terms.cosLat * sinDeltaLon,
                y: -(cosCenterLat * terms.sinLat - sinCenterLat * terms.cosLat * cosDeltaLon),
                cosC: sinCenterLat * terms.sinLat + cosCenterLat * terms.cosLat * cosDeltaLon
            )
        }
    }

    /// Projects (lat, lon) onto the view disc of a globe centered at (centerLat, centerLon).
    /// `cosC` is negative when the point is on the far side of the sphere.
    static func projectRaw(lat: Double, lon: Double, centerLat: Double, centerLon: Double) -> Projection {
        let phi = lat * .pi / 180
        let phi0 = centerLat * .pi / 180
        let dLambda = normalizeLon(lon - centerLon) * .pi / 180
        let cosC = sin(phi0) * sin(phi) + cos(phi0) * cos(phi) * cos(dLambda)
        let x = cos(phi) * sin(dLambda)
        let y = -(cos(phi0) * sin(phi) - sin(phi0) * cos(phi) * cos(dLambda))
        return Projection(x: x, y: y, cosC: cosC)
    }

    /// Like `projectRaw` but nil when the point is behind the limb.
    static func project(lat: Double, lon: Double, centerLat: Double, centerLon: Double) -> Projection? {
        let p = projectRaw(lat: lat, lon: lon, centerLat: centerLat, centerLon: centerLon)
        return p.cosC >= 0 ? p : nil
    }

    /// Inverse projection: disc coordinates (units of radius, screen y down) back to lat/lon.
    /// Returns nil if the point lies outside the disc.
    static func unproject(x: Double, y: Double, centerLat: Double, centerLon: Double) -> (lat: Double, lon: Double)? {
        let rho = (x * x + y * y).squareRoot()
        if rho > 1 { return nil }
        let c = asin(min(1, max(-1, rho)))
        let phi0 = centerLat * .pi / 180
        let sinC = sin(c)
        let cosC = cos(c)
        let lat: Double
        let lonOffset: Double
        if rho < 1e-9 {
            lat = centerLat
            lonOffset = 0
        } else {
            lat = asin(cosC * sin(phi0) + (-y) * sinC * cos(phi0) / rho) * 180 / .pi
            lonOffset = atan2(x * sinC, rho * cos(phi0) * cosC - (-y) * sin(phi0) * sinC) * 180 / .pi
        }
        return (lat, normalizeLon(centerLon + lonOffset))
    }

    static func normalizeLon(_ lon: Double) -> Double {
        var x = lon.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 }
        if x < -180 { x += 360 }
        return x
    }

    /// Longitude span of a geohash cell in degrees.
    static func cellSpanLon(precision: Int) -> Double {
        360 / pow(2, (5 * Double(precision) / 2).rounded(.up))
    }

    /// Latitude span of a geohash cell in degrees.
    static func cellSpanLat(precision: Int) -> Double {
        180 / pow(2, (5 * Double(precision) / 2).rounded(.down))
    }

    /// Picks the geohash precision whose cells render at a comfortable on-screen size
    /// for the current zoom: the largest precision whose cell is at least ~22% of the
    /// screen's smallest dimension.
    static func autoPrecision(globeRadius: Double, screenMin: Double) -> Int {
        let target = screenMin * 0.22
        var best = 1
        for p in 1...maxPrecision {
            let span = cellSpanLat(precision: p) * .pi / 180 * globeRadius
            if span >= target { best = p } else { break }
        }
        return min(max(best, 1), maxPrecision)
    }

    /// Zoom factor (globe radius multiplier over the fit-to-screen base radius) that frames
    /// a cell of the given precision nicely: the cell spans ~1/3 of the screen.
    static func zoomForPrecision(_ precision: Int, baseRadius: Double, screenMin: Double) -> Double {
        let spanRadians = cellSpanLat(precision: precision) * .pi / 180
        let targetRadius = (screenMin / 3) / spanRadians
        return min(max(targetRadius / baseRadius, minZoom), maxZoom)
    }
}
