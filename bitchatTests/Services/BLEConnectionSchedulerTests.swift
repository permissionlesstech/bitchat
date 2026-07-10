import Foundation
import Testing
@testable import bitchat

struct BLEConnectionSchedulerTests {
    @Test
    func discoveryQueuesWeakSignalCandidates() {
        let scheduler = BLEConnectionScheduler<String>(dynamicRSSIThreshold: -80)
        let now = Date()
        let candidate = makeCandidate(id: "p1", rssi: -85, now: now)

        let decision = scheduler.handleDiscovery(
            candidate,
            connectedOrConnectingCount: 0,
            existingState: nil,
            peripheralState: .disconnected,
            now: now
        )

        #expect(decision == .queued)
        #expect(scheduler.candidateCount == 1)
    }

    @Test
    func discoveryQueuesAndSchedulesRetryWhenRateLimited() {
        let scheduler = BLEConnectionScheduler<String>(connectRateLimitInterval: 1.0)
        let now = Date()
        scheduler.recordConnectionAttempt(at: now)

        let decision = scheduler.handleDiscovery(
            makeCandidate(id: "p1", rssi: -50, now: now),
            connectedOrConnectingCount: 0,
            existingState: nil,
            peripheralState: .disconnected,
            now: now.addingTimeInterval(0.25)
        )

        guard case .scheduleRetry(let delay) = decision else {
            Issue.record("Expected scheduleRetry, got \(decision)")
            return
        }
        #expect(delay > 0)
        #expect(scheduler.candidateCount == 1)
    }

    @Test
    func nextCandidateSelectsBestScoredCandidate() {
        let scheduler = BLEConnectionScheduler<String>()
        let now = Date()
        scheduler.enqueue(makeCandidate(id: "weak", rssi: -88, now: now))
        scheduler.enqueue(makeCandidate(id: "strong", rssi: -60, now: now.addingTimeInterval(1)))

        let decision = scheduler.nextCandidate(
            connectedOrConnectingCount: 0,
            isAlreadyConnectingOrConnected: { _ in false },
            now: now.addingTimeInterval(2)
        )

        guard case .connect(let candidate) = decision else {
            Issue.record("Expected connect decision")
            return
        }
        #expect(candidate.peripheralID == "strong")
    }

    @Test
    func enqueueReplacesExistingPeripheralCandidate() {
        let scheduler = BLEConnectionScheduler<String>()
        let now = Date()
        scheduler.enqueue(makeCandidate(id: "same", rssi: -90, now: now))
        scheduler.enqueue(makeCandidate(id: "same", rssi: -55, now: now.addingTimeInterval(1)))

        let decision = scheduler.nextCandidate(
            connectedOrConnectingCount: 0,
            isAlreadyConnectingOrConnected: { _ in false },
            now: now.addingTimeInterval(2)
        )

        guard case .connect(let candidate) = decision else {
            Issue.record("Expected connect decision")
            return
        }
        #expect(scheduler.candidateCount == 0)
        #expect(candidate.peripheralID == "same")
        #expect(candidate.rssi == -55)
    }

    @Test
    func weakTimedOutCandidateIsRequeuedWithRetryDelay() {
        let scheduler = BLEConnectionScheduler<String>(
            weakLinkCooldownSeconds: 30,
            weakLinkRSSICutoff: -90
        )
        let now = Date()
        scheduler.recordConnectionTimeout(peripheralID: "weak", at: now)
        scheduler.enqueue(makeCandidate(id: "weak", rssi: -95, now: now))

        let decision = scheduler.nextCandidate(
            connectedOrConnectingCount: 0,
            isAlreadyConnectingOrConnected: { _ in false },
            now: now.addingTimeInterval(5)
        )

        guard case .retryAfter(let delay) = decision else {
            Issue.record("Expected retryAfter decision")
            return
        }
        #expect(delay == 15)
        #expect(scheduler.candidateCount == 1)
    }

    @Test
    func disconnectErrorOnlyBrieflyBlocksRediscovery() {
        // A dropped established connection (walked out of range) gets a short
        // settle window, not the full connect-timeout backoff.
        let scheduler = BLEConnectionScheduler<String>()
        let now = Date()
        scheduler.recordDisconnectError(peripheralID: "p1", at: now)

        let during = scheduler.handleDiscovery(
            makeCandidate(id: "p1", rssi: -80, now: now.addingTimeInterval(1)),
            connectedOrConnectingCount: 0,
            existingState: nil,
            peripheralState: .disconnected,
            now: now.addingTimeInterval(1)
        )
        #expect(during == .ignore)

        let afterWindow = now.addingTimeInterval(TransportConfig.bleDisconnectDiscoveryIgnoreSeconds + 1)
        let after = scheduler.handleDiscovery(
            makeCandidate(id: "p1", rssi: -80, now: afterWindow),
            connectedOrConnectingCount: 0,
            existingState: nil,
            peripheralState: .disconnected,
            now: afterWindow
        )
        #expect(after == .connectNow)
    }

    @Test
    func disconnectSettleWindowAppliesToQueuedCandidates() {
        // A candidate can already be queued when its peripheral drops (weak
        // adverts are enqueued even while connected). The post-disconnect
        // queue drain must honor the settle window, not reconnect instantly.
        let scheduler = BLEConnectionScheduler<String>()
        let now = Date()
        scheduler.enqueue(makeCandidate(id: "p1", rssi: -85, now: now))
        scheduler.recordDisconnectError(peripheralID: "p1", at: now)

        let during = scheduler.nextCandidate(
            connectedOrConnectingCount: 0,
            isAlreadyConnectingOrConnected: { _ in false },
            now: now.addingTimeInterval(0.1)
        )
        guard case .retryAfter(let delay) = during else {
            Issue.record("Expected retryAfter during settle window, got \(during)")
            return
        }
        #expect(delay > 0)
        #expect(scheduler.candidateCount == 1)

        let after = scheduler.nextCandidate(
            connectedOrConnectingCount: 0,
            isAlreadyConnectingOrConnected: { _ in false },
            now: now.addingTimeInterval(TransportConfig.bleDisconnectDiscoveryIgnoreSeconds + 1)
        )
        guard case .connect(let candidate) = after else {
            Issue.record("Expected connect after settle window, got \(after)")
            return
        }
        #expect(candidate.peripheralID == "p1")
    }

    @Test
    func connectTimeoutBlocksRediscoveryForFullWindow() {
        let scheduler = BLEConnectionScheduler<String>()
        let now = Date()
        scheduler.recordConnectionTimeout(peripheralID: "p1", at: now)

        let midWindow = scheduler.handleDiscovery(
            makeCandidate(id: "p1", rssi: -80, now: now.addingTimeInterval(10)),
            connectedOrConnectingCount: 0,
            existingState: nil,
            peripheralState: .disconnected,
            now: now.addingTimeInterval(10)
        )
        #expect(midWindow == .ignore)
    }

    @Test
    func repeatedTimeoutsDoNotTightenGlobalRSSIThreshold() {
        // Flaky links are penalized per-peripheral only; timeouts from a few
        // distant peers must not blind us to every other edge-of-range peer.
        let scheduler = BLEConnectionScheduler<String>()
        let now = Date()
        scheduler.recordConnectionTimeout(peripheralID: "p1", at: now)
        scheduler.recordConnectionTimeout(peripheralID: "p2", at: now)
        scheduler.recordConnectionTimeout(peripheralID: "p3", at: now)

        let threshold = scheduler.updateRSSIThreshold(
            connectedCount: 1,
            connectedOrConnectingLinkCount: 1,
            now: now.addingTimeInterval(1)
        )

        #expect(threshold == TransportConfig.bleDynamicRSSIThresholdDefault)
    }

    @Test
    func isolationRelaxesRSSIThresholdOverTime() {
        let scheduler = BLEConnectionScheduler<String>()
        let now = Date()

        let initial = scheduler.updateRSSIThreshold(
            connectedCount: 0,
            connectedOrConnectingLinkCount: 0,
            now: now
        )
        #expect(initial == TransportConfig.bleRSSIIsolatedBase)

        let relaxed = scheduler.updateRSSIThreshold(
            connectedCount: 0,
            connectedOrConnectingLinkCount: 0,
            now: now.addingTimeInterval(TransportConfig.bleIsolationRelaxThresholdSeconds + 1)
        )
        #expect(relaxed == TransportConfig.bleRSSIIsolatedRelaxed)
    }

    @Test
    func rssiThresholdTightensWhenCandidateQueueIsFull() {
        let scheduler = BLEConnectionScheduler<String>(candidateCap: 2)
        let now = Date()
        scheduler.enqueue(makeCandidate(id: "p1", rssi: -65, now: now))
        scheduler.enqueue(makeCandidate(id: "p2", rssi: -66, now: now))

        let threshold = scheduler.updateRSSIThreshold(
            connectedCount: 1,
            connectedOrConnectingLinkCount: 1,
            now: now
        )

        #expect(threshold == TransportConfig.bleRSSIConnectedThreshold)
    }
}

private func makeCandidate(id: String, rssi: Int, now: Date) -> BLEConnectionCandidate<String> {
    BLEConnectionCandidate(
        peripheral: id,
        peripheralID: id,
        rssi: rssi,
        name: id,
        isConnectable: true,
        discoveredAt: now
    )
}
