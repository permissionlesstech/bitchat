import Testing
import CoreBluetooth
@testable import bitchat

@MainActor
struct SessionStoreTests {
    private func makeRuntime() -> AppRuntime {
        TestHelpers.resetSharedApplicationState()
        return AppRuntime(transport: MockTransport())
    }

    @Test
    func storeReflectsViewModelSessionUpdates() {
        let runtime = makeRuntime()

        runtime.chatViewModel.showBluetoothAlert = true
        runtime.chatViewModel.bluetoothAlertMessage = "Bluetooth required"
        runtime.chatViewModel.teleportedGeo = ["deadbeef"]

        #expect(runtime.sessionStore.showBluetoothAlert)
        #expect(runtime.sessionStore.bluetoothAlertMessage == "Bluetooth required")
        #expect(runtime.sessionStore.teleportedGeo == ["deadbeef"])
    }

    @Test
    func storeWritesFlowBackToChatViewModel() {
        let runtime = makeRuntime()

        runtime.sessionStore.nickname = "alice"
        runtime.sessionStore.isAppInfoPresented = true

        #expect(runtime.chatViewModel.nickname == "alice")
        #expect(runtime.chatViewModel.isAppInfoPresented)
    }

    @Test
    func transportStateUpdatesFlowBackToChatViewModel() {
        let runtime = makeRuntime()

        runtime.sessionStore.setConnected(true)
        runtime.sessionStore.setBluetoothState(.unsupported)

        #expect(runtime.chatViewModel.isConnected)
        #expect(runtime.chatViewModel.bluetoothState == .unsupported)
        #expect(runtime.chatViewModel.showBluetoothAlert)
    }
}
