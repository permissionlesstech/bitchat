import Foundation

/// Levels of location channels mapped to geohash precisions.
enum GeohashChannelLevel: CaseIterable, Codable, Equatable {
    case block
    case neighborhood
    case city
    case province   // previously .region
    case region     // previously .country

    /// Geohash length used for this level.
    var precision: Int {
        switch self {
        case .block: return 7
        case .neighborhood: return 6
        case .city: return 5
        case .province: return 4
        case .region: return 2
    }
    }

    var displayName: String {
        switch self {
        case .block: return "Block"
        case .neighborhood: return "Neighborhood"
        case .city: return "City"
        case .province: return "Province"
        case .region: return "Region"
    }
}
}
// Backward-compatible Codable for renamed cases
extension GeohashChannelLevel {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let raw = try? container.decode(String.self) {
            switch raw {
            case "block": self = .block
            case "neighborhood": self = .neighborhood
            case "city": self = .city
            case "region": self = .province      // old "region" maps to new .province
            case "country": self = .region       // old "country" maps to new .region
            case "province": self = .province
            default:
                self = .block
            }
        } else if let precision = try? container.decode(Int.self) {
            switch precision {
            case 7: self = .block
            case 6: self = .neighborhood
            case 5: self = .city
            case 4: self = .province
            case 0...3: self = .region
            default: self = .block
            }
        } else {
            self = .block
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .block: try container.encode("block")
        case .neighborhood: try container.encode("neighborhood")
        case .city: try container.encode("city")
        case .province: try container.encode("province")
        case .region: try container.encode("region")
        }
    }
}

/// A computed geohash channel option.
struct GeohashChannel: Codable, Equatable, Hashable, Identifiable {
    let level: GeohashChannelLevel
    let geohash: String

    var id: String { "\(level)-\(geohash)" }

    var displayName: String {
        "\(level.displayName) • \(geohash)"
    }
}

/// Identifier for current public chat channel (mesh or a location geohash).
enum ChannelID: Equatable, Codable {
    case mesh
    case location(GeohashChannel)

    /// Human readable name for UI.
    var displayName: String {
        switch self {
        case .mesh:
            return "Mesh"
        case .location(let ch):
            return ch.displayName
        }
    }

    /// Nostr tag value for scoping (geohash), if applicable.
    var nostrGeohashTag: String? {
        switch self {
        case .mesh: return nil
        case .location(let ch): return ch.geohash
        }
    }
}
