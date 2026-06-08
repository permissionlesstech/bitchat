import Combine
import Foundation

@MainActor
final class LocationPresenceStore: ObservableObject {
    @Published private(set) var currentGeohash: String?
    @Published private(set) var geoNicknames: [String: String] = [:]
    @Published private(set) var teleportedGeo: Set<String> = []

    private let teleportedGeoCapacity: Int
    private var teleportedGeoOrder: [String] = []

    init(teleportedGeoCapacity: Int = TransportConfig.geoTeleportedParticipantsCap) {
        self.teleportedGeoCapacity = max(0, teleportedGeoCapacity)
    }

    func setCurrentGeohash(_ geohash: String?) {
        let normalized = geohash?.lowercased()
        if currentGeohash != normalized {
            clearTeleportedGeo()
        }
        currentGeohash = normalized
    }

    func setNickname(_ nickname: String, for pubkeyHex: String) {
        geoNicknames[pubkeyHex.lowercased()] = nickname
    }

    func replaceGeoNicknames(_ nicknames: [String: String]) {
        geoNicknames = Dictionary(
            uniqueKeysWithValues: nicknames.map { key, value in
                (key.lowercased(), value)
            }
        )
    }

    func clearGeoNicknames() {
        geoNicknames.removeAll()
    }

    func markTeleported(_ pubkeyHex: String) {
        guard teleportedGeoCapacity > 0 else {
            clearTeleportedGeo()
            return
        }

        let key = pubkeyHex.lowercased()
        guard !teleportedGeo.contains(key) else { return }

        while teleportedGeoOrder.count >= teleportedGeoCapacity, let oldest = teleportedGeoOrder.first {
            teleportedGeoOrder.removeFirst()
            teleportedGeo.remove(oldest)
        }

        teleportedGeo.insert(key)
        teleportedGeoOrder.append(key)
    }

    func clearTeleported(_ pubkeyHex: String) {
        let key = pubkeyHex.lowercased()
        teleportedGeo.remove(key)
        teleportedGeoOrder.removeAll { $0 == key }
    }

    func replaceTeleportedGeo(_ pubkeys: Set<String>) {
        guard teleportedGeoCapacity > 0 else {
            clearTeleportedGeo()
            return
        }

        var seen: Set<String> = []
        var ordered: [String] = []
        for key in pubkeys.map({ $0.lowercased() }) where !seen.contains(key) {
            seen.insert(key)
            ordered.append(key)
        }
        if ordered.count > teleportedGeoCapacity {
            ordered = Array(ordered.suffix(teleportedGeoCapacity))
        }
        teleportedGeoOrder = ordered
        teleportedGeo = Set(ordered)
    }

    func retainTeleportedGeo(keeping pubkeys: Set<String>) {
        let allowed = Set(pubkeys.map { $0.lowercased() })
        teleportedGeoOrder = teleportedGeoOrder.filter { allowed.contains($0) }
        teleportedGeo = teleportedGeo.intersection(allowed)
    }

    func clearTeleportedGeo() {
        teleportedGeo.removeAll()
        teleportedGeoOrder.removeAll()
    }

    func reset() {
        currentGeohash = nil
        geoNicknames.removeAll()
        teleportedGeo.removeAll()
        teleportedGeoOrder.removeAll()
    }
}
