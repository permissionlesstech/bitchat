import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("BLE Noise reconnect policy")
struct BLENoiseReconnectPolicyTests {
    @Test("Revalidation requires a cached session and no authenticated link")
    func revalidationPreconditions() {
        var policy = BLENoiseReconnectPolicy()
        let link = BLEIngressLinkID.peripheral("peripheral-a")
        let now = Date(timeIntervalSince1970: 1_000)

        let withoutSession = policy.shouldRevalidate(
            on: link,
            hasEstablishedSession: false,
            isNoiseAuthenticatedLink: false,
            hasAuthenticatedPeerLink: false,
            now: now
        )
        #expect(!withoutSession)
        let authenticated = policy.shouldRevalidate(
            on: link,
            hasEstablishedSession: true,
            isNoiseAuthenticatedLink: true,
            hasAuthenticatedPeerLink: true,
            now: now
        )
        #expect(!authenticated)
        let eligible = policy.shouldRevalidate(
            on: link,
            hasEstablishedSession: true,
            isNoiseAuthenticatedLink: false,
            hasAuthenticatedPeerLink: false,
            now: now
        )
        #expect(eligible)
    }

    @Test("Revalidation is once per link epoch or after sixty seconds")
    func revalidationIsBoundPerLinkEpoch() {
        var policy = BLENoiseReconnectPolicy()
        let link = BLEIngressLinkID.central("central-a")
        let start = Date(timeIntervalSince1970: 2_000)

        let initial = policy.shouldRevalidate(
            on: link,
            hasEstablishedSession: true,
            isNoiseAuthenticatedLink: false,
            hasAuthenticatedPeerLink: false,
            now: start
        )
        #expect(initial)
        let duringCooldown = policy.shouldRevalidate(
            on: link,
            hasEstablishedSession: true,
            isNoiseAuthenticatedLink: false,
            hasAuthenticatedPeerLink: false,
            now: start.addingTimeInterval(59.999)
        )
        #expect(!duringCooldown)
        let afterCooldown = policy.shouldRevalidate(
            on: link,
            hasEstablishedSession: true,
            isNoiseAuthenticatedLink: false,
            hasAuthenticatedPeerLink: false,
            now: start.addingTimeInterval(60)
        )
        #expect(afterCooldown)

        policy.endLinkEpoch(link)
        let nextEpoch = policy.shouldRevalidate(
            on: link,
            hasEstablishedSession: true,
            isNoiseAuthenticatedLink: false,
            hasAuthenticatedPeerLink: false,
            now: start.addingTimeInterval(60.001)
        )
        #expect(nextEpoch)
    }

    @Test("An authenticated sibling suppresses redundant reconnect")
    func authenticatedSiblingSuppressesReconnect() {
        var policy = BLENoiseReconnectPolicy()
        let link = BLEIngressLinkID.peripheral("unproven-sibling")
        let start = Date(timeIntervalSince1970: 3_000)

        let suppressed = policy.shouldRevalidate(
            on: link,
            hasEstablishedSession: true,
            isNoiseAuthenticatedLink: false,
            hasAuthenticatedPeerLink: true,
            now: start
        )
        #expect(!suppressed)
        let eligible = policy.shouldRevalidate(
            on: link,
            hasEstablishedSession: true,
            isNoiseAuthenticatedLink: false,
            hasAuthenticatedPeerLink: false,
            now: start
        )
        #expect(eligible)
    }

    @Test("Reserved replacement bit is not advertised")
    func reservedReplacementBitIsNotAdvertised() {
        #expect(
            !PeerCapabilities.localSupported.contains(
                .nonDestructiveNoiseReplacement
            )
        )
        #expect(PeerCapabilities.localSupported.contains(.privateMedia))
        #expect(
            PeerCapabilities.localSupported.contains(.privateMediaReceipts)
        )
    }
}
