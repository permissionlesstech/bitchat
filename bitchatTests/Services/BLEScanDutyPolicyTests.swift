import Testing
@testable import bitchat

struct BLEScanDutyPolicyTests {
    @Test
    func continuousScanWhenInactiveOrTrafficIsRecent() {
        #expect(BLEScanDutyPolicy.plan(
            appIsActive: false,
            connectedCount: 4,
            hasRecentTraffic: false
        ) == .continuous)

        #expect(BLEScanDutyPolicy.plan(
            appIsActive: true,
            connectedCount: 4,
            hasRecentTraffic: true
        ) == .continuous)
    }

    @Test
    func dutyCyclesWhenActiveAndIdleIncludingSoloAndSmallMeshes() {
        for count in [0, 1, 2, 3] {
            let plan = BLEScanDutyPolicy.plan(
                appIsActive: true,
                connectedCount: count,
                hasRecentTraffic: false
            )
            #expect(plan == .dutyCycle(
                onDuration: TransportConfig.bleDutyOnDuration,
                offDuration: TransportConfig.bleDutyOffDuration
            ))
        }
    }

    @Test
    func dutyCyclesDenseActiveMeshesWithDenseDurations() {
        let plan = BLEScanDutyPolicy.plan(
            appIsActive: true,
            connectedCount: TransportConfig.bleHighDegreeThreshold,
            hasRecentTraffic: false
        )

        #expect(plan == .dutyCycle(
            onDuration: TransportConfig.bleDutyOnDurationDense,
            offDuration: TransportConfig.bleDutyOffDurationDense
        ))
    }

    @Test
    func lowPowerModeDutyCyclesEvenWhenDisconnectedOrSparse() {
        let idlePlan = BLEScanDutyPolicy.plan(
            appIsActive: true,
            connectedCount: 0,
            hasRecentTraffic: false,
            lowPowerMode: true
        )
        #expect(idlePlan == .dutyCycle(onDuration: 3.0, offDuration: 15.0))

        let densePlan = BLEScanDutyPolicy.plan(
            appIsActive: true,
            connectedCount: TransportConfig.bleHighDegreeThreshold,
            hasRecentTraffic: false,
            lowPowerMode: true
        )
        #expect(densePlan == .dutyCycle(onDuration: 2.0, offDuration: 20.0))

        // Active traffic still keeps continuous scanning so conversations stay snappy.
        let activePlan = BLEScanDutyPolicy.plan(
            appIsActive: true,
            connectedCount: 3,
            hasRecentTraffic: true,
            lowPowerMode: true
        )
        #expect(activePlan == .continuous)
    }
}

struct BLEFragmentScanPauseTrackerTests {
    @Test
    func singleBeginAndEndTracksPauseStateAndReturnsHandle() {
        var tracker = BLEFragmentScanPauseTracker<String, Int>()
        #expect(!tracker.isPaused)

        let begin = tracker.begin(token: "t1", timeoutHandle: 101)
        #expect(begin.becamePaused)
        #expect(begin.replacedHandle == nil)
        #expect(tracker.isPaused)
        #expect(tracker.activeCount == 1)

        let end = tracker.end(token: "t1")
        #expect(end.removedHandle == 101)
        #expect(end.shouldResumeScanning)
        #expect(!tracker.isPaused)
    }

    @Test
    func overlappingTokensStayPausedUntilLastTokenEndsOrTimesOut() {
        var tracker = BLEFragmentScanPauseTracker<String, Int>()
        _ = tracker.begin(token: "t1", timeoutHandle: 1)
        let second = tracker.begin(token: "t2", timeoutHandle: 2)
        #expect(!second.becamePaused)
        #expect(tracker.activeCount == 2)

        let endFirst = tracker.end(token: "t1")
        #expect(endFirst.removedHandle == 1)
        #expect(!endFirst.shouldResumeScanning)
        #expect(tracker.isPaused)

        let timeout1 = tracker.timeoutFired(token: "t1")
        #expect(timeout1 == false)
        let timeout2 = tracker.timeoutFired(token: "t2")
        #expect(timeout2 == true)
        #expect(!tracker.isPaused)
    }

    @Test
    func cancelAllDrainsHandlesAndPreventsLaterTimeoutsFromResuming() {
        var tracker = BLEFragmentScanPauseTracker<String, Int>()
        _ = tracker.begin(token: "t1", timeoutHandle: 11)
        _ = tracker.begin(token: "t2", timeoutHandle: 22)

        let cancelled = Set(tracker.cancelAll())
        #expect(cancelled == [11, 22])
        #expect(!tracker.isPaused)
        #expect(tracker.activeCount == 0)

        let timeout1 = tracker.timeoutFired(token: "t1")
        #expect(timeout1 == false)
        let ended = tracker.end(token: "t2")
        #expect(ended.removedHandle == nil)
        #expect(!ended.shouldResumeScanning)
    }

    @Test
    func replacingTokenReturnsPreviousHandleForCancellation() {
        var tracker = BLEFragmentScanPauseTracker<String, Int>()
        let first = tracker.begin(token: "t1", timeoutHandle: 10)
        #expect(first.replacedHandle == nil)

        let replacement = tracker.begin(token: "t1", timeoutHandle: 20)
        #expect(!replacement.becamePaused)
        #expect(replacement.replacedHandle == 10)
        #expect(tracker.activeCount == 1)
    }
}
