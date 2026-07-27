import Foundation

enum BLEScanDutyPlan: Equatable {
    case continuous
    case dutyCycle(onDuration: TimeInterval, offDuration: TimeInterval)
    case suspended
}

enum BLEScanDutyPolicy {
    static func plan(
        dutyEnabled: Bool,
        appIsActive: Bool,
        connectedCount: Int,
        hasRecentTraffic: Bool,
        isLowPowerModeOrLowBattery: Bool = false,
        idleTopologyDuration: TimeInterval = 0,
        highDegreeThreshold: Int = TransportConfig.bleHighDegreeThreshold
    ) -> BLEScanDutyPlan {
        if isLowPowerModeOrLowBattery {
            return .suspended
        }

        let forceContinuousScan = connectedCount <= 2 || hasRecentTraffic
        let shouldDutyCycle = dutyEnabled && appIsActive && connectedCount > 0 && !forceContinuousScan

        guard shouldDutyCycle else {
            return .continuous
        }

        // If topology has been idle for >5 minutes, drop scan duty cycle to 10% on to save battery
        if idleTopologyDuration >= 300 {
            return .dutyCycle(
                onDuration: 1.0,
                offDuration: 9.0
            )
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
