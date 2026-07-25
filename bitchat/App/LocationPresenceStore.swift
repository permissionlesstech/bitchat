import Combine
import Foundation

@MainActor
final class LocationPresenceStore: ObservableObject {
    @Published private(set) var currentGeohash: String?
    @Published private(set) var geoNicknames: [String: String] = [:]
    @Published private(set) var teleportedGeo: Set<String> = []

    private let geoNicknameCapacity: Int
    private var geoNicknameOrder: [String] = []

    init(geoNicknameCapacity: Int = TransportConfig.geoNicknameParticipantsCap) {
        self.geoNicknameCapacity = max(0, geoNicknameCapacity)
    }

    func setCurrentGeohash(_ geohash: String?) {
        let normalized = geohash?.lowercased()
        if currentGeohash != normalized {
            // Nicknames are scoped to the active geohash presence table.
            clearGeoNicknames()
        }
        currentGeohash = normalized
    }

    func setNickname(_ nickname: String, for pubkeyHex: String) {
        guard geoNicknameCapacity > 0 else {
            clearGeoNicknames()
            return
        }

        let key = pubkeyHex.lowercased()
        if geoNicknames[key] != nil {
            geoNicknames[key] = nickname
            return
        }

        while geoNicknameOrder.count >= geoNicknameCapacity, let oldest = geoNicknameOrder.first {
            geoNicknameOrder.removeFirst()
            geoNicknames.removeValue(forKey: oldest)
        }

        geoNicknames[key] = nickname
        geoNicknameOrder.append(key)
    }

    func replaceGeoNicknames(_ nicknames: [String: String]) {
        guard geoNicknameCapacity > 0 else {
            clearGeoNicknames()
            return
        }

        var seen: Set<String> = []
        var ordered: [String] = []
        var normalized: [String: String] = [:]
        for (key, value) in nicknames {
            let lower = key.lowercased()
            guard seen.insert(lower).inserted else { continue }
            ordered.append(lower)
            normalized[lower] = value
        }
        if ordered.count > geoNicknameCapacity {
            let kept = Array(ordered.suffix(geoNicknameCapacity))
            ordered = kept
            normalized = Dictionary(uniqueKeysWithValues: kept.compactMap { key in
                normalized[key].map { (key, $0) }
            })
        }
        geoNicknameOrder = ordered
        geoNicknames = normalized
    }

    func clearGeoNicknames() {
        geoNicknames.removeAll()
        geoNicknameOrder.removeAll()
    }

    func retainGeoNicknames(keeping pubkeys: Set<String>) {
        let allowed = Set(pubkeys.map { $0.lowercased() })
        geoNicknameOrder = geoNicknameOrder.filter { allowed.contains($0) }
        geoNicknames = geoNicknames.filter { allowed.contains($0.key) }
    }

    func markTeleported(_ pubkeyHex: String) {
        teleportedGeo.insert(pubkeyHex.lowercased())
    }

    func clearTeleported(_ pubkeyHex: String) {
        teleportedGeo.remove(pubkeyHex.lowercased())
    }

    func replaceTeleportedGeo(_ pubkeys: Set<String>) {
        teleportedGeo = Set(pubkeys.map { $0.lowercased() })
    }

    func clearTeleportedGeo() {
        teleportedGeo.removeAll()
    }

    func reset() {
        currentGeohash = nil
        geoNicknames.removeAll()
        geoNicknameOrder.removeAll()
        teleportedGeo.removeAll()
    }
}
