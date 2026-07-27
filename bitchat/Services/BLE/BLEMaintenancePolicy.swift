import Foundation

struct BLEMaintenancePlan: Equatable {
    let shouldSendAnnounce: Bool
    let shouldEnsureAdvertising: Bool
    let shouldRunCleanup: Bool
    let shouldFlushDirectedSpool: Bool
    let shouldResetCounter: Bool
}

enum BLEMaintenancePolicy {
    static func plan(
        cycle: Int,
        connectedCount: Int,
        peerRegistryIsEmpty: Bool,
        elapsedSinceLastAnnounce: TimeInterval,
        hasRecentTraffic: Bool,
        connectedAnnounceJitterOffset: TimeInterval? = nil,
        highDegreeThreshold: Int = TransportConfig.bleHighDegreeThreshold
    ) -> BLEMaintenancePlan {
        BLEMaintenancePlan(
            shouldSendAnnounce: shouldSendAnnounce(
                connectedCount: connectedCount,
                elapsedSinceLastAnnounce: elapsedSinceLastAnnounce,
                hasRecentTraffic: hasRecentTraffic,
                connectedAnnounceJitterOffset: connectedAnnounceJitterOffset,
                highDegreeThreshold: highDegreeThreshold
            ),
            shouldEnsureAdvertising: peerRegistryIsEmpty,
            shouldRunCleanup: cycle.isMultiple(of: 3),
            shouldFlushDirectedSpool: !cycle.isMultiple(of: 2),
            shouldResetCounter: cycle >= 6
        )
    }

    static func shouldSendAnnounce(
        connectedCount: Int,
        elapsedSinceLastAnnounce: TimeInterval,
        hasRecentTraffic: Bool,
        connectedAnnounceJitterOffset: TimeInterval? = nil,
        highDegreeThreshold: Int = TransportConfig.bleHighDegreeThreshold
    ) -> Bool {
        if hasRecentTraffic && elapsedSinceLastAnnounce >= 10.0 {
            return true
        }

        guard connectedCount > 0 else {
            return elapsedSinceLastAnnounce >= TransportConfig.bleAnnounceIntervalSeconds
        }

        let highDegree = connectedCount >= highDegreeThreshold
        let base = highDegree ?
            TransportConfig.bleConnectedAnnounceBaseSecondsDense :
            TransportConfig.bleConnectedAnnounceBaseSecondsSparse
        let jitter = highDegree ?
            TransportConfig.bleConnectedAnnounceJitterDense :
            TransportConfig.bleConnectedAnnounceJitterSparse
        let jitterOffset = connectedAnnounceJitterOffset ?? Double.random(in: -jitter...jitter)

        return elapsedSinceLastAnnounce >= base + jitterOffset
    }
}
