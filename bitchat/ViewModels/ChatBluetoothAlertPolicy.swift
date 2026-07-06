import CoreBluetooth
import Foundation

struct ChatBluetoothAlertUpdate: Equatable {
    let isPresented: Bool
    let message: String?
}

enum ChatBluetoothAlertPolicy {
    static func update(for state: CBManagerState) -> ChatBluetoothAlertUpdate {
        switch state {
        case .poweredOff:
            ChatBluetoothAlertUpdate(
                isPresented: true,
                message: String(localized: "content.alert.bluetooth_required.off", defaultValue: "bluetooth is turned off. please turn on bluetooth in settings to use bitchat.", comment: "Message shown when Bluetooth is turned off")
            )
        case .unauthorized:
            ChatBluetoothAlertUpdate(
                isPresented: true,
                message: String(localized: "content.alert.bluetooth_required.permission", defaultValue: "bitchat needs bluetooth permission to connect with nearby devices. please enable bluetooth access in settings.", comment: "Message shown when Bluetooth permission is missing")
            )
        case .unsupported:
            ChatBluetoothAlertUpdate(
                isPresented: true,
                message: String(localized: "content.alert.bluetooth_required.unsupported", defaultValue: "this device does not support bluetooth. bitchat requires bluetooth to function.", comment: "Message shown when the device lacks Bluetooth support")
            )
        case .poweredOn:
            ChatBluetoothAlertUpdate(isPresented: false, message: "")
        case .unknown, .resetting:
            ChatBluetoothAlertUpdate(isPresented: false, message: nil)
        @unknown default:
            ChatBluetoothAlertUpdate(isPresented: false, message: nil)
        }
    }
}
