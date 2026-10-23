//
// AppRuntimeGeohashLinkTests.swift
// bitchatTests
//
// External #geohash links (geo-activity notification taps, shared invites)
// open their channel once, in AppRuntime, rather than in every message list
// on screen.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

@Suite("AppRuntime geohash links")
struct AppRuntimeGeohashLinkTests {
    @Test("a bitchat geohash link names its geohash")
    func geohashLink_namesItsGeohash() throws {
        let link = try #require(URL(string: "bitchat://geohash/u4pruy"))
        #expect(AppRuntime.geohashLinkTarget(link) == "u4pruy")

        // The notification deep link is built the same way.
        let deeplink = try #require(URL(string: "bitchat://geohash/9q8yy/"))
        #expect(AppRuntime.geohashLinkTarget(deeplink) == "9q8yy")
    }

    @Test("other links name no geohash")
    func otherLinks_nameNoGeohash() throws {
        for string in [
            "bitchat://geohash",
            "bitchat://geohash/",
            "bitchat://user/0102030405060708",
            "bitchat://share",
            "https://geohash/u4pruy",
        ] {
            let url = try #require(URL(string: string))
            #expect(AppRuntime.geohashLinkTarget(url) == nil, "\(string)")
        }
    }
}
