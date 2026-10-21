//
// LANTransportSelectorTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

struct LANTransportSelectorTests {

    @Test("Wi-Fi wins over BLE and Nostr for a peer that is authenticated on the LAN")
    func lanWinsForAuthenticatedPeer() {
        let selector = LANTransportSelector(isEnabled: true, permission: .granted)
        let choice = selector.select(
            peerState: .authenticated,
            bleConnected: true,
            bleReachable: true,
            nostrReachable: true
        )
        #expect(choice == .lan)
    }

    @Test("A peer that is not authenticated on the LAN falls back to BLE")
    func fallsBackToBleForUnauthenticatedPeer() {
        let selector = LANTransportSelector(isEnabled: true, permission: .granted)
        let choice = selector.select(
            peerState: .handshaking,
            bleConnected: true,
            bleReachable: true,
            nostrReachable: true
        )
        #expect(choice == .ble)
    }

    @Test("A denied local-network permission never selects Wi-Fi")
    func deniedPermissionFallsBack() {
        let selector = LANTransportSelector(isEnabled: true, permission: .denied)
        let result = selector.selectWithReason(
            peerState: .authenticated,
            bleConnected: true,
            bleReachable: true,
            nostrReachable: true
        )
        #expect(result.choice == .ble)
        #expect(result.reason == .permissionDenied)
    }

    @Test("An unavailable local-network permission never selects Wi-Fi")
    func unavailablePermissionFallsBack() {
        let selector = LANTransportSelector(isEnabled: true, permission: .unavailable)
        let result = selector.selectWithReason(
            peerState: .authenticated,
            bleConnected: false,
            bleReachable: true,
            nostrReachable: false
        )
        #expect(result.choice == .ble)
        #expect(result.reason == .permissionUnavailable)
    }

    @Test("A permission that was never granted does not select Wi-Fi")
    func unknownPermissionFallsBack() {
        let selector = LANTransportSelector(isEnabled: true, permission: .unknown)
        let result = selector.selectWithReason(
            peerState: .authenticated,
            bleConnected: false,
            bleReachable: false,
            nostrReachable: true
        )
        #expect(result.choice == .nostr)
        #expect(result.reason == .permissionNotGranted)
    }

    @Test("The disabled feature flag keeps the existing BLE/Nostr behaviour")
    func disabledFeatureFlag() {
        let selector = LANTransportSelector(isEnabled: false, permission: .granted)
        let result = selector.selectWithReason(
            peerState: .authenticated,
            bleConnected: true,
            bleReachable: true,
            nostrReachable: true
        )
        #expect(result.choice == .ble)
        #expect(result.reason == .featureDisabled)
        #expect(selector.isLANEligible == false)
    }

    @Test("Nostr is the last resort and nothing is selected when no transport can reach the peer")
    func nostrAndNone() {
        let selector = LANTransportSelector(isEnabled: true, permission: .granted)
        #expect(
            selector.select(
                peerState: nil,
                bleConnected: false,
                bleReachable: false,
                nostrReachable: true
            ) == .nostr
        )
        #expect(
            selector.select(
                peerState: nil,
                bleConnected: false,
                bleReachable: false,
                nostrReachable: false
            ) == .none
        )
    }

    @Test("A peer that is unknown on the LAN reports the LAN fallback reason")
    func peerNotOnLAN() {
        let selector = LANTransportSelector(isEnabled: true, permission: .granted)
        let result = selector.selectWithReason(
            peerState: nil,
            bleConnected: false,
            bleReachable: true,
            nostrReachable: false
        )
        #expect(result.choice == .ble)
        #expect(result.reason == .peerNotOnLAN)
    }

    @Test("Only a granted permission makes the LAN transport eligible")
    func eligibility() {
        #expect(LANTransportSelector(isEnabled: true, permission: .granted).isLANEligible)
        #expect(!LANTransportSelector(isEnabled: true, permission: .denied).isLANEligible)
        #expect(!LANTransportSelector(isEnabled: true, permission: .unknown).isLANEligible)
        #expect(!LANTransportSelector(isEnabled: false, permission: .granted).isLANEligible)
    }
}
