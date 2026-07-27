import Testing
@testable import bitchat

struct BLEScanDutyPolicyTests {
    @Test
    func continuousScanWhenDutyIsDisabledInactiveDisconnectedOrTrafficIsRecent() {
        #expect(BLEScanDutyPolicy.plan(
            dutyEnabled: false,
            appIsActive: true,
            connectedCount: 4,
            hasRecentTraffic: false
        ) == .continuous)

        #expect(BLEScanDutyPolicy.plan(
            dutyEnabled: true,
            appIsActive: false,
            connectedCount: 4,
            hasRecentTraffic: false
        ) == .continuous)

        #expect(BLEScanDutyPolicy.plan(
            dutyEnabled: true,
            appIsActive: true,
            connectedCount: 0,
            hasRecentTraffic: false
        ) == .continuous)

        #expect(BLEScanDutyPolicy.plan(
            dutyEnabled: true,
            appIsActive: true,
            connectedCount: 4,
            hasRecentTraffic: true
        ) == .continuous)
    }

    @Test
    func continuousScanForSmallMeshes() {
        #expect(BLEScanDutyPolicy.plan(
            dutyEnabled: true,
            appIsActive: true,
            connectedCount: 2,
            hasRecentTraffic: false
        ) == .continuous)
    }

    @Test
    func dutyCyclesSparseActiveMeshes() {
        let plan = BLEScanDutyPolicy.plan(
            dutyEnabled: true,
            appIsActive: true,
            connectedCount: 3,
            hasRecentTraffic: false
        )

        #expect(plan == .dutyCycle(
            onDuration: TransportConfig.bleDutyOnDuration,
            offDuration: TransportConfig.bleDutyOffDuration
        ))
    }

    @Test
    func dutyCyclesDenseActiveMeshesWithDenseDurations() {
        let plan = BLEScanDutyPolicy.plan(
            dutyEnabled: true,
            appIsActive: true,
            connectedCount: TransportConfig.bleHighDegreeThreshold,
            hasRecentTraffic: false
        )

        #expect(plan == .dutyCycle(
            onDuration: TransportConfig.bleDutyOnDurationDense,
            offDuration: TransportConfig.bleDutyOffDurationDense
        ))
    }
}
