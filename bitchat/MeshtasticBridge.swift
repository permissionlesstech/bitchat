//
// MeshtasticBridge.swift
// BitChat Meshtastic Integration
//
// Swift wrapper for the Python Meshtastic bridge service
//

import Foundation
import SwiftUI

struct MeshtasticMessage {
    let messageId: String
    let senderId: String
    let senderName: String
    let content: String
    let messageType: Int
    let channel: String?
    let timestamp: Int
    let ttl: Int
    let encrypted: Bool
}

struct MeshtasticDeviceInfo {
    let deviceId: String
    let name: String
    let interfaceType: String
    let connectionString: String
    let signalStrength: Int?
    let batteryLevel: Int?
    let available: Bool
}

enum MeshtasticStatus: String, CaseIterable {
    case disabled = "disabled"
    case bleActive = "ble_active"
    case checkingMeshtastic = "checking_meshtastic"
    case meshtasticConnecting = "meshtastic_connecting"
    case meshtasticActive = "meshtastic_active"
    case searchingTowers = "searching_towers"
    case fallbackFailed = "fallback_failed"
    
    var displayName: String {
        switch self {
        case .disabled: return "Disabled"
        case .bleActive: return "BLE Active"
        case .checkingMeshtastic: return "Checking Meshtastic"
        case .meshtasticConnecting: return "Connecting"
        case .meshtasticActive: return "Meshtastic Active"
        case .searchingTowers: return "Searching Towers"
        case .fallbackFailed: return "Fallback Failed"
        }
    }
    
    var color: Color {
        switch self {
        case .disabled: return .gray
        case .bleActive: return .green
        case .checkingMeshtastic: return .yellow
        case .meshtasticConnecting: return .orange
        case .meshtasticActive: return .blue
        case .searchingTowers: return .purple
        case .fallbackFailed: return .red
        }
    }
}

@MainActor
class MeshtasticBridge: ObservableObject {
    @Published var isConnected = false
    @Published var status: MeshtasticStatus = .disabled
    @Published var availableDevices: [MeshtasticDeviceInfo] = []
    @Published var lastError: String?
    
    private var bridgeProcess: Process?
    private let bridgeQueue = DispatchQueue(label: "meshtastic.bridge", qos: .utility)
    
    static let shared = MeshtasticBridge()
    
    private init() {
        setupBridge()
    }
    
    private func setupBridge() {
        // Check if Python bridge is available
        checkPythonBridgeAvailability()
    }
    
    func checkPythonBridgeAvailability() -> Bool {
        let fileManager = FileManager.default
        let bridgePath = Bundle.main.path(forResource: "meshtastic_bridge", ofType: "py")
        
        if bridgePath == nil {
            // Try relative path for development
            let currentDir = fileManager.currentDirectoryPath
            let devBridgePath = "\(currentDir)/meshtastic_bridge.py"
            return fileManager.fileExists(atPath: devBridgePath)
        }
        
        return bridgePath != nil
    }
    
    func startBridge() async -> Bool {
        return await withCheckedContinuation { continuation in
            bridgeQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: false)
                    return
                }
                
                let success = self.launchPythonBridge()
                
                DispatchQueue.main.async {
                    self.isConnected = success
                    if success {
                        self.status = .checkingMeshtastic
                    } else {
                        self.status = .fallbackFailed
                        self.lastError = "Failed to start Python bridge"
                    }
                }
                
                continuation.resume(returning: success)
            }
        }
    }
    
    func stopBridge() {
        bridgeProcess?.terminate()
        bridgeProcess?.waitUntilExit()
        bridgeProcess = nil
        
        isConnected = false
        status = .disabled
    }
    
    func scanDevices() async -> [MeshtasticDeviceInfo] {
        guard isConnected else { return [] }
        
        return await withCheckedContinuation { continuation in
            bridgeQueue.async { [weak self] in
                let devices = self?.executeBridgeCommand(["--scan"]) ?? []
                
                DispatchQueue.main.async {
                    self?.availableDevices = devices
                }
                
                continuation.resume(returning: devices)
            }
        }
    }
    
    func sendMessage(_ message: MeshtasticMessage) async -> Bool {
        guard isConnected else { return false }
        
        return await withCheckedContinuation { continuation in
            bridgeQueue.async { [weak self] in
                let success = self?.sendMessageToBridge(message) ?? false
                continuation.resume(returning: success)
            }
        }
    }
    
    func connectToDevice(_ deviceId: String? = nil) async -> Bool {
        guard isConnected else { return false }
        
        status = .meshtasticConnecting
        
        return await withCheckedContinuation { continuation in
            bridgeQueue.async { [weak self] in
                let success = self?.connectDeviceViaBridge(deviceId) ?? false
                
                DispatchQueue.main.async {
                    if success {
                        self?.status = .meshtasticActive
                    } else {
                        self?.status = .fallbackFailed
                        self?.lastError = "Failed to connect to Meshtastic device"
                    }
                }
                
                continuation.resume(returning: success)
            }
        }
    }
    
    private func launchPythonBridge() -> Bool {
        do {
            let process = Process()
            
            // Find Python executable
            guard let pythonPath = findPythonExecutable() else {
                print("Python3 not found")
                return false
            }
            
            // Find bridge script
            guard let bridgeScript = findBridgeScript() else {
                print("Meshtastic bridge script not found")
                return false
            }
            
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = [bridgeScript]
            
            // Set up pipes for communication
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            
            // Start monitoring output
            startMonitoringBridgeOutput(outputPipe, errorPipe)
            
            try process.run()
            bridgeProcess = process
            
            // Give the bridge time to initialize
            Thread.sleep(forTimeInterval: 2.0)
            
            return process.isRunning
            
        } catch {
            print("Error launching Python bridge: \(error)")
            return false
        }
    }
    
    private func findPythonExecutable() -> String? {
        let possiblePaths = [
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/bin/python3"
        ]
        
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        // Try to find python3 in PATH
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return path
            }
        } catch {
            print("Error finding python3: \(error)")
        }
        
        return nil
    }
    
    private func findBridgeScript() -> String? {
        // Try bundle resource first (for production)
        if let bundlePath = Bundle.main.path(forResource: "meshtastic_bridge", ofType: "py") {
            return bundlePath
        }
        
        // Try current directory (for development)
        let currentDir = FileManager.default.currentDirectoryPath
        let devPath = "\(currentDir)/meshtastic_bridge.py"
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        
        return nil
    }
    
    private func startMonitoringBridgeOutput(_ outputPipe: Pipe, _ errorPipe: Pipe) {
        // Monitor stdout
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                let output = String(data: data, encoding: .utf8) ?? ""
                self?.processBridgeOutput(output)
            }
        }
        
        // Monitor stderr
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                let error = String(data: data, encoding: .utf8) ?? ""
                print("Bridge error: \(error)")
                
                DispatchQueue.main.async {
                    self?.lastError = error
                }
            }
        }
    }
    
    private func processBridgeOutput(_ output: String) {
        // Parse JSON responses from the Python bridge
        let lines = output.components(separatedBy: .newlines)
        
        for line in lines {
            if line.isEmpty { continue }
            
            do {
                if let data = line.data(using: .utf8),
                   let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    
                    DispatchQueue.main.async { [weak self] in
                        self?.handleBridgeMessage(json)
                    }
                }
            } catch {
                // Ignore non-JSON output (debug prints, etc.)
            }
        }
    }
    
    private func handleBridgeMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        
        switch type {
        case "status_update":
            if let statusString = message["status"] as? String,
               let newStatus = MeshtasticStatus(rawValue: statusString) {
                status = newStatus
            }
            
        case "device_list":
            if let devicesData = message["devices"] as? [[String: Any]] {
                availableDevices = devicesData.compactMap { parseDeviceInfo($0) }
            }
            
        case "message_received":
            if let messageData = message["message"] as? [String: Any] {
                handleReceivedMessage(messageData)
            }
            
        case "error":
            if let error = message["error"] as? String {
                lastError = error
            }
            
        default:
            break
        }
    }
    
    private func parseDeviceInfo(_ data: [String: Any]) -> MeshtasticDeviceInfo? {
        guard let deviceId = data["device_id"] as? String,
              let name = data["name"] as? String,
              let interfaceType = data["interface_type"] as? String,
              let connectionString = data["connection_string"] as? String else {
            return nil
        }
        
        return MeshtasticDeviceInfo(
            deviceId: deviceId,
            name: name,
            interfaceType: interfaceType,
            connectionString: connectionString,
            signalStrength: data["signal_strength"] as? Int,
            batteryLevel: data["battery_level"] as? Int,
            available: data["available"] as? Bool ?? true
        )
    }
    
    private func handleReceivedMessage(_ data: [String: Any]) {
        // Parse received Meshtastic message and forward to BitChat
        guard let messageId = data["message_id"] as? String,
              let senderId = data["sender_id"] as? String,
              let senderName = data["sender_name"] as? String,
              let content = data["content"] as? String,
              let messageType = data["message_type"] as? Int else {
            return
        }
        
        let message = MeshtasticMessage(
            messageId: messageId,
            senderId: senderId,
            senderName: senderName,
            content: content,
            messageType: messageType,
            channel: data["channel"] as? String,
            timestamp: data["timestamp"] as? Int ?? Int(Date().timeIntervalSince1970),
            ttl: data["ttl"] as? Int ?? 7,
            encrypted: data["encrypted"] as? Bool ?? false
        )
        
        // Forward to BitChat message system
        forwardMessageToBitChat(message)
    }
    
    private func forwardMessageToBitChat(_ message: MeshtasticMessage) {
        // This would integrate with BitChat's existing message handling
        // For now, we'll post a notification that can be caught by the UI
        
        let userInfo: [String: Any] = [
            "source": "meshtastic",
            "message": message
        ]
        
        NotificationCenter.default.post(
            name: NSNotification.Name("MeshtasticMessageReceived"),
            object: nil,
            userInfo: userInfo
        )
    }
    
    private func executeBridgeCommand(_ args: [String]) -> [MeshtasticDeviceInfo] {
        // Execute command via bridge process
        // This is a simplified implementation
        return []
    }
    
    private func sendMessageToBridge(_ message: MeshtasticMessage) -> Bool {
        // Send message via bridge process
        guard let bridgeProcess = bridgeProcess,
              bridgeProcess.isRunning else {
            return false
        }
        
        let messageData: [String: Any] = [
            "type": "send_message",
            "message": [
                "message_id": message.messageId,
                "sender_id": message.senderId,
                "sender_name": message.senderName,
                "content": message.content,
                "message_type": message.messageType,
                "channel": message.channel as Any,
                "timestamp": message.timestamp,
                "ttl": message.ttl,
                "encrypted": message.encrypted
            ]
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: messageData)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                let command = jsonString + "\n"
                bridgeProcess.standardInput?.fileHandleForWriting.write(command.data(using: .utf8) ?? Data())
                return true
            }
        } catch {
            print("Error encoding message for bridge: \(error)")
        }
        
        return false
    }
    
    private func connectDeviceViaBridge(_ deviceId: String?) -> Bool {
        guard let bridgeProcess = bridgeProcess,
              bridgeProcess.isRunning else {
            return false
        }
        
        let command: [String: Any] = [
            "type": "connect_device",
            "device_id": deviceId as Any
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: command)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                let commandString = jsonString + "\n"
                bridgeProcess.standardInput?.fileHandleForWriting.write(commandString.data(using: .utf8) ?? Data())
                return true
            }
        } catch {
            print("Error encoding connect command: \(error)")
        }
        
        return false
    }
    
    deinit {
        stopBridge()
    }
}
