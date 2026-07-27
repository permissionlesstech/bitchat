import Foundation
import Testing
@testable import bitchat

struct BLEOutboundNotificationBufferTests {
    @Test
    func enqueueStoresNotificationsUntilTaken() {
        var buffer = BLEOutboundNotificationBuffer<String>()

        let result = buffer.enqueue(
            data: Data([0x01]),
            targets: ["central-1"],
            capCount: 2
        )

        if case let .enqueued(count) = result {
            #expect(count == 1)
        } else {
            Issue.record("Expected notification to be enqueued")
        }

        let pending = buffer.takeAll()

        #expect(pending.count == 1)
        #expect(pending.first?.data == Data([0x01]))
        #expect(pending.first?.targets == ["central-1"])
        #expect(buffer.isEmpty)
    }

    @Test
    func enqueueRejectsWhenCapIsFull() {
        var buffer = BLEOutboundNotificationBuffer<String>()

        _ = buffer.enqueue(data: Data([0x01]), targets: nil, capCount: 1)
        let result = buffer.enqueue(data: Data([0x02]), targets: nil, capCount: 1)

        if case let .full(count) = result {
            #expect(count == 1)
        } else {
            Issue.record("Expected full notification buffer")
        }

        #expect(buffer.count == 1)
    }

    @Test
    func prependRestoresUnsentNotificationsAheadOfNewerItems() {
        var buffer = BLEOutboundNotificationBuffer<String>()
        let unsent = [
            BLEPendingNotification(data: Data([0x01]), targets: ["old"])
        ]

        _ = buffer.enqueue(data: Data([0x02]), targets: ["new"], capCount: 4)
        buffer.prepend(unsent)

        let pending = buffer.takeAll()

        #expect(pending.map { Int($0.data.first ?? 0) } == [0x01, 0x02])
    }

    @Test
    func removeAllClearsBufferedNotifications() {
        var buffer = BLEOutboundNotificationBuffer<String>()

        _ = buffer.enqueue(data: Data([0x01]), targets: nil, capCount: 4)
        buffer.removeAll()

        #expect(buffer.isEmpty)
    }

    @Test
    func unsubscribeRemovesTargetSpecificCiphertextOnlyForThatCentral() {
        var buffer = BLEOutboundNotificationBuffer<String>()
        _ = buffer.enqueue(data: Data([1]), targets: ["gone"], capCount: 4)
        _ = buffer.enqueue(data: Data([2]), targets: ["gone", "live"], capCount: 4)
        _ = buffer.enqueue(data: Data([3]), targets: nil, capCount: 4)

        buffer.removeTarget { $0 == "gone" }
        let remaining = buffer.takeAll()

        #expect(remaining.map(\.data) == [Data([2]), Data([3])])
        #expect(remaining[0].targets == ["live"])
        #expect(remaining[1].targets == nil)
    }
}
