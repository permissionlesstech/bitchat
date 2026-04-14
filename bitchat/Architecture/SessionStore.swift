import CoreBluetooth
import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published var nickname: String = "" {
        didSet {
            let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != nickname {
                nickname = trimmed
                return
            }
            guard oldValue != nickname else { return }
            onNicknameChanged?(nickname)
        }
    }
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var teleportedGeo: Set<String> = []
    @Published var showBluetoothAlert: Bool = false
    @Published private(set) var bluetoothAlertMessage: String = ""
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published var isLocationChannelsSheetPresented: Bool = false
    @Published var isAppInfoPresented: Bool = false
    @Published var showScreenshotPrivacyWarning: Bool = false
    @Published private(set) var isBatchingPublic: Bool = false

    private let onNicknameChanged: ((String) -> Void)?

    init(onNicknameChanged: ((String) -> Void)? = nil) {
        self.onNicknameChanged = onNicknameChanged
    }

    func setConnected(_ isConnected: Bool) {
        guard self.isConnected != isConnected else { return }
        self.isConnected = isConnected
    }

    func replaceTeleportedGeo(_ teleportedGeo: Set<String>) {
        guard self.teleportedGeo != teleportedGeo else { return }
        self.teleportedGeo = teleportedGeo
    }

    func setPublicBatching(_ isBatching: Bool) {
        guard isBatchingPublic != isBatching else { return }
        isBatchingPublic = isBatching
    }

    func setBluetoothAlertMessage(_ message: String) {
        guard bluetoothAlertMessage != message else { return }
        bluetoothAlertMessage = message
    }

    func setBluetoothState(_ state: CBManagerState) {
        if bluetoothState != state {
            bluetoothState = state
        }

        switch state {
        case .poweredOff:
            setBluetoothAlertMessage(
                String(localized: "content.alert.bluetooth_required.off", comment: "Message shown when Bluetooth is turned off")
            )
            showBluetoothAlert = true
        case .unauthorized:
            setBluetoothAlertMessage(
                String(localized: "content.alert.bluetooth_required.permission", comment: "Message shown when Bluetooth permission is missing")
            )
            showBluetoothAlert = true
        case .unsupported:
            setBluetoothAlertMessage(
                String(localized: "content.alert.bluetooth_required.unsupported", comment: "Message shown when the device lacks Bluetooth support")
            )
            showBluetoothAlert = true
        case .poweredOn:
            showBluetoothAlert = false
            setBluetoothAlertMessage("")
        case .unknown, .resetting:
            showBluetoothAlert = false
            setBluetoothAlertMessage("")
        @unknown default:
            showBluetoothAlert = false
            setBluetoothAlertMessage("")
        }
    }
}
