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
import os.log
#if os(macOS)
import AppKit
import IOKit.ps
#else
import UIKit
#endif

// Extension for hex encoding/decoding
extension Data {
    func hexEncodedString() -> String {
        if self.isEmpty {
            return ""
        }
        return self.map { String(format: "%02x", $0) }.joined()
    }
    
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        
        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(String(hexString[index..<nextIndex]), radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        
        self = data
    }
}

// Extension for TimeInterval to Data conversion
extension TimeInterval {
    var data: Data {
        var value = self
        return Data(bytes: &value, count: MemoryLayout<TimeInterval>.size)
    }
}

// Version negotiation state
enum VersionNegotiationState {
    case none
    case helloSent
    case ackReceived(version: UInt8)
    case failed(reason: String)
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
    // Thread-safe collections using concurrent queues
    private let collectionsQueue = DispatchQueue(label: "bitchat.collections", attributes: .concurrent)
    private var peerNicknames: [String: String] = [:]
    private var activePeers: Set<String> = []  // Track all active peers
    private var peerRSSI: [String: NSNumber] = [:] // Track RSSI values for peers
    private var peripheralRSSI: [String: NSNumber] = [:] // Track RSSI by peripheral ID during discovery
    private var loggedCryptoErrors = Set<String>()  // Track which peers we've logged crypto errors for
    
    // MARK: - Peer Identity Rotation
    // Mappings between ephemeral peer IDs and permanent fingerprints
    private var peerIDToFingerprint: [String: String] = [:]  // PeerID -> Fingerprint
    private var fingerprintToPeerID: [String: String] = [:]  // Fingerprint -> Current PeerID
    private var peerIdentityBindings: [String: PeerIdentityBinding] = [:]  // Fingerprint -> Full binding
    private var previousPeerID: String?  // Our previous peer ID for grace period
    private var rotationTimestamp: Date?  // When we last rotated
    private let rotationGracePeriod: TimeInterval = 60.0  // 1 minute grace period
    private var rotationLocked = false  // Prevent rotation during critical operations
    private var rotationTimer: Timer?  // Timer for scheduled rotations
    
    weak var delegate: BitchatDelegate?
    private let noiseService = NoiseEncryptionService()
    
    // Protocol version negotiation state
    private var versionNegotiationState: [String: VersionNegotiationState] = [:]
    private var negotiatedVersions: [String: UInt8] = [:]  // peerID -> agreed version
    
    func getNoiseService() -> NoiseEncryptionService {
        return noiseService
    }
    private let messageQueue = DispatchQueue(label: "bitchat.messageQueue", attributes: .concurrent) // Concurrent queue with barriers
    private let processedMessages = BoundedSet<String>(maxSize: 1000)  // Bounded to prevent memory growth
    private let maxTTL: UInt8 = 7  // Maximum hops for long-distance delivery
    private var announcedToPeers = Set<String>()  // Track which peers we've announced to
    private var announcedPeers = Set<String>()  // Track peers who have already been announced
    private var intentionalDisconnects = Set<String>()  // Track peripherals we're disconnecting intentionally
    private var peerLastSeenTimestamps = LRUCache<String, Date>(maxSize: 100)  // Bounded cache for peer timestamps
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
    private let deliveredMessages = BoundedSet<String>(maxSize: 5000)  // Bounded to prevent memory growth
    private var cachedMessagesSentToPeer = Set<String>()  // Track which peers have already received cached messages
    private let receivedMessageTimestamps = LRUCache<String, Date>(maxSize: 1000)  // Bounded cache
    private let recentlySentMessages = BoundedSet<String>(maxSize: 500)  // Short-term bounded cache
    private let lastMessageFromPeer = LRUCache<String, Date>(maxSize: 100)  // Bounded cache
    private let processedNoiseMessages = BoundedSet<String>(maxSize: 1000)  // Bounded cache
    
    // Battery and range optimizations
    private var scanDutyCycleTimer: Timer?
    private var isActivelyScanning = true
    private var activeScanDuration: TimeInterval = 5.0  // will be adjusted based on battery
    private var scanPauseDuration: TimeInterval = 10.0  // will be adjusted based on battery
    private var lastRSSIUpdate: [String: Date] = [:]  // Throttle RSSI updates
    private var batteryMonitorTimer: Timer?
    private var currentBatteryLevel: Float = 1.0  // Default to full battery
    
    // Battery optimizer integration
    private let batteryOptimizer = BatteryOptimizer.shared
    private var batteryOptimizerCancellables = Set<AnyCancellable>()
    
    // Peer list update debouncing
    private var peerListUpdateTimer: Timer?
    private let peerListUpdateDebounceInterval: TimeInterval = 0.1  // 100ms debounce for more responsive updates
    
    // Track when we last sent identity announcements to prevent flooding
    private var lastIdentityAnnounceTimes: [String: Date] = [:]
    private let identityAnnounceMinInterval: TimeInterval = 2.0  // Minimum 2 seconds between announcements per peer
    
    // Track handshake attempts to handle timeouts
    private var handshakeAttemptTimes: [String: Date] = [:]
    private let handshakeTimeout: TimeInterval = 5.0  // 5 seconds before retrying
    
    // Pending private messages waiting for handshake
    private var pendingPrivateMessages: [String: [(content: String, recipientNickname: String, messageID: String)]] = [:]
    
    // Cover traffic for privacy
    private var coverTrafficTimer: Timer?
    private let coverTrafficPrefix = "☂DUMMY☂"  // Prefix to identify dummy messages after decryption
    private var lastCoverTrafficTime = Date()
    private var advertisingTimer: Timer?  // Timer for interval-based advertising
    
    // Timing randomization for privacy
    private let minMessageDelay: TimeInterval = 0.01  // 10ms minimum for faster sync
    private let maxMessageDelay: TimeInterval = 0.1   // 100ms maximum for faster sync
    
    // Fragment handling with security limits
    private var incomingFragments: [String: [Int: Data]] = [:]  // fragmentID -> [index: data]
    private var fragmentMetadata: [String: (originalType: UInt8, totalFragments: Int, timestamp: Date)] = [:]
    private let maxFragmentSize = 500  // Optimized for BLE 5.0 extended data length
    private let maxConcurrentFragmentSessions = 20  // Limit concurrent fragment sessions to prevent DoS
    private let fragmentTimeout: TimeInterval = 30  // 30 seconds timeout for incomplete fragments
    
    var myPeerID: String
    
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
    
    // Removed getPublicKeyFingerprint - no longer needed with Noise
    
    // Get peer's fingerprint (replaces getPeerPublicKey)
    func getPeerFingerprint(_ peerID: String) -> String? {
        return noiseService.getPeerFingerprint(peerID)
    }
    
    // MARK: - Peer Identity Mapping
    
    // Update peer identity binding when receiving announcements
    func updatePeerBinding(_ newPeerID: String, fingerprint: String, binding: PeerIdentityBinding) {
        // Use async to ensure we're not blocking during view updates
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            var oldPeerID: String? = nil
            
            // Remove old peer ID mapping if exists
            if let existingPeerID = self.fingerprintToPeerID[fingerprint], existingPeerID != newPeerID {
                oldPeerID = existingPeerID
                
                self.peerIDToFingerprint.removeValue(forKey: existingPeerID)
                
                // Transfer nickname if known
                if let nickname = self.peerNicknames[existingPeerID] {
                    self.peerNicknames[newPeerID] = nickname
                    self.peerNicknames.removeValue(forKey: existingPeerID)
                }
                
                // Update active peers set
                if self.activePeers.contains(existingPeerID) {
                    self.activePeers.remove(existingPeerID)
                    // Don't pre-insert the new peer ID - let the announce packet handle it
                    // This ensures the connect message logic works properly
                }
                
                // Transfer any connected peripherals
                if let peripheral = self.connectedPeripherals[existingPeerID] {
                    self.connectedPeripherals.removeValue(forKey: existingPeerID)
                    self.connectedPeripherals[newPeerID] = peripheral
                }
                
                // Transfer RSSI data
                if let rssi = self.peerRSSI[existingPeerID] {
                    self.peerRSSI.removeValue(forKey: existingPeerID)
                    self.peerRSSI[newPeerID] = rssi
                }
            }
            
            // Add new mapping
            self.peerIDToFingerprint[newPeerID] = fingerprint
            self.fingerprintToPeerID[fingerprint] = newPeerID
            self.peerIdentityBindings[fingerprint] = binding
            
            // Also update nickname from binding
            self.peerNicknames[newPeerID] = binding.nickname
            
            // Notify about the change if it's a rotation
            if let oldID = oldPeerID {
                self.notifyPeerIDChange(oldPeerID: oldID, newPeerID: newPeerID, fingerprint: fingerprint)
            }
        }
    }
    
    // Get current peer ID for a fingerprint
    func getCurrentPeerID(for fingerprint: String) -> String? {
        return collectionsQueue.sync {
            fingerprintToPeerID[fingerprint]
        }
    }
    
    // Get fingerprint for a peer ID
    func getFingerprint(for peerID: String) -> String? {
        return collectionsQueue.sync {
            peerIDToFingerprint[peerID]
        }
    }
    
    // Check if a peer ID belongs to us (current or previous)
    func isPeerIDOurs(_ peerID: String) -> Bool {
        if peerID == myPeerID {
            return true
        }
        
        // Check if it's our previous ID within grace period
        if let previousID = previousPeerID,
           peerID == previousID,
           let rotationTime = rotationTimestamp,
           Date().timeIntervalSince(rotationTime) < rotationGracePeriod {
            return true
        }
        
        return false
    }
    
    // MARK: - Peer ID Rotation
    
    private func generateNewPeerID() -> String {
        // Generate 8 random bytes (64 bits) for strong collision resistance
        var randomBytes = [UInt8](repeating: 0, count: 8)
        let result = SecRandomCopyBytes(kSecRandomDefault, 8, &randomBytes)
        
        // If SecRandomCopyBytes fails, use alternative randomization
        if result != errSecSuccess {
            for i in 0..<8 {
                randomBytes[i] = UInt8.random(in: 0...255)
            }
        }
        
        // Add timestamp entropy to ensure uniqueness
        // Use lower 32 bits of timestamp in milliseconds to avoid overflow
        let timestampMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let timestamp = UInt32(timestampMs & 0xFFFFFFFF)
        randomBytes[4] = UInt8((timestamp >> 24) & 0xFF)
        randomBytes[5] = UInt8((timestamp >> 16) & 0xFF)
        randomBytes[6] = UInt8((timestamp >> 8) & 0xFF)
        randomBytes[7] = UInt8(timestamp & 0xFF)
        
        return randomBytes.map { String(format: "%02x", $0) }.joined()
    }
    
    func rotatePeerID() {
        guard !rotationLocked else {
            // Schedule rotation for later
            scheduleRotation(delay: 30.0)
            return
        }
        
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            // Save current peer ID as previous
            let oldID = self.myPeerID
            self.previousPeerID = oldID
            self.rotationTimestamp = Date()
            
            // Generate new peer ID
            self.myPeerID = self.generateNewPeerID()
            
            // Update advertising with new peer ID
            DispatchQueue.main.async { [weak self] in
                self?.updateAdvertisement()
            }
            
            // Send identity announcement with new peer ID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.sendNoiseIdentityAnnounce()
            }
            
            // Schedule next rotation
            self.scheduleNextRotation()
        }
    }
    
    private func scheduleRotation(delay: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            self?.rotationTimer?.invalidate()
            self?.rotationTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                self?.rotatePeerID()
            }
        }
    }
    
    private func scheduleNextRotation() {
        // Base interval: 1-6 hours
        let baseInterval = TimeInterval.random(in: 3600...21600)
        
        // Add jitter: ±30 minutes
        let jitter = TimeInterval.random(in: -1800...1800)
        
        // Additional random delay to prevent synchronization
        let networkDelay = TimeInterval.random(in: 0...300) // 0-5 minutes
        
        let nextRotation = baseInterval + jitter + networkDelay
        
        scheduleRotation(delay: nextRotation)
    }
    
    private func updateAdvertisement() {
        guard isAdvertising else { return }
        
        peripheralManager?.stopAdvertising()
        
        // Update advertisement data with new peer ID
        advertisementData = [
            CBAdvertisementDataServiceUUIDsKey: [BluetoothMeshService.serviceUUID],
            CBAdvertisementDataLocalNameKey: myPeerID
        ]
        
        peripheralManager?.startAdvertising(advertisementData)
    }
    
    func lockRotation() {
        rotationLocked = true
    }
    
    func unlockRotation() {
        rotationLocked = false
    }
    
    override init() {
        // Generate ephemeral peer ID for each session to prevent tracking
        self.myPeerID = ""
        super.init()
        self.myPeerID = generateNewPeerID()
        
        centralManager = CBCentralManager(delegate: self, queue: nil)
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        
        // Start bloom filter reset timer (reset every 5 minutes)
        bloomFilterResetTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.messageQueue.async(flags: .barrier) {
                guard let self = self else { return }
                
                // Adapt Bloom filter size based on network size
                let networkSize = self.estimatedNetworkSize
                self.messageBloomFilter = OptimizedBloomFilter.adaptive(for: networkSize)
                
                // Clear other duplicate detection sets
                self.processedMessages.removeAll()
                
            }
        }
        
        // Start stale peer cleanup timer (every 30 seconds)
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.cleanupStalePeers()
        }
        
        // Schedule first peer ID rotation
        scheduleNextRotation()
        
        // Setup noise callbacks
        noiseService.onPeerAuthenticated = { [weak self] peerID, fingerprint in
            // Get peer's public key data from noise service
            if let publicKeyData = self?.noiseService.getPeerPublicKeyData(peerID) {
                // Register with ChatViewModel for verification tracking
                DispatchQueue.main.async {
                    (self?.delegate as? ChatViewModel)?.registerPeerPublicKey(peerID: peerID, publicKeyData: publicKeyData)
                }
            }
            
            // Send regular announce packet when authenticated to trigger connect message
            // This covers the case where we're the responder in the handshake
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.sendAnnouncementToPeer(peerID)
            }
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
        rotationTimer?.invalidate()
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
        collectionsQueue.sync(flags: .barrier) {
            activePeers.removeAll()
        }
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
            
            // Also send Noise identity announcement
            self?.sendNoiseIdentityAnnounce()
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
                
                
                // Use unified message type with broadcast recipient
                let packet = BitchatPacket(
                    type: MessageType.message.rawValue,
                    senderID: Data(hexString: self.myPeerID) ?? Data(),
                    recipientID: SpecialRecipients.broadcast,  // Special broadcast ID
                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000), // milliseconds
                    payload: messageData,
                    signature: nil,
                    ttl: self.adaptiveTTL
                )
                
                // Track this message to prevent duplicate sends
                let msgID = "\(packet.timestamp)-\(self.myPeerID)-\(packet.payload.prefix(32).hashValue)"
                
                let shouldSend = !self.recentlySentMessages.contains(msgID)
                if shouldSend {
                    self.recentlySentMessages.insert(msgID)
                }
                
                if shouldSend {
                    // Clean up old entries after 10 seconds
                    self.messageQueue.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                        guard let self = self else { return }
                        self.recentlySentMessages.remove(msgID)
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
        guard !content.isEmpty, !recipientPeerID.isEmpty, !recipientNickname.isEmpty else { 
            return 
        }
        
        let msgID = messageID ?? UUID().uuidString
        
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Check if this is an old peer ID that has rotated
            var targetPeerID = recipientPeerID
            
            // If we have a fingerprint for this peer ID, check if there's a newer peer ID
            if let fingerprint = self.collectionsQueue.sync(execute: { self.peerIDToFingerprint[recipientPeerID] }),
               let currentPeerID = self.collectionsQueue.sync(execute: { self.fingerprintToPeerID[fingerprint] }),
               currentPeerID != recipientPeerID {
                // Use the current peer ID instead
                targetPeerID = currentPeerID
            }
            
            // Always use Noise encryption
            self.sendPrivateMessageViaNoise(content, to: targetPeerID, recipientNickname: recipientNickname, messageID: msgID)
        }
    }
    
    // Public method to get current peer ID for a fingerprint
    func getCurrentPeerIDForFingerprint(_ fingerprint: String) -> String? {
        return collectionsQueue.sync {
            return fingerprintToPeerID[fingerprint]
        }
    }
    
    // Public method to get all current peer IDs for known fingerprints
    func getCurrentPeerIDs() -> [String: String] {
        return collectionsQueue.sync {
            return fingerprintToPeerID
        }
    }
    
    // Notify delegate when peer ID changes
    private func notifyPeerIDChange(oldPeerID: String, newPeerID: String, fingerprint: String) {
        DispatchQueue.main.async { [weak self] in
            // Remove old peer ID from active peers and announcedPeers
            _ = self?.collectionsQueue.sync(flags: .barrier) {
                self?.activePeers.remove(oldPeerID)
                // Don't pre-insert the new peer ID - let the announce packet handle it
                // This ensures the connect message logic works properly
            }
            
            // Also remove from announcedPeers so the new ID can trigger a connect message
            self?.announcedPeers.remove(oldPeerID)
            
            // Update peer list
            self?.notifyPeerListUpdate(immediate: true)
            
            // Don't send disconnect/connect messages for peer ID rotation
            // The peer didn't actually disconnect, they just rotated their ID
            // This prevents confusing messages like "3a7e1c2c0d8943b9 disconnected"
            
            // Instead, notify the delegate about the peer ID change if needed
            // (Could add a new delegate method for this in the future)
        }
    }
    
    func sendChannelLeaveNotification(_ channel: String) {
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Create a leave packet with channel hashtag as payload
            let packet = BitchatPacket(
                type: MessageType.leave.rawValue,
                senderID: Data(hexString: self.myPeerID) ?? Data(),
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
            
            // Check if we have a Noise session with this peer
            // Use noiseService directly
            if self.noiseService.hasEstablishedSession(with: recipientID) {
                // Use Noise encryption - encrypt only the ACK payload directly
                do {
                    // Create a special payload that indicates this is a delivery ACK
                    // Format: [1 byte type marker] + [ACK JSON data]
                    var ackPayload = Data()
                    ackPayload.append(MessageType.deliveryAck.rawValue) // Type marker
                    ackPayload.append(ackData) // ACK JSON
                    
                    // Encrypt only the payload (not a full packet)
                    let encryptedPayload = try noiseService.encrypt(ackPayload, for: recipientID)
                    
                    // Create outer Noise packet with the encrypted payload
                    let outerPacket = BitchatPacket(
                        type: MessageType.noiseEncrypted.rawValue,
                        senderID: Data(hexString: self.myPeerID) ?? Data(),
                        recipientID: Data(hexString: recipientID) ?? Data(),
                        timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                        payload: encryptedPayload,
                        signature: nil,
                        ttl: 3
                    )
                    
                    self.broadcastPacket(outerPacket)
                } catch {
                    SecurityLogger.log("Failed to encrypt delivery ACK via Noise for \(recipientID): \(error)", 
                                     category: SecurityLogger.encryption, level: .error)
                }
            } else {
                // Fall back to legacy encryption
                let encryptedPayload: Data
                do {
                    encryptedPayload = try self.noiseService.encrypt(ackData, for: recipientID)
                } catch {
                    SecurityLogger.log("Failed to encrypt delivery ACK for \(recipientID): \(error)", 
                                     category: SecurityLogger.encryption, level: .error)
                    return
                }
                
                // Create ACK packet with direct routing to original sender
                let packet = BitchatPacket(
                    type: MessageType.deliveryAck.rawValue,
                    senderID: Data(hexString: self.myPeerID) ?? Data(),
                    recipientID: Data(hexString: recipientID) ?? Data(),
                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                    payload: encryptedPayload,
                    signature: nil,  // ACKs don't need signatures
                    ttl: 3  // Limited TTL for ACKs
                )
                
                // Send immediately without delay (ACKs should be fast)
                self.broadcastPacket(packet)
            }
        }
    }
    
    func sendReadReceipt(_ receipt: ReadReceipt, to recipientID: String) {
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Encode the receipt
            guard let receiptData = receipt.encode() else {
                return
            }
            
            // Check if we have a Noise session with this peer
            // Use noiseService directly
            if self.noiseService.hasEstablishedSession(with: recipientID) {
                // Use Noise encryption - send as Noise encrypted message
                do {
                    // Create inner read receipt packet
                    let innerPacket = BitchatPacket(
                        type: MessageType.readReceipt.rawValue,
                        senderID: Data(hexString: self.myPeerID) ?? Data(),
                        recipientID: Data(hexString: recipientID) ?? Data(),
                        timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                        payload: receiptData,
                        signature: nil,
                        ttl: 3
                    )
                    
                    // Encrypt the entire inner packet
                    if let innerData = innerPacket.toBinaryData() {
                        let encryptedInnerData = try noiseService.encrypt(innerData, for: recipientID)
                        
                        // Create outer Noise packet
                        let outerPacket = BitchatPacket(
                            type: MessageType.noiseEncrypted.rawValue,
                            senderID: Data(hexString: self.myPeerID) ?? Data(),
                            recipientID: Data(hexString: recipientID) ?? Data(),
                            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                            payload: encryptedInnerData,
                            signature: nil,
                            ttl: 3
                        )
                        
                        self.broadcastPacket(outerPacket)
                    }
                } catch {
                    SecurityLogger.log("Failed to encrypt read receipt via Noise for \(recipientID): \(error)", 
                                     category: SecurityLogger.encryption, level: .error)
                }
            } else {
                // Fall back to legacy encryption
                let encryptedPayload: Data
                do {
                    encryptedPayload = try self.noiseService.encrypt(receiptData, for: recipientID)
                } catch {
                    return
                }
                
                // Create read receipt packet with direct routing to original sender
                let packet = BitchatPacket(
                    type: MessageType.readReceipt.rawValue,
                    senderID: Data(hexString: self.myPeerID) ?? Data(),
                    recipientID: Data(hexString: recipientID) ?? Data(),
                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                    payload: encryptedPayload,
                    signature: nil,  // Read receipts don't need signatures
                    ttl: 3  // Limited TTL for receipts
                )
                
                // Send immediately without delay
                self.broadcastPacket(packet)
            }
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
                senderID: Data(hexString: self.myPeerID) ?? Data(),
                recipientID: SpecialRecipients.broadcast,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: Data(payload.utf8),
                signature: nil,
                ttl: 5  // Allow wider propagation for channel announcements
            )
            
            self.broadcastPacket(packet)
        }
    }
    
    func sendChannelMetadata(_ metadata: ChannelMetadata) {
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard let metadataData = metadata.encode() else { return }
            
            let packet = BitchatPacket(
                type: MessageType.channelMetadata.rawValue,
                senderID: Data(hexString: self.myPeerID) ?? Data(),
                recipientID: SpecialRecipients.broadcast,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: metadataData,
                signature: nil,
                ttl: 5  // Allow wider propagation for channel metadata
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
                senderID: Data(hexString: self.myPeerID) ?? Data(),
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
                    
                    let packet = BitchatPacket(
                        type: MessageType.message.rawValue,
                        senderID: Data(hexString: self.myPeerID) ?? Data(),
                        recipientID: SpecialRecipients.broadcast,
                        timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                        payload: messageData,
                        signature: nil,
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
        return collectionsQueue.sync {
            return peerNicknames
        }
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
        noiseService.clearPersistentIdentity()
        
    }
    
    private func getAllConnectedPeerIDs() -> [String] {
        // Return all valid active peers
        let peersCopy = collectionsQueue.sync {
            return activePeers
        }
        
        
        let validPeers = peersCopy.filter { peerID in
            // Ensure peerID is valid and not self
            let isEmpty = peerID.isEmpty
            let isUnknown = peerID == "unknown"
            let isSelf = peerID == self.myPeerID
            
            return !isEmpty && !isUnknown && !isSelf
        }
        
        let result = Array(validPeers).sorted()
        return result
    }
    
    // Debounced peer list update notification
    private func notifyPeerListUpdate(immediate: Bool = false) {
        if immediate {
            // For initial connections, update immediately
            let connectedPeerIDs = self.getAllConnectedPeerIDs()
            
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
                    
                    self.delegate?.didUpdatePeerList(connectedPeerIDs)
                }
            }
        }
    }
    
    // Clean up stale peers that haven't been seen in a while
    private func cleanupStalePeers() {
        let staleThreshold: TimeInterval = 180.0 // 3 minutes - increased for better stability
        let now = Date()
        
        let peersToRemove = collectionsQueue.sync(flags: .barrier) {
            let toRemove = activePeers.filter { peerID in
                if let lastSeen = peerLastSeenTimestamps.get(peerID) {
                    return now.timeIntervalSince(lastSeen) > staleThreshold
                }
                return false // Keep peers we haven't tracked yet
            }
            
            var actuallyRemoved: [String] = []
            
            for peerID in toRemove {
                // Check if this peer has an active peripheral connection
                if let peripheral = connectedPeripherals[peerID], peripheral.state == .connected {
                    // Skipping removal - still has active connection
                    // Update last seen time to prevent immediate re-removal
                    peerLastSeenTimestamps.set(peerID, value: Date())
                    continue
                }
                
                activePeers.remove(peerID)
                peerLastSeenTimestamps.remove(peerID)
                
                // Clean up all associated data
                connectedPeripherals.removeValue(forKey: peerID)
                peerRSSI.removeValue(forKey: peerID)
                announcedPeers.remove(peerID)
                announcedToPeers.remove(peerID)
                peerNicknames.removeValue(forKey: peerID)
                
                actuallyRemoved.append(peerID)
                // Removed stale peer
            }
            return actuallyRemoved
        }
        
        if !peersToRemove.isEmpty {
            notifyPeerListUpdate()
        }
    }
    
    // MARK: - Store-and-Forward Methods
    
    private func cacheMessage(_ packet: BitchatPacket, messageID: String) {
        messageQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            // Don't cache certain message types
            guard packet.type != MessageType.announce.rawValue,
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
               let recipientID = packet.recipientID {
                let recipientPeerID = recipientID.hexEncodedString()
                // Check if recipient is a favorite via their public key fingerprint
                if let fingerprint = self.noiseService.getPeerFingerprint(recipientPeerID) {
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
                if let recipientID = packet.recipientID {
                    let recipientPeerID = recipientID.hexEncodedString()
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
                if let recipientID = storedMessage.packet.recipientID {
                    let recipientPeerID = recipientID.hexEncodedString()
                    return recipientPeerID == peerID
                }
                return false  // Don't forward broadcast messages
            }
            messagesToSend.append(contentsOf: recipientMessages)
            
            
            // Sort messages by timestamp to ensure proper ordering
            messagesToSend.sort { $0.timestamp < $1.timestamp }
            
            if !messagesToSend.isEmpty {
            }
            
            // Mark messages as delivered immediately to prevent duplicates
            let messageIDsToRemove = messagesToSend.map { $0.messageID }
            for messageID in messageIDsToRemove {
                self.deliveredMessages.insert(messageID)
            }
            
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
        // CRITICAL CHECK: Never send unencrypted JSON
        if packet.type == MessageType.deliveryAck.rawValue {
            // Check if payload looks like JSON
            if let jsonCheck = String(data: packet.payload.prefix(1), encoding: .utf8), jsonCheck == "{" {
                // Block unencrypted JSON in delivery ACKs
                return
            }
        }
        
        
        guard let data = packet.toBinaryData() else { 
            // Failed to convert packet - add to retry queue if it's our message
            let senderID = packet.senderID.hexEncodedString()
            if senderID == self.myPeerID,
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
        
        // Check if fragmentation is needed for large packets
        if data.count > 512 && packet.type != MessageType.fragmentStart.rawValue && 
           packet.type != MessageType.fragmentContinue.rawValue && 
           packet.type != MessageType.fragmentEnd.rawValue {
            sendFragmentedPacket(packet)
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
            }
        }
        
        // Send to subscribed centrals (as peripheral)
        var sentToCentrals = 0
        if let char = characteristic, !subscribedCentrals.isEmpty {
            // Send to all subscribed centrals
            // Note: Large packets should already be fragmented by the check at the beginning of broadcastPacket
            let success = peripheralManager?.updateValue(data, for: char, onSubscribedCentrals: nil) ?? false
            if success {
                sentToCentrals = subscribedCentrals.count
            }
        }
        
        // If no peers received the message, add to retry queue ONLY if it's our own message
        if sentToPeripherals == 0 && sentToCentrals == 0 {
            // Check if this packet originated from us
            let senderID = packet.senderID.hexEncodedString()
            if senderID == self.myPeerID {
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
            
            
            // Log specific Noise packet types
            
            guard packet.ttl > 0 else { 
                return 
            }
            
            // Validate packet has payload
            guard !packet.payload.isEmpty else {
                return
            }
            
            // Update last seen timestamp for this peer
            let senderID = packet.senderID.hexEncodedString()
            if senderID != "unknown" && senderID != self.myPeerID {
                peerLastSeenTimestamps.set(senderID, value: Date())
            }
            
            // Replay attack protection: Check timestamp is within reasonable window (5 minutes)
            let currentTime = UInt64(Date().timeIntervalSince1970 * 1000) // milliseconds
            let timeDiff = abs(Int64(currentTime) - Int64(packet.timestamp))
            if timeDiff > 300000 { // 5 minutes in milliseconds
                return
            }
        
        // For fragments, include packet type in messageID to avoid dropping CONTINUE/END fragments
        let messageID: String
        if packet.type == MessageType.fragmentStart.rawValue || 
           packet.type == MessageType.fragmentContinue.rawValue || 
           packet.type == MessageType.fragmentEnd.rawValue {
            // Include both type and payload hash for fragments to ensure uniqueness
            messageID = "\(packet.timestamp)-\(packet.senderID.hexEncodedString())-\(packet.type)-\(packet.payload.hashValue)"
        } else {
            // Include payload hash for absolute uniqueness (handles same-second messages)
            messageID = "\(packet.timestamp)-\(packet.senderID.hexEncodedString())-\(packet.payload.prefix(64).hashValue)"
        }
        
        // Use bloom filter for efficient duplicate detection
        if messageBloomFilter.contains(messageID) {
            // Also check exact set for accuracy (bloom filter can have false positives)
            if processedMessages.contains(messageID) {
                return
            } else {
                // False positive from Bloom filter
            }
        }
        
        messageBloomFilter.insert(messageID)
        processedMessages.insert(messageID)
        
        // Log statistics periodically
        if messageBloomFilter.insertCount % 100 == 0 {
            _ = messageBloomFilter.estimatedFalsePositiveRate
        }
        
        // Bloom filter will be reset by timer, processedMessages is now bounded
        
        // let _ = packet.senderID.hexEncodedString()
        
        
        // Note: We'll decode messages in the switch statement below, not here
        
        switch MessageType(rawValue: packet.type) {
        case .message:
            // Unified message handler for both broadcast and private messages
            // Convert binary senderID back to hex string
            let senderID = packet.senderID.hexEncodedString()
            if senderID.isEmpty {
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
                    
                    // No signature verification - broadcasts are not authenticated
                    
                    // Parse broadcast message (not encrypted)
                    if let message = BitchatMessage.fromBinaryPayload(packet.payload) {
                            
                        // Store nickname mapping
                        collectionsQueue.sync(flags: .barrier) {
                            self.peerNicknames[senderID] = message.sender
                        }
                        
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
                        let peerID = packet.senderID.hexEncodedString()
                        self.lastMessageFromPeer.set(peerID, value: Date())
                        
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
                    
                } else if isPeerIDOurs(recipientID.hexEncodedString()) {
                    // PRIVATE MESSAGE FOR US
                    
                    
                    // No signature verification - broadcasts are not authenticated
                    
                    // Private messages should only come through Noise now
                    // If we're getting a private message here, it must already be decrypted from Noise
                    let decryptedPayload = packet.payload
                    
                    // Parse the message
                    if let message = BitchatMessage.fromBinaryPayload(decryptedPayload) {
                        
                        // Check if this is a dummy message for cover traffic
                        if message.content.hasPrefix(self.coverTrafficPrefix) {
                                return  // Silently discard dummy messages
                        }
                        
                        // Check if we've seen this exact message recently (within 5 seconds)
                        let messageKey = "\(senderID)-\(message.content)-\(message.timestamp)"
                        if let lastReceived = self.receivedMessageTimestamps.get(messageKey) {
                            let timeSinceLastReceived = Date().timeIntervalSince(lastReceived)
                            if timeSinceLastReceived < 5.0 {
                            }
                        }
                        self.receivedMessageTimestamps.set(messageKey, value: Date())
                        
                        // LRU cache handles cleanup automatically
                        
                        collectionsQueue.sync(flags: .barrier) {
                            if self.peerNicknames[senderID] == nil {
                                self.peerNicknames[senderID] = message.sender
                            }
                        }
                        
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
                        let peerID = packet.senderID.hexEncodedString()
                        self.lastMessageFromPeer.set(peerID, value: Date())
                        
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
                    } else {
                        SecurityLogger.log("Failed to parse private message from binary payload, payload size: \(decryptedPayload.count)", 
                                         category: SecurityLogger.encryption, level: .error)
                    }
                    
                } else if packet.ttl > 0 {
                    // RELAY PRIVATE MESSAGE (not for us)
                    var relayPacket = packet
                    relayPacket.ttl -= 1
                    
                    // Check if this message is for an offline favorite and cache it
                    let recipientIDString = recipientID.hexEncodedString()
                    if let fingerprint = self.noiseService.getPeerFingerprint(recipientIDString) {
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
                } else {
                    // Message has recipient ID but not for us and TTL is 0
                    // Message not for us - will be relayed if TTL > 0
                }
            } else {
                // No recipient ID - this shouldn't happen for messages
                SecurityLogger.log("Message packet with no recipient ID from \(senderID)", 
                                 category: SecurityLogger.encryption, level: .warning)
            }
            
        // Note: 0x02 was legacy keyExchange - removed
            
        case .announce:
            if let nickname = String(data: packet.payload, encoding: .utf8) {
                let senderID = packet.senderID.hexEncodedString()
                
                // Ignore if it's from ourselves (including previous peer IDs)
                if isPeerIDOurs(senderID) {
                    return
                }
                
                // Check if we've already announced this peer
                let isFirstAnnounce = !announcedPeers.contains(senderID)
                
                // Clean up stale peer IDs with the same nickname
                collectionsQueue.sync(flags: .barrier) {
                    var stalePeerIDs: [String] = []
                    for (existingPeerID, existingNickname) in self.peerNicknames {
                        if existingNickname == nickname && existingPeerID != senderID {
                            // Check if this peer was seen very recently (within 10 seconds)
                            let wasRecentlySeen = self.peerLastSeenTimestamps.get(existingPeerID).map { Date().timeIntervalSince($0) < 10.0 } ?? false
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
                        self.peerNicknames.removeValue(forKey: stalePeerID)
                        
                        // Also remove from active peers
                        self.activePeers.remove(stalePeerID)
                        
                        // Remove from announced peers
                        self.announcedPeers.remove(stalePeerID)
                        self.announcedToPeers.remove(stalePeerID)
                        
                        // Disconnect any peripherals associated with stale ID
                        if let peripheral = self.connectedPeripherals[stalePeerID] {
                            self.intentionalDisconnects.insert(peripheral.identifier.uuidString)
                            self.centralManager?.cancelPeripheralConnection(peripheral)
                            self.connectedPeripherals.removeValue(forKey: stalePeerID)
                            self.peripheralCharacteristics.removeValue(forKey: peripheral)
                        }
                        
                        // Remove RSSI data
                        self.peerRSSI.removeValue(forKey: stalePeerID)
                        
                        // Clear cached messages tracking
                        self.cachedMessagesSentToPeer.remove(stalePeerID)
                        
                        // Remove from last seen timestamps
                        self.peerLastSeenTimestamps.remove(stalePeerID)
                        
                        // No longer tracking key exchanges
                    }
                    
                    // If we had stale peers, notify the UI immediately
                    if !stalePeerIDs.isEmpty {
                        DispatchQueue.main.async { [weak self] in
                            self?.notifyPeerListUpdate(immediate: true)
                        }
                    }
                    
                    // Now add the new peer ID with the nickname
                    self.peerNicknames[senderID] = nickname
                }
                
                // Update peripheral mapping if we have it
                if let peripheral = peripheral {
                    // Find and remove any temp ID mapping for this peripheral
                    var tempIDToRemove: String? = nil
                    for (id, per) in self.connectedPeripherals {
                        if per == peripheral && id != senderID {
                            tempIDToRemove = id
                            break
                        }
                    }
                    
                    if let tempID = tempIDToRemove {
                        // Remove temp mapping
                        self.connectedPeripherals.removeValue(forKey: tempID)
                        // Add real peer ID mapping
                        self.connectedPeripherals[senderID] = peripheral
                        
                        // IMPORTANT: Remove old peer ID from activePeers to prevent duplicates
                        collectionsQueue.sync(flags: .barrier) {
                            if self.activePeers.contains(tempID) {
                                self.activePeers.remove(tempID)
                            }
                        }
                        
                        // Don't notify about disconnect - this is just cleanup of temporary ID
                    }
                }
                
                // Add to active peers if not already there
                if senderID != "unknown" && senderID != self.myPeerID {
                    // Check for duplicate nicknames and remove old peer IDs
                    collectionsQueue.sync(flags: .barrier) {
                        // Find any existing peers with the same nickname
                        var oldPeerIDsToRemove: [String] = []
                        for existingPeerID in self.activePeers {
                            if existingPeerID != senderID {
                                let existingNickname = self.peerNicknames[existingPeerID] ?? ""
                                if existingNickname == nickname && !existingNickname.isEmpty && existingNickname != "unknown" {
                                    oldPeerIDsToRemove.append(existingPeerID)
                                }
                            }
                        }
                        
                        // Remove old peer IDs with same nickname
                        for oldPeerID in oldPeerIDsToRemove {
                            self.activePeers.remove(oldPeerID)
                            self.peerNicknames.removeValue(forKey: oldPeerID)
                            self.connectedPeripherals.removeValue(forKey: oldPeerID)
                            
                            // Don't notify about disconnect - this is just cleanup of duplicate
                        }
                    }
                    
                    let wasInserted = collectionsQueue.sync(flags: .barrier) {
                        // Final safety check
                        if senderID == self.myPeerID {
                            SecurityLogger.log("Blocked self from being added to activePeers", category: SecurityLogger.noise, level: .error)
                            return false
                        }
                        let result = self.activePeers.insert(senderID).inserted
                        return result
                    }
                    if wasInserted {
                        // Added peer \(senderID) (\(nickname)) to active peers
                    }
                    
                    // Show join message only for first announce AND if we actually added the peer
                    if isFirstAnnounce && wasInserted {
                        announcedPeers.insert(senderID)
                        
                        // Delay the connect message slightly to allow identity announcement to be processed
                        // This helps ensure fingerprint mappings are available for nickname resolution
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            self.delegate?.didConnectToPeer(senderID)
                        }
                        self.notifyPeerListUpdate(immediate: true)
                        
                        DispatchQueue.main.async {
                            // Check if this is a favorite peer and send notification
                            // Note: This might not work immediately if key exchange hasn't happened yet
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                                guard let self = self else { return }
                                
                                // Check if this is a favorite using their public key fingerprint
                                if let fingerprint = self.noiseService.getPeerFingerprint(senderID) {
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
            let senderID = packet.senderID.hexEncodedString()
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
                    if String(data: packet.payload, encoding: .utf8) != nil {
                        // Remove from active peers with proper locking
                        collectionsQueue.sync(flags: .barrier) {
                            self.activePeers.remove(senderID)
                            self.peerNicknames.removeValue(forKey: senderID)
                        }
                        
                        announcedPeers.remove(senderID)
                        
                        // Show leave message
                        DispatchQueue.main.async {
                            self.delegate?.didDisconnectFromPeer(senderID)
                        }
                        self.notifyPeerListUpdate()
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
               isPeerIDOurs(recipientIDData.hexEncodedString()) {
                // This ACK is for us
                let senderID = packet.senderID.hexEncodedString()
                // Check if payload is already decrypted (came through Noise)
                    if let ack = DeliveryAck.decode(from: packet.payload) {
                        // Already decrypted - process directly
                        DeliveryTracker.shared.processDeliveryAck(ack)
                        
                        
                        // Notify delegate
                        DispatchQueue.main.async {
                            self.delegate?.didReceiveDeliveryAck(ack)
                        }
                    } else {
                        // Try legacy decryption
                        do {
                            let decryptedData = try noiseService.decrypt(packet.payload, from: senderID)
                            if let ack = DeliveryAck.decode(from: decryptedData) {
                                // Process the ACK
                                DeliveryTracker.shared.processDeliveryAck(ack)
                                
                                
                                // Notify delegate
                                DispatchQueue.main.async {
                                    self.delegate?.didReceiveDeliveryAck(ack)
                                }
                            }
                        } catch {
                            SecurityLogger.log("Failed to decrypt delivery ACK from \(senderID): \(error)", 
                                             category: SecurityLogger.encryption, level: .error)
                        }
                    }
            } else if packet.ttl > 0 {
                // Relay the ACK if not for us
                
                // SAFETY CHECK: Never relay unencrypted JSON
                if let jsonCheck = String(data: packet.payload.prefix(1), encoding: .utf8), jsonCheck == "{" {
                    return
                }
                
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
               isPeerIDOurs(recipientIDData.hexEncodedString()) {
                // This read receipt is for us
                let senderID = packet.senderID.hexEncodedString()
                // Check if payload is already decrypted (came through Noise)
                    if let receipt = ReadReceipt.decode(from: packet.payload) {
                        // Already decrypted - process directly
                        DispatchQueue.main.async {
                            self.delegate?.didReceiveReadReceipt(receipt)
                        }
                    } else {
                        // Try legacy decryption
                        do {
                            let decryptedData = try noiseService.decrypt(packet.payload, from: senderID)
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
            
        case .noiseIdentityAnnounce:
            // Handle Noise identity announcement
            let senderID = packet.senderID.hexEncodedString()
            if senderID != myPeerID && !isPeerIDOurs(senderID) {
                // Decode the announcement
                guard let announcement = NoiseIdentityAnnouncement.decode(from: packet.payload) else {
                    return
                }
                
                // Verify the signature (currently always returns true for compatibility)
                let bindingData = announcement.peerID.data(using: .utf8)! + announcement.publicKey + announcement.timestamp.timeIntervalSince1970.data
                if !noiseService.verifySignature(announcement.signature, for: bindingData, publicKey: announcement.publicKey) {
                    // Log but don't reject - signature verification is temporarily disabled
                    SecurityLogger.log("Signature verification skipped for \(senderID)", category: SecurityLogger.noise, level: .debug)
                }
                
                // Calculate fingerprint from public key
                let hash = SHA256.hash(data: announcement.publicKey)
                let fingerprint = hash.map { String(format: "%02x", $0) }.joined()
                
                // Create the binding
                let binding = PeerIdentityBinding(
                    currentPeerID: announcement.peerID,
                    fingerprint: fingerprint,
                    publicKey: announcement.publicKey,
                    nickname: announcement.nickname,
                    bindingTimestamp: announcement.timestamp,
                    signature: announcement.signature
                )
                
                // Update our mappings
                updatePeerBinding(announcement.peerID, fingerprint: fingerprint, binding: binding)
                
                // Register the peer's public key with ChatViewModel for verification tracking
                DispatchQueue.main.async { [weak self] in
                    (self?.delegate as? ChatViewModel)?.registerPeerPublicKey(peerID: announcement.peerID, publicKeyData: announcement.publicKey)
                }
                
                // If we don't have a session yet, check if we should initiate
                if !noiseService.hasEstablishedSession(with: announcement.peerID) {
                    // Lock rotation during handshake
                    lockRotation()
                    
                    // Use lexicographic comparison as tie-breaker to prevent simultaneous handshakes
                    // Only the peer with the "lower" ID initiates
                    if myPeerID < announcement.peerID {
                        initiateNoiseHandshake(with: announcement.peerID)
                    } else {
                        // Send our identity back so they know we're ready
                        sendNoiseIdentityAnnounce(to: announcement.peerID)
                    }
                } else {
                    // We already have a session, but ensure ChatViewModel knows about the fingerprint
                    // This handles the case where handshake completed before identity announcement
                    DispatchQueue.main.async { [weak self] in
                        if let publicKeyData = self?.noiseService.getPeerPublicKeyData(announcement.peerID) {
                            (self?.delegate as? ChatViewModel)?.registerPeerPublicKey(peerID: announcement.peerID, publicKeyData: publicKeyData)
                        }
                    }
                }
            }
            
        case .noiseHandshakeInit:
            // Handle incoming Noise handshake initiation
            let senderID = packet.senderID.hexEncodedString()
            // Check if this handshake is for us or broadcast
            if let recipientID = packet.recipientID,
               !isPeerIDOurs(recipientID.hexEncodedString()) {
                // Not for us, ignore
                return
            }
            if !isPeerIDOurs(senderID) {
                // Check if we've completed version negotiation with this peer
                if negotiatedVersions[senderID] == nil {
                    // Legacy peer - assume version 1 for backward compatibility
                    SecurityLogger.log("Received Noise handshake from \(senderID) without version negotiation, assuming v1", 
                                      category: SecurityLogger.session, level: .debug)
                    negotiatedVersions[senderID] = 1
                    versionNegotiationState[senderID] = .ackReceived(version: 1)
                }
                handleNoiseHandshakeMessage(from: senderID, message: packet.payload, isInitiation: true)
            }
            
        case .noiseHandshakeResp:
            // Handle Noise handshake response
            let senderID = packet.senderID.hexEncodedString()
            // Check if this handshake response is for us
            if let recipientID = packet.recipientID,
               !isPeerIDOurs(recipientID.hexEncodedString()) {
                // Not for us, ignore
                return
            }
            if !isPeerIDOurs(senderID) {
                handleNoiseHandshakeMessage(from: senderID, message: packet.payload, isInitiation: false)
            }
            
        case .noiseEncrypted:
            // Handle Noise encrypted message
            let senderID = packet.senderID.hexEncodedString()
            if !isPeerIDOurs(senderID) {
                _ = packet.recipientID?.hexEncodedString()
                handleNoiseEncryptedMessage(from: senderID, encryptedData: packet.payload, originalPacket: packet)
            }
            
        case .channelKeyVerifyRequest:
            // Handle channel key verification request
            let senderID = packet.senderID.hexEncodedString()
            if !isPeerIDOurs(senderID) {
                handleChannelKeyVerifyRequest(from: senderID, data: packet.payload)
            }
            
        case .channelKeyVerifyResponse:
            // Handle channel key verification response
            let senderID = packet.senderID.hexEncodedString()
            if !isPeerIDOurs(senderID) {
                handleChannelKeyVerifyResponse(from: senderID, data: packet.payload)
            }
            
        case .channelPasswordUpdate:
            // Handle channel password update from owner
            let senderID = packet.senderID.hexEncodedString()
            if !isPeerIDOurs(senderID) {
                handleChannelPasswordUpdate(from: senderID, data: packet.payload)
            }
            
        case .channelMetadata:
            // Handle channel metadata announcement
            let senderID = packet.senderID.hexEncodedString()
            if !isPeerIDOurs(senderID) {
                handleChannelMetadata(from: senderID, data: packet.payload)
            }
            
        case .versionHello:
            // Handle version negotiation hello
            let senderID = packet.senderID.hexEncodedString()
            if !isPeerIDOurs(senderID) {
                handleVersionHello(from: senderID, data: packet.payload, peripheral: peripheral)
            }
            
        case .versionAck:
            // Handle version negotiation acknowledgment
            let senderID = packet.senderID.hexEncodedString()
            if !isPeerIDOurs(senderID) {
                handleVersionAck(from: senderID, data: packet.payload)
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
                senderID: packet.senderID,  // Use original packet's senderID (already Data)
                recipientID: packet.recipientID,  // Preserve recipient if any
                timestamp: packet.timestamp,  // Use original timestamp
                payload: fragmentPayload,
                signature: nil,  // Fragments don't need signatures
                ttl: packet.ttl
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
            // Check if we've reached the concurrent session limit
            if incomingFragments.count >= maxConcurrentFragmentSessions {
                // Clean up oldest fragments first
                cleanupOldFragments()
                
                // If still at limit, reject new session to prevent DoS
                if incomingFragments.count >= maxConcurrentFragmentSessions {
                    return
                }
            }
            
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
        
        // Periodic cleanup of old fragments
        cleanupOldFragments()
    }
    
    private func cleanupOldFragments() {
        let cutoffTime = Date().addingTimeInterval(-fragmentTimeout)
        var fragmentsToRemove: [String] = []
        
        for (fragID, metadata) in fragmentMetadata {
            if metadata.timestamp < cutoffTime {
                fragmentsToRemove.append(fragID)
            }
        }
        
        // Remove expired fragments
        for fragID in fragmentsToRemove {
            incomingFragments.removeValue(forKey: fragID)
            fragmentMetadata.removeValue(forKey: fragID)
        }
        
        // Also enforce memory bounds - if we have too many fragment bytes, remove oldest
        var totalFragmentBytes = 0
        let maxFragmentBytes = 10 * 1024 * 1024  // 10MB max for all fragments
        
        for (_, fragments) in incomingFragments {
            for (_, data) in fragments {
                totalFragmentBytes += data.count
            }
        }
        
        if totalFragmentBytes > maxFragmentBytes {
            // Remove oldest fragments until under limit
            let sortedFragments = fragmentMetadata.sorted { $0.value.timestamp < $1.value.timestamp }
            for (fragID, _) in sortedFragments {
                incomingFragments.removeValue(forKey: fragID)
                fragmentMetadata.removeValue(forKey: fragID)
                
                // Recalculate total
                totalFragmentBytes = 0
                for (_, fragments) in incomingFragments {
                    for (_, data) in fragments {
                        totalFragmentBytes += data.count
                    }
                }
                
                if totalFragmentBytes <= maxFragmentBytes {
                    break
                }
            }
        }
    }
}

extension BluetoothMeshService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Central manager state updated
        switch central.state {
        case .unknown: break
        case .resetting: break
        case .unsupported: break
        case .unauthorized: break
        case .poweredOff: break
        case .poweredOn: break
        @unknown default: break
        }
        
        if central.state == .unsupported {
        } else if central.state == .unauthorized {
        } else if central.state == .poweredOff {
        } else if central.state == .poweredOn {
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
        guard rssiValue > -90 else { 
            // Ignoring peripheral due to very weak signal
            return 
        }
        
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
        // Peer IDs are 8 bytes = 16 hex characters
        if let name = peripheral.name, name.count == 16 {
            // Assume 16-character hex names are peer IDs
            let peerID = name
            
            // Don't process our own advertisements (including previous peer IDs)
            if isPeerIDOurs(peerID) {
                return
            }
            
            peerRSSI[peerID] = RSSI
            // Discovered potential peer
            SecurityLogger.log("Discovered peer with ID: \(peerID), self ID: \(myPeerID)", category: SecurityLogger.noise, level: .debug)
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
            
            // Only remove from active peers if it's not a temp ID
            // Temp IDs shouldn't be in activePeers anyway
            let (removed, _) = collectionsQueue.sync(flags: .barrier) {
                var removed = false
                if peerID.count == 16 {  // Real peer ID (8 bytes = 16 hex chars)
                    removed = activePeers.remove(peerID) != nil
                    if removed {
                        }
                    
                    announcedPeers.remove(peerID)
                    announcedToPeers.remove(peerID)
                } else {
                }
                
                // Clear cached messages tracking for this peer to allow re-sending if they reconnect
                cachedMessagesSentToPeer.remove(peerID)
                
                // Clear version negotiation state
                versionNegotiationState.removeValue(forKey: peerID)
                negotiatedVersions.removeValue(forKey: peerID)
                
                // Peer disconnected
                
                return (removed, peerNicknames[peerID])
            }
            
            if removed {
                DispatchQueue.main.async {
                    self.delegate?.didDisconnectFromPeer(peerID)
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
        if let error = error {
            SecurityLogger.log("Error discovering services: \(error)", 
                             category: SecurityLogger.encryption, level: .error)
            return
        }
        
        guard let services = peripheral.services else { return }
        
        
        for service in services {
            peripheral.discoverCharacteristics([BluetoothMeshService.characteristicUUID], for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            SecurityLogger.log("Error discovering characteristics: \(error)", 
                             category: SecurityLogger.encryption, level: .error)
            return
        }
        
        guard let characteristics = service.characteristics else { return }
        
        
        for characteristic in characteristics {
            if characteristic.uuid == BluetoothMeshService.characteristicUUID {
                peripheral.setNotifyValue(true, for: characteristic)
                peripheralCharacteristics[peripheral] = characteristic
                
                // Request maximum MTU for faster data transfer
                // iOS supports up to 512 bytes with BLE 5.0
                peripheral.maximumWriteValueLength(for: .withoutResponse)
                
                // Start version negotiation instead of immediately sending Noise identity
                self.sendVersionHello(to: peripheral)
                
                // Send announce packet after version negotiation completes
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
            return 
        }
        
        
        // Use the sender ID from the packet, not our local mapping which might still be a temp ID
        let _ = connectedPeripherals.first(where: { $0.value == peripheral })?.key ?? "unknown"
        let packetSenderID = packet.senderID.hexEncodedString()
        
        
        // Always handle received packets
        handleReceivedPacket(packet, from: packetSenderID, peripheral: peripheral)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            // Log error but don't spam for common errors
            let errorCode = (error as NSError).code
            if errorCode != 242 { // Don't log the common "Unknown ATT error"
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
                
                if peerID.count != 16 {
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
        case .unknown: break
        case .resetting: break
        case .unsupported: break
        case .unauthorized: break
        case .poweredOff: break
        case .poweredOn: break
        @unknown default: break
        }
        
        switch peripheral.state {
        case .unsupported:
            break
        case .unauthorized:
            break
        case .poweredOff:
            break
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
        // Service added
    }
    
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        // Advertising state changed
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if let data = request.value {
                        
                if let packet = BitchatPacket.from(data) {
                    
                    // Log specific Noise packet types
                    switch packet.type {
                    case MessageType.noiseHandshakeInit.rawValue:
                        break
                    case MessageType.noiseHandshakeResp.rawValue:
                        break
                    case MessageType.noiseEncrypted.rawValue:
                        break
                    default:
                        break
                    }
                    
                    // Try to identify peer from packet
                    let peerID = packet.senderID.hexEncodedString()
                    
                    // Store the central for updates
                if !subscribedCentrals.contains(request.central) {
                    subscribedCentrals.append(request.central)
                }
                
                // Track this peer as connected
                if peerID != "unknown" && peerID != myPeerID {
                    // Double-check we're not adding ourselves
                    if peerID == self.myPeerID {
                        SecurityLogger.log("Preventing self from being added as peer (peripheral manager)", category: SecurityLogger.noise, level: .warning)
                        peripheral.respond(to: request, withResult: .success)
                        return
                    }
                    
                    // Note: Legacy keyExchange (0x02) no longer handled
                    
                    self.notifyPeerListUpdate()
                }
                
                    handleReceivedPacket(packet, from: peerID)
                    peripheral.respond(to: request, withResult: .success)
                } else {
                    peripheral.respond(to: request, withResult: .invalidPdu)
                }
            } else {
                peripheral.respond(to: request, withResult: .invalidPdu)
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if !subscribedCentrals.contains(central) {
            subscribedCentrals.append(central)
            
            // Send Noise identity announcement to newly connected central
            sendNoiseIdentityAnnounce()
            
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
                let peer1Activity = lastMessageFromPeer.get(peer1.identifier.uuidString) ?? Date.distantPast
                let peer2Activity = lastMessageFromPeer.get(peer2.identifier.uuidString) ?? Date.distantPast
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
        let recipientNickname = collectionsQueue.sync {
            return peerNicknames[randomPeer] ?? "unknown"
        }
        
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
        peerLastSeenTimestamps.set(peerID, value: Date())
    }
    
    private func sendPendingPrivateMessages(to peerID: String) {
        messageQueue.async(flags: .barrier) { [weak self] in
            guard let self = self,
                  let pendingMessages = self.pendingPrivateMessages[peerID] else { return }
            
            // Clear pending messages for this peer
            self.pendingPrivateMessages.removeValue(forKey: peerID)
            
            // Send each pending message
            for (content, recipientNickname, messageID) in pendingMessages {
                // Use async to avoid blocking the queue
                DispatchQueue.global().async { [weak self] in
                    self?.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
                }
            }
        }
    }
    
    // MARK: - Noise Protocol Support
    
    private func initiateNoiseHandshake(with peerID: String) {
        // Use noiseService directly
        
        SecurityLogger.log("Initiating Noise handshake with \(peerID)", category: SecurityLogger.noise, level: .info)
        
        // Check if we've recently tried to handshake with this peer
        if let lastAttempt = handshakeAttemptTimes[peerID],
           Date().timeIntervalSince(lastAttempt) < handshakeTimeout {
            SecurityLogger.log("Skipping handshake with \(peerID) - too recent", category: SecurityLogger.noise, level: .debug)
            return
        }
        
        handshakeAttemptTimes[peerID] = Date()
        
        
        do {
            // Generate handshake initiation message
            let handshakeData = try noiseService.initiateHandshake(with: peerID)
            
            // Send handshake initiation
            let packet = BitchatPacket(
                type: MessageType.noiseHandshakeInit.rawValue,
                senderID: Data(hexString: myPeerID) ?? Data(),
                recipientID: Data(hexString: peerID) ?? Data(), // Add recipient ID for targeted delivery
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: handshakeData,
                signature: nil,
                ttl: 3 // Moderate TTL for handshakes
            )
            
            // Use broadcastPacket instead of sendPacket to ensure it goes through the mesh
            broadcastPacket(packet)
            
        } catch NoiseSessionError.alreadyEstablished {
            // Session already established, no need to handshake
        } catch {
            // Failed to initiate handshake silently
        }
    }
    
    private func handleNoiseHandshakeMessage(from peerID: String, message: Data, isInitiation: Bool) {
        // Use noiseService directly
        
        do {
            // Process handshake message
            if let response = try noiseService.processHandshakeMessage(from: peerID, message: message) {
                // Always send responses as handshake response type
                let packet = BitchatPacket(
                    type: MessageType.noiseHandshakeResp.rawValue,
                    senderID: Data(hexString: myPeerID) ?? Data(),
                    recipientID: Data(hexString: peerID) ?? Data(), // Add recipient ID for targeted delivery
                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                    payload: response,
                    signature: nil,
                    ttl: 3
                )
                
                // Use broadcastPacket instead of sendPacket to ensure it goes through the mesh
                broadcastPacket(packet)
            }
            
            // Check if handshake is complete
            if noiseService.hasEstablishedSession(with: peerID) {
                // Unlock rotation now that handshake is complete
                unlockRotation()
                
                // Session established successfully
                
                // Clear handshake attempt time on success
                handshakeAttemptTimes.removeValue(forKey: peerID)
                
                // Send identity announcement to this specific peer
                sendNoiseIdentityAnnounce(to: peerID)
                
                // Also broadcast to ensure all peers get it
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.sendNoiseIdentityAnnounce()
                }
                
                // Send regular announce packet after handshake to trigger connect message
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.sendAnnouncementToPeer(peerID)
                }
                
                // Send any pending private messages
                self.sendPendingPrivateMessages(to: peerID)
                
                // Send any cached store-and-forward messages
                sendCachedMessages(to: peerID)
            }
        } catch NoiseSessionError.alreadyEstablished {
            // Session already established, ignore handshake
        } catch {
            // Handshake failed
        }
    }
    
    private func handleNoiseEncryptedMessage(from peerID: String, encryptedData: Data, originalPacket: BitchatPacket) {
        // Use noiseService directly
        
        // For Noise encrypted messages, we need to decrypt first to check the inner packet
        // The outer packet's recipientID might be for routing, not the final recipient
        
        // Create unique identifier for this encrypted message
        let messageHash = encryptedData.prefix(32).hexEncodedString() // Use first 32 bytes as identifier
        let messageKey = "\(peerID)-\(messageHash)"
        
        // Check if we've already processed this exact encrypted message
        let alreadyProcessed = collectionsQueue.sync(flags: .barrier) {
            if processedNoiseMessages.contains(messageKey) {
                return true
            }
            processedNoiseMessages.insert(messageKey)
            return false
        }
        
        if alreadyProcessed {
            return
        }
        
        do {
            // Decrypt the message
            let decryptedData = try noiseService.decrypt(encryptedData, from: peerID)
            
            // Check if this is a special format message (type marker + payload)
            if decryptedData.count > 1 {
                let typeMarker = decryptedData[0]
                
                // Check if this is a delivery ACK with the new format
                if typeMarker == MessageType.deliveryAck.rawValue {
                    // Extract the ACK JSON data (skip the type marker)
                    let ackData = decryptedData.dropFirst()
                    
                    // Decode the delivery ACK
                    if let ack = DeliveryAck.decode(from: ackData) {
                        
                        // Process the ACK
                        DeliveryTracker.shared.processDeliveryAck(ack)
                        
                        // Notify delegate
                        DispatchQueue.main.async {
                            self.delegate?.didReceiveDeliveryAck(ack)
                        }
                        return
                    }
                }
            }
            
            // Try to parse as a full inner packet (for backward compatibility and other message types)
            if let innerPacket = BitchatPacket.from(decryptedData) {
                
                // Process the decrypted inner packet
                // The packet will be handled according to its recipient ID
                // If it's for us, it won't be relayed
                handleReceivedPacket(innerPacket, from: peerID)
            }
        } catch {
            // Failed to decrypt - might need to re-establish session
            if !noiseService.hasEstablishedSession(with: peerID) {
                initiateNoiseHandshake(with: peerID)
            }
        }
    }
    
    private func handleChannelKeyVerifyRequest(from peerID: String, data: Data) {
        guard let request = ChannelKeyVerifyRequest.decode(from: data) else { return }
        
        // Forward to delegate (ChatViewModel) to handle
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didReceiveChannelKeyVerifyRequest(request, from: peerID)
        }
    }
    
    private func handleChannelKeyVerifyResponse(from peerID: String, data: Data) {
        guard let response = ChannelKeyVerifyResponse.decode(from: data) else { return }
        
        // Forward to delegate (ChatViewModel) to handle
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didReceiveChannelKeyVerifyResponse(response, from: peerID)
        }
    }
    
    private func handleChannelPasswordUpdate(from peerID: String, data: Data) {
        // First decrypt the data using Noise session
        // Use noiseService directly
        
        do {
            // Decrypt the outer message
            let decryptedData = try noiseService.decrypt(data, from: peerID)
            
            // Parse the password update
            guard let update = ChannelPasswordUpdate.decode(from: decryptedData) else { return }
            
            // Forward to delegate (ChatViewModel) to handle
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didReceiveChannelPasswordUpdate(update, from: peerID)
            }
        } catch {
        }
    }
    
    private func handleChannelMetadata(from peerID: String, data: Data) {
        // Channel metadata is broadcast unencrypted (like channel announcements)
        guard let metadata = ChannelMetadata.decode(from: data) else { return }
        
        // Forward to delegate (ChatViewModel) to handle
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didReceiveChannelMetadata(metadata, from: peerID)
        }
    }
    
    // MARK: - Protocol Version Negotiation
    
    private func handleVersionHello(from peerID: String, data: Data, peripheral: CBPeripheral? = nil) {
        guard let hello = VersionHello.decode(from: data) else {
            SecurityLogger.log("Failed to decode version hello from \(peerID)", category: SecurityLogger.session, level: .error)
            return
        }
        
        SecurityLogger.log("Received version hello from \(peerID): supported versions \(hello.supportedVersions), preferred \(hello.preferredVersion)", 
                          category: SecurityLogger.session, level: .debug)
        
        // Find the best common version
        let ourVersions = Array(ProtocolVersion.supportedVersions)
        if let agreedVersion = ProtocolVersion.negotiateVersion(clientVersions: hello.supportedVersions, serverVersions: ourVersions) {
            // We can communicate! Send ACK
            negotiatedVersions[peerID] = agreedVersion
            versionNegotiationState[peerID] = .ackReceived(version: agreedVersion)
            
            let ack = VersionAck(
                agreedVersion: agreedVersion,
                serverVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                platform: getPlatformString()
            )
            
            sendVersionAck(ack, to: peerID)
            
            // Proceed with Noise handshake after successful version negotiation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.sendNoiseIdentityAnnounce()
                self?.initiateNoiseHandshake(with: peerID)
            }
        } else {
            // No compatible version
            versionNegotiationState[peerID] = .failed(reason: "No compatible protocol version")
            
            let ack = VersionAck(
                agreedVersion: 0,
                serverVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                platform: getPlatformString(),
                rejected: true,
                reason: "No compatible protocol version. Client supports: \(hello.supportedVersions), server supports: \(ourVersions)"
            )
            
            sendVersionAck(ack, to: peerID)
            
            // Disconnect after a short delay
            if let peripheral = peripheral {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.centralManager?.cancelPeripheralConnection(peripheral)
                }
            }
        }
    }
    
    private func handleVersionAck(from peerID: String, data: Data) {
        guard let ack = VersionAck.decode(from: data) else {
            SecurityLogger.log("Failed to decode version ack from \(peerID)", category: SecurityLogger.session, level: .error)
            return
        }
        
        if ack.rejected {
            SecurityLogger.log("Version negotiation rejected by \(peerID): \(ack.reason ?? "Unknown reason")", 
                              category: SecurityLogger.session, level: .error)
            versionNegotiationState[peerID] = .failed(reason: ack.reason ?? "Version rejected")
            // TODO: Handle disconnection
        } else {
            SecurityLogger.log("Version negotiation successful with \(peerID): agreed on version \(ack.agreedVersion)", 
                              category: SecurityLogger.session, level: .debug)
            negotiatedVersions[peerID] = ack.agreedVersion
            versionNegotiationState[peerID] = .ackReceived(version: ack.agreedVersion)
            
            // If we were the initiator (sent hello first), proceed with Noise handshake
            // Note: Since we're handling their ACK, they initiated, so we should not initiate again
            // The peer who sent hello will initiate the Noise handshake
        }
    }
    
    private func sendVersionHello(to peripheral: CBPeripheral? = nil) {
        let hello = VersionHello(
            clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            platform: getPlatformString()
        )
        
        guard let helloData = hello.encode() else { return }
        
        let packet = BitchatPacket(
            type: MessageType.versionHello.rawValue,
            ttl: 1,  // Version negotiation is direct, no relay
            senderID: myPeerID,
            payload: helloData
        )
        
        // Mark that we initiated version negotiation
        // We don't know the peer ID yet from peripheral, so we'll track it when we get the response
        
        if let peripheral = peripheral,
           let characteristic = peripheralCharacteristics[peripheral] {
            // Send directly to specific peripheral
            if let data = packet.toBinaryData() {
                let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
                peripheral.writeValue(data, for: characteristic, type: writeType)
            }
        } else {
            // Broadcast to all
            broadcastPacket(packet)
        }
    }
    
    private func sendVersionAck(_ ack: VersionAck, to peerID: String) {
        guard let ackData = ack.encode() else { return }
        
        let packet = BitchatPacket(
            type: MessageType.versionAck.rawValue,
            senderID: Data(myPeerID.utf8),
            recipientID: Data(peerID.utf8),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: ackData,
            signature: nil,
            ttl: 1  // Direct response, no relay
        )
        
        broadcastPacket(packet)
    }
    
    private func getPlatformString() -> String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #else
        return "Unknown"
        #endif
    }
    
    func sendChannelKeyVerifyRequest(_ request: ChannelKeyVerifyRequest, to peers: [String]) {
        guard let requestData = request.encode() else { return }
        
        // Send to each peer
        for peerID in peers {
            let packet = BitchatPacket(
                type: MessageType.channelKeyVerifyRequest.rawValue,
                senderID: Data(myPeerID.utf8),
                recipientID: Data(peerID.utf8),
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: requestData,
                signature: nil,
                ttl: 3  // Limited TTL for verification requests
            )
            
            broadcastPacket(packet)
        }
    }
    
    func sendChannelKeyVerifyResponse(_ response: ChannelKeyVerifyResponse, to peerID: String) {
        guard let responseData = response.encode() else { return }
        
        let packet = BitchatPacket(
            type: MessageType.channelKeyVerifyResponse.rawValue,
            senderID: Data(myPeerID.utf8),
            recipientID: Data(peerID.utf8),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: responseData,
            signature: nil,
            ttl: 3  // Limited TTL for responses
        )
        
        broadcastPacket(packet)
    }
    
    func sendChannelPasswordUpdate(_ password: String, channel: String, newCommitment: String, to peerID: String) {
        // Use noiseService directly
        
        // Check if we have a Noise session with this peer
        if !noiseService.hasEstablishedSession(with: peerID) {
            return
        }
        
        // Get our fingerprint
        let myFingerprint = noiseService.getIdentityFingerprint()
        
        // Create password update with encrypted password field
        let update = ChannelPasswordUpdate(
            channel: channel,
            ownerID: myPeerID,  // Keep for backward compatibility
            ownerFingerprint: myFingerprint,
            encryptedPassword: Data(password.utf8),  // Will be encrypted as whole message
            newKeyCommitment: newCommitment
        )
        
        guard let updateData = update.encode() else { return }
        
        do {
            // Encrypt the entire update message
            let encryptedData = try noiseService.encrypt(updateData, for: peerID)
            
            let packet = BitchatPacket(
                type: MessageType.channelPasswordUpdate.rawValue,
                senderID: Data(myPeerID.utf8),
                recipientID: Data(peerID.utf8),
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: encryptedData,
                signature: nil,
                ttl: 3  // Limited TTL for password updates
            )
            
            broadcastPacket(packet)
        } catch {
        }
    }
    
    private func sendNoiseIdentityAnnounce(to specificPeerID: String? = nil) {
        // Rate limit identity announcements
        let now = Date()
        
        // If targeting a specific peer, check rate limit
        if let peerID = specificPeerID {
            if let lastTime = lastIdentityAnnounceTimes[peerID],
               now.timeIntervalSince(lastTime) < identityAnnounceMinInterval {
                // Too soon, skip this announcement
                return
            }
            lastIdentityAnnounceTimes[peerID] = now
        } else {
            // Broadcasting to all - check global rate limit
            if let lastTime = lastIdentityAnnounceTimes["*broadcast*"],
               now.timeIntervalSince(lastTime) < identityAnnounceMinInterval {
                return
            }
            lastIdentityAnnounceTimes["*broadcast*"] = now
        }
        
        // Get our Noise static public key
        let staticKey = noiseService.getStaticPublicKeyData()
        
        // Get nickname from delegate
        let nickname = (delegate as? ChatViewModel)?.nickname ?? "Anonymous"
        
        // Create the binding data to sign
        let bindingData = myPeerID.data(using: .utf8)! + staticKey + now.timeIntervalSince1970.data
        
        // Sign the binding with our private key
        let signature = noiseService.signData(bindingData) ?? Data()
        
        // Create the identity announcement
        let announcement = NoiseIdentityAnnouncement(
            peerID: myPeerID,
            publicKey: staticKey,
            nickname: nickname,
            previousPeerID: previousPeerID,
            signature: signature
        )
        
        // Encode the announcement
        guard let announcementData = announcement.encode() else {
            return
        }
        
        let packet = BitchatPacket(
            type: MessageType.noiseIdentityAnnounce.rawValue,
            senderID: Data(hexString: myPeerID) ?? Data(),
            recipientID: specificPeerID.flatMap { Data(hexString: $0) },  // Targeted or broadcast
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: announcementData,
            signature: nil,
            ttl: adaptiveTTL
        )
        
        broadcastPacket(packet)
    }
    
    // Removed sendPacket method - all packets should use broadcastPacket to ensure mesh delivery
    
    // Send private message using Noise Protocol
    private func sendPrivateMessageViaNoise(_ content: String, to recipientPeerID: String, recipientNickname: String, messageID: String? = nil) {
        // Use noiseService directly
        
        // Check if we have a Noise session with this peer
        if !noiseService.hasEstablishedSession(with: recipientPeerID) {
            SecurityLogger.log("No Noise session with \(recipientPeerID), initiating handshake", category: SecurityLogger.noise, level: .info)
            
            // Apply tie-breaker logic for handshake initiation
            if myPeerID < recipientPeerID {
                // We have lower ID, initiate handshake
                initiateNoiseHandshake(with: recipientPeerID)
            } else {
                // We have higher ID, send targeted identity announce to prompt them to initiate
                sendNoiseIdentityAnnounce(to: recipientPeerID)
            }
            
            // Queue message for sending after handshake completes
            messageQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else { return }
                if self.pendingPrivateMessages[recipientPeerID] == nil {
                    self.pendingPrivateMessages[recipientPeerID] = []
                }
                self.pendingPrivateMessages[recipientPeerID]?.append((content, recipientNickname, messageID ?? UUID().uuidString))
                SecurityLogger.log("Queued private message for \(recipientPeerID), \(self.pendingPrivateMessages[recipientPeerID]?.count ?? 0) messages pending", category: SecurityLogger.noise, level: .info)
            }
            return
        }
        
        // Use provided message ID or generate a new one
        let msgID = messageID ?? UUID().uuidString
        
        // Check if we're already processing this message
        let sendKey = "\(msgID)-\(recipientPeerID)"
        let alreadySending = collectionsQueue.sync(flags: .barrier) {
            if recentlySentMessages.contains(sendKey) {
                return true
            }
            recentlySentMessages.insert(sendKey)
            // Clean up old entries after 10 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                self?.collectionsQueue.sync(flags: .barrier) {
                    self?.recentlySentMessages.remove(sendKey)
                }
            }
            return false
        }
        
        if alreadySending {
            return
        }
        
        
        // Get sender nickname from delegate
        let nickname = self.delegate as? ChatViewModel
        let senderNick = nickname?.nickname ?? self.myPeerID
        
        // Create the inner message
        let message = BitchatMessage(
            id: msgID,
            sender: senderNick,
            content: content,
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: recipientNickname,
            senderPeerID: myPeerID
        )
        
        // Use binary payload format to match the receiver's expectations
        guard let messageData = message.toBinaryPayload() else { 
            return 
        }
        
        // Create inner packet
        let innerPacket = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data(hexString: myPeerID) ?? Data(),
            recipientID: Data(hexString: recipientPeerID) ?? Data(),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: messageData,
            signature: nil,
            ttl: self.adaptiveTTL // Inner packet needs valid TTL for processing after decryption
        )
        
        guard let innerData = innerPacket.toBinaryData() else { return }
        
        do {
            // Encrypt with Noise
            let encryptedData = try noiseService.encrypt(innerData, for: recipientPeerID)
            
            // Send as Noise encrypted message
            let outerPacket = BitchatPacket(
                type: MessageType.noiseEncrypted.rawValue,
                senderID: Data(hexString: myPeerID) ?? Data(),
                recipientID: Data(hexString: recipientPeerID) ?? Data(),
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: encryptedData,
                signature: nil,
                ttl: adaptiveTTL
            )
            
            broadcastPacket(outerPacket)
        } catch {
            // Failed to encrypt message
        }
    }
}
