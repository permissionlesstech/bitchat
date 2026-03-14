import Testing
import CoreBluetooth
@testable import bitchat

@MainActor
struct SessionStoreTests {

    @Test
    func storeReflectsViewModelSessionUpdates() {
        let runtime = AppRuntime()

        runtime.chatViewModel.showBluetoothAlert = true
        runtime.chatViewModel.bluetoothAlertMessage = "Bluetooth required"
        runtime.chatViewModel.teleportedGeo = ["deadbeef"]

        #expect(runtime.sessionStore.showBluetoothAlert)
        #expect(runtime.sessionStore.bluetoothAlertMessage == "Bluetooth required")
        #expect(runtime.sessionStore.teleportedGeo == ["deadbeef"])
    }

    @Test
    func storeWritesFlowBackToChatViewModel() {
        let runtime = AppRuntime()

        runtime.sessionStore.nickname = "alice"
        runtime.sessionStore.isAppInfoPresented = true

        #expect(runtime.chatViewModel.nickname == "alice")
        #expect(runtime.chatViewModel.isAppInfoPresented)
    }

    @Test
    func transportStateUpdatesFlowBackToChatViewModel() {
        let runtime = AppRuntime()

        runtime.sessionStore.setConnected(true)
        runtime.sessionStore.setBluetoothState(.unsupported)

        #expect(runtime.chatViewModel.isConnected)
        #expect(runtime.chatViewModel.bluetoothState == .unsupported)
        #expect(runtime.chatViewModel.showBluetoothAlert)
    }
}
