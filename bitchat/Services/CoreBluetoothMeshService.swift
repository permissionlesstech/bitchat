import CoreBluetooth
import Foundation // For UUIDs

// MARK: - Bluetooth UUIDs (Must match ESP32S3 firmware)
// These CBUUIDs should be defined with the exact same string values
// as you configure in your ESP32S3 firmware.
struct BluetoothMeshServiceUUIDs {
    static let MeshServiceUUID = CBUUID(string: "YOUR_MESH_SERVICE_UUID") // E.g., "4A00" or a full UUID string
    static let CommandCharacteristicUUID = CBUUID(string: "YOUR_COMMAND_CHAR_UUID") // E.g., "4A01"
    static let DataCharacteristicUUID = CBUUID(string: "YOUR_DATA_CHAR_UUID")     // E.g., "4A02"
}

// MARK: - BluetoothMeshService Class
class BluetoothMeshService: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    // ObservableObject allows SwiftUI Views to observe this service
    @Published var isConnected: Bool = false
    @Published var receivedData: String = "" // Holds data received from the mesh network
    @Published var statusMessage: String = "Bluetooth Ready"

    var centralManager: CBCentralManager!
    var esp32Peripheral: CBPeripheral?
    var commandCharacteristic: CBCharacteristic? // For sending commands
    var dataCharacteristic: CBCharacteristic?     // For receiving data

    override init() {
        super.init()
        // Initialize the CoreBluetooth central manager
        // queue: nil means it will use the main Dispatch Queue
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - CBCentralManagerDelegate Methods

    // Monitors changes in Bluetooth state (on/off, etc.)
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            statusMessage = "Bluetooth Powered On. Searching for ESP32S3..."
            // It's recommended to scan for a specific service UUID
            centralManager.scanForPeripherals(withServices: [BluetoothMeshServiceUUIDs.MeshServiceUUID], options: nil)
        case .poweredOff:
            statusMessage = "Bluetooth Powered Off."
            isConnected = false
        case .resetting:
            statusMessage = "Bluetooth Resetting."
        case .unauthorized:
            statusMessage = "Bluetooth Unauthorized."
        case .unsupported:
            statusMessage = "Bluetooth Not Supported."
        case .unknown:
            statusMessage = "Bluetooth State Unknown."
        @unknown default:
            statusMessage = "Unknown Bluetooth State."
        }
    }

    // Called when a peripheral is discovered
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Check if the device name contains "ESP32" or if it advertises your specific UUID
        // Make sure your ESP32S3 advertises a recognizable name or service UUID
        if peripheral.name?.contains("ESP32") == true { // Or check service UUID from advertisementData
            statusMessage = "ESP32S3 found: \(peripheral.name ?? "Unknown Device")"
            esp32Peripheral = peripheral
            esp32Peripheral?.delegate = self // Set the peripheral's delegate
            centralManager.stopScan() // Stop scanning
            centralManager.connect(peripheral, options: nil) // Connect to the device
        }
    }

    // Called when successfully connected to a peripheral
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        statusMessage = "Connected to \(peripheral.name ?? "Device"). Discovering services..."
        peripheral.discoverServices([BluetoothMeshServiceUUIDs.MeshServiceUUID]) // Discover only the relevant service
    }

    // Called when the peripheral connection is disconnected
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        statusMessage = "Disconnected from \(peripheral.name ?? "Device"). Reconnecting..."
        // Start scanning again when connection is lost
        centralManager.scanForPeripherals(withServices: [BluetoothMeshServiceUUIDs.MeshServiceUUID], options: nil)
    }

    // MARK: - CBPeripheralDelegate Methods

    // Called when services are discovered
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            if service.uuid == BluetoothMeshServiceUUIDs.MeshServiceUUID {
                statusMessage = "Mesh Service discovered. Searching for characteristics..."
                // Discover characteristics for the relevant service
                peripheral.discoverCharacteristics([BluetoothMeshServiceUUIDs.CommandCharacteristicUUID, BluetoothMeshServiceUUIDs.DataCharacteristicUUID], for: service)
            }
        }
    }

    // Called when characteristics are discovered
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            if characteristic.uuid == BluetoothMeshServiceUUIDs.CommandCharacteristicUUID {
                commandCharacteristic = characteristic
                statusMessage = "Command Characteristic found."
            } else if characteristic.uuid == BluetoothMeshServiceUUIDs.DataCharacteristicUUID {
                dataCharacteristic = characteristic
                // We want to receive notifications from this characteristic (for mesh data)
                peripheral.setNotifyValue(true, for: characteristic)
                statusMessage = "Data Characteristic found and notifications set."
            }
        }
    }

    // Called when characteristic values are updated (notification received)
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BluetoothMeshServiceUUIDs.DataCharacteristicUUID,
              let data = characteristic.value else { return }

        // Convert the incoming data to a String and display it (for example)
        if let message = String(data: data, encoding: .utf8) {
            receivedData = message // @Published property automatically updates UI
            statusMessage = "Data received from mesh: \(message)"
        }
    }

    // MARK: - Function to Send Commands from App to Mesh

    // Sends a command from the mobile app to the ESP32S3, and from there to the mesh network
    func sendCommandToMesh(command: String) {
        guard let peripheral = esp32Peripheral,
              let characteristic = commandCharacteristic else {
            statusMessage = "ESP32S3 not connected or command characteristic not found."
            return
        }

        if let data = command.data(using: .utf8) {
            // Write with response (get acknowledgment if write was successful)
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            statusMessage = "Command sent: \(command)"
        }
    }

    // MARK: - Communication Mode Switching (BT Mesh vs. WiFi Mesh)

    // Logic to switch between WiFi Mesh and Bluetooth Mesh (can be within this service or elsewhere)
    // This part depends on your overall application architecture and how your WiFi mesh solution works.
    func switchCommunicationMode(to mode: CommunicationMode) {
        switch mode {
        case .bluetoothMesh:
            if !isConnected {
                statusMessage = "Switching to Bluetooth Mesh mode. Searching for ESP32S3..."
                centralManager.scanForPeripherals(withServices: [BluetoothMeshServiceUUIDs.MeshServiceUUID], options: nil)
            } else {
                statusMessage = "Already in Bluetooth Mesh mode."
            }
            // Logic to disable WiFi connection or lower its priority would go here
        case .wifiMesh:
            statusMessage = "Switching to WiFi Mesh mode."
            // Disconnect current Bluetooth connection
            if let peripheral = esp32Peripheral {
                centralManager.cancelPeripheralConnection(peripheral)
                self.esp32Peripheral = nil // Reset the reference
                self.commandCharacteristic = nil
                self.dataCharacteristic = nil
            }
            // Logic to initiate or activate WiFi connection would go here
            // This might be managed by a separate `WiFiMeshService` class.
        }
    }
}

// Enum for communication modes
enum CommunicationMode {
    case bluetoothMesh
    case wifiMesh
}
