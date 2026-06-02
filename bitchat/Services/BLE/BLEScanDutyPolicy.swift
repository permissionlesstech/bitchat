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
        highDegreeThreshold: Int = TransportConfig.bleHighDegreeThreshold
    ) -> BLEScanDutyPlan {
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
