import Combine
import Foundation

@MainActor
final class LocationPresenceStore: ObservableObject {
    @Published private(set) var currentGeohash: String?
    @Published private(set) var geoNicknames: [String: String] = [:]
    @Published private(set) var teleportedGeo: Set<String> = []

    func setCurrentGeohash(_ geohash: String?) {
        currentGeohash = geohash?.lowercased()
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
        teleportedGeo.removeAll()
    }
}
