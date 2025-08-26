import Foundation

/// Levels of location channels mapped to geohash precisions.
enum GeohashChannelLevel: CaseIterable, Codable, Equatable {
    case block
    case neighborhood
    case city
    case region
    case country

    /// Geohash length used for this level.
    var precision: Int {
        switch self {
        case .block: return 7
        case .neighborhood: return 6
        case .city: return 5
        case .region: return 4
        case .country: return 2
        }
    }

    var displayName: String {
        switch self {
        case .block: return String(localized: "location.level.block")
        case .neighborhood: return String(localized: "location.level.neighborhood")
        case .city: return String(localized: "location.level.city")
        case .region: return String(localized: "location.level.region")
        case .country: return String(localized: "location.level.country")
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
            return String(localized: "channel.mesh")
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
