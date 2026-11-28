import Foundation

enum NostrRequest: Encodable {
    case event(NostrEvent)
    case subscribe(id: String, filters: [NostrFilter])
    case close(id: String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()

        switch self {
        case .event(let event):
            try container.encode("EVENT")
            try container.encode(event)

        case .subscribe(let id, let filters):
            try container.encode("REQ")
            try container.encode(id)
            for filter in filters {
                try container.encode(filter)
            }

        case .close(let id):
            try container.encode("CLOSE")
            try container.encode(id)
        }
    }
}

struct NostrFilter: Encodable {
    var ids: [String]?
    var authors: [String]?
    var kinds: [Int]?
    var since: Int?
    var until: Int?
    var limit: Int?

    // Tag filters - stored internally but encoded specially
    fileprivate var tagFilters: [String: [String]]?

    init() {
        // Default initializer
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)

        // Encode standard fields
        if let ids = ids { try container.encode(ids, forKey: DynamicCodingKey(stringValue: "ids")) }
        if let authors = authors { try container.encode(authors, forKey: DynamicCodingKey(stringValue: "authors")) }
        if let kinds = kinds { try container.encode(kinds, forKey: DynamicCodingKey(stringValue: "kinds")) }
        if let since = since { try container.encode(since, forKey: DynamicCodingKey(stringValue: "since")) }
        if let until = until { try container.encode(until, forKey: DynamicCodingKey(stringValue: "until")) }
        if let limit = limit { try container.encode(limit, forKey: DynamicCodingKey(stringValue: "limit")) }

        // Encode tag filters with # prefix
        if let tagFilters = tagFilters {
            for (tag, values) in tagFilters {
                try container.encode(values, forKey: DynamicCodingKey(stringValue: "#\(tag)"))
            }
        }
    }

    // For NIP-17 gift wraps
    static func giftWrapsFor(pubkey: String, since: Date? = nil) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [1059] // Gift wrap kind
        filter.since = since?.timeIntervalSince1970.toInt()
        filter.tagFilters = ["p": [pubkey]]
        filter.limit = TransportConfig.nostrRelayDefaultFetchLimit // reasonable limit
        return filter
    }

    // For location channels: geohash-scoped ephemeral events (kind 20000) and presence (kind 20001)
    static func geohashEphemeral(_ geohash: String, since: Date? = nil, limit: Int = 1000) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [20000, 20001]
        filter.since = since?.timeIntervalSince1970.toInt()
        filter.tagFilters = ["g": [geohash]]
        filter.limit = limit
        return filter
    }

    // For location notes with neighbors: subscribe to multiple geohashes (center + neighbors)
    static func geohashNotes(_ geohashes: [String], since: Date? = nil, limit: Int = 200) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [1]
        filter.since = since?.timeIntervalSince1970.toInt()
        filter.tagFilters = ["g": geohashes]
        filter.limit = limit
        return filter
    }

    // For Place Feed: kind-1 notes/replies and kind-7 NIP-25 reactions on one
    // For Place Feed: fetches kind-1 notes/replies, kind-7 NIP-25 reactions,
    // and kind-5 NIP-09 deletions in one per-place relay subscription (avoids
    // opening extra sockets/REQs over Tor).
    static func geohashFeed(_ geohashes: [String], since: Date? = nil, limit: Int = 200) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [
            NostrProtocol.EventKind.textNote.rawValue,
            NostrProtocol.EventKind.reaction.rawValue,
            NostrProtocol.EventKind.deletion.rawValue
        ]
        filter.since = since?.timeIntervalSince1970.toInt()
        filter.tagFilters = ["g": geohashes]
        filter.limit = limit
        return filter
    }

    // For Following Home Feed: kind-1 notes from followed pubkeys on default relays.
    static func authorNotes(_ pubkeys: [String], since: Date? = nil, limit: Int = 150) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [NostrProtocol.EventKind.textNote.rawValue]
        filter.authors = pubkeys
        filter.since = since?.timeIntervalSince1970.toInt()
        filter.limit = limit
        return filter
    }

    // For NIP-01 kind-0 profile metadata batch lookups.
    static func authorProfiles(_ pubkeys: [String], limit: Int? = nil) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [NostrProtocol.EventKind.metadata.rawValue]
        filter.authors = pubkeys
        filter.limit = limit ?? max(pubkeys.count * 2, 20)
        return filter
    }

    // For the mesh bridge: rendezvous messages (kind 20000) and presence
    // (kind 20001) tagged `#r` with one or more cells (own + neighbors).
    static func bridgeRendezvous(_ cells: [String], since: Date? = nil, limit: Int = 200) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [20000, 20001]
        filter.since = since?.timeIntervalSince1970.toInt()
        filter.tagFilters = ["r": cells]
        filter.limit = limit
        return filter
    }

    // For courier drops: sealed envelopes (kind 1401) parked under rotating
    // recipient tags (`#x`, hex). Callers pass every candidate tag (adjacent
    // UTC days x recipients) in one filter.
    static func courierDrops(recipientTagsHex: [String], since: Date? = nil, limit: Int = 100) -> NostrFilter {
        var filter = NostrFilter()
        filter.kinds = [NostrProtocol.EventKind.courierDrop.rawValue]
        filter.since = since?.timeIntervalSince1970.toInt()
        filter.tagFilters = ["x": recipientTagsHex]
        filter.limit = limit
        return filter
    }
}

// Dynamic coding key for tag filters
private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private extension TimeInterval {
    func toInt() -> Int {
        return Int(self)
    }
}
