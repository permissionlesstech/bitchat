import Foundation
import Testing
@testable import bitchat

@Suite("BLE maintenance policy tests")
struct BLEMaintenancePolicyTests {
    @Test("discovery mode keeps announces frequent and advertising on")
    func discoveryModeAnnouncesAndEnsuresAdvertising() {
        let plan = BLEMaintenancePolicy.plan(
            cycle: 1,
            connectedCount: 0,
            peerRegistryIsEmpty: true,
            elapsedSinceLastAnnounce: TransportConfig.bleAnnounceIntervalSeconds,
            hasRecentTraffic: false
        )

        #expect(plan.shouldSendAnnounce)
        #expect(plan.shouldEnsureAdvertising)
        #expect(plan.shouldFlushDirectedSpool)
        #expect(!plan.shouldRunCleanup)
        #expect(!plan.shouldResetCounter)
    }

    @Test("connected sparse meshes use sparse announce cadence")
    func connectedSparseMeshUsesSparseAnnounceCadence() {
        let beforeTarget = BLEMaintenancePolicy.plan(
            cycle: 2,
            connectedCount: 2,
            peerRegistryIsEmpty: false,
            elapsedSinceLastAnnounce: TransportConfig.bleConnectedAnnounceBaseSecondsSparse - 0.1,
            hasRecentTraffic: false,
            connectedAnnounceJitterOffset: 0
        )
        let atTarget = BLEMaintenancePolicy.plan(
            cycle: 2,
            connectedCount: 2,
            peerRegistryIsEmpty: false,
            elapsedSinceLastAnnounce: TransportConfig.bleConnectedAnnounceBaseSecondsSparse,
            hasRecentTraffic: false,
            connectedAnnounceJitterOffset: 0
        )

        #expect(!beforeTarget.shouldSendAnnounce)
        #expect(atTarget.shouldSendAnnounce)
        #expect(!beforeTarget.shouldEnsureAdvertising)
    }

    @Test("dense meshes use dense announce cadence")
    func denseMeshUsesDenseAnnounceCadence() {
        let beforeTarget = BLEMaintenancePolicy.plan(
            cycle: 3,
            connectedCount: TransportConfig.bleHighDegreeThreshold,
            peerRegistryIsEmpty: false,
            elapsedSinceLastAnnounce: TransportConfig.bleConnectedAnnounceBaseSecondsDense - 0.1,
            hasRecentTraffic: false,
            connectedAnnounceJitterOffset: 0
        )
        let atTarget = BLEMaintenancePolicy.plan(
            cycle: 3,
            connectedCount: TransportConfig.bleHighDegreeThreshold,
            peerRegistryIsEmpty: false,
            elapsedSinceLastAnnounce: TransportConfig.bleConnectedAnnounceBaseSecondsDense,
            hasRecentTraffic: false,
            connectedAnnounceJitterOffset: 0
        )

        #expect(!beforeTarget.shouldSendAnnounce)
        #expect(atTarget.shouldSendAnnounce)
        #expect(atTarget.shouldRunCleanup)
    }

    @Test("recent traffic can request a quick announce")
    func recentTrafficRequestsQuickAnnounce() {
        let plan = BLEMaintenancePolicy.plan(
            cycle: 4,
            connectedCount: 2,
            peerRegistryIsEmpty: false,
            elapsedSinceLastAnnounce: 10.0,
            hasRecentTraffic: true,
            connectedAnnounceJitterOffset: TransportConfig.bleConnectedAnnounceJitterSparse
        )

        #expect(plan.shouldSendAnnounce)
        #expect(!plan.shouldFlushDirectedSpool)
    }

    @Test("maintenance cadence controls cleanup spool flushing and counter reset")
    func maintenanceCadenceControlsPeriodicWork() {
        let cleanupAndFlush = BLEMaintenancePolicy.plan(
            cycle: 3,
            connectedCount: 1,
            peerRegistryIsEmpty: false,
            elapsedSinceLastAnnounce: 0,
            hasRecentTraffic: false,
            connectedAnnounceJitterOffset: 0
        )
        let reset = BLEMaintenancePolicy.plan(
            cycle: 6,
            connectedCount: 1,
            peerRegistryIsEmpty: false,
            elapsedSinceLastAnnounce: 0,
            hasRecentTraffic: false,
            connectedAnnounceJitterOffset: 0
        )

        #expect(cleanupAndFlush.shouldRunCleanup)
        #expect(cleanupAndFlush.shouldFlushDirectedSpool)
        #expect(!cleanupAndFlush.shouldResetCounter)
        #expect(reset.shouldRunCleanup)
        #expect(!reset.shouldFlushDirectedSpool)
        #expect(reset.shouldResetCounter)
    }
}
