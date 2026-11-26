import Foundation

/// Lightweight Geohash encoder used for Location Channels.
/// Encodes latitude/longitude to base32 geohash with a fixed precision.
enum Geohash {
    private static let base32Bytes: [UInt8] = Array("0123456789bcdefghjkmnpqrstuvwxyz".utf8)
    private static let base32DecodeTable: [Int8] = {
        var table = [Int8](repeating: -1, count: 128)
        for (i, byte) in base32Bytes.enumerated() {
            table[Int(byte)] = Int8(i)
            // Also map uppercase ASCII letters directly to avoid allocating `.lowercased()`
            if byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z") {
                table[Int(byte - 32)] = Int8(i)
            }
        }
        return table
    }()

    /// Validates a geohash string at any channel precision (1-12 characters).
    /// - Parameter geohash: The geohash string to validate
    /// - Returns: true if a non-empty base32 geohash of at most 12 characters
    static func isValidGeohash(_ geohash: String) -> Bool {
        let utf8 = geohash.utf8
        let count = utf8.count
        guard count >= 1 && count <= 12 else { return false }
        for byte in utf8 {
            guard byte < 128 && base32DecodeTable[Int(byte)] >= 0 else { return false }
        }
        return true
    }

    /// Encodes the provided coordinates into a geohash string.
    /// - Parameters:
    ///   - latitude: Latitude in degrees (-90...90)
    ///   - longitude: Longitude in degrees (-180...180)
    ///   - precision: Number of geohash characters (2-12 typical). Values <= 0 return an empty string.
    /// - Returns: Base32 geohash string of length `precision`.
    static func encode(latitude: Double, longitude: Double, precision: Int) -> String {
        guard precision > 0 else { return "" }

        var latMin = -90.0
        var latMax = 90.0
        var lonMin = -180.0
        var lonMax = 180.0

        var isEven = true
        var bit = 0
        var ch = 0

        let lat = max(-90.0, min(90.0, latitude))
        let lon = max(-180.0, min(180.0, longitude))

        return String(unsafeUninitializedCapacity: precision) { buffer in
            var idx = 0
            while idx < precision {
                if isEven {
                    let mid = (lonMin + lonMax) * 0.5
                    if lon >= mid {
                        ch |= (1 << (4 - bit))
                        lonMin = mid
                    } else {
                        lonMax = mid
                    }
                } else {
                    let mid = (latMin + latMax) * 0.5
                    if lat >= mid {
                        ch |= (1 << (4 - bit))
                        latMin = mid
                    } else {
                        latMax = mid
                    }
                }

                isEven.toggle()
                if bit < 4 {
                    bit += 1
                } else {
                    buffer[idx] = base32Bytes[ch]
                    idx += 1
                    bit = 0
                    ch = 0
                }
            }
            return idx
        }
    }

    /// Decodes a geohash into the center latitude/longitude of its bounding box.
    /// - Parameter geohash: Base32 geohash string.
    /// - Returns: (lat, lon) center coordinate.
    static func decodeCenter(_ geohash: String) -> (lat: Double, lon: Double) {
        let bounds = decodeBounds(geohash)
        return ((bounds.latMin + bounds.latMax) * 0.5, (bounds.lonMin + bounds.lonMax) * 0.5)
    }

    /// Decodes a geohash into its latitude and longitude bounds.
    /// - Parameter geohash: Base32 geohash string.
    /// - Returns: (latMin, latMax, lonMin, lonMax)
    static func decodeBounds(_ geohash: String) -> (latMin: Double, latMax: Double, lonMin: Double, lonMax: Double) {
        var latMin = -90.0
        var latMax = 90.0
        var lonMin = -180.0
        var lonMax = 180.0

        var isEven = true
        for byte in geohash.utf8 {
            guard byte < 128 else { continue }
            let cd = Int(base32DecodeTable[Int(byte)])
            guard cd >= 0 else { continue }
            var mask = 16
            while mask > 0 {
                if isEven {
                    let mid = (lonMin + lonMax) * 0.5
                    if (cd & mask) != 0 { lonMin = mid } else { lonMax = mid }
                } else {
                    let mid = (latMin + latMax) * 0.5
                    if (cd & mask) != 0 { latMin = mid } else { latMax = mid }
                }
                isEven.toggle()
                mask >>= 1
            }
        }
        return (latMin, latMax, lonMin, lonMax)
    }

    /// Returns all 8 neighboring geohash cells at the same precision.
    /// - Parameter geohash: Base32 geohash string.
    /// - Returns: Array of 8 neighboring geohashes (N, NE, E, SE, S, SW, W, NW order).
    static func neighbors(of geohash: String) -> [String] {
        guard !geohash.isEmpty else { return [] }

        let precision = geohash.count
        let bounds = decodeBounds(geohash)
        let centerLat = (bounds.latMin + bounds.latMax) * 0.5
        let centerLon = (bounds.lonMin + bounds.lonMax) * 0.5

        // Calculate cell dimensions
        let latHeight = bounds.latMax - bounds.latMin
        let lonWidth = bounds.lonMax - bounds.lonMin

        // Helper to wrap longitude around ±180
        func wrapLongitude(_ lon: Double) -> Double {
            var wrapped = lon
            while wrapped > 180.0 { wrapped -= 360.0 }
            while wrapped < -180.0 { wrapped += 360.0 }
            return wrapped
        }

        // Calculate 8 neighbor centers
        let offsets: [(dLat: Double, dLon: Double)] = [
            (latHeight, 0),            // N
            (latHeight, lonWidth),     // NE
            (0, lonWidth),             // E
            (-latHeight, lonWidth),    // SE
            (-latHeight, 0),           // S
            (-latHeight, -lonWidth),   // SW
            (0, -lonWidth),            // W
            (latHeight, -lonWidth)     // NW
        ]

        var result: [String] = []
        result.reserveCapacity(8)
        for (dLat, dLon) in offsets {
            let rawLat = centerLat + dLat
            // Skip if we've crossed a pole
            if rawLat > 90.0 || rawLat < -90.0 {
                continue
            }
            let lon = wrapLongitude(centerLon + dLon)
            result.append(encode(latitude: rawLat, longitude: lon, precision: precision))
        }
        return result
    }
}
