import Foundation
import Testing

@testable import bitchat

struct LocationChannelTests {
    @Test
    func geohashChannelLevelDisplayNamesAndLegacyDecoding() throws {
        for level in GeohashChannelLevel.allCases {
            #expect(level.displayName.isEmpty == false)
        }

        #expect(try decodeLevel(from: "\"building\"") == .building)
        #expect(try decodeLevel(from: "\"block\"") == .block)
        #expect(try decodeLevel(from: "\"neighborhood\"") == .neighborhood)
        #expect(try decodeLevel(from: "\"city\"") == .city)
        #expect(try decodeLevel(from: "\"province\"") == .province)
        #expect(try decodeLevel(from: "\"region\"") == .province)
        #expect(try decodeLevel(from: "\"country\"") == .region)
        #expect(try decodeLevel(from: "\"unknown\"") == .block)
        #expect(try decodeLevel(from: "8") == .building)
        #expect(try decodeLevel(from: "7") == .block)
        #expect(try decodeLevel(from: "6") == .neighborhood)
        #expect(try decodeLevel(from: "5") == .city)
        #expect(try decodeLevel(from: "4") == .province)
        #expect(try decodeLevel(from: "3") == .region)
        #expect(try decodeLevel(from: "0") == .region)
        #expect(try decodeLevel(from: "99") == .block)
        #expect(try decodeLevel(from: "true") == .block)
    }

    @Test
    func geohashChannelAndChannelIDExposeStableAccessors() {
        let channel = GeohashChannel(level: .city, geohash: "u4pru")

        #expect(channel.id == "city-u4pru")
        #expect(channel.displayName.contains("u4pru"))
        #expect(channel.displayName.contains(channel.level.displayName))

        let mesh = ChannelID.mesh
        #expect(mesh.displayName == "Mesh")
        #expect(mesh.nostrGeohashTag == nil)
        #expect(mesh.isMesh)
        #expect(mesh.isLocation == false)

        let location = ChannelID.location(channel)
        #expect(location.displayName == channel.displayName)
        #expect(location.nostrGeohashTag == "u4pru")
        #expect(location.isMesh == false)
        #expect(location.isLocation)
    }

    private func decodeLevel(from json: String) throws -> GeohashChannelLevel {
        try JSONDecoder().decode(GeohashChannelLevel.self, from: Data(json.utf8))
    }
}
