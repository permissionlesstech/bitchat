import Foundation

enum BLEScanDutyPlan: Equatable {
    case continuous
    case dutyCycle(onDuration: TimeInterval, offDuration: TimeInterval)
}

enum BLEScanDutyPolicy {
    static func plan(
        dutyEnabled: Bool,
        appIsActive: Bool,
        connectedCount: Int,
        hasRecentTraffic: Bool,
        highDegreeThreshold: Int = TransportConfig.bleHighDegreeThreshold,
        lowPowerMode: Bool = false
    ) -> BLEScanDutyPlan {
        // Under Low Power Mode, duty-cycle aggressively even with 0-2 peers
        // whenever there is no active traffic burst so the BLE radio sleeps ~85-90% of the time.
        if lowPowerMode && dutyEnabled && appIsActive && !hasRecentTraffic {
            if connectedCount >= highDegreeThreshold {
                return .dutyCycle(
                    onDuration: 2.0,
                    offDuration: 20.0
                )
            }
            return .dutyCycle(
                onDuration: TransportConfig.bleDutyOnDurationDense,
                offDuration: TransportConfig.bleDutyOffDurationDense
            )
        }

        let forceContinuousScan = connectedCount <= 2 || hasRecentTraffic
        let shouldDutyCycle = dutyEnabled && appIsActive && connectedCount > 0 && !forceContinuousScan

        guard shouldDutyCycle else {
            return .continuous
        }

        if connectedCount >= highDegreeThreshold {
            return .dutyCycle(
                onDuration: TransportConfig.bleDutyOnDurationDense,
                offDuration: TransportConfig.bleDutyOffDurationDense
            )
        }

        return .dutyCycle(
            onDuration: TransportConfig.bleDutyOnDuration,
            offDuration: TransportConfig.bleDutyOffDuration
        )
    }
}
