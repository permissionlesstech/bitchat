//
// GlobeWorldData.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// A polygon ring or polyline on the globe, with projection terms prepared once.
struct GlobeRing: Sendable {
    let lats: [Double]
    let lons: [Double]
    let terms: [GlobeMath.Terms]

    var count: Int { lats.count }

    init(lats: [Double], lons: [Double]) {
        self.lats = lats
        self.lons = lons
        self.terms = zip(lats, lons).map { GlobeMath.Terms(lat: $0, lon: $1) }
    }
}

struct GlobeCity: Sendable {
    let name: String
    let rank: Int
    let capital: Bool
    let megacity: Bool
    /// The position, kept only as the projection terms the renderer reads.
    let terms: GlobeMath.Terms

    init(name: String, lat: Double, lon: Double, rank: Int, capital: Bool, megacity: Bool) {
        self.name = name
        self.rank = rank
        self.capital = capital
        self.megacity = megacity
        self.terms = GlobeMath.Terms(lat: lat, lon: lon)
    }
}

/// The bundled Natural Earth geometry (public domain) the globe draws: 110m land
/// polygons, admin-0 boundary lines and 50m populated places. The files are the
/// same ones the Android picker ships.
struct GlobeWorldData: Sendable {
    let land: [GlobeRing]
    let borders: [GlobeRing]
    let cities: [GlobeCity]

    /// Parsed on first access; callers load it off the main thread.
    static let bundled = GlobeWorldData(bundle: .main)

    init(land: [GlobeRing], borders: [GlobeRing], cities: [GlobeCity]) {
        self.land = land
        self.borders = borders
        self.cities = cities
    }

    private init(bundle: Bundle) {
        func data(_ name: String) -> Data? {
            bundle.url(forResource: name, withExtension: "geojson").flatMap { try? Data(contentsOf: $0) }
        }
        self.init(
            land: data("world_land").map(Self.parseLand) ?? [],
            borders: data("world_borders").map(Self.parseBorders) ?? [],
            cities: data("world_cities").map(Self.parseCities) ?? []
        )
    }

    /// Polygon and MultiPolygon geometries; every ring (outer and holes) becomes one entry.
    static func parseLand(_ data: Data) -> [GlobeRing] {
        var rings: [GlobeRing] = []
        for geometry in geometries(data) {
            switch geometry["type"] as? String {
            case "Polygon":
                appendRings(geometry["coordinates"], minimumPoints: 3, to: &rings)
            case "MultiPolygon":
                for polygon in geometry["coordinates"] as? [Any] ?? [] {
                    appendRings(polygon, minimumPoints: 3, to: &rings)
                }
            default:
                continue
            }
        }
        return rings
    }

    /// LineString and MultiLineString geometries.
    static func parseBorders(_ data: Data) -> [GlobeRing] {
        var lines: [GlobeRing] = []
        for geometry in geometries(data) {
            switch geometry["type"] as? String {
            case "LineString":
                appendRings([geometry["coordinates"] as Any], minimumPoints: 2, to: &lines)
            case "MultiLineString":
                appendRings(geometry["coordinates"], minimumPoints: 2, to: &lines)
            default:
                continue
            }
        }
        return lines
    }

    /// `{"cities": [{"n": name, "r": rank, "cap": 0|1, "mega": 0|1, "lat": .., "lon": ..}]}`
    static func parseCities(_ data: Data) -> [GlobeCity] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["cities"] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let name = entry["n"] as? String,
                  let lat = (entry["lat"] as? NSNumber)?.doubleValue,
                  let lon = (entry["lon"] as? NSNumber)?.doubleValue,
                  let rank = (entry["r"] as? NSNumber)?.intValue else { return nil }
            return GlobeCity(
                name: name,
                lat: lat,
                lon: lon,
                rank: rank,
                capital: (entry["cap"] as? NSNumber)?.intValue == 1,
                megacity: (entry["mega"] as? NSNumber)?.intValue == 1
            )
        }
    }

    private static func geometries(_ data: Data) -> [[String: Any]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return root["geometries"] as? [[String: Any]] ?? []
    }

    /// GeoJSON positions are [lon, lat].
    private static func appendRings(_ ringsJSON: Any?, minimumPoints: Int, to out: inout [GlobeRing]) {
        for ring in ringsJSON as? [Any] ?? [] {
            guard let points = ring as? [[NSNumber]], points.count >= minimumPoints else { continue }
            let valid = points.filter { $0.count >= 2 }
            guard valid.count >= minimumPoints else { continue }
            out.append(GlobeRing(lats: valid.map { $0[1].doubleValue }, lons: valid.map { $0[0].doubleValue }))
        }
    }
}
