import CoreBluetooth
import Testing
@testable import bitchat

struct ChatBluetoothAlertPolicyTests {
    @Test
    func poweredOffShowsAlertMessage() {
        let update = ChatBluetoothAlertPolicy.update(for: .poweredOff)

        #expect(update.isPresented)
        #expect(update.message?.isEmpty == false)
    }

    @Test
    func unauthorizedShowsAlertMessage() {
        let update = ChatBluetoothAlertPolicy.update(for: .unauthorized)

        #expect(update.isPresented)
        #expect(update.message?.isEmpty == false)
    }

    @Test
    func poweredOnHidesAndClearsAlertMessage() {
        let update = ChatBluetoothAlertPolicy.update(for: .poweredOn)

        #expect(!update.isPresented)
        #expect(update.message == "")
    }

    @Test
    func transientStatesHideWithoutChangingAlertMessage() {
        let unknown = ChatBluetoothAlertPolicy.update(for: .unknown)
        let resetting = ChatBluetoothAlertPolicy.update(for: .resetting)

        #expect(!unknown.isPresented)
        #expect(unknown.message == nil)
        #expect(!resetting.isPresented)
        #expect(resetting.message == nil)
    }
}
