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
}
