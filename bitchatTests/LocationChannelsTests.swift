import XCTest
@testable import bitchat

final class LocationChannelsTests: XCTestCase {
    func testGeohashEncoderPrecisionMapping() {
        // Sanity: known coords (Statue of Liberty approx)
        let lat = 40.6892
        let lon = -74.0445
        let block = Geohash.encode(latitude: lat, longitude: lon, precision: GeohashChannelLevel.block.precision)
        let neighborhood = Geohash.encode(latitude: lat, longitude: lon, precision: GeohashChannelLevel.neighborhood.precision)
        let city = Geohash.encode(latitude: lat, longitude: lon, precision: GeohashChannelLevel.city.precision)
        let region = Geohash.encode(latitude: lat, longitude: lon, precision: GeohashChannelLevel.province.precision)
        let country = Geohash.encode(latitude: lat, longitude: lon, precision: GeohashChannelLevel.region.precision)
        
        XCTAssertEqual(block.count, 7)
        XCTAssertEqual(neighborhood.count, 6)
        XCTAssertEqual(city.count, 5)
        XCTAssertEqual(region.count, 4)
        XCTAssertEqual(country.count, 2)
        
        // All prefixes must match progressively
        XCTAssertTrue(block.hasPrefix(neighborhood))
        XCTAssertTrue(neighborhood.hasPrefix(city))
        XCTAssertTrue(city.hasPrefix(region))
        XCTAssertTrue(region.hasPrefix(country))
    }

    func testNostrGeohashFilterEncoding() throws {
        let gh = "u4pruy"
        let filter = NostrFilter.geohashEphemeral(gh)
        let data = try JSONEncoder().encode(filter)
        let json = String(data: data, encoding: .utf8) ?? ""
        // Expect kinds includes 20000 and tag filter '#g':[gh]
        XCTAssertTrue(json.contains("20000"))
        XCTAssertTrue(json.contains("\"#g\":[\"\(gh)\"]"))
    }

    func testPerGeohashIdentityDeterministic() throws {
        // Derive twice for same geohash; should be identical
        let gh = "u4pruy"
        let id1 = try NostrIdentityBridge.deriveIdentity(forGeohash: gh)
        let id2 = try NostrIdentityBridge.deriveIdentity(forGeohash: gh)
        XCTAssertEqual(id1.publicKeyHex, id2.publicKeyHex)
    }
}
