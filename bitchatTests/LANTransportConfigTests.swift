//
// LANTransportConfigTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
import BitFoundation
@testable import bitchat

struct LANTransportConfigTests {

    private func makeDefaults() -> UserDefaults {
        let suiteName = "bitchat.lan.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return .standard
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("The Wi-Fi LAN transport is off by default")
    func defaultsToDisabled() {
        let defaults = makeDefaults()
        let settings = LANTransportSettings(defaults: defaults)
        #expect(settings.isEnabled == false)
    }

    @Test("The feature flag round-trips through the settings store")
    func flagRoundTrip() {
        let defaults = makeDefaults()
        let settings = LANTransportSettings(defaults: defaults)
        settings.isEnabled = true
        #expect(settings.isEnabled)
        #expect(LANTransportSettings(defaults: defaults).isEnabled)
        settings.isEnabled = false
        #expect(settings.isEnabled == false)
    }

    @Test("The advertised Bonjour name carries the peer ID")
    func serviceNameRoundTrip() {
        let peerID = PeerID(str: "0123456789abcdef")
        let name = LANTransportConfig.serviceName(for: peerID)
        #expect(name == "bitchat-0123456789abcdef")
        #expect(LANTransportConfig.peerID(fromServiceName: name) == peerID)
    }

    @Test("Foreign Bonjour services are ignored")
    func foreignServiceNames() {
        #expect(LANTransportConfig.peerID(fromServiceName: "SomeOtherApp") == nil)
        #expect(LANTransportConfig.peerID(fromServiceName: "bitchat-") == nil)
        #expect(LANTransportConfig.peerID(fromServiceName: "bitchat-nothex") == nil)
        #expect(LANTransportConfig.peerID(fromServiceName: "bitchat-" + String(repeating: "a", count: 64)) == nil)
        #expect(LANTransportConfig.peerID(fromServiceName: "") == nil)
    }

    @Test("The Bonjour service type is the one declared in Info.plist")
    func serviceType() {
        #expect(LANTransportConfig.serviceType == "_bitchat._tcp")
    }

    @Test("A denied local-network failure maps to the denied permission state")
    func permissionResolution() {
        #expect(
            LANPermissionStateResolver.resolve(failure: .permissionDenied) == .denied
        )
        #expect(
            LANPermissionStateResolver.resolve(failure: .unavailable) == .unavailable
        )
        #expect(
            LANPermissionStateResolver.resolve(failure: .transient) == .unknown
        )
    }

    @Test("Only a granted permission allows local-network access")
    func permissionGate() {
        #expect(LANPermissionState.granted.allowsLocalNetworkAccess)
        #expect(!LANPermissionState.denied.allowsLocalNetworkAccess)
        #expect(!LANPermissionState.unknown.allowsLocalNetworkAccess)
        #expect(!LANPermissionState.unavailable.allowsLocalNetworkAccess)
    }

    @Test("The first enable may start Bonjour to trigger the permission prompt")
    func permissionCanAttemptStart() {
        #expect(LANPermissionState.unknown.canAttemptStart)
        #expect(LANPermissionState.granted.canAttemptStart)
        #expect(!LANPermissionState.denied.canAttemptStart)
        #expect(!LANPermissionState.unavailable.canAttemptStart)
    }

    @Test("The connection table has a positive hard cap")
    func connectionCap() {
        #expect(LANTransportConfig.maxConcurrentConnections > 0)
    }
}
