import Testing
import Foundation
@testable import bitchat

struct LocationChannelsTests {
    @Test func geohashEncoderPrecisionMapping() {
        // Sanity: known coords (Statue of Liberty approx)
        let lat = 40.6892
        let lon = -74.0445
        let block = Geohash.encode(latitude: lat, longitude: lon, precision: GeohashChannelLevel.block.precision)
        let neighborhood = Geohash.encode(latitude: lat, longitude: lon, precision: GeohashChannelLevel.neighborhood.precision)
        let city = Geohash.encode(latitude: lat, longitude: lon, precision: GeohashChannelLevel.city.precision)
        let region = Geohash.encode(latitude: lat, longitude: lon, precision: GeohashChannelLevel.province.precision)
        let country = Geohash.encode(latitude: lat, longitude: lon, precision: GeohashChannelLevel.region.precision)
        
        #expect(block.count == 7)
        #expect(neighborhood.count == 6)
        #expect(city.count == 5)
        #expect(region.count == 4)
        #expect(country.count == 2)
        
        // All prefixes must match progressively
        #expect(block.hasPrefix(neighborhood))
        #expect(neighborhood.hasPrefix(city))
        #expect(city.hasPrefix(region))
        #expect(region.hasPrefix(country))
    }

    @Test func nostrGeohashFilterEncoding() throws {
        let gh = "u4pruy"
        let filter = NostrFilter.geohashEphemeral(gh)
        let data = try JSONEncoder().encode(filter)
        let json = String(data: data, encoding: .utf8) ?? ""
        // Expect kinds includes 20000 and tag filter '#g':[gh]
        #expect(json.contains("20000"))
        #expect(json.contains("\"#g\":[\"\(gh)\"]"))
    }

    @Test func perGeohashIdentityDeterministic() throws {
        // Derive twice for same geohash; should be identical
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let gh = "u4pruy"
        let id1 = try idBridge.deriveIdentity(forGeohash: gh)
        let id2 = try idBridge.deriveIdentity(forGeohash: gh)
        #expect(id1.publicKeyHex == id2.publicKeyHex)
    }

    @Test func bookmarkNamesMigrationDropsLowPrecisionEntries() throws {
        let suite = "bitchat.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Seed stale state: pre-fix cache has "England" for a 2-char UK geohash,
        // plus higher-precision entries that must survive the migration.
        let seeded: [String: String] = [
            "gc": "England",
            "u3": "Île-de-France",
            "u4pr": "Paris",
            "u4pruy": "Le Marais"
        ]
        let seededData = try JSONEncoder().encode(seeded)
        defaults.set(seededData, forKey: "locationChannel.bookmarkNames")
        #expect(defaults.integer(forKey: "locationChannel.bookmarkNamesSchemaVersion") == 0)

        let mgr = LocationStateManager(storage: defaults)

        // Low-precision entries are dropped so resolver recomputes them.
        #expect(mgr.bookmarkNames["gc"] == nil)
        #expect(mgr.bookmarkNames["u3"] == nil)
        // Higher-precision entries are preserved.
        #expect(mgr.bookmarkNames["u4pr"] == "Paris")
        #expect(mgr.bookmarkNames["u4pruy"] == "Le Marais")
        // Schema version bumped — migration runs once.
        #expect(defaults.integer(forKey: "locationChannel.bookmarkNamesSchemaVersion") == 1)

        // Second init is a no-op (idempotent); no crash, state preserved.
        _ = LocationStateManager(storage: defaults)
        #expect(defaults.integer(forKey: "locationChannel.bookmarkNamesSchemaVersion") == 1)
    }
}
