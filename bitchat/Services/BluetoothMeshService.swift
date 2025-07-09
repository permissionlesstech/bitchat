//
// BluetoothMeshService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CoreBluetooth
import Combine
import CryptoKit
#if os(macOS)
import AppKit
import IOKit.ps
#else
import UIKit
#endif

// Extension for hex encoding
extension Data {
    func hexEncodedString() -> String {
        if self.isEmpty {
            return ""
        }
        return self.map { String(format: "%02x", $0) }.joined()
    }
}

class BluetoothMeshService: NSObject {
    static let serviceUUID = CBUUID(string: "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C")
    static let characteristicUUID = CBUUID(string: "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
    
    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var discoveredPeripherals: [CBPeripheral] = []
    private var connectedPeripherals: [String: CBPeripheral] = [:]
    private var peripheralCharacteristics: [CBPeripheral: CBCharacteristic] = [:]
    private var characteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [CBCentral] = []
    private var peerNicknames: [String: String] = [:]
    private let peerNicknamesLock = NSLock()
    private var activePeers: Set<String> = []  // Track all active peers
    private let activePeersLock = NSLock()  // Thread safety for activePeers
    private var peerRSSI: [String: NSNumber] = [:] // Track RSSI values for peers
    private var peripheralRSSI: [String: NSNumber] = [:] // Track RSSI by peripheral ID during discovery
    private var loggedCryptoErrors = Set<String>()  // Track which peers we've logged crypto errors for
    
    weak var delegate: BitchatDelegate?
    private let encryptionService = EncryptionService()
    private let messageQueue = DispatchQueue(label: "bitchat.messageQueue", attributes: .concurrent)
    private var processedMessages = Set<String>()
    private let maxTTL: UInt8 = 7  // Maximum hops for long-distance delivery
    private var announcedToPeers = Set<String>()  // Track which peers we've announced to
    private var announcedPeers = Set<String>()  // Track peers who have already been announced
    private var processedKeyExchanges = Set<String>()  // Track processed key exchanges to prevent duplicates
    private var intentionalDisconnects = Set<String>()  // Track peripherals we're disconnecting intentionally
    private var peerLastSeenTimestamps: [String: Date] = [:]  // Track when we last heard from each peer
    private var cleanupTimer: Timer?  // Timer to clean up stale peers
    
    // Store-and-forward message cache
    private struct StoredMessage {
        let packet: BitchatPacket
        let timestamp: Date
        let messageID: String
        let isForFavorite: Bool  // Messages for favorites stored indefinitely
    }
    private var messageCache: [StoredMessage] = []
    private let messageCacheTimeout: TimeInterval = 43200  // 12 hours for regular peers
    private let maxCachedMessages = 100  // For regular peers
    private let maxCachedMessagesForFavorites = 1000  // Much larger cache for favorites
    private var favoriteMessageQueue: [String: [StoredMessage]] = [:]  // Per-favorite message queues
    private var deliveredMessages: Set<String> = []  // Track delivered message IDs to prevent duplicates
    private var cachedMessagesSentToPeer: Set<String> = []  // Track which peers have already received cached messages
    private var receivedMessageTimestamps: [String: Date] = [:]  // Track timestamps of received messages for debugging
    private var recentlySentMessages: Set<String> = []  // Short-term cache to prevent any duplicate sends
    private let recentlySentMessagesLock = NSLock()  // Thread safety for recentlySentMessages
    private var lastMessageFromPeer: [String: Date] = [:]  // Track last message time from each peer for connection prioritization
    
    // Battery and range optimizations
    private var scanDutyCycleTimer: Timer?
    private var isActivelyScanning = true
    private var activeScanDuration: TimeInterval = 2.0  // Scan actively for 2 seconds - will be adjusted based on battery
    private var scanPauseDuration: TimeInterval = 3.0  // Pause for 3 seconds - will be adjusted based on battery
    private var lastRSSIUpdate: [String: Date] = [:]  // Throttle RSSI updates
    private var batteryMonitorTimer: Timer?
    private var currentBatteryLevel: Float = 1.0  // Default to full battery
    
    // Battery optimizer integration
    private let batteryOptimizer = BatteryOptimizer.shared
    private var batteryOptimizerCancellables = Set<AnyCancellable>()
    
    // Peer list update debouncing
    private var peerListUpdateTimer: Timer?
    private let peerListUpdateDebounceInterval: TimeInterval = 0.1  // 100ms debounce for more responsive updates
    
    // Cover traffic for privacy
    private var coverTrafficTimer: Timer?
    private let coverTrafficPrefix = "☂DUMMY☂"  // Prefix to identify dummy messages after decryption
    private var lastCoverTrafficTime = Date()
    private var advertisingTimer: Timer?  // Timer for interval-based advertising
    
    // Timing randomization for privacy
    private let minMessageDelay: TimeInterval = 0.01  // 10ms minimum for faster sync
    private let maxMessageDelay: TimeInterval = 0.1   // 100ms maximum for faster sync
    
    // Fragment handling
    private var incomingFragments: [String: [Int: Data]] = [:]  // fragmentID -> [index: data]
    private var fragmentMetadata: [String: (originalType: UInt8, totalFragments: Int, timestamp: Date)] = [:]
    private let maxFragmentSize = 500  // Optimized for BLE 5.0 extended data length
    
    let myPeerID: String
    
    // ===== SCALING OPTIMIZATIONS =====
    
    // Connection pooling
    private var connectionPool: [String: CBPeripheral] = [:]
    private var connectionAttempts: [String: Int] = [:]
    private var connectionBackoff: [String: TimeInterval] = [:]
    private let maxConnectionAttempts = 3
    private let baseBackoffInterval: TimeInterval = 1.0
    
    // Probabilistic flooding
    private var relayProbability: Double = 1.0  // Start at 100%, decrease with peer count
    private let minRelayProbability: Double = 0.4  // Minimum 40% relay chance - ensures coverage
    
    // Message aggregation
    private var pendingMessages: [(message: BitchatPacket, destination: String?)] = []
    private var aggregationTimer: Timer?
    private var aggregationWindow: TimeInterval = 0.1  // 100ms window
    private let maxAggregatedMessages = 5
    
    // Optimized Bloom filter for efficient duplicate detection
    private var messageBloomFilter = OptimizedBloomFilter(expectedItems: 2000, falsePositiveRate: 0.01)
    private var bloomFilterResetTimer: Timer?
    private var lastBloomFilterNetworkSize: Int = 0  // Track network size for adaptive resizing
    
    // Network size estimation
    private var estimatedNetworkSize: Int {
        return max(activePeers.count, connectedPeripherals.count)
    }
    
    // Adaptive parameters based on network size
    private var adaptiveTTL: UInt8 {
        // Keep TTL high enough for messages to travel far
        let networkSize = estimatedNetworkSize
        if networkSize <= 20 {
            return 6  // Small networks: max distance
        } else if networkSize <= 50 {
            return 5  // Medium networks: still good reach
        } else if networkSize <= 100 {
            return 4  // Large networks: reasonable reach
        } else {
            return 3  // Very large networks: minimum viable
        }
    }
    
    private var adaptiveRelayProbability: Double {
        // Keep relay probability high enough to ensure delivery
        let networkSize = estimatedNetworkSize
        if networkSize <= 10 {
            return 1.0  // 100% for small networks
        } else if networkSize <= 30 {
            return 0.85 // 85% - most nodes relay
        } else if networkSize <= 50 {
            return 0.7  // 70% - still high probability
        } else if networkSize <= 100 {
            return 0.55 // 55% - over half relay
        } else {
            return 0.4  // 40% minimum - never go below this
        }
    }
    
    // BLE advertisement for lightweight presence
    private var advertisementData: [String: Any] = [:]
    private var isAdvertising = false
    
    // ===== MESSAGE AGGREGATION =====
    
    private func startAggregationTimer() {
        aggregationTimer?.invalidate()
        aggregationTimer = Timer.scheduledTimer(withTimeInterval: aggregationWindow, repeats: false) { [weak self] _ in
            self?.flushPendingMessages()
        }
    }
    
    private func flushPendingMessages() {
        guard !pendingMessages.isEmpty else { return }
        
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Group messages by destination
            var messagesByDestination: [String?: [BitchatPacket]] = [:]
            
            for (message, destination) in self.pendingMessages {
                if messagesByDestination[destination] == nil {
                    messagesByDestination[destination] = []
                }
                messagesByDestination[destination]?.append(message)
            }
            
            // Send aggregated messages
            for (destination, messages) in messagesByDestination {
                if messages.count == 1 {
                    // Single message, send normally
                    if destination == nil {
                        self.broadcastPacket(messages[0])
                    } else if let dest = destination,
                              let peripheral = self.connectedPeripherals[dest],
                              peripheral.state == .connected,
                              let characteristic = self.peripheralCharacteristics[peripheral] {
                        if let data = messages[0].toBinaryData() {
                            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                        }
                    }
                } else {
                    // Multiple messages - could aggregate into a single packet
                    // For now, send with minimal delay between them
                    for (index, message) in messages.enumerated() {
                        let delay = Double(index) * 0.02  // 20ms between messages
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            if destination == nil {
                                self?.broadcastPacket(message)
                            } else if let dest = destination,
                                      let peripheral = self?.connectedPeripherals[dest],
                                      peripheral.state == .connected,
                                      let characteristic = self?.peripheralCharacteristics[peripheral] {
                                if let data = message.toBinaryData() {
                                    peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                                }
                            }
                        }
                    }
                }
            }
            
            // Clear pending messages
            self.pendingMessages.removeAll()
        }
    }
    
    // Helper method to get fingerprint from public key data
    private func getPublicKeyFingerprint(_ publicKeyData: Data) -> String {
        let fingerprint = SHA256.hash(data: publicKeyData)
            .compactMap { String(format: "%02x", $0) }
            .joined()
            .prefix(16)  // Use first 16 chars for brevity
            .lowercased()
        return String(fingerprint)
    }
    
    // Public method to get peer's public key data
    func getPeerPublicKey(_ peerID: String) -> Data? {
        return encryptionService.getPeerIdentityKey(peerID)
    }
    
    override init() {
        // Generate ephemeral peer ID for each session to prevent tracking
        // Use random bytes instead of UUID for better anonymity
        var randomBytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &randomBytes)
        self.myPeerID = randomBytes.map { String(format: "%02x", $0) }.joined()
        
        super.init()
        
        centralManager = CBCentralManager(delegate: self, queue: nil)
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        
        // Start bloom filter reset timer (reset every 5 minutes)
        bloomFilterResetTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.messageQueue.async(flags: .barrier) {
                guard let self = self else { return }
                
                let networkSize = self.estimatedNetworkSize
                let sizeChange = abs(networkSize - self.lastBloomFilterNetworkSize)
                
                // Only recreate bloom filter if network size changed significantly (>50% or >20 peers)
                if sizeChange > max(self.lastBloomFilterNetworkSize / 2, 20) {
                    self.messageBloomFilter = OptimizedBloomFilter.adaptive(for: networkSize)
                    self.lastBloomFilterNetworkSize = networkSize
                    print("[BloomFilter] Recreated for network size: \(networkSize), memory: \(self.messageBloomFilter.memorySizeBytes) bytes")
                } else {
                    // Just reset the existing bloom filter - much more efficient
                    self.messageBloomFilter.reset()
                    print("[BloomFilter] Reset (no recreation needed), network size: \(networkSize)")
                }
                
                // Clear other duplicate detection sets
                self.processedMessages.removeAll()
                self.processedKeyExchanges.removeAll()
            }
        }
        
        // Start stale peer cleanup timer (every 30 seconds)
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.cleanupStalePeers()
        }
        
        // Register for app termination notifications
        #if os(macOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        #else
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        #endif
    }
    
    deinit {
        cleanup()
        scanDutyCycleTimer?.invalidate()
        batteryMonitorTimer?.invalidate()
        coverTrafficTimer?.invalidate()
        bloomFilterResetTimer?.invalidate()
        aggregationTimer?.invalidate()
        cleanupTimer?.invalidate()
    }
    
    @objc private func appWillTerminate() {
        cleanup()
    }
    
    private func cleanup() {
        // Send leave announcement before disconnecting
        sendLeaveAnnouncement()
        
        // Give the leave message time to send
        Thread.sleep(forTimeInterval: 0.2)
        
        // First, disconnect all peripherals which will trigger disconnect delegates
        for (_, peripheral) in connectedPeripherals {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        
        // Stop advertising
        if peripheralManager?.isAdvertising == true {
            peripheralManager?.stopAdvertising()
        }
        
        // Stop scanning
        centralManager?.stopScan()
        
        // Remove all services - this will disconnect any connected centrals
        if peripheralManager?.state == .poweredOn {
            peripheralManager?.removeAllServices()
        }
        
        // Clear all tracking
        connectedPeripherals.removeAll()
        subscribedCentrals.removeAll()
        activePeersLock.lock()
        activePeers.removeAll()
        activePeersLock.unlock()
        announcedPeers.removeAll()
        
        // Clear announcement tracking
        announcedToPeers.removeAll()
        
        // Clear last seen timestamps
        peerLastSeenTimestamps.removeAll()
    }
    
    func startServices() {
        // Starting services
        // Start both central and peripheral services
        if centralManager?.state == .poweredOn {
            startScanning()
        }
        if peripheralManager?.state == .poweredOn {
            setupPeripheral()
            startAdvertising()
        }
        
        // Send initial announces after services are ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.sendBroadcastAnnounce()
        }
        
        // Setup battery optimizer
        setupBatteryOptimizer()
        
        // Start cover traffic for privacy
        startCoverTraffic()
    }
    
    func sendBroadcastAnnounce() {
        guard let vm = delegate as? ChatViewModel else { return }
        
        let announcePacket = BitchatPacket(
            type: MessageType.announce.rawValue,
            ttl: 3,  // Increase TTL so announce reaches all peers
            senderID: myPeerID,
            payload: Data(vm.nickname.utf8)
        )
        
        
        // Initial send with random delay
        let initialDelay = self.randomDelay()
        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
            self?.broadcastPacket(announcePacket)
        }
        
        // Send multiple times for reliability with jittered delays
        for baseDelay in [0.2, 0.5, 1.0] {
            let jitteredDelay = baseDelay + self.randomDelay()
            DispatchQueue.main.asyncAfter(deadline: .now() + jitteredDelay) { [weak self] in
                guard let self = self else { return }
                self.broadcastPacket(announcePacket)
            }
        }
    }
    
    func startAdvertising() {
        guard peripheralManager?.state == .poweredOn else { 
            return 
        }
        
        // Use generic advertising to avoid identification
        // No identifying prefixes or app names for activist safety
        
        // Only use allowed advertisement keys
        advertisementData = [
            CBAdvertisementDataServiceUUIDsKey: [BluetoothMeshService.serviceUUID],
            // Use only peer ID without any identifying prefix
            CBAdvertisementDataLocalNameKey: myPeerID
        ]
        
        isAdvertising = true
        peripheralManager?.startAdvertising(advertisementData)
    }
    
    func startScanning() {
        guard centralManager?.state == .poweredOn else { 
            return 
        }
        
        // Enable duplicate detection for RSSI tracking
        let scanOptions: [String: Any] = [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ]
        
        centralManager?.scanForPeripherals(
            withServices: [BluetoothMeshService.serviceUUID],
            options: scanOptions
        )
        
        // Update scan parameters based on battery before starting
        updateScanParametersForBattery()
        
        // Implement scan duty cycling for battery efficiency
        scheduleScanDutyCycle()
    }
    
    private func scheduleScanDutyCycle() {
        guard scanDutyCycleTimer == nil else { return }
        
        // Start with active scanning
        isActivelyScanning = true
        
        scanDutyCycleTimer = Timer.scheduledTimer(withTimeInterval: activeScanDuration, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            if self.isActivelyScanning {
                // Pause scanning to save battery
                self.centralManager?.stopScan()
                self.isActivelyScanning = false
                
                // Schedule resume
                DispatchQueue.main.asyncAfter(deadline: .now() + self.scanPauseDuration) { [weak self] in
                    guard let self = self else { return }
                    if self.centralManager?.state == .poweredOn {
                        self.centralManager?.scanForPeripherals(
                            withServices: [BluetoothMeshService.serviceUUID],
                            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
                        )
                        self.isActivelyScanning = true
                    }
                }
            }
        }
    }
    
    private func setupPeripheral() {
        let characteristic = CBMutableCharacteristic(
            type: BluetoothMeshService.characteristicUUID,
            properties: [.read, .write, .writeWithoutResponse, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )
        
        let service = CBMutableService(type: BluetoothMeshService.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        
        peripheralManager?.add(service)
        self.characteristic = characteristic
    }
    
    func sendMessage(_ content: String, mentions: [String] = [], channel: String? = nil, to recipientID: String? = nil, messageID: String? = nil, timestamp: Date? = nil) {
        // Defensive check for empty content
        guard !content.isEmpty else { return }
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            let nickname = self.delegate as? ChatViewModel
            let senderNick = nickname?.nickname ?? self.myPeerID
            
            let message = BitchatMessage(
                id: messageID,
                sender: senderNick,
                content: content,
                timestamp: timestamp ?? Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: self.myPeerID,
                mentions: mentions.isEmpty ? nil : mentions,
                channel: channel
            )
            
            if let messageData = message.toBinaryPayload() {
                // Sign the message payload (no encryption for broadcasts)
                let signature: Data?
                do {
                    signature = try self.encryptionService.sign(messageData)
                } catch {
                    // print("[CRYPTO] Failed to sign message: \(error)")
                    signature = nil
                }
                
                // Use unified message type with broadcast recipient
                let packet = BitchatPacket(
                    type: MessageType.message.rawValue,
                    senderID: Data(self.myPeerID.utf8),
                    recipientID: SpecialRecipients.broadcast,  // Special broadcast ID
                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000), // milliseconds
                    payload: messageData,
                    signature: signature,
                    ttl: self.adaptiveTTL
                )
                
                // Track this message to prevent duplicate sends
                let msgID = "\(packet.timestamp)-\(self.myPeerID)-\(packet.payload.prefix(32).hashValue)"
                
                self.recentlySentMessagesLock.lock()
                let shouldSend = !self.recentlySentMessages.contains(msgID)
                if shouldSend {
                    self.recentlySentMessages.insert(msgID)
                }
                self.recentlySentMessagesLock.unlock()
                
                if shouldSend {
                    // Clean up old entries after 10 seconds
                    self.messageQueue.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                        guard let self = self else { return }
                        self.recentlySentMessagesLock.lock()
                        self.recentlySentMessages.remove(msgID)
                        self.recentlySentMessagesLock.unlock()
                    }
                    
                    // Add random delay before initial send
                    let initialDelay = self.randomDelay()
                    DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
                        self?.broadcastPacket(packet)
                    }
                    
                    // Single retry for reliability
                    let retryDelay = 0.3 + self.randomDelay()
                    DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                        self?.broadcastPacket(packet)
                        // Re-sending message
                    }
                }
            }
        }
    }
    
    
    func sendPrivateMessage(_ content: String, to recipientPeerID: String, recipientNickname: String, messageID: String? = nil) {
        // Defensive checks
        guard !content.isEmpty, !recipientPeerID.isEmpty, !recipientNickname.isEmpty else { return }
        
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            let nickname = self.delegate as? ChatViewModel
            let senderNick = nickname?.nickname ?? self.myPeerID
            
            // Use provided message ID or generate a new one
            let msgID = messageID ?? UUID().uuidString
            
            let message = BitchatMessage(
                id: msgID,
                sender: senderNick,
                content: content,
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: true,
                recipientNickname: recipientNickname,
                senderPeerID: self.myPeerID
            )
            
            if let messageData = message.toBinaryPayload() {
                // Pad message to standard block size for privacy
                let blockSize = MessagePadding.optimalBlockSize(for: messageData.count)
                let paddedData = MessagePadding.pad(messageData, toSize: blockSize)
                
                // Encrypt the padded message for the recipient
                let encryptedPayload: Data
                do {
                    encryptedPayload = try self.encryptionService.encrypt(paddedData, for: recipientPeerID)
                } catch {
                    // print("[CRYPTO] Failed to encrypt private message: \(error)")
                    // Don't send unencrypted private messages
                    return
                }
                
                // Sign the encrypted payload
                let signature: Data?
                do {
                    signature = try self.encryptionService.sign(encryptedPayload)
                } catch {
                    // print("[CRYPTO] Failed to sign private message: \(error)")
                    signature = nil
                }
                
                // Create packet with recipient ID for proper routing
                let packet = BitchatPacket(
                    type: MessageType.message.rawValue,
                    senderID: Data(self.myPeerID.utf8),
                    recipientID: Data(recipientPeerID.utf8),
                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000), // milliseconds
                    payload: encryptedPayload,
                    signature: signature,
                    ttl: self.adaptiveTTL
                )
                
                
                // Check if recipient is offline and cache if they're a favorite
                self.activePeersLock.lock()
                let isRecipientOffline = !self.activePeers.contains(recipientPeerID)
                self.activePeersLock.unlock()
                
                if isRecipientOffline {
                    if let publicKeyData = self.encryptionService.getPeerIdentityKey(recipientPeerID) {
                        let fingerprint = self.getPublicKeyFingerprint(publicKeyData)
                        if self.delegate?.isFavorite(fingerprint: fingerprint) ?? false {
                            // Recipient is offline favorite, cache the message
                            let messageID = "\(packet.timestamp)-\(self.myPeerID)"
                            self.cacheMessage(packet, messageID: messageID)
                        }
                    }
                }
                
                // Track to prevent duplicate sends
                let msgID = "\(packet.timestamp)-\(self.myPeerID)-\(packet.payload.prefix(32).hashValue)"
                
                self.recentlySentMessagesLock.lock()
                let shouldSend = !self.recentlySentMessages.contains(msgID)
                if shouldSend {
                    self.recentlySentMessages.insert(msgID)
                }
                self.recentlySentMessagesLock.unlock()
                
                if shouldSend {
                    // Clean up after 10 seconds
                    self.messageQueue.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                        guard let self = self else { return }
                        self.recentlySentMessagesLock.lock()
                        self.recentlySentMessages.remove(msgID)
                        self.recentlySentMessagesLock.unlock()
                    }
                    
                    // Message tracking is now done in ChatViewModel to ensure consistent message IDs
                    
                    // Add random delay for timing obfuscation
                    let delay = self.randomDelay()
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.broadcastPacket(packet)
                        // Private message sent with timing delay
                    }
                    
                    // Don't call didReceiveMessage here - let the view model handle it directly
                }
            }
        }
    }
    
    func sendChannelLeaveNotification(_ channel: String) {
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Create a leave packet with channel hashtag as payload
            let packet = BitchatPacket(
                type: MessageType.leave.rawValue,
                senderID: Data(self.myPeerID.utf8),
                recipientID: SpecialRecipients.broadcast,  // Broadcast to all
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: Data(channel.utf8),  // Channel hashtag as payload
                signature: nil,
                ttl: 3  // Short TTL for leave notifications
            )
            
            self.broadcastPacket(packet)
        }
    }
    
    func sendDeliveryAck(_ ack: DeliveryAck, to recipientID: String) {
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Encode the ACK
            guard let ackData = ack.encode() else {
                return
            }
            
            // Encrypt ACK for the original sender
            let encryptedPayload: Data
            do {
                encryptedPayload = try self.encryptionService.encrypt(ackData, for: recipientID)
            } catch {
                return
            }
            
            // Create ACK packet with direct routing to original sender
            let packet = BitchatPacket(
                type: MessageType.deliveryAck.rawValue,
                senderID: Data(self.myPeerID.utf8),
                recipientID: Data(recipientID.utf8),
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: encryptedPayload,
                signature: nil,  // ACKs don't need signatures
                ttl: 3  // Limited TTL for ACKs
            )
            
            // Send immediately without delay (ACKs should be fast)
            self.broadcastPacket(packet)
        }
    }
    
    func sendReadReceipt(_ receipt: ReadReceipt, to recipientID: String) {
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Encode the receipt
            guard let receiptData = receipt.encode() else {
                return
            }
            
            // Encrypt receipt for the original sender
            let encryptedPayload: Data
            do {
                encryptedPayload = try self.encryptionService.encrypt(receiptData, for: recipientID)
            } catch {
                return
            }
            
            // Create read receipt packet with direct routing to original sender
            let packet = BitchatPacket(
                type: MessageType.readReceipt.rawValue,
                senderID: Data(self.myPeerID.utf8),
                recipientID: Data(recipientID.utf8),
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: encryptedPayload,
                signature: nil,  // Read receipts don't need signatures
                ttl: 3  // Limited TTL for receipts
            )
            
            // Send immediately without delay
            self.broadcastPacket(packet)
        }
    }
    
    func announcePasswordProtectedChannel(_ channel: String, isProtected: Bool = true, creatorID: String? = nil, keyCommitment: String? = nil) {
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Payload format: channel|isProtected|creatorID|keyCommitment
            let protectedFlag = isProtected ? "1" : "0"
            let creator = creatorID ?? self.myPeerID
            let commitment = keyCommitment ?? ""
            let payload = "\(channel)|\(protectedFlag)|\(creator)|\(commitment)"
            
            let packet = BitchatPacket(
                type: MessageType.channelAnnounce.rawValue,
                senderID: Data(self.myPeerID.utf8),
                recipientID: SpecialRecipients.broadcast,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: Data(payload.utf8),
                signature: nil,
                ttl: 5  // Allow wider propagation for channel announcements
            )
            
            self.broadcastPacket(packet)
        }
    }
    
    func sendChannelRetentionAnnouncement(_ channel: String, enabled: Bool) {
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Payload format: channel|enabled|creatorID
            let enabledFlag = enabled ? "1" : "0"
            let payload = "\(channel)|\(enabledFlag)|\(self.myPeerID)"
            
            let packet = BitchatPacket(
                type: MessageType.channelRetention.rawValue,
                senderID: Data(self.myPeerID.utf8),
                recipientID: SpecialRecipients.broadcast,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: Data(payload.utf8),
                signature: nil,
                ttl: 5  // Allow wider propagation for channel announcements
            )
            
            self.broadcastPacket(packet)
        }
    }
    
    func sendEncryptedChannelMessage(_ content: String, mentions: [String], channel: String, channelKey: SymmetricKey, messageID: String? = nil, timestamp: Date? = nil) {
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            let nickname = self.delegate as? ChatViewModel
            let senderNick = nickname?.nickname ?? self.myPeerID
            
            // Encrypt the content
            guard let contentData = content.data(using: .utf8) else { return }
            
            // Debug logging removed
            
            do {
                let sealedBox = try AES.GCM.seal(contentData, using: channelKey)
                guard let encryptedData = sealedBox.combined else {
                    // Encryption failed to produce combined data
                    return
                }
                
                // Create message with encrypted content
                let message = BitchatMessage(
                    id: messageID,
                    sender: senderNick,
                    content: "",  // Empty placeholder since actual content is encrypted
                    timestamp: timestamp ?? Date(),
                    isRelay: false,
                    originalSender: nil,
                    isPrivate: false,
                    recipientNickname: nil,
                    senderPeerID: self.myPeerID,
                    mentions: mentions.isEmpty ? nil : mentions,
                    channel: channel,
                    encryptedContent: encryptedData,
                    isEncrypted: true
                )
                
                if let messageData = message.toBinaryPayload() {
                    // Sign the message payload
                    let signature: Data?
                    do {
                        signature = try self.encryptionService.sign(messageData)
                    } catch {
                        signature = nil
                    }
                    
                    let packet = BitchatPacket(
                        type: MessageType.message.rawValue,
                        senderID: Data(self.myPeerID.utf8),
                        recipientID: SpecialRecipients.broadcast,
                        timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                        payload: messageData,
                        signature: signature,
                        ttl: self.adaptiveTTL
                    )
                    
                    self.broadcastPacket(packet)
                }
            } catch {
            }
        }
    }
    
    private func sendAnnouncementToPeer(_ peerID: String) {
        guard let vm = delegate as? ChatViewModel else { return }
        
        
        // Always send announce, don't check if already announced
        // This ensures peers get our nickname even if they reconnect
        
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            ttl: 3,  // Allow relay for better reach
            senderID: myPeerID,
            payload: Data(vm.nickname.utf8)
        )
        
        if let data = packet.toBinaryData() {
            // Try both broadcast and targeted send
            broadcastPacket(packet)
            
            // Also try targeted send if we have the peripheral
            if let peripheral = connectedPeripherals[peerID],
               peripheral.state == .connected,
               let characteristic = peripheral.services?.first(where: { $0.uuid == BluetoothMeshService.serviceUUID })?.characteristics?.first(where: { $0.uuid == BluetoothMeshService.characteristicUUID }) {
                let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
                peripheral.writeValue(data, for: characteristic, type: writeType)
            } else {
            }
        } else {
        }
        
        announcedToPeers.insert(peerID)
    }
    
    private func sendLeaveAnnouncement() {
        guard let vm = delegate as? ChatViewModel else { return }
        
        let packet = BitchatPacket(
            type: MessageType.leave.rawValue,
            ttl: 1,  // Don't relay leave messages
            senderID: myPeerID,
            payload: Data(vm.nickname.utf8)
        )
        
        broadcastPacket(packet)
    }
    
    
    func getPeerNicknames() -> [String: String] {
        peerNicknamesLock.lock()
        let copy = peerNicknames
        peerNicknamesLock.unlock()
        return copy
    }
    
    func getPeerRSSI() -> [String: NSNumber] {
        // Create a copy with default values for connected peers without RSSI
        var rssiWithDefaults = peerRSSI
        
        // For any active peer without RSSI, assume decent signal (-60)
        // This handles centrals where we can't read RSSI
        for peerID in activePeers {
            if rssiWithDefaults[peerID] == nil {
                rssiWithDefaults[peerID] = NSNumber(value: -60)  // Good signal default
            }
        }
        
        return rssiWithDefaults
    }
    
    // Emergency disconnect for panic situations
    func emergencyDisconnectAll() {
        // Stop advertising immediately
        if peripheralManager?.isAdvertising == true {
            peripheralManager?.stopAdvertising()
        }
        
        // Stop scanning
        centralManager?.stopScan()
        scanDutyCycleTimer?.invalidate()
        scanDutyCycleTimer = nil
        
        // Disconnect all peripherals
        for (_, peripheral) in connectedPeripherals {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        
        // Clear all peer data
        connectedPeripherals.removeAll()
        peripheralCharacteristics.removeAll()
        discoveredPeripherals.removeAll()
        subscribedCentrals.removeAll()
        peerNicknames.removeAll()
        activePeers.removeAll()
        peerRSSI.removeAll()
        peripheralRSSI.removeAll()
        announcedToPeers.removeAll()
        announcedPeers.removeAll()
        processedMessages.removeAll()
        incomingFragments.removeAll()
        fragmentMetadata.removeAll()
        
        // Clear persistent identity
        encryptionService.clearPersistentIdentity()
        
        // print("[PANIC] Emergency disconnect completed")
    }
    
    private func getAllConnectedPeerIDs() -> [String] {
        // Return all valid active peers
        activePeersLock.lock()
        let peersCopy = activePeers
        activePeersLock.unlock()
        
        let validPeers = peersCopy.filter { peerID in
            // Ensure peerID is valid
            return !peerID.isEmpty &&
                   peerID != "unknown" &&
                   peerID != myPeerID
        }
        
        return Array(validPeers).sorted()
    }
    
    // Debounced peer list update notification
    private func notifyPeerListUpdate(immediate: Bool = false) {
        if immediate {
            // For initial connections, update immediately
            let connectedPeerIDs = self.getAllConnectedPeerIDs()
            // print("[DEBUG] Notifying peer list update immediately: \(connectedPeerIDs.count) peers")
            
            DispatchQueue.main.async {
                self.delegate?.didUpdatePeerList(connectedPeerIDs)
            }
        } else {
            // Must schedule timer on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // Cancel any pending update
                self.peerListUpdateTimer?.invalidate()
                
                // Schedule a new update after debounce interval
                self.peerListUpdateTimer = Timer.scheduledTimer(withTimeInterval: self.peerListUpdateDebounceInterval, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    
                    let connectedPeerIDs = self.getAllConnectedPeerIDs()
                    // print("[DEBUG] Notifying peer list update after debounce: \(connectedPeerIDs.count) peers")
                    
                    self.delegate?.didUpdatePeerList(connectedPeerIDs)
                }
            }
        }
    }
    
    // Clean up stale peers that haven't been seen in a while
    private func cleanupStalePeers() {
        let staleThreshold: TimeInterval = 180.0 // 3 minutes - increased for better stability
        let now = Date()
        
        activePeersLock.lock()
        let peersToRemove = activePeers.filter { peerID in
            if let lastSeen = peerLastSeenTimestamps[peerID] {
                return now.timeIntervalSince(lastSeen) > staleThreshold
            }
            return false // Keep peers we haven't tracked yet
        }
        
        for peerID in peersToRemove {
            // Check if this peer has an active peripheral connection
            if let peripheral = connectedPeripherals[peerID], peripheral.state == .connected {
                // Skipping removal - still has active connection
                // Update last seen time to prevent immediate re-removal
                peerLastSeenTimestamps[peerID] = Date()
                continue
            }
            
            activePeers.remove(peerID)
            peerLastSeenTimestamps.removeValue(forKey: peerID)
            
            // Clean up all associated data
            connectedPeripherals.removeValue(forKey: peerID)
            peerRSSI.removeValue(forKey: peerID)
            announcedPeers.remove(peerID)
            announcedToPeers.remove(peerID)
            processedKeyExchanges = processedKeyExchanges.filter { !$0.contains(peerID) }
            
            peerNicknamesLock.lock()
            peerNicknames.removeValue(forKey: peerID)
            peerNicknamesLock.unlock()
            
            // Removed stale peer
        }
        activePeersLock.unlock()
        
        if !peersToRemove.isEmpty {
            notifyPeerListUpdate()
        }
    }
    
    // MARK: - Store-and-Forward Methods
    
    private func cacheMessage(_ packet: BitchatPacket, messageID: String) {
        messageQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            // Don't cache certain message types
            guard packet.type != MessageType.keyExchange.rawValue,
                  packet.type != MessageType.announce.rawValue,
                  packet.type != MessageType.leave.rawValue,
                  packet.type != MessageType.fragmentStart.rawValue,
                  packet.type != MessageType.fragmentContinue.rawValue,
                  packet.type != MessageType.fragmentEnd.rawValue else {
                return
            }
            
            // Don't cache broadcast messages
            if let recipientID = packet.recipientID,
               recipientID == SpecialRecipients.broadcast {
                return  // Never cache broadcast messages
            }
            
            // Check if this is a private message for a favorite
            var isForFavorite = false
            if packet.type == MessageType.message.rawValue,
               let recipientID = packet.recipientID,
               let recipientPeerID = String(data: recipientID.trimmingNullBytes(), encoding: .utf8) {
                // Check if recipient is a favorite via their public key fingerprint
                if let publicKeyData = self.encryptionService.getPeerIdentityKey(recipientPeerID) {
                    let fingerprint = self.getPublicKeyFingerprint(publicKeyData)
                    isForFavorite = self.delegate?.isFavorite(fingerprint: fingerprint) ?? false
                }
            }
            
            // Create stored message with original packet timestamp preserved
            let storedMessage = StoredMessage(
                packet: packet,
                timestamp: Date(timeIntervalSince1970: TimeInterval(packet.timestamp) / 1000.0), // convert from milliseconds
                messageID: messageID,
                isForFavorite: isForFavorite
            )
            
            
            if isForFavorite {
                if let recipientID = packet.recipientID,
                   let recipientPeerID = String(data: recipientID.trimmingNullBytes(), encoding: .utf8) {
                    if self.favoriteMessageQueue[recipientPeerID] == nil {
                        self.favoriteMessageQueue[recipientPeerID] = []
                    }
                    self.favoriteMessageQueue[recipientPeerID]?.append(storedMessage)
                    
                    // Limit favorite queue size
                    if let count = self.favoriteMessageQueue[recipientPeerID]?.count,
                       count > self.maxCachedMessagesForFavorites {
                        self.favoriteMessageQueue[recipientPeerID]?.removeFirst()
                    }
                    
                }
            } else {
                // Clean up old messages first (only for regular cache)
                self.cleanupMessageCache()
                
                // Add to regular cache
                self.messageCache.append(storedMessage)
                
                // Limit cache size
                if self.messageCache.count > self.maxCachedMessages {
                    self.messageCache.removeFirst()
                }
                
            }
        }
    }
    
    private func cleanupMessageCache() {
        let cutoffTime = Date().addingTimeInterval(-messageCacheTimeout)
        // Only remove non-favorite messages that are older than timeout
        messageCache.removeAll { !$0.isForFavorite && $0.timestamp < cutoffTime }
        
        // Clean up delivered messages set periodically (keep recent 1000 entries)
        if deliveredMessages.count > 1000 {
            // Clear older entries while keeping recent ones
            deliveredMessages.removeAll()
        }
    }
    
    private func sendCachedMessages(to peerID: String) {
        messageQueue.async { [weak self] in
            guard let self = self,
                  let peripheral = self.connectedPeripherals[peerID],
                  let characteristic = self.peripheralCharacteristics[peripheral] else {
                return
            }
            
            
            // Check if we've already sent cached messages to this peer in this session
            if self.cachedMessagesSentToPeer.contains(peerID) {
                return  // Already sent cached messages to this peer in this session
            }
            
            // Mark that we're sending cached messages to this peer
            self.cachedMessagesSentToPeer.insert(peerID)
            
            // Clean up old messages first
            self.cleanupMessageCache()
            
            var messagesToSend: [StoredMessage] = []
            
            // First, check if this peer has any favorite messages waiting
            if let favoriteMessages = self.favoriteMessageQueue[peerID] {
                // Filter out already delivered messages
                let undeliveredFavoriteMessages = favoriteMessages.filter { !self.deliveredMessages.contains($0.messageID) }
                messagesToSend.append(contentsOf: undeliveredFavoriteMessages)
                // Clear the favorite queue after adding to send list
                self.favoriteMessageQueue[peerID] = nil
            }
            
            // Filter regular cached messages for this specific recipient
            let recipientMessages = self.messageCache.filter { storedMessage in
                if self.deliveredMessages.contains(storedMessage.messageID) {
                    return false
                }
                if let recipientID = storedMessage.packet.recipientID,
                   let recipientPeerID = String(data: recipientID.trimmingNullBytes(), encoding: .utf8) {
                    return recipientPeerID == peerID
                }
                return false  // Don't forward broadcast messages
            }
            messagesToSend.append(contentsOf: recipientMessages)
            
            
            // Sort messages by timestamp to ensure proper ordering
            messagesToSend.sort { $0.timestamp < $1.timestamp }
            
            if !messagesToSend.isEmpty {
                // print("[STORE_FORWARD] Sending \(messagesToSend.count) cached messages to \(peerID)")
            }
            
            // Mark messages as delivered immediately to prevent duplicates
            let messageIDsToRemove = messagesToSend.map { $0.messageID }
            self.deliveredMessages.formUnion(messageIDsToRemove)
            
            // Send cached messages with slight delay between each
            for (index, storedMessage) in messagesToSend.enumerated() {
                let delay = Double(index) * 0.02 // 20ms between messages for faster sync
                
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak peripheral] in
                    guard let peripheral = peripheral,
                          peripheral.state == .connected else {
                        return
                    }
                    
                    // Send the original packet with preserved timestamp
                    let packetToSend = storedMessage.packet
                    
                    if let data = packetToSend.toBinaryData(),
                       characteristic.properties.contains(.writeWithoutResponse) {
                        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                    }
                }
            }
            
            // Remove sent messages immediately
            if !messageIDsToRemove.isEmpty {
                self.messageQueue.async(flags: .barrier) {
                    // Remove only the messages we sent to this specific peer
                    self.messageCache.removeAll { message in
                        messageIDsToRemove.contains(message.messageID)
                    }
                    
                    // Also remove from favorite queue if any
                    if var favoriteQueue = self.favoriteMessageQueue[peerID] {
                        favoriteQueue.removeAll { message in
                            messageIDsToRemove.contains(message.messageID)
                        }
                        self.favoriteMessageQueue[peerID] = favoriteQueue.isEmpty ? nil : favoriteQueue
                    }
                }
            }
        }
    }
    
    private func estimateDistance(rssi: Int) -> Int {
        // Rough distance estimation based on RSSI
        // Using path loss formula: RSSI = TxPower - 10 * n * log10(distance)
        // Assuming TxPower = -59 dBm at 1m, n = 2.0 (free space)
        let txPower = -59.0
        let pathLossExponent = 2.0
        
        let ratio = (txPower - Double(rssi)) / (10.0 * pathLossExponent)
        let distance = pow(10.0, ratio)
        
        return Int(distance)
    }
    
    private func broadcastPacket(_ packet: BitchatPacket) {
        guard let data = packet.toBinaryData() else { 
            // print("[ERROR] Failed to convert packet to binary data")
            // Add to retry queue if this is a message packet AND it's our own message
            if let senderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8),
               senderID == self.myPeerID,
               packet.type == MessageType.message.rawValue,
               let message = BitchatMessage.fromBinaryPayload(packet.payload) {
                MessageRetryService.shared.addMessageForRetry(
                    content: message.content,
                    mentions: message.mentions,
                    channel: message.channel,
                    isPrivate: message.isPrivate,
                    recipientPeerID: nil,
                    recipientNickname: message.recipientNickname,
                    channelKey: nil,
                    originalMessageID: message.id,
                    originalTimestamp: message.timestamp
                )
            }
            return 
        }
        
        
        // Send to connected peripherals (as central)
        var sentToPeripherals = 0
        for (_, peripheral) in connectedPeripherals {
            if let characteristic = peripheralCharacteristics[peripheral] {
                // Check if peripheral is connected before writing
                if peripheral.state == .connected {
                    // Use withoutResponse for faster transmission when possible
                    // Only use withResponse for critical messages or when MTU negotiation needed
                    let writeType: CBCharacteristicWriteType = data.count > 512 ? .withResponse : .withoutResponse
                    
                    // Additional safety check for characteristic properties
                    if characteristic.properties.contains(.write) || 
                       characteristic.properties.contains(.writeWithoutResponse) {
                        peripheral.writeValue(data, for: characteristic, type: writeType)
                        sentToPeripherals += 1
                    }
                } else {
                    if let peerID = connectedPeripherals.first(where: { $0.value == peripheral })?.key {
                        connectedPeripherals.removeValue(forKey: peerID)
                        peripheralCharacteristics.removeValue(forKey: peripheral)
                    }
                }
            } else {
            }
        }
        
        // Send to subscribed centrals (as peripheral)
        var sentToCentrals = 0
        if let char = characteristic, !subscribedCentrals.isEmpty {
            // Send to all subscribed centrals
            let success = peripheralManager?.updateValue(data, for: char, onSubscribedCentrals: nil) ?? false
            if success {
                sentToCentrals = subscribedCentrals.count
            } else {
            }
        } else {
            if characteristic == nil {
            }
        }
        
        // If no peers received the message, add to retry queue ONLY if it's our own message
        if sentToPeripherals == 0 && sentToCentrals == 0 {
            // Check if this packet originated from us
            if let senderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8),
               senderID == self.myPeerID {
                // This is our own message that failed to send
                if packet.type == MessageType.message.rawValue,
                   let message = BitchatMessage.fromBinaryPayload(packet.payload) {
                    // For encrypted channel messages, we need to preserve the channel key
                    var channelKeyData: Data? = nil
                    if let channel = message.channel, message.isEncrypted {
                        // This is an encrypted channel message
                        if let viewModel = delegate as? ChatViewModel,
                           let channelKey = viewModel.channelKeys[channel] {
                            channelKeyData = channelKey.withUnsafeBytes { Data($0) }
                        }
                    }
                    
                    MessageRetryService.shared.addMessageForRetry(
                        content: message.content,
                        mentions: message.mentions,
                        channel: message.channel,
                        isPrivate: message.isPrivate,
                        recipientPeerID: nil,
                        recipientNickname: message.recipientNickname,
                        channelKey: channelKeyData,
                        originalMessageID: message.id,
                        originalTimestamp: message.timestamp
                    )
                }
            }
        }
    }
    
    private func handleReceivedPacket(_ packet: BitchatPacket, from peerID: String, peripheral: CBPeripheral? = nil) {
        messageQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            guard packet.ttl > 0 else { 
                return 
            }
            
            // Validate packet has payload
            guard !packet.payload.isEmpty else {
                return
            }
            
            // Update last seen timestamp for this peer
            if let senderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8),
               senderID != "unknown" && senderID != self.myPeerID {
                peerLastSeenTimestamps[senderID] = Date()
            }
            
            // Replay attack protection: Check timestamp is within reasonable window (5 minutes)
            let currentTime = UInt64(Date().timeIntervalSince1970 * 1000) // milliseconds
            let timeDiff = abs(Int64(currentTime) - Int64(packet.timestamp))
            if timeDiff > 300000 { // 5 minutes in milliseconds
                // print("[SECURITY] Dropping packet from \(peerID) type:\(packet.type) - timestamp diff: \(timeDiff/1000)s (packet:\(packet.timestamp) vs current:\(currentTime))")
                return
            }
        
        // For fragments, include packet type in messageID to avoid dropping CONTINUE/END fragments
        let messageID: String
        if packet.type == MessageType.fragmentStart.rawValue || 
           packet.type == MessageType.fragmentContinue.rawValue || 
           packet.type == MessageType.fragmentEnd.rawValue {
            // Include both type and payload hash for fragments to ensure uniqueness
            messageID = "\(packet.timestamp)-\(String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) ?? "")-\(packet.type)-\(packet.payload.hashValue)"
        } else {
            // Include payload hash for absolute uniqueness (handles same-second messages)
            messageID = "\(packet.timestamp)-\(String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) ?? "")-\(packet.payload.prefix(64).hashValue)"
        }
        
        // Use bloom filter for efficient duplicate detection
        if messageBloomFilter.contains(messageID) {
            // Also check exact set for accuracy (bloom filter can have false positives)
            if processedMessages.contains(messageID) {
                return
            } else {
                // False positive from Bloom filter
                print("[BloomFilter] False positive detected for message: \(messageID)")
            }
        }
        
        messageBloomFilter.insert(messageID)
        processedMessages.insert(messageID)
        
        // Log statistics periodically
        if messageBloomFilter.insertCount % 100 == 0 {
            let fpRate = messageBloomFilter.estimatedFalsePositiveRate
            print("[BloomFilter] Items: \(messageBloomFilter.insertCount), Est. FP rate: \(String(format: "%.3f%%", fpRate * 100))")
        }
        
        // Reset bloom filter periodically to prevent saturation
        if processedMessages.count > 1000 {
            processedMessages.removeAll()
            messageBloomFilter.reset()
        }
        
        // let _ = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) ?? "unknown"
        
        
        // Note: We'll decode messages in the switch statement below, not here
        
        switch MessageType(rawValue: packet.type) {
        case .message:
            // Unified message handler for both broadcast and private messages
            guard let senderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) else {
                return
            }
            
            // Ignore our own messages
            if senderID == myPeerID {
                return
            }
            
            // Check if this is a broadcast or private message
            if let recipientID = packet.recipientID {
                if recipientID == SpecialRecipients.broadcast {
                    // BROADCAST MESSAGE
                    
                    // Verify signature if present
                    if let signature = packet.signature {
                        do {
                            let isValid = try encryptionService.verify(signature, for: packet.payload, from: senderID)
                            if !isValid {
                                return
                            }
                        } catch {
                            if !loggedCryptoErrors.contains(senderID) {
                                // print("[CRYPTO] Failed to verify signature from \(senderID): \(error)")
                                loggedCryptoErrors.insert(senderID)
                            }
                        }
                    }
                    
                    // Parse broadcast message (not encrypted)
                    if let message = BitchatMessage.fromBinaryPayload(packet.payload) {
                            
                        // Store nickname mapping
                        peerNicknamesLock.lock()
                        peerNicknames[senderID] = message.sender
                        peerNicknamesLock.unlock()
                        
                        // Handle encrypted channel messages
                        var finalContent = message.content
                        if message.isEncrypted, let channel = message.channel, let encryptedData = message.encryptedContent {
                            // Try to decrypt the content
                            if let decryptedContent = self.delegate?.decryptChannelMessage(encryptedData, channel: channel) {
                                finalContent = decryptedContent
                            } else {
                                // Unable to decrypt - show placeholder
                                finalContent = "[Encrypted message - password required]"
                            }
                        }
                        
                        let messageWithPeerID = BitchatMessage(
                            id: message.id,  // Preserve the original message ID
                            sender: message.sender,
                            content: finalContent,
                            timestamp: message.timestamp,
                            isRelay: message.isRelay,
                            originalSender: message.originalSender,
                            isPrivate: false,
                            recipientNickname: nil,
                            senderPeerID: senderID,
                            mentions: message.mentions,
                            channel: message.channel,
                            encryptedContent: message.encryptedContent,
                            isEncrypted: message.isEncrypted
                        )
                        
                        // Track last message time from this peer
                        if let peerID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) {
                            self.lastMessageFromPeer[peerID] = Date()
                        }
                        
                        DispatchQueue.main.async {
                            self.delegate?.didReceiveMessage(messageWithPeerID)
                        }
                        
                        // Generate and send ACK for channel messages if we're mentioned or it's a small channel
                        let viewModel = self.delegate as? ChatViewModel
                        let myNickname = viewModel?.nickname ?? self.myPeerID
                        if let _ = message.channel,
                           let mentions = message.mentions,
                           (mentions.contains(myNickname) || self.activePeers.count < 10) {
                            if let ack = DeliveryTracker.shared.generateAck(
                                for: messageWithPeerID,
                                myPeerID: self.myPeerID,
                                myNickname: myNickname,
                                hopCount: UInt8(self.maxTTL - packet.ttl)
                            ) {
                                self.sendDeliveryAck(ack, to: senderID)
                            }
                        }
                    }
                    
                    // Relay broadcast messages
                    var relayPacket = packet
                    relayPacket.ttl -= 1
                    if relayPacket.ttl > 0 {
                        // Probabilistic flooding with smart relay decisions
                        let relayProb = self.adaptiveRelayProbability
                        
                        // Always relay if TTL is high (fresh messages need to spread)
                        // or if we have few peers (ensure coverage in sparse networks)
                        let shouldRelay = relayPacket.ttl >= 4 || 
                                         self.activePeers.count <= 3 ||
                                         Double.random(in: 0...1) < relayProb
                        
                        if shouldRelay {
                            // Add random delay to prevent collision storms
                            let delay = Double.random(in: minMessageDelay...maxMessageDelay)
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                                self?.broadcastPacket(relayPacket)
                            }
                        }
                    }
                    
                } else if let recipientIDString = String(data: recipientID.trimmingNullBytes(), encoding: .utf8),
                          recipientIDString == myPeerID {
                    // PRIVATE MESSAGE FOR US
                    
                    // Verify signature if present
                    if let signature = packet.signature {
                        do {
                            let isValid = try encryptionService.verify(signature, for: packet.payload, from: senderID)
                            if !isValid {
                                return
                            }
                        } catch {
                            if !loggedCryptoErrors.contains(senderID) {
                                // print("[CRYPTO] Failed to verify signature from \(senderID): \(error)")
                                loggedCryptoErrors.insert(senderID)
                            }
                        }
                    }
                    
                    // Decrypt the message
                    let decryptedPayload: Data
                    do {
                        let decryptedPadded = try encryptionService.decrypt(packet.payload, from: senderID)
                        
                        // Remove padding
                        decryptedPayload = MessagePadding.unpad(decryptedPadded)
                    } catch {
                        // print("[CRYPTO] Failed to decrypt private message from \(senderID): \(error)")
                        return
                    }
                    
                    // Parse the decrypted message
                    if let message = BitchatMessage.fromBinaryPayload(decryptedPayload) {
                        // Check if this is a dummy message for cover traffic
                        if message.content.hasPrefix(self.coverTrafficPrefix) {
                                return  // Silently discard dummy messages
                        }
                        
                        // Check if we've seen this exact message recently (within 5 seconds)
                        let messageKey = "\(senderID)-\(message.content)-\(message.timestamp)"
                        if let lastReceived = self.receivedMessageTimestamps[messageKey] {
                            let timeSinceLastReceived = Date().timeIntervalSince(lastReceived)
                            if timeSinceLastReceived < 5.0 {
                                // print("[DUPLICATE] Message from \(senderID) received \(timeSinceLastReceived)s after first")
                            }
                        }
                        self.receivedMessageTimestamps[messageKey] = Date()
                        
                        // Clean up old entries (older than 1 minute)
                        let cutoffTime = Date().addingTimeInterval(-60)
                        self.receivedMessageTimestamps = self.receivedMessageTimestamps.filter { $0.value > cutoffTime }
                        
                        peerNicknamesLock.lock()
                        if peerNicknames[senderID] == nil {
                            peerNicknames[senderID] = message.sender
                        }
                        peerNicknamesLock.unlock()
                        
                        let messageWithPeerID = BitchatMessage(
                            id: message.id,  // Preserve the original message ID
                            sender: message.sender,
                            content: message.content,
                            timestamp: message.timestamp,
                            isRelay: message.isRelay,
                            originalSender: message.originalSender,
                            isPrivate: message.isPrivate,
                            recipientNickname: message.recipientNickname,
                            senderPeerID: senderID,
                            mentions: message.mentions,
                            channel: message.channel,
                            deliveryStatus: nil  // Will be set to .delivered in ChatViewModel
                        )
                        
                        // Track last message time from this peer
                        if let peerID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) {
                            self.lastMessageFromPeer[peerID] = Date()
                        }
                        
                        DispatchQueue.main.async {
                            self.delegate?.didReceiveMessage(messageWithPeerID)
                        }
                        
                        // Generate and send ACK for private messages
                        let viewModel = self.delegate as? ChatViewModel
                        let myNickname = viewModel?.nickname ?? self.myPeerID
                        if let ack = DeliveryTracker.shared.generateAck(
                            for: messageWithPeerID,
                            myPeerID: self.myPeerID,
                            myNickname: myNickname,
                            hopCount: UInt8(self.maxTTL - packet.ttl)
                        ) {
                            self.sendDeliveryAck(ack, to: senderID)
                        }
                    }
                    
                } else if packet.ttl > 0 {
                    // RELAY PRIVATE MESSAGE (not for us)
                    var relayPacket = packet
                    relayPacket.ttl -= 1
                    
                    // Check if this message is for an offline favorite and cache it
                    if let recipientIDString = String(data: recipientID.trimmingNullBytes(), encoding: .utf8),
                       let publicKeyData = self.encryptionService.getPeerIdentityKey(recipientIDString) {
                        let fingerprint = self.getPublicKeyFingerprint(publicKeyData)
                        // Only cache if recipient is a favorite AND is currently offline
                        if (self.delegate?.isFavorite(fingerprint: fingerprint) ?? false) && !self.activePeers.contains(recipientIDString) {
                            self.cacheMessage(relayPacket, messageID: messageID)
                        }
                    }
                    
                    // Private messages are important - use higher relay probability
                    let relayProb = min(self.adaptiveRelayProbability + 0.15, 1.0)  // Boost by 15%
                    
                    // Always relay if TTL is high or we have few peers
                    let shouldRelay = relayPacket.ttl >= 4 || 
                                     self.activePeers.count <= 3 ||
                                     Double.random(in: 0...1) < relayProb
                    
                    if shouldRelay {
                        // Add random delay to prevent collision storms
                        let delay = Double.random(in: minMessageDelay...maxMessageDelay)
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            self?.broadcastPacket(relayPacket)
                        }
                    }
                }
            }
            
        case .keyExchange:
            // Use senderID from packet for consistency
            if let senderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) {
                if packet.payload.count > 0 {
                    let publicKeyData = packet.payload
                    
                    // Create a unique key for this exchange
                    let exchangeKey = "\(senderID)-\(publicKeyData.hexEncodedString().prefix(16))"
                    
                    // Check if we've already processed this key exchange
                    if processedKeyExchanges.contains(exchangeKey) {
                        // print("[DEBUG] Ignoring duplicate key exchange from \(senderID)")
                        return
                    }
                    
                    // Mark this key exchange as processed
                    processedKeyExchanges.insert(exchangeKey)
                    do {
                        try encryptionService.addPeerPublicKey(senderID, publicKeyData: publicKeyData)
                    } catch {
                        // print("[KEY_EXCHANGE] Failed to add public key for \(senderID): \(error)")
                    }
                    
                    // Register identity key with view model for persistent favorites
                    if let viewModel = self.delegate as? ChatViewModel,
                       let identityKeyData = encryptionService.getPeerIdentityKey(senderID) {
                        viewModel.registerPeerPublicKey(peerID: senderID, publicKeyData: identityKeyData)
                    }
                    
                    // If we have RSSI from discovery, apply it to this peer
                    if let peripheral = peripheral,
                       let tempRSSI = peripheralRSSI[peripheral.identifier.uuidString] {
                        peerRSSI[senderID] = tempRSSI
                    }
                    
                    // Track this peer temporarily
                    if senderID != "unknown" && senderID != myPeerID {
                        // Check if we need to update peripheral mapping from the specific peripheral that sent this
                        if let peripheral = peripheral {
                            // Check if we already have a different peripheral connected for this peer
                            if let existingPeripheral = self.connectedPeripherals[senderID],
                               existingPeripheral != peripheral {
                                // We have a duplicate connection - disconnect the newer one
                                // print("[DEBUG] Duplicate connection detected for \(senderID), keeping existing")
                                intentionalDisconnects.insert(peripheral.identifier.uuidString)
                                centralManager?.cancelPeripheralConnection(peripheral)
                                return
                            }
                            
                            // Find if this peripheral is currently mapped with a temp ID
                            if let tempID = self.connectedPeripherals.first(where: { $0.value == peripheral })?.key,
                               tempID.count > 8 { // It's a temp ID
                                // Add real peer ID mapping BEFORE removing temp mapping
                                self.connectedPeripherals[senderID] = peripheral
                                // Then remove temp mapping
                                self.connectedPeripherals.removeValue(forKey: tempID)
                                // print("[DEBUG] Updated peripheral mapping from \(tempID) to \(senderID)")
                                
                                // Transfer RSSI from temp ID to peer ID
                                if let rssi = self.peripheralRSSI[tempID] {
                                    self.peerRSSI[senderID] = rssi
                                    self.peripheralRSSI.removeValue(forKey: tempID)
                                }
                            } else {
                                if !self.connectedPeripherals.keys.contains(senderID) {
                                    self.connectedPeripherals[senderID] = peripheral
                                }
                            }
                        }
                        
                        // Add to active peers with proper locking
                        activePeersLock.lock()
                        let wasNewPeer = !activePeers.contains(senderID)
                        if wasNewPeer {
                            activePeers.insert(senderID)
                            // print("[DEBUG] Added peer \(senderID) to active peers via key exchange")
                        }
                        activePeersLock.unlock()
                        
                        // Only notify if this was actually a new peer
                        if wasNewPeer {
                            self.notifyPeerListUpdate(immediate: true)
                        }
                    }
                    
                    // Send announce with our nickname immediately
                    self.sendAnnouncementToPeer(senderID)
                    
                    // Send cached messages immediately for faster sync
                    // Check if this peer has cached messages (especially for favorites)
                    self.sendCachedMessages(to: senderID)
                }
            }
            
        case .announce:
            if let nickname = String(data: packet.payload, encoding: .utf8), 
               let senderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) {
                
                // Ignore if it's from ourselves
                if senderID == myPeerID {
                    return
                }
                
                // Check if we've already announced this peer
                let isFirstAnnounce = !announcedPeers.contains(senderID)
                
                // Clean up stale peer IDs with the same nickname
                peerNicknamesLock.lock()
                var stalePeerIDs: [String] = []
                for (existingPeerID, existingNickname) in peerNicknames {
                    if existingNickname == nickname && existingPeerID != senderID {
                        // Check if this peer was seen very recently (within 10 seconds)
                        let wasRecentlySeen = peerLastSeenTimestamps[existingPeerID].map { Date().timeIntervalSince($0) < 10.0 } ?? false
                        if !wasRecentlySeen {
                            // Found a stale peer ID with the same nickname
                            stalePeerIDs.append(existingPeerID)
                            // Found stale peer ID
                        } else {
                            // Peer was seen recently, keeping both
                        }
                    }
                }
                
                // Remove stale peer IDs
                for stalePeerID in stalePeerIDs {
                    // Removing stale peer
                    peerNicknames.removeValue(forKey: stalePeerID)
                    
                    // Also remove from active peers
                    activePeersLock.lock()
                    activePeers.remove(stalePeerID)
                    activePeersLock.unlock()
                    
                    // Remove from announced peers
                    announcedPeers.remove(stalePeerID)
                    announcedToPeers.remove(stalePeerID)
                    
                    // Disconnect any peripherals associated with stale ID
                    if let peripheral = connectedPeripherals[stalePeerID] {
                        intentionalDisconnects.insert(peripheral.identifier.uuidString)
                        centralManager?.cancelPeripheralConnection(peripheral)
                        connectedPeripherals.removeValue(forKey: stalePeerID)
                        peripheralCharacteristics.removeValue(forKey: peripheral)
                    }
                    
                    // Remove RSSI data
                    peerRSSI.removeValue(forKey: stalePeerID)
                    
                    // Clear cached messages tracking
                    cachedMessagesSentToPeer.remove(stalePeerID)
                    
                    // Remove from last seen timestamps
                    peerLastSeenTimestamps.removeValue(forKey: stalePeerID)
                    
                    // Remove from processed key exchanges
                    processedKeyExchanges = processedKeyExchanges.filter { !$0.contains(stalePeerID) }
                }
                
                // If we had stale peers, notify the UI immediately
                if !stalePeerIDs.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        self?.notifyPeerListUpdate(immediate: true)
                    }
                }
                
                // Now add the new peer ID with the nickname
                peerNicknames[senderID] = nickname
                peerNicknamesLock.unlock()
                
                // Note: We can't update peripheral mapping here since we don't have 
                // access to which peripheral sent this announce. The mapping will be
                // updated when we receive key exchange packets where we do have the peripheral.
                
                // Add to active peers if not already there
                if senderID != "unknown" {
                    activePeersLock.lock()
                    let wasInserted = activePeers.insert(senderID).inserted
                    activePeersLock.unlock()
                    if wasInserted {
                        // Added peer \(senderID) (\(nickname)) to active peers
                    }
                    
                    // Show join message only for first announce
                    if isFirstAnnounce {
                        announcedPeers.insert(senderID)
                        DispatchQueue.main.async {
                            self.delegate?.didConnectToPeer(nickname)
                        }
                        self.notifyPeerListUpdate(immediate: true)
                        
                        DispatchQueue.main.async {
                            // Check if this is a favorite peer and send notification
                            // Note: This might not work immediately if key exchange hasn't happened yet
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                                guard let self = self else { return }
                                
                                // Check if this is a favorite using their public key fingerprint
                                if let publicKeyData = self.encryptionService.getPeerIdentityKey(senderID) {
                                    let fingerprint = self.getPublicKeyFingerprint(publicKeyData)
                                    if self.delegate?.isFavorite(fingerprint: fingerprint) ?? false {
                                        NotificationService.shared.sendFavoriteOnlineNotification(nickname: nickname)
                                        
                                        // Send any cached messages for this favorite
                                        self.sendCachedMessages(to: senderID)
                                    }
                                }
                            }
                        }
                    } else {
                        // Just update the peer list
                        self.notifyPeerListUpdate()
                    }
                } else {
                }
                
                // Relay announce if TTL > 0
                if packet.ttl > 1 {
                    var relayPacket = packet
                    relayPacket.ttl -= 1
                    
                    // Add small delay to prevent collision
                    let delay = Double.random(in: 0.1...0.3)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.broadcastPacket(relayPacket)
                    }
                }
            } else {
            }
            
        case .leave:
            if let senderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) {
                // Check if payload contains a channel hashtag
                if let channel = String(data: packet.payload, encoding: .utf8),
                   channel.hasPrefix("#") {
                    // Channel leave notification
                    
                    DispatchQueue.main.async {
                        self.delegate?.didReceiveChannelLeave(channel, from: senderID)
                    }
                    
                    // Relay if TTL > 0
                    if packet.ttl > 1 {
                        var relayPacket = packet
                        relayPacket.ttl -= 1
                        self.broadcastPacket(relayPacket)
                    }
                } else {
                    // Legacy peer disconnect (keeping for backwards compatibility)
                    if let nickname = String(data: packet.payload, encoding: .utf8) {
                        // Remove from active peers with proper locking
                        activePeersLock.lock()
                        activePeers.remove(senderID)
                        activePeersLock.unlock()
                        
                        announcedPeers.remove(senderID)
                        
                        // Show leave message
                        DispatchQueue.main.async {
                            self.delegate?.didDisconnectFromPeer(nickname)
                        }
                        self.notifyPeerListUpdate()
                        
                        // Clean up peer data
                        peerNicknamesLock.lock()
                        peerNicknames.removeValue(forKey: senderID)
                        peerNicknamesLock.unlock()
                    }
                }
            }
            
        case .fragmentStart, .fragmentContinue, .fragmentEnd:
            // let fragmentTypeStr = packet.type == MessageType.fragmentStart.rawValue ? "START" : 
            //                    (packet.type == MessageType.fragmentContinue.rawValue ? "CONTINUE" : "END")
            
            // Validate fragment has minimum required size
            if packet.payload.count < 13 {
                return
            }
            
            handleFragment(packet, from: peerID)
            
            // Relay fragments if TTL > 0
            var relayPacket = packet
            relayPacket.ttl -= 1
            if relayPacket.ttl > 0 {
                self.broadcastPacket(relayPacket)
            }
            
        case .channelAnnounce:
            if let payloadStr = String(data: packet.payload, encoding: .utf8) {
                // Parse payload: channel|isProtected|creatorID|keyCommitment
                let components = payloadStr.split(separator: "|").map(String.init)
                if components.count >= 3 {
                    let channel = components[0]
                    let isProtected = components[1] == "1"
                    let creatorID = components[2]
                    let keyCommitment = components.count >= 4 ? components[3] : nil
                    
                    
                    DispatchQueue.main.async {
                        self.delegate?.didReceivePasswordProtectedChannelAnnouncement(channel, isProtected: isProtected, creatorID: creatorID, keyCommitment: keyCommitment)
                    }
                    
                    // Relay announcement
                    if packet.ttl > 1 {
                        var relayPacket = packet
                        relayPacket.ttl -= 1
                        self.broadcastPacket(relayPacket)
                    }
                }
            }
            
        case .deliveryAck:
            // Handle delivery acknowledgment
            if let recipientIDData = packet.recipientID,
               let recipientID = String(data: recipientIDData.trimmingNullBytes(), encoding: .utf8),
               recipientID == myPeerID {
                // This ACK is for us - decrypt it
                if let senderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) {
                    do {
                        let decryptedData = try encryptionService.decrypt(packet.payload, from: senderID)
                        if let ack = DeliveryAck.decode(from: decryptedData) {
                            // Process the ACK
                            DeliveryTracker.shared.processDeliveryAck(ack)
                            
                            // Notify delegate
                            DispatchQueue.main.async {
                                self.delegate?.didReceiveDeliveryAck(ack)
                            }
                        }
                    } catch {
                        // Failed to decrypt ACK - might be from unknown sender
                    }
                }
            } else if packet.ttl > 0 {
                // Relay the ACK if not for us
                var relayPacket = packet
                relayPacket.ttl -= 1
                self.broadcastPacket(relayPacket)
            }
            
        case .channelRetention:
            if let payloadStr = String(data: packet.payload, encoding: .utf8) {
                // Parse payload: channel|enabled|creatorID
                let components = payloadStr.split(separator: "|").map(String.init)
                if components.count >= 3 {
                    let channel = components[0]
                    let enabled = components[1] == "1"
                    let creatorID = components[2]
                    
                    
                    DispatchQueue.main.async {
                        self.delegate?.didReceiveChannelRetentionAnnouncement(channel, enabled: enabled, creatorID: creatorID)
                    }
                    
                    // Relay announcement
                    if packet.ttl > 1 {
                        var relayPacket = packet
                        relayPacket.ttl -= 1
                        self.broadcastPacket(relayPacket)
                    }
                }
            }
            
        case .readReceipt:
            // Handle read receipt
            if let recipientIDData = packet.recipientID,
               let recipientID = String(data: recipientIDData.trimmingNullBytes(), encoding: .utf8),
               recipientID == myPeerID {
                // This read receipt is for us - decrypt it
                if let senderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) {
                    do {
                        let decryptedData = try encryptionService.decrypt(packet.payload, from: senderID)
                        if let receipt = ReadReceipt.decode(from: decryptedData) {
                            // Process the read receipt
                            DispatchQueue.main.async {
                                self.delegate?.didReceiveReadReceipt(receipt)
                            }
                        }
                    } catch {
                        // Failed to decrypt read receipt - might be from unknown sender
                    }
                }
            } else if packet.ttl > 0 {
                // Relay the read receipt if not for us
                var relayPacket = packet
                relayPacket.ttl -= 1
                self.broadcastPacket(relayPacket)
            }
            
        default:
            break
        }
        }
    }
    
    private func sendFragmentedPacket(_ packet: BitchatPacket) {
        guard let fullData = packet.toBinaryData() else { return }
        
        // Generate a fixed 8-byte fragment ID
        var fragmentID = Data(count: 8)
        fragmentID.withUnsafeMutableBytes { bytes in
            arc4random_buf(bytes.baseAddress, 8)
        }
        
        let fragments = stride(from: 0, to: fullData.count, by: maxFragmentSize).map { offset in
            fullData[offset..<min(offset + maxFragmentSize, fullData.count)]
        }
        
        // Splitting into fragments
        
        // Optimize fragment transmission for speed
        // Use minimal delay for BLE 5.0 which supports better throughput
        let delayBetweenFragments: TimeInterval = 0.02  // 20ms between fragments for faster transmission
        
        for (index, fragmentData) in fragments.enumerated() {
            var fragmentPayload = Data()
            
            // Fragment header: fragmentID (8) + index (2) + total (2) + originalType (1) + data
            fragmentPayload.append(fragmentID)
            fragmentPayload.append(UInt8((index >> 8) & 0xFF))
            fragmentPayload.append(UInt8(index & 0xFF))
            fragmentPayload.append(UInt8((fragments.count >> 8) & 0xFF))
            fragmentPayload.append(UInt8(fragments.count & 0xFF))
            fragmentPayload.append(packet.type)
            fragmentPayload.append(fragmentData)
            
            let fragmentType: MessageType
            if index == 0 {
                fragmentType = .fragmentStart
            } else if index == fragments.count - 1 {
                fragmentType = .fragmentEnd
            } else {
                fragmentType = .fragmentContinue
            }
            
            let fragmentPacket = BitchatPacket(
                type: fragmentType.rawValue,
                ttl: packet.ttl,
                senderID: myPeerID,
                payload: fragmentPayload
            )
            
            // Send fragments with linear delay
            let totalDelay = Double(index) * delayBetweenFragments
            
            // Send fragments on background queue with calculated delay
            messageQueue.asyncAfter(deadline: .now() + totalDelay) { [weak self] in
                self?.broadcastPacket(fragmentPacket)
            }
        }
        
        let _ = Double(fragments.count - 1) * delayBetweenFragments
    }
    
    private func handleFragment(_ packet: BitchatPacket, from peerID: String) {
        // Handling fragment
        
        guard packet.payload.count >= 13 else { 
            return 
        }
        
        // Convert to array for safer access
        let payloadArray = Array(packet.payload)
        var offset = 0
        
        // Extract fragment ID as binary data (8 bytes)
        guard payloadArray.count >= 8 else {
            return
        }
        
        let fragmentIDData = Data(payloadArray[0..<8])
        let fragmentID = fragmentIDData.hexEncodedString()
        offset = 8
        
        // Safely extract index
        guard payloadArray.count >= offset + 2 else { 
            // Not enough data for index
            return 
        }
        let index = Int(payloadArray[offset]) << 8 | Int(payloadArray[offset + 1])
        offset += 2
        
        // Safely extract total
        guard payloadArray.count >= offset + 2 else { 
            // Not enough data for total
            return 
        }
        let total = Int(payloadArray[offset]) << 8 | Int(payloadArray[offset + 1])
        offset += 2
        
        // Safely extract original type
        guard payloadArray.count >= offset + 1 else { 
            // Not enough data for type
            return 
        }
        let originalType = payloadArray[offset]
        offset += 1
        
        // Extract fragment data
        let fragmentData: Data
        if payloadArray.count > offset {
            fragmentData = Data(payloadArray[offset...])
        } else {
            fragmentData = Data()
        }
        
        
        // Initialize fragment collection if needed
        if incomingFragments[fragmentID] == nil {
            incomingFragments[fragmentID] = [:]
            fragmentMetadata[fragmentID] = (originalType, total, Date())
        }
        
        incomingFragments[fragmentID]?[index] = fragmentData
        
        
        // Check if we have all fragments
        if let fragments = incomingFragments[fragmentID],
           fragments.count == total {
            
            // Reassemble the original packet
            var reassembledData = Data()
            for i in 0..<total {
                if let fragment = fragments[i] {
                    reassembledData.append(fragment)
                } else {
                    // Missing fragment
                    return
                }
            }
            
            // Successfully reassembled fragments
            
            // Parse and handle the reassembled packet
            if let reassembledPacket = BitchatPacket.from(reassembledData) {
                // Clean up
                incomingFragments.removeValue(forKey: fragmentID)
                fragmentMetadata.removeValue(forKey: fragmentID)
                
                // Handle the reassembled packet
                handleReceivedPacket(reassembledPacket, from: peerID, peripheral: nil)
            }
        }
        
        // Clean up old fragments (older than 30 seconds)
        let cutoffTime = Date().addingTimeInterval(-30)
        for (fragID, metadata) in fragmentMetadata {
            if metadata.timestamp < cutoffTime {
                incomingFragments.removeValue(forKey: fragID)
                fragmentMetadata.removeValue(forKey: fragID)
            }
        }
    }
}

extension BluetoothMeshService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Central manager state updated
        if central.state == .poweredOn {
            startScanning()
            
            // Send announces when central manager is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.sendBroadcastAnnounce()
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Optimize for 300m range - only connect to strong enough signals
        let rssiValue = RSSI.intValue
        
        // Filter out very weak signals (below -90 dBm) to save battery
        guard rssiValue > -90 else { return }
        
        // Throttle RSSI updates to save CPU
        let peripheralID = peripheral.identifier.uuidString
        if let lastUpdate = lastRSSIUpdate[peripheralID],
           Date().timeIntervalSince(lastUpdate) < 1.0 {
            return  // Skip update if less than 1 second since last update
        }
        lastRSSIUpdate[peripheralID] = Date()
        
        // Store RSSI by peripheral ID for later use
        peripheralRSSI[peripheralID] = RSSI
        
        // Extract peer ID from name (no prefix for stealth)
        if let name = peripheral.name, name.count == 8 {
            // Assume 8-character names are peer IDs
            let peerID = name
            peerRSSI[peerID] = RSSI
            // Discovered potential peer
        }
        
        // Connection pooling with exponential backoff
        // peripheralID already declared above
        
        // Check if we should attempt connection (considering backoff)
        if let backoffTime = connectionBackoff[peripheralID],
           Date().timeIntervalSince1970 < backoffTime {
            // Still in backoff period, skip connection
            return
        }
        
        // Check if we already have this peripheral in our pool
        if let pooledPeripheral = connectionPool[peripheralID] {
            // Reuse existing peripheral from pool
            if pooledPeripheral.state == CBPeripheralState.disconnected {
                // Reconnect if disconnected
                central.connect(pooledPeripheral, options: [
                    CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnNotificationKey: true
                ])
            }
            return
        }
        
        // New peripheral - add to pool and connect
        if !discoveredPeripherals.contains(peripheral) {
            discoveredPeripherals.append(peripheral)
            peripheral.delegate = self
            connectionPool[peripheralID] = peripheral
            
            // Track connection attempts
            let attempts = connectionAttempts[peripheralID] ?? 0
            connectionAttempts[peripheralID] = attempts + 1
            
            // Only attempt if under max attempts
            if attempts < maxConnectionAttempts {
                // Use optimized connection parameters for better range
                let connectionOptions: [String: Any] = [
                    CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnNotificationKey: true
                ]
                
                central.connect(peripheral, options: connectionOptions)
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([BluetoothMeshService.serviceUUID])
        
        // Store peripheral by its system ID temporarily until we get the real peer ID
        let tempID = peripheral.identifier.uuidString
        connectedPeripherals[tempID] = peripheral
        
        // Connected to peripheral
        
        // Don't show connected message yet - wait for key exchange
        // This prevents the connect/disconnect/connect pattern
        
        // Request RSSI reading
        peripheral.readRSSI()
        
        // iOS 11+ BLE 5.0: Request 2M PHY for better range and speed
        if #available(iOS 11.0, macOS 10.14, *) {
            // 2M PHY provides better range than 1M PHY
            // This is a hint - system will use best available
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let peripheralID = peripheral.identifier.uuidString
        
        // Check if this was an intentional disconnect
        if intentionalDisconnects.contains(peripheralID) {
            intentionalDisconnects.remove(peripheralID)
            // Don't process this disconnect further
            return
        }
        
        // Implement exponential backoff for failed connections
        if error != nil {
            let attempts = connectionAttempts[peripheralID] ?? 0
            if attempts >= maxConnectionAttempts {
                // Max attempts reached, apply long backoff
                let backoffDuration = baseBackoffInterval * pow(2.0, Double(attempts))
                connectionBackoff[peripheralID] = Date().timeIntervalSince1970 + backoffDuration
            }
        } else {
            // Clean disconnect, reset attempts
            connectionAttempts[peripheralID] = 0
            connectionBackoff.removeValue(forKey: peripheralID)
        }
        
        // Find peer ID for this peripheral (could be temp ID or real ID)
        var foundPeerID: String? = nil
        for (id, per) in connectedPeripherals {
            if per == peripheral {
                foundPeerID = id
                break
            }
        }
        
        if let peerID = foundPeerID {
            connectedPeripherals.removeValue(forKey: peerID)
            peripheralCharacteristics.removeValue(forKey: peripheral)
            
            // print("[DEBUG] Peripheral disconnected with ID: \(peerID)")
            
            // Only remove from active peers if it's not a temp ID
            // Temp IDs shouldn't be in activePeers anyway
            if peerID.count <= 8 {  // Real peer ID
                activePeersLock.lock()
                let wasRemoved = activePeers.remove(peerID) != nil
                activePeersLock.unlock()
                
                if wasRemoved {
                    // print("[DEBUG] Removed peer \(peerID) from active peers due to disconnect")
                }
                
                announcedPeers.remove(peerID)
                announcedToPeers.remove(peerID)
            } else {
                // print("[DEBUG] Peripheral with temp ID \(peerID) disconnected, not removing from active peers")
            }
            
            // Clear cached messages tracking for this peer to allow re-sending if they reconnect
            cachedMessagesSentToPeer.remove(peerID)
            // Peer disconnected
            
            // Only show disconnect if we have a resolved nickname
            peerNicknamesLock.lock()
            let nickname = peerNicknames[peerID]
            peerNicknamesLock.unlock()
            
            if let nickname = nickname, nickname != peerID {
                DispatchQueue.main.async {
                    self.delegate?.didDisconnectFromPeer(nickname)
                }
            }
            self.notifyPeerListUpdate()
        }
        
        // Keep in pool but remove from discovered list
        discoveredPeripherals.removeAll { $0 == peripheral }
        
        // Continue scanning for reconnection
        if centralManager?.state == .poweredOn {
            // Stop and restart to ensure clean state
            centralManager?.stopScan()
            centralManager?.scanForPeripherals(withServices: [BluetoothMeshService.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }
}

extension BluetoothMeshService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        
        for service in services {
            peripheral.discoverCharacteristics([BluetoothMeshService.characteristicUUID], for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        
        for characteristic in characteristics {
            if characteristic.uuid == BluetoothMeshService.characteristicUUID {
                peripheral.setNotifyValue(true, for: characteristic)
                peripheralCharacteristics[peripheral] = characteristic
                
                // Request maximum MTU for faster data transfer
                // iOS supports up to 512 bytes with BLE 5.0
                peripheral.maximumWriteValueLength(for: .withoutResponse)
                
                // Send key exchange and announce immediately without any delay
                let publicKeyData = self.encryptionService.getCombinedPublicKeyData()
                let packet = BitchatPacket(
                    type: MessageType.keyExchange.rawValue,
                    ttl: 1,
                    senderID: self.myPeerID,
                    payload: publicKeyData
                )
                
                if let data = packet.toBinaryData() {
                    let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
                    peripheral.writeValue(data, for: characteristic, type: writeType)
                }
                
                // Send announce packet after a short delay to avoid overwhelming the connection
                // Send multiple times for reliability
                if let vm = self.delegate as? ChatViewModel {
                    // Send announces multiple times with delays
                    for delay in [0.3, 0.8, 1.5] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self = self else { return }
                            let announcePacket = BitchatPacket(
                                type: MessageType.announce.rawValue,
                                ttl: 3,
                                senderID: self.myPeerID,
                                payload: Data(vm.nickname.utf8)
                            )
                            self.broadcastPacket(announcePacket)
                        }
                    }
                    
                    // Also send targeted announce to this specific peripheral
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak peripheral] in
                        guard let self = self,
                              let peripheral = peripheral,
                              peripheral.state == .connected,
                              let characteristic = peripheral.services?.first(where: { $0.uuid == BluetoothMeshService.serviceUUID })?.characteristics?.first(where: { $0.uuid == BluetoothMeshService.characteristicUUID }) else { return }
                        
                        let announcePacket = BitchatPacket(
                            type: MessageType.announce.rawValue,
                            ttl: 3,
                            senderID: self.myPeerID,
                            payload: Data(vm.nickname.utf8)
                        )
                        if let data = announcePacket.toBinaryData() {
                            let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
                            peripheral.writeValue(data, for: characteristic, type: writeType)
                        }
                    }
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else {
            return
        }
        
        guard let packet = BitchatPacket.from(data) else { 
            // Failed to parse packet
            return 
        }
        
        // Use the sender ID from the packet, not our local mapping which might still be a temp ID
        let _ = connectedPeripherals.first(where: { $0.value == peripheral })?.key ?? "unknown"
        let packetSenderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) ?? "unknown"
        
        // Always handle received packets
        handleReceivedPacket(packet, from: packetSenderID, peripheral: peripheral)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            // Log error but don't spam for common errors
            let errorCode = (error as NSError).code
            if errorCode != 242 { // Don't log the common "Unknown ATT error"
                // print("[ERROR] Write failed: \(error)")
            }
        } else {
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        peripheral.discoverServices([BluetoothMeshService.serviceUUID])
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        // Handle notification state updates if needed
    }
    
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        
        // Find the peer ID for this peripheral
        if let peerID = connectedPeripherals.first(where: { $0.value == peripheral })?.key {
            // Handle both temp IDs and real peer IDs
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                if peerID.count > 8 {
                    // It's a temp ID, store RSSI temporarily
                    self.peripheralRSSI[peerID] = RSSI
                    // Keep trying to read RSSI until we get real peer ID
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak peripheral] in
                        peripheral?.readRSSI()
                    }
                } else {
                    // It's a real peer ID, store it
                    self.peerRSSI[peerID] = RSSI
                    // Force UI update when we have a real peer ID
                    self.notifyPeerListUpdate()
                }
            }
            
            // Periodically update RSSI
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak peripheral] in
                peripheral?.readRSSI()
            }
        }
    }
}

extension BluetoothMeshService: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        // Peripheral manager state updated
        switch peripheral.state {
        case .poweredOn:
            setupPeripheral()
            startAdvertising()
            
            // Send announces when peripheral manager is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.sendBroadcastAnnounce()
            }
        default:
            break
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        // Handle service addition if needed
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if let data = request.value,
               let packet = BitchatPacket.from(data) {
                // Try to identify peer from packet
                let peerID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) ?? "unknown"
                
                
                // Store the central for updates
                if !subscribedCentrals.contains(request.central) {
                    subscribedCentrals.append(request.central)
                }
                
                // Track this peer as connected
                if peerID != "unknown" && peerID != myPeerID {
                    // Send key exchange back if we haven't already
                    if packet.type == MessageType.keyExchange.rawValue {
                        let publicKeyData = self.encryptionService.getCombinedPublicKeyData()
                        let responsePacket = BitchatPacket(
                            type: MessageType.keyExchange.rawValue,
                            ttl: 1,
                            senderID: self.myPeerID,
                            payload: publicKeyData
                        )
                        if let data = responsePacket.toBinaryData() {
                            if let char = self.characteristic {
                                peripheral.updateValue(data, for: char, onSubscribedCentrals: [request.central])
                            }
                        }
                        
                        // Send announce immediately after key exchange
                        // Send multiple times for reliability
                        if let vm = self.delegate as? ChatViewModel {
                            for delay in [0.1, 0.5, 1.0] {
                                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                                    guard let self = self else { return }
                                    let announcePacket = BitchatPacket(
                                        type: MessageType.announce.rawValue,
                                        ttl: 3,
                                        senderID: self.myPeerID,
                                        payload: Data(vm.nickname.utf8)
                                    )
                                    if let data = announcePacket.toBinaryData() {
                                        if let char = self.characteristic {
                                            peripheral.updateValue(data, for: char, onSubscribedCentrals: nil)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    self.notifyPeerListUpdate()
                }
                
                handleReceivedPacket(packet, from: peerID)
                peripheral.respond(to: request, withResult: .success)
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if !subscribedCentrals.contains(central) {
            subscribedCentrals.append(central)
            
            // Send our public key to the newly connected central
            let publicKeyData = encryptionService.getCombinedPublicKeyData()
            let keyPacket = BitchatPacket(
                type: MessageType.keyExchange.rawValue,
                ttl: 1,
                senderID: myPeerID,
                payload: publicKeyData
            )
            
            if let data = keyPacket.toBinaryData() {
                if let char = self.characteristic {
                    peripheral.updateValue(data, for: char, onSubscribedCentrals: [central])
                }
                
                // We'll send announce when we receive their key exchange
            }
            
            // Update peer list to show we're connected (even without peer ID yet)
            self.notifyPeerListUpdate()
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeAll { $0 == central }
        
        // Don't aggressively remove peers when centrals unsubscribe
        // Peers may be connected through multiple paths
        
        // Ensure advertising continues for reconnection
        if peripheralManager?.state == .poweredOn && peripheralManager?.isAdvertising == false {
            startAdvertising()
        }
    }
    
    // MARK: - Battery Monitoring
    
    private func setupBatteryOptimizer() {
        // Subscribe to power mode changes
        batteryOptimizer.$currentPowerMode
            .sink { [weak self] powerMode in
                self?.handlePowerModeChange(powerMode)
            }
            .store(in: &batteryOptimizerCancellables)
        
        // Subscribe to battery level changes
        batteryOptimizer.$batteryLevel
            .sink { [weak self] level in
                self?.currentBatteryLevel = level
            }
            .store(in: &batteryOptimizerCancellables)
        
        // Initial update
        handlePowerModeChange(batteryOptimizer.currentPowerMode)
    }
    
    private func handlePowerModeChange(_ powerMode: PowerMode) {
        let params = batteryOptimizer.scanParameters
        activeScanDuration = params.duration
        scanPauseDuration = params.pause
        
        // Update max connections
        let maxConnections = powerMode.maxConnections
        
        // If we have too many connections, disconnect from the least important ones
        if connectedPeripherals.count > maxConnections {
            disconnectLeastImportantPeripherals(keepCount: maxConnections)
        }
        
        // Update message aggregation window
        aggregationWindow = powerMode.messageAggregationWindow
        
        // If we're currently scanning, restart with new parameters
        if scanDutyCycleTimer != nil {
            scanDutyCycleTimer?.invalidate()
            scheduleScanDutyCycle()
        }
        
        // Handle advertising intervals
        if powerMode.advertisingInterval > 0 {
            // Stop continuous advertising and use interval-based
            scheduleAdvertisingCycle(interval: powerMode.advertisingInterval)
        } else {
            // Continuous advertising for performance mode
            startAdvertising()
        }
    }
    
    private func disconnectLeastImportantPeripherals(keepCount: Int) {
        // Disconnect peripherals with lowest activity/importance
        let sortedPeripherals = connectedPeripherals.values
            .sorted { peer1, peer2 in
                // Keep peripherals we've recently communicated with
                let peer1Activity = lastMessageFromPeer[peer1.identifier.uuidString] ?? Date.distantPast
                let peer2Activity = lastMessageFromPeer[peer2.identifier.uuidString] ?? Date.distantPast
                return peer1Activity > peer2Activity
            }
        
        // Disconnect the least active ones
        let toDisconnect = sortedPeripherals.dropFirst(keepCount)
        for peripheral in toDisconnect {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }
    
    private func scheduleAdvertisingCycle(interval: TimeInterval) {
        advertisingTimer?.invalidate()
        
        // Stop advertising
        if isAdvertising {
            peripheralManager?.stopAdvertising()
            isAdvertising = false
        }
        
        // Schedule next advertising burst
        advertisingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.advertiseBurst()
        }
    }
    
    private func advertiseBurst() {
        guard batteryOptimizer.currentPowerMode != .ultraLowPower || !batteryOptimizer.isInBackground else {
            return // Skip advertising in ultra low power + background
        }
        
        startAdvertising()
        
        // Stop advertising after a short burst (1 second)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if self?.batteryOptimizer.currentPowerMode.advertisingInterval ?? 0 > 0 {
                self?.peripheralManager?.stopAdvertising()
                self?.isAdvertising = false
            }
        }
    }
    
    // Legacy battery monitoring methods - kept for compatibility
    // Now handled by BatteryOptimizer
    private func updateBatteryLevel() {
        // This method is now handled by BatteryOptimizer
        // Keeping empty implementation for compatibility
    }
    
    private func updateScanParametersForBattery() {
        // This method is now handled by BatteryOptimizer through handlePowerModeChange
        // Keeping empty implementation for compatibility
    }
    
    // MARK: - Privacy Utilities
    
    private func randomDelay() -> TimeInterval {
        // Generate random delay between min and max for timing obfuscation
        return TimeInterval.random(in: minMessageDelay...maxMessageDelay)
    }
    
    // MARK: - Cover Traffic
    
    private func startCoverTraffic() {
        // Start cover traffic with random interval
        scheduleCoverTraffic()
    }
    
    private func scheduleCoverTraffic() {
        // Random interval between 30-120 seconds
        let interval = TimeInterval.random(in: 30...120)
        
        coverTrafficTimer?.invalidate()
        coverTrafficTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.sendDummyMessage()
            self?.scheduleCoverTraffic() // Schedule next dummy message
        }
    }
    
    private func sendDummyMessage() {
        // Only send dummy messages if we have connected peers
        let peers = getAllConnectedPeerIDs()
        guard !peers.isEmpty else { return }
        
        // Skip if battery is low
        if currentBatteryLevel < 0.2 {
            return
        }
        
        // Pick a random peer to send to
        guard let randomPeer = peers.randomElement() else { return }
        
        // Generate random dummy content
        let dummyContent = generateDummyContent()
        
        // Sending cover traffic
        
        // Send as a private message so it's encrypted
        peerNicknamesLock.lock()
        let recipientNickname = peerNicknames[randomPeer] ?? "unknown"
        peerNicknamesLock.unlock()
        
        sendPrivateMessage(dummyContent, to: randomPeer, recipientNickname: recipientNickname)
    }
    
    private func generateDummyContent() -> String {
        // Generate realistic-looking dummy messages
        let templates = [
            "hey",
            "ok",
            "got it",
            "sure",
            "sounds good",
            "thanks",
            "np",
            "see you there",
            "on my way",
            "running late",
            "be there soon",
            "👍",
            "✓",
            "meeting at the usual spot",
            "confirmed",
            "roger that"
        ]
        
        // Prefix with dummy marker (will be encrypted)
        return coverTrafficPrefix + (templates.randomElement() ?? "ok")
    }
    
    
    private func updatePeerLastSeen(_ peerID: String) {
        peerLastSeenTimestamps[peerID] = Date()
    }
}
