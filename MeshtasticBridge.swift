import Foundation
import Combine

/**
 * BitChat Meshtastic Bridge
 * 
 * Swift wrapper for the Python Meshtastic bridge service that handles
 * device management and message routing between BitChat and LoRa mesh networks.
 */
class MeshtasticBridge: ObservableObject {
    
    @Published var isActive = false
    @Published var status: FallbackStatus = .disabled
    @Published var availableDevices: [MeshtasticDeviceInfo] = []
    @Published var connectedDevice: MeshtasticDeviceInfo?
    @Published var errorMessage: String?
    
    private var pythonProcess: Process?
    private var bridgeConfig: MeshtasticConfiguration
    private var messageCallbacks: [(Data) -> Void] = []
    
    init() {
        self.bridgeConfig = MeshtasticConfiguration()
        setupBridge()
    }
    
    // MARK: - Public Interface
    
    func start() -> Bool {
        guard bridgeConfig.isEnabled else {
            status = .disabled
            return false
        }
        
        status = .checkingMeshtastic
        return startPythonBridge()
    }
    
    func stop() {
        stopPythonBridge()
        status = .disabled
        isActive = false
        connectedDevice = nil
    }
    
    func scanForDevices() {
        guard isActive else { return }
        
        executePythonCommand("scan_devices") { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    self?.handleDeviceScanResult(data)
                case .failure(let error):
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    func connect(to deviceId: String) {
        guard isActive else { return }
        
        status = .meshtasticConnecting
        
        let command = ["connect_device", deviceId]
        executePythonCommand(command.joined(separator: " ")) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    self?.handleConnectionResult(data, deviceId: deviceId)
                case .failure(let error):
                    self?.status = .fallbackFailed
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    func sendMessage(_ message: BitChatMessage) -> AnyPublisher<FallbackResponse, Error> {
        return Future { [weak self] promise in
            guard let self = self, self.isActive else {
                promise(.failure(MeshtasticError.bridgeNotActive))
                return
            }
            
            do {
                let messageData = try JSONEncoder().encode(message)
                let messageString = String(data: messageData, encoding: .utf8) ?? ""
                
                self.executePythonCommand("send_message \(messageString)") { result in
                    switch result {
                    case .success(let data):
                        do {
                            let response = try JSONDecoder().decode(FallbackResponse.self, from: data)
                            promise(.success(response))
                        } catch {
                            promise(.failure(error))
                        }
                    case .failure(let error):
                        promise(.failure(error))
                    }
                }
            } catch {
                promise(.failure(error))
            }
        }
        .eraseToAnyPublisher()
    }
    
    func addMessageCallback(_ callback: @escaping (Data) -> Void) {
        messageCallbacks.append(callback)
    }
    
    func checkFallbackNeeded(bleActivityTimestamp: TimeInterval) -> Bool {
        guard bridgeConfig.shouldAutoFallback else { return false }
        
        let currentTime = Date().timeIntervalSince1970
        let timeSinceActivity = currentTime - bleActivityTimestamp
        
        return timeSinceActivity > Double(bridgeConfig.fallbackThreshold)
    }
    
    // MARK: - Private Implementation
    
    private func setupBridge() {
        // Initialize configuration
        bridgeConfig.load()
    }
    
    private func startPythonBridge() -> Bool {
        guard pythonProcess == nil else { return true }
        
        pythonProcess = Process()
        pythonProcess?.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        pythonProcess?.arguments = [
            "meshtastic_bridge.py",
            "--interactive"
        ]
        
        // Setup pipes for communication
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        pythonProcess?.standardInput = inputPipe
        pythonProcess?.standardOutput = outputPipe
        pythonProcess?.standardError = errorPipe
        
        // Monitor output
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                self?.handlePythonOutput(data)
            }
        }
        
        // Monitor errors
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let errorString = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.errorMessage = errorString
                }
            }
        }
        
        do {
            try pythonProcess?.run()
            isActive = true
            return true
        } catch {
            errorMessage = "Failed to start Python bridge: \(error.localizedDescription)"
            return false
        }
    }
    
    private func stopPythonBridge() {
        pythonProcess?.terminate()
        pythonProcess = nil
        isActive = false
    }
    
    private func executePythonCommand(_ command: String, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let process = pythonProcess,
              let inputHandle = process.standardInput as? FileHandle else {
            completion(.failure(MeshtasticError.bridgeNotActive))
            return
        }
        
        let commandData = "\(command)\n".data(using: .utf8) ?? Data()
        inputHandle.write(commandData)
        
        // Response handling is done via output monitoring
        // This is a simplified implementation - in practice you'd need request/response correlation
    }
    
    private func handlePythonOutput(_ data: Data) {
        guard let outputString = String(data: data, encoding: .utf8) else { return }
        
        // Parse different types of output from Python bridge
        let lines = outputString.components(separatedBy: .newlines)
        
        for line in lines {
            if line.hasPrefix("STATUS:") {
                handleStatusUpdate(line)
            } else if line.hasPrefix("MESSAGE:") {
                handleIncomingMessage(line)
            } else if line.hasPrefix("DEVICES:") {
                handleDeviceUpdate(line)
            }
        }
    }
    
    private func handleStatusUpdate(_ line: String) {
        let statusString = String(line.dropFirst("STATUS:".count)).trimmingCharacters(in: .whitespaces)
        
        DispatchQueue.main.async {
            if let newStatus = FallbackStatus(rawValue: statusString) {
                self.status = newStatus
            }
        }
    }
    
    private func handleIncomingMessage(_ line: String) {
        let messageString = String(line.dropFirst("MESSAGE:".count)).trimmingCharacters(in: .whitespaces)
        
        if let messageData = messageString.data(using: .utf8) {
            // Notify all message callbacks
            messageCallbacks.forEach { callback in
                callback(messageData)
            }
        }
    }
    
    private func handleDeviceUpdate(_ line: String) {
        let devicesString = String(line.dropFirst("DEVICES:".count)).trimmingCharacters(in: .whitespaces)
        
        if let devicesData = devicesString.data(using: .utf8) {
            do {
                let devices = try JSONDecoder().decode([MeshtasticDeviceInfo].self, from: devicesData)
                DispatchQueue.main.async {
                    self.availableDevices = devices
                }
            } catch {
                // Handle decoding error
            }
        }
    }
    
    private func handleDeviceScanResult(_ data: Data) {
        do {
            let devices = try JSONDecoder().decode([MeshtasticDeviceInfo].self, from: data)
            availableDevices = devices
        } catch {
            errorMessage = "Failed to parse device scan results"
        }
    }
    
    private func handleConnectionResult(_ data: Data, deviceId: String) {
        // Parse connection result and update status
        if let device = availableDevices.first(where: { $0.deviceId == deviceId }) {
            connectedDevice = device
            status = .meshtasticActive
            bridgeConfig.setPreferredDevice(deviceId)
        } else {
            status = .fallbackFailed
            errorMessage = "Failed to connect to device"
        }
    }
}

// MARK: - Supporting Types

enum MeshtasticError: Error, LocalizedError {
    case bridgeNotActive
    case deviceNotFound
    case connectionFailed
    case sendFailed
    
    var errorDescription: String? {
        switch self {
        case .bridgeNotActive:
            return "Meshtastic bridge is not active"
        case .deviceNotFound:
            return "Meshtastic device not found"
        case .connectionFailed:
            return "Failed to connect to Meshtastic device"
        case .sendFailed:
            return "Failed to send message via Meshtastic"
        }
    }
}

struct FallbackResponse: Codable {
    let success: Bool
    let messageId: String
    let status: FallbackStatus
    let errorMessage: String?
    let meshtasticNodeId: String?
    let hopsUsed: Int?
    let signalQuality: Double?
}

struct BitChatMessage: Codable {
    let messageId: String
    let senderId: String
    let senderName: String
    let content: String
    let messageType: MessageType
    let channel: String?
    let timestamp: Int?
    let ttl: Int
    let encrypted: Bool
    
    enum MessageType: Int, Codable {
        case text = 0
        case privateMessage = 1
        case channelJoin = 2
        case channelLeave = 3
        case userInfo = 4
        case system = 5
        case encrypted = 6
    }
}

struct MeshtasticDeviceInfo: Codable, Identifiable {
    let id = UUID()
    let deviceId: String
    let name: String
    let interfaceType: String
    let connectionString: String
    let signalStrength: Int?
    let batteryLevel: Int?
    let available: Bool
    
    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case name
        case interfaceType = "interface_type"
        case connectionString = "connection_string"
        case signalStrength = "signal_strength"
        case batteryLevel = "battery_level"
        case available
    }
}

enum FallbackStatus: String, Codable, CaseIterable {
    case disabled = "disabled"
    case bleActive = "ble_active"
    case checkingMeshtastic = "checking_meshtastic"
    case meshtasticConnecting = "meshtastic_connecting"
    case meshtasticActive = "meshtastic_active"
    case searchingTowers = "searching_towers"
    case fallbackFailed = "fallback_failed"
    
    var displayName: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .bleActive:
            return "Bluetooth Active"
        case .checkingMeshtastic:
            return "Checking Meshtastic"
        case .meshtasticConnecting:
            return "Connecting..."
        case .meshtasticActive:
            return "LoRa Mesh Active"
        case .searchingTowers:
            return "Searching Towers"
        case .fallbackFailed:
            return "Connection Failed"
        }
    }
    
    var color: Color {
        switch self {
        case .disabled:
            return .gray
        case .bleActive:
            return .blue
        case .checkingMeshtastic, .meshtasticConnecting, .searchingTowers:
            return .orange
        case .meshtasticActive:
            return .green
        case .fallbackFailed:
            return .red
        }
    }
}