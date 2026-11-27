import CoreBluetooth
import Foundation
import Testing
@testable import bitchat

struct BLELinkCommandTests {
    @Test func notifyCentralsCarriesExpectedPayloadAndBackpressurePolicy() {
        let characteristic = CBMutableCharacteristic(
            type: CBUUID(string: "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D"),
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )
        let payload = Data([0x01, 0x02, 0x03])
        let command = BLELinkCommand.notifyCentrals(
            data: payload,
            characteristic: characteristic,
            centrals: nil,
            enqueueOnBackpressure: true,
            context: "broadcast"
        )

        if case .notifyCentrals(let data, let ch, let centrals, let enqueue, let context) = command {
            #expect(data == payload)
            #expect(ch === characteristic)
            #expect(centrals == nil)
            #expect(enqueue == true)
            #expect(context == "broadcast")
        } else {
            Issue.record("Expected notifyCentrals command")
        }
    }

    @Test func clearPendingNotificationsCaseMatches() {
        let command = BLELinkCommand.clearPendingNotifications
        if case .clearPendingNotifications = command {
            #expect(true)
        } else {
            Issue.record("Expected clearPendingNotifications command")
        }
    }
}
