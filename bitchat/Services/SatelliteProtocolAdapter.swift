//
// SatelliteProtocolAdapter.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Combine
import CryptoKit

// Satellite message types for the SatMesh extension
enum SatelliteMessageType: UInt8 {
    case emergencyBroadcast = 0x20
    case globalMessage = 0x21
    case satelliteAck = 0x22
    case satelliteStatus = 0x23
    case satelliteQueue = 0x24
    case emergencySOS = 0x25
    case disasterRelay = 0x26
    case globalRouting = 0x27
}

// Satellite packet structure
struct SatellitePacket: Codable {
    let version: UInt8
    let type: UInt8
    let senderID: Data
    let recipientID: Data?
    let timestamp: UInt64
    let payload: Data
    let signature: Data?
    let priority: UInt8 // 0=low, 1=normal, 2=high, 3=emergency
    let ttl: UInt8
    let satelliteID: String? // Which satellite constellation
    let routingPath: [String]? // Multi-path routing information
    
    init(type: UInt8, senderID: Data, recipientID: Data?, payload: Data, priority: UInt8 = 1, satelliteID: String? = nil, routingPath: [String]? = nil) {
        self.version = 1
        self.type = type
        self.senderID = senderID
        self.recipientID = recipientID
        self.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        self.payload = payload
        self.signature = nil
        self.priority = priority
        self.ttl = 10 // Higher TTL for satellite routing
        self.satelliteID = satelliteID
        self.routingPath = routingPath
    }
    
    var data: Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func from(_ data: Data) -> SatellitePacket? {
        try? JSONDecoder().decode(SatellitePacket.self, from: data)
    }
}

// Emergency message structure
struct EmergencyMessage: Codable {
    let messageID: String
    let senderID: String
    let senderNickname: String
    let content: String
    let emergencyType: EmergencyType
    let location: LocationData?
    let timestamp: Date
    let expiresAt: Date
    
    enum EmergencyType: String, Codable {
        case sos = "sos"
        case disaster = "disaster"
        case medical = "medical"
        case security = "security"
        case weather = "weather"
    }
    
    struct LocationData: Codable {
        let latitude: Double
        let longitude: Double
        let accuracy: Double?
        let timestamp: Date
    }
}

// Global addressing structure
struct GlobalAddress: Codable {
    let peerID: String
    let publicKey: Data
    let location: LocationData?
    let lastSeen: Date
    let satelliteGateway: String? // Which gateway last saw this peer
    let routingInfo: RoutingInfo?
    
    struct RoutingInfo: Codable {
        let preferredPath: [String]
        let backupPaths: [[String]]
        let latency: TimeInterval
        let reliability: Double
    }
}

// Satellite gateway status
struct SatelliteGatewayStatus: Codable {
    let gatewayID: String
    let isOnline: Bool
    let batteryLevel: Float
    let signalStrength: Int
    let satelliteConnection: SatelliteConnection?
    let lastHeartbeat: Date
    let messageQueueSize: Int
    let emergencyQueueSize: Int
    
    struct SatelliteConnection: Codable {
        let constellation: String // "iridium", "starlink", "globalstar"
        let signalQuality: Int // 0-100
        let dataRate: Double // bits per second
        let latency: TimeInterval
        let nextPass: Date?
    }
}

protocol SatelliteProtocolAdapterDelegate: AnyObject {
    func didReceiveSatelliteMessage(_ message: SatellitePacket)
    func didUpdateGatewayStatus(_ status: SatelliteGatewayStatus)
    func didReceiveEmergencyBroadcast(_ emergency: EmergencyMessage)
    func didUpdateGlobalAddresses(_ addresses: [GlobalAddress])
    func satelliteConnectionChanged(_ isConnected: Bool)
}

class SatelliteProtocolAdapter: ObservableObject {
    static let shared = SatelliteProtocolAdapter()
    
    @Published var isConnected = false
    @Published var gatewayStatus: SatelliteGatewayStatus?
    @Published var globalAddresses: [GlobalAddress] = []
    @Published var emergencyQueue: [EmergencyMessage] = []
    @Published var messageQueue: [SatellitePacket] = []
    
    weak var delegate: SatelliteProtocolAdapterDelegate?
    
    private let encryptionService = EncryptionService()
    private let messageQueue = DispatchQueue(label: "satellite.messageQueue", attributes: .concurrent)
    private var cancellables = Set<AnyCancellable>()
    
    // Satellite connection management
    private var satelliteModem: SatelliteModem?
    private var connectionTimer: Timer?
    private var heartbeatTimer: Timer?
    
    // Message prioritization
    private let emergencyPriority = 3
    private let highPriority = 2
    private let normalPriority = 1
    private let lowPriority = 0
    
    // Bandwidth optimization
    private let compressionUtil = CompressionUtil()
    private let maxMessageSize = 500 // Optimized for satellite packets
    private var messageDeduplication = Set<String>()
    
    // Store-and-forward queue
    private var storeAndForwardQueue: [SatellitePacket] = []
    private let maxQueueSize = 1000
    private var queueTimer: Timer?
    
    init() {
        setupSatelliteConnection()
        startHeartbeat()
        startQueueProcessing()
    }
    
    // MARK: - Satellite Connection Management
    
    private func setupSatelliteConnection() {
        // Initialize satellite modem (placeholder for actual hardware integration)
        satelliteModem = SatelliteModem()
        
        // Set up connection monitoring
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkSatelliteConnection()
        }
    }
    
    private func checkSatelliteConnection() {
        guard let modem = satelliteModem else { return }
        
        let wasConnected = isConnected
        isConnected = modem.isConnected
        
        if wasConnected != isConnected {
            delegate?.satelliteConnectionChanged(isConnected)
            
            if isConnected {
                // Process queued messages when connection is restored
                processQueuedMessages()
            }
        }
        
        // Update gateway status
        updateGatewayStatus()
    }
    
    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.sendHeartbeat()
        }
    }
    
    private func sendHeartbeat() {
        let heartbeat = SatellitePacket(
            type: SatelliteMessageType.satelliteStatus.rawValue,
            senderID: getGatewayID().data(using: .utf8)!,
            recipientID: nil,
            payload: createStatusPayload(),
            priority: lowPriority
        )
        
        sendSatelliteMessage(heartbeat)
    }
    
    private func createStatusPayload() -> Data {
        let status = SatelliteGatewayStatus(
            gatewayID: getGatewayID(),
            isOnline: isConnected,
            batteryLevel: getBatteryLevel(),
            signalStrength: getSignalStrength(),
            satelliteConnection: getSatelliteConnection(),
            lastHeartbeat: Date(),
            messageQueueSize: messageQueue.count,
            emergencyQueueSize: emergencyQueue.count
        )
        
        return (try? JSONEncoder().encode(status)) ?? Data()
    }
    
    // MARK: - Message Handling
    
    func sendEmergencyMessage(_ emergency: EmergencyMessage) {
        let packet = SatellitePacket(
            type: SatelliteMessageType.emergencySOS.rawValue,
            senderID: emergency.senderID.data(using: .utf8)!,
            recipientID: nil,
            payload: (try? JSONEncoder().encode(emergency)) ?? Data(),
            priority: emergencyPriority,
            satelliteID: getPreferredSatellite()
        )
        
        // Emergency messages bypass normal queue
        sendSatelliteMessage(packet)
        
        // Also add to emergency queue for local tracking
        emergencyQueue.append(emergency)
    }
    
    func sendGlobalMessage(_ message: BitchatMessage, priority: UInt8 = normalPriority) {
        let packet = SatellitePacket(
            type: SatelliteMessageType.globalMessage.rawValue,
            senderID: message.senderPeerID?.data(using: .utf8) ?? Data(),
            recipientID: nil,
            payload: (try? JSONEncoder().encode(message)) ?? Data(),
            priority: priority
        )
        
        if priority >= emergencyPriority {
            // High priority messages sent immediately
            sendSatelliteMessage(packet)
        } else {
            // Normal messages go to queue
            addToMessageQueue(packet)
        }
    }
    
    func sendSatelliteMessage(_ packet: SatellitePacket) {
        guard let modem = satelliteModem, isConnected else {
            // Store for later if not connected
            addToStoreAndForwardQueue(packet)
            return
        }
        
        // Compress payload for bandwidth optimization
        let compressedPayload = compressionUtil.compress(packet.payload)
        var compressedPacket = packet
        compressedPacket.payload = compressedPayload
        
        // Send via satellite modem
        modem.sendMessage(compressedPacket.data ?? Data())
    }
    
    func receiveSatelliteMessage(_ data: Data) {
        guard let packet = SatellitePacket.from(data) else { return }
        
        // Decompress payload
        let decompressedPayload = compressionUtil.decompress(packet.payload)
        var decompressedPacket = packet
        decompressedPacket.payload = decompressedPayload
        
        // Handle different message types
        switch packet.type {
        case SatelliteMessageType.emergencySOS.rawValue:
            handleEmergencyMessage(packet)
        case SatelliteMessageType.globalMessage.rawValue:
            handleGlobalMessage(packet)
        case SatelliteMessageType.satelliteAck.rawValue:
            handleSatelliteAck(packet)
        case SatelliteMessageType.satelliteStatus.rawValue:
            handleSatelliteStatus(packet)
        default:
            print("Unknown satellite message type: \(packet.type)")
        }
        
        delegate?.didReceiveSatelliteMessage(packet)
    }
    
    // MARK: - Message Processing
    
    private func handleEmergencyMessage(_ packet: SatellitePacket) {
        guard let emergency = try? JSONDecoder().decode(EmergencyMessage.self, from: packet.payload) else { return }
        
        // Add to emergency queue
        emergencyQueue.append(emergency)
        
        // Notify delegate
        delegate?.didReceiveEmergencyBroadcast(emergency)
        
        // Relay to local Bluetooth mesh if needed
        relayToLocalMesh(emergency)
    }
    
    private func handleGlobalMessage(_ packet: SatellitePacket) {
        guard let message = try? JSONDecoder().decode(BitchatMessage.self, from: packet.payload) else { return }
        
        // Add to message queue
        messageQueue.append(packet)
        
        // Relay to local Bluetooth mesh
        relayToLocalMesh(message)
    }
    
    private func handleSatelliteAck(_ packet: SatellitePacket) {
        // Handle acknowledgment of sent messages
        print("Received satellite ACK for message")
    }
    
    private func handleSatelliteStatus(_ packet: SatellitePacket) {
        guard let status = try? JSONDecoder().decode(SatelliteGatewayStatus.self, from: packet.payload) else { return }
        
        // Update global addresses if this is from another gateway
        if status.gatewayID != getGatewayID() {
            updateGlobalAddresses(from: status)
        }
        
        delegate?.didUpdateGatewayStatus(status)
    }
    
    // MARK: - Queue Management
    
    private func addToMessageQueue(_ packet: SatellitePacket) {
        messageQueue.append(packet)
        
        // Maintain queue size
        if messageQueue.count > maxQueueSize {
            messageQueue.removeFirst()
        }
    }
    
    private func addToStoreAndForwardQueue(_ packet: SatellitePacket) {
        storeAndForwardQueue.append(packet)
        
        // Maintain queue size
        if storeAndForwardQueue.count > maxQueueSize {
            storeAndForwardQueue.removeFirst()
        }
    }
    
    private func startQueueProcessing() {
        queueTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.processQueuedMessages()
        }
    }
    
    private func processQueuedMessages() {
        guard isConnected else { return }
        
        // Process emergency messages first
        let emergencyMessages = messageQueue.filter { $0.priority >= emergencyPriority }
        for message in emergencyMessages {
            sendSatelliteMessage(message)
            messageQueue.removeAll { $0.id == message.id }
        }
        
        // Process normal messages (limit to avoid overwhelming the connection)
        let normalMessages = messageQueue.prefix(10)
        for message in normalMessages {
            sendSatelliteMessage(message)
            messageQueue.removeAll { $0.id == message.id }
        }
        
        // Process store-and-forward queue
        let storedMessages = storeAndForwardQueue.prefix(5)
        for message in storedMessages {
            sendSatelliteMessage(message)
            storeAndForwardQueue.removeAll { $0.id == message.id }
        }
    }
    
    // MARK: - Local Mesh Integration
    
    private func relayToLocalMesh(_ emergency: EmergencyMessage) {
        // Convert emergency message to local format and relay via Bluetooth mesh
        let localMessage = BitchatMessage(
            sender: "satellite",
            content: "🚨 EMERGENCY: \(emergency.content)",
            timestamp: Date(),
            isRelay: true,
            originalSender: emergency.senderNickname
        )
        
        // This would integrate with the existing BluetoothMeshService
        // For now, we'll notify the delegate
        delegate?.didReceiveSatelliteMessage(SatellitePacket(
            type: SatelliteMessageType.emergencyBroadcast.rawValue,
            senderID: emergency.senderID.data(using: .utf8)!,
            recipientID: nil,
            payload: (try? JSONEncoder().encode(localMessage)) ?? Data(),
            priority: emergencyPriority
        ))
    }
    
    private func relayToLocalMesh(_ message: BitchatMessage) {
        // Relay global message to local Bluetooth mesh
        let relayMessage = BitchatMessage(
            sender: "satellite",
            content: "🌍 GLOBAL: \(message.content)",
            timestamp: Date(),
            isRelay: true,
            originalSender: message.sender
        )
        
        // This would integrate with the existing BluetoothMeshService
        delegate?.didReceiveSatelliteMessage(SatellitePacket(
            type: SatelliteMessageType.globalMessage.rawValue,
            senderID: message.senderPeerID?.data(using: .utf8) ?? Data(),
            recipientID: nil,
            payload: (try? JSONEncoder().encode(relayMessage)) ?? Data(),
            priority: normalPriority
        ))
    }
    
    // MARK: - Utility Methods
    
    private func getGatewayID() -> String {
        // Generate unique gateway ID based on device
        return "gateway-\(UUID().uuidString.prefix(8))"
    }
    
    private func getBatteryLevel() -> Float {
        // Get device battery level
        #if os(macOS)
        return 1.0 // Placeholder for macOS
        #else
        return UIDevice.current.batteryLevel
        #endif
    }
    
    private func getSignalStrength() -> Int {
        // Get satellite signal strength
        return satelliteModem?.signalStrength ?? 0
    }
    
    private func getSatelliteConnection() -> SatelliteGatewayStatus.SatelliteConnection? {
        guard let modem = satelliteModem else { return nil }
        
        return SatelliteGatewayStatus.SatelliteConnection(
            constellation: modem.constellation,
            signalQuality: modem.signalQuality,
            dataRate: modem.dataRate,
            latency: modem.latency,
            nextPass: modem.nextPass
        )
    }
    
    private func getPreferredSatellite() -> String {
        // Return preferred satellite constellation
        return "iridium" // Default to Iridium for now
    }
    
    private func updateGatewayStatus() {
        gatewayStatus = SatelliteGatewayStatus(
            gatewayID: getGatewayID(),
            isOnline: isConnected,
            batteryLevel: getBatteryLevel(),
            signalStrength: getSignalStrength(),
            satelliteConnection: getSatelliteConnection(),
            lastHeartbeat: Date(),
            messageQueueSize: messageQueue.count,
            emergencyQueueSize: emergencyQueue.count
        )
    }
    
    private func updateGlobalAddresses(from status: SatelliteGatewayStatus) {
        // Update global address routing information
        // This would be implemented based on the specific routing protocol
    }
}

// MARK: - Satellite Modem Interface

class SatelliteModem {
    var isConnected: Bool = false
    var signalStrength: Int = 0
    var constellation: String = "iridium"
    var signalQuality: Int = 0
    var dataRate: Double = 0.0
    var latency: TimeInterval = 0.0
    var nextPass: Date?
    
    func sendMessage(_ data: Data) {
        // Placeholder for actual satellite modem implementation
        print("Satellite modem sending: \(data.count) bytes")
    }
    
    func connect() {
        // Placeholder for connection logic
        isConnected = true
    }
    
    func disconnect() {
        // Placeholder for disconnection logic
        isConnected = false
    }
}

// MARK: - Extensions for Message Deduplication

extension SatellitePacket {
    var id: String {
        // Generate unique ID for deduplication
        let content = "\(type)-\(senderID.hexEncodedString())-\(timestamp)"
        return SHA256.hash(data: content.data(using: .utf8)!).compactMap { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    func hexEncodedString() -> String {
        return self.map { String(format: "%02x", $0) }.joined()
    }
} 