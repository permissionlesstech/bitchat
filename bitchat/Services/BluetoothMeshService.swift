//
// BluetoothMeshService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

///
/// # BluetoothMeshService
///
/// The core networking component that manages peer-to-peer Bluetooth LE connections
/// and implements the BitChat mesh networking protocol.
///
/// ## Overview
/// This service is the heart of BitChat's decentralized architecture. It manages all
/// Bluetooth LE communications, enabling devices to form an ad-hoc mesh network without
/// any infrastructure. The service handles:
/// - Peer discovery and connection management
/// - Message routing and relay functionality
/// - Protocol version negotiation
/// - Connection state tracking and recovery
/// - Integration with the Noise encryption layer
///
/// ## Architecture
/// The service operates in a dual mode:
/// - **Central Mode**: Scans for and connects to other BitChat devices
/// - **Peripheral Mode**: Advertises its presence and accepts connections
///
/// This dual-mode operation enables true peer-to-peer connectivity where any device
/// can initiate or accept connections, forming a resilient mesh topology.
///
/// ## Mesh Networking
/// Messages are relayed through the mesh using a TTL (Time To Live) mechanism:
/// - Each message has a TTL that decrements at each hop
/// - Messages are cached to prevent loops (via Bloom filters)
/// - Store-and-forward ensures delivery to temporarily offline peers
///
/// ## Connection Lifecycle
/// 1. **Discovery**: Devices scan and advertise simultaneously
/// 2. **Connection**: BLE connection established
/// 3. **Version Negotiation**: Ensure protocol compatibility
/// 4. **Authentication**: Noise handshake for encrypted channels
/// 5. **Message Exchange**: Bidirectional communication
/// 6. **Disconnection**: Graceful cleanup and state preservation
///
/// ## Security Integration
/// - Coordinates with NoiseEncryptionService for private messages
/// - Maintains peer identity mappings
/// - Handles lazy handshake initiation
/// - Ensures message authenticity
///
/// ## Performance Optimizations
/// - Connection pooling and reuse
/// - Adaptive scanning based on battery level
/// - Message batching for efficiency
/// - Smart retry logic with exponential backoff
///
/// ## Thread Safety
/// All public methods are thread-safe. The service uses:
/// - Serial queues for Core Bluetooth operations
/// - Thread-safe collections for peer management
/// - Atomic operations for state updates
///
/// ## Error Handling
/// - Automatic reconnection for lost connections
/// - Graceful degradation when Bluetooth is unavailable
/// - Clear error reporting through BitchatDelegate
///
/// ## Usage Example
/// ```swift
/// let meshService = BluetoothMeshService()
/// meshService.delegate = self
/// meshService.localUserID = "user123"
/// meshService.startMeshService()
/// ```
///

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

// Hex encoding/decoding is now in BinaryEncodingUtils.swift

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

// Peer connection state tracking
enum PeerConnectionState: CustomStringConvertible {
    case disconnected
    case connecting
    case connected         // BLE connected but not authenticated
    case authenticating    // Performing handshake
    case authenticated     // Handshake complete, ready for messages
    
    var isAvailable: Bool {
        switch self {
        case .authenticated:
            return true
        default:
            return false
        }
    }
    
    var description: String {
        switch self {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .authenticating: return "authenticating"
        case .authenticated: return "authenticated"
        }
    }
}

/// Manages all Bluetooth LE networking operations for the BitChat mesh network.
/// This class handles peer discovery, connection management, message routing,
/// and protocol negotiation. It acts as both a BLE central (scanner) and
/// peripheral (advertiser) simultaneously to enable true peer-to-peer connectivity.
class BluetoothMeshService: NSObject {
    // MARK: - Constants
    
    static let serviceUUID = CBUUID(string: "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C")
    static let characteristicUUID = CBUUID(string: "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
    
    // MARK: - Core Bluetooth Properties
    
    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var discoveredPeripherals: [CBPeripheral] = []
    private var connectedPeripherals: [String: CBPeripheral] = [:]  // Still needed for peripheral management
    private var peripheralCharacteristics: [CBPeripheral: CBCharacteristic] = [:]
    
    // MARK: - Unified Peer Session Tracking
    
    /// Single source of truth for all peer data
    private var peerSessions: [String: PeerSession] = [:]  // peerID -> PeerSession
    
    // MARK: - Migration Helpers
    
    /// Update peripheral connection - safe to call from within collectionsQueue
    private func updatePeripheralConnection(_ peerID: String, peripheral: CBPeripheral?, characteristic: CBCharacteristic? = nil) {
        // Check if we're already on the collections queue
        if DispatchQueue.getSpecific(key: collectionsQueueKey) != nil {
            // Already on collections queue, update directly
            if let session = peerSessions[peerID] {
                session.updateBluetoothConnection(peripheral: peripheral, characteristic: characteristic)
            } else if let peripheral = peripheral {
                // Create session if needed - try to get a better nickname
                let nickname = getBestAvailableNickname(for: peerID)
                let session = PeerSession(peerID: peerID, nickname: nickname)
                session.updateBluetoothConnection(peripheral: peripheral, characteristic: characteristic)
                peerSessions[peerID] = session
            }
            
            // Still need to update these legacy mappings for peripheral management
            if let peripheral = peripheral {
                connectedPeripherals[peerID] = peripheral
                if let characteristic = characteristic {
                    peripheralCharacteristics[peripheral] = characteristic
                }
            } else {
                connectedPeripherals.removeValue(forKey: peerID)
            }
        } else {
            // Not on collections queue, dispatch sync
            collectionsQueue.sync(flags: .barrier) {
                if let session = peerSessions[peerID] {
                    session.updateBluetoothConnection(peripheral: peripheral, characteristic: characteristic)
                } else if let peripheral = peripheral {
                    // Create session if needed - try to get a better nickname
                    let nickname = getBestAvailableNickname(for: peerID)
                    let session = PeerSession(peerID: peerID, nickname: nickname)
                    session.updateBluetoothConnection(peripheral: peripheral, characteristic: characteristic)
                    peerSessions[peerID] = session
                }
                
                // Still need to update these legacy mappings for peripheral management
                if let peripheral = peripheral {
                    connectedPeripherals[peerID] = peripheral
                    if let characteristic = characteristic {
                        peripheralCharacteristics[peripheral] = characteristic
                    }
                } else {
                    connectedPeripherals.removeValue(forKey: peerID)
                }
            }
        }
    }
    
    /// Update last heard time for a peer - safe to call from within collectionsQueue
    private func updateLastHeardFromPeer(_ peerID: String) {
        let now = Date()
        
        // Check if we're already on the collections queue
        if DispatchQueue.getSpecific(key: collectionsQueueKey) != nil {
            // Already on collections queue, update directly
            if let session = peerSessions[peerID] {
                session.lastHeardFromPeer = now
            }
        } else {
            // Not on collections queue, dispatch sync
            collectionsQueue.sync(flags: .barrier) {
                if let session = peerSessions[peerID] {
                    session.lastHeardFromPeer = now
                }
            }
        }
    }
    
    /// Update last successful message time for a peer - safe to call from within collectionsQueue
    private func updateLastSuccessfulMessageTime(_ peerID: String) {
        let now = Date()
        
        // Check if we're already on the collections queue
        if DispatchQueue.getSpecific(key: collectionsQueueKey) != nil {
            // Already on collections queue, update directly
            if let session = peerSessions[peerID] {
                session.lastSuccessfulMessageTime = now
            }
        } else {
            // Not on collections queue, dispatch sync
            collectionsQueue.sync(flags: .barrier) {
                if let session = peerSessions[peerID] {
                    session.lastSuccessfulMessageTime = now
                }
            }
        }
    }
    
    /// Update last connection time for a peer - safe to call from within collectionsQueue
    private func updateLastConnectionTime(_ peerID: String) {
        let now = Date()
        
        // Check if we're already on the collections queue
        if DispatchQueue.getSpecific(key: collectionsQueueKey) != nil {
            // Already on collections queue, update directly
            if let session = peerSessions[peerID] {
                session.lastConnectionTime = now
            }
        } else {
            // Not on collections queue, dispatch sync
            collectionsQueue.sync(flags: .barrier) {
                if let session = peerSessions[peerID] {
                    session.lastConnectionTime = now
                }
            }
        }
    }
    
    // MARK: - Connection Tracking
    
    // MARK: - Peer Availability
    
    // Peer availability tracking
    private let peerAvailabilityTimeout: TimeInterval = 60.0  // Mark unavailable after 60s of no response - increased for stability
    private var availabilityCheckTimer: Timer?
    
    // MARK: - Peripheral Management
    
    private var characteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [CBCentral] = []
    
    // MARK: - Thread-Safe Collections
    
    private let collectionsQueue = DispatchQueue(label: "bitchat.collections", attributes: .concurrent)
    private let collectionsQueueKey = DispatchSpecificKey<Void>()
    
    // MARK: - Encryption Queues
    
    // Per-peer encryption queues to prevent nonce desynchronization
    private var peerEncryptionQueues: [String: DispatchQueue] = [:]
    private let encryptionQueuesLock = NSLock()
    
    // MARK: - Peer Identity Rotation
    // Mappings between ephemeral peer IDs and permanent fingerprints
    private var peerIDToFingerprint: [String: String] = [:]  // PeerID -> Fingerprint
    private var fingerprintToPeerID: [String: String] = [:]  // Fingerprint -> Current PeerID
    private var peerIdentityBindings: [String: PeerIdentityBinding] = [:]  // Fingerprint -> Full binding
    private var rotationTimestamp: Date?  // When we last rotated
    private var rotationLocked = false  // Prevent rotation during critical operations
    private var rotationTimer: Timer?  // Timer for scheduled rotations
    
    // MARK: - Identity Cache
    // In-memory cache for peer public keys to avoid keychain lookups
    private var peerPublicKeyCache: [String: Data] = [:]  // PeerID -> Public Key Data
    private var peerSigningKeyCache: [String: Data] = [:]  // PeerID -> Signing Key Data
    private let identityCacheTTL: TimeInterval = 3600.0  // 1 hour TTL
    private var identityCacheTimestamps: [String: Date] = [:]  // Track when entries were cached
    
    // MARK: - Delegates and Services
    
    weak var delegate: BitchatDelegate?
    private let noiseService = NoiseEncryptionService()
    private let handshakeCoordinator = NoiseHandshakeCoordinator()
    
    // MARK: - Protocol Version Negotiation
    
    // Protocol version negotiation state
    private var versionNegotiationState: [String: VersionNegotiationState] = [:]
    private var negotiatedVersions: [String: UInt8] = [:]  // peerID -> agreed version
    
    // Version cache for optimistic negotiation skip
    private struct CachedVersion {
        let version: UInt8
        let cachedAt: Date
        let expiresAt: Date
        
        var isExpired: Bool {
            return Date() > expiresAt
        }
    }
    private var versionCache: [String: CachedVersion] = [:]
    private let versionCacheDuration: TimeInterval = 24 * 60 * 60  // 24 hours
    
    // MARK: - Protocol Message Deduplication
    
    private struct DedupKey: Hashable {
        let peerID: String  // Use "broadcast" for broadcast messages
        let messageType: MessageType
        let contentHash: Int?  // Optional hash of content for messages that vary
    }
    
    private struct DedupEntry {
        let sentAt: Date
        let expiresAt: Date
    }
    
    private var protocolMessageDedup: [DedupKey: DedupEntry] = [:]
    private let dedupDurations: [MessageType: TimeInterval] = [
        .announce: 5.0,               // Suppress duplicate announces for 5 seconds
        .versionHello: 10.0,          // Suppress version hellos for 10 seconds
        .versionAck: 10.0,            // Suppress version acks for 10 seconds
        .noiseIdentityAnnounce: 5.0,  // Suppress noise identity announcements for 5 seconds
        .leave: 1.0                   // Suppress leave messages for 1 second
    ]
    
    // MARK: - Write Queue for Disconnected Peripherals
    private struct QueuedWrite {
        let data: Data
        let peripheralID: String
        let peerID: String?
        let timestamp: Date
        let retryCount: Int
    }
    
    private var writeQueue: [String: [QueuedWrite]] = [:]  // PeripheralID -> Queue of writes
    private let writeQueueLock = NSLock()
    private let maxWriteQueueSize = 50  // Max queued writes per peripheral
    private let maxWriteRetries = 3
    private let writeQueueTTL: TimeInterval = 60.0  // Expire queued writes after 1 minute
    private var writeQueueTimer: Timer?  // Timer for processing expired writes
    
    // MARK: - Connection Pooling
    private var maxConnectedPeripherals: Int {
        calculateDynamicConnectionLimit()
    }
    private let maxScanningDuration: TimeInterval = 5.0  // Stop scanning after 5 seconds to save battery
    
    func getNoiseService() -> NoiseEncryptionService {
        return noiseService
    }
    
    
    private func cleanExpiredIdentityCache() {
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            let now = Date()
            var expiredPeerIDs: [String] = []
            
            for (peerID, timestamp) in self.identityCacheTimestamps {
                if now.timeIntervalSince(timestamp) >= self.identityCacheTTL {
                    expiredPeerIDs.append(peerID)
                }
            }
            
            for peerID in expiredPeerIDs {
                self.peerPublicKeyCache.removeValue(forKey: peerID)
                self.peerSigningKeyCache.removeValue(forKey: peerID)
                self.identityCacheTimestamps.removeValue(forKey: peerID)
            }
            
            if !expiredPeerIDs.isEmpty {
                SecureLogger.log("Cleaned \(expiredPeerIDs.count) expired identity cache entries", 
                               category: SecureLogger.session, level: .debug)
            }
        }
    }
    
    // MARK: - Write Queue Management
    
    private func writeToPeripheral(_ data: Data, peripheral: CBPeripheral, characteristic: CBCharacteristic, peerID: String? = nil) {
        let peripheralID = peripheral.identifier.uuidString
        
        // Double check the peripheral state to avoid API misuse
        guard peripheral.state == .connected else {
            // Queue write for disconnected peripheral
            queueWrite(data: data, peripheralID: peripheralID, peerID: peerID)
            return
        }
        
        // Verify characteristic is valid and writable
        guard characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) else {
            SecureLogger.log("Characteristic does not support writing for peripheral \(peripheralID)", 
                           category: SecureLogger.session, level: .warning)
            return
        }
        
        // Direct write if connected
        let writeType: CBCharacteristicWriteType = data.count > 512 ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: writeType)
        
        // Update activity tracking
        updatePeripheralActivity(peripheralID)
    }
    
    private func queueWrite(data: Data, peripheralID: String, peerID: String?) {
        writeQueueLock.lock()
        defer { writeQueueLock.unlock() }
        
        // Check backpressure - drop oldest if queue is full
        var queue = writeQueue[peripheralID] ?? []
        
        if queue.count >= maxWriteQueueSize {
            // Remove oldest entries
            let removeCount = queue.count - maxWriteQueueSize + 1
            queue.removeFirst(removeCount)
            SecureLogger.log("Write queue full for \(peripheralID), dropped \(removeCount) oldest writes", 
                           category: SecureLogger.session, level: .warning)
        }
        
        let queuedWrite = QueuedWrite(
            data: data,
            peripheralID: peripheralID,
            peerID: peerID,
            timestamp: Date(),
            retryCount: 0
        )
        
        queue.append(queuedWrite)
        writeQueue[peripheralID] = queue
        
        SecureLogger.log("Queued write for disconnected peripheral \(peripheralID), queue size: \(queue.count)", 
                       category: SecureLogger.session, level: .debug)
    }
    
    private func processWriteQueue(for peripheral: CBPeripheral) {
        guard peripheral.state == .connected,
              let characteristic = peripheralCharacteristics[peripheral] else { return }
        
        let peripheralID = peripheral.identifier.uuidString
        
        writeQueueLock.lock()
        let queue = writeQueue[peripheralID] ?? []
        writeQueue[peripheralID] = []
        writeQueueLock.unlock()
        
        if !queue.isEmpty {
            SecureLogger.log("Processing \(queue.count) queued writes for \(peripheralID)", 
                           category: SecureLogger.session, level: .info)
        }
        
        // Process queued writes with small delay between them
        for (index, queuedWrite) in queue.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.01) { [weak self] in
                guard let self = self,
                      peripheral.state == .connected,
                      characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) else { 
                    return 
                }
                
                let writeType: CBCharacteristicWriteType = queuedWrite.data.count > 512 ? .withResponse : .withoutResponse
                peripheral.writeValue(queuedWrite.data, for: characteristic, type: writeType)
                
                // Update activity tracking
                self.updatePeripheralActivity(peripheralID)
            }
        }
    }
    
    private func cleanExpiredWriteQueues() {
        writeQueueLock.lock()
        defer { writeQueueLock.unlock() }
        
        let now = Date()
        var expiredWrites = 0
        
        for (peripheralID, queue) in writeQueue {
            let filteredQueue = queue.filter { write in
                now.timeIntervalSince(write.timestamp) < writeQueueTTL
            }
            
            expiredWrites += queue.count - filteredQueue.count
            
            if filteredQueue.isEmpty {
                writeQueue.removeValue(forKey: peripheralID)
            } else {
                writeQueue[peripheralID] = filteredQueue
            }
        }
        
        if expiredWrites > 0 {
            SecureLogger.log("Cleaned \(expiredWrites) expired queued writes", 
                           category: SecureLogger.session, level: .debug)
        }
    }
    // MARK: - Message Processing
    
    private let messageQueue = DispatchQueue(label: "bitchat.messageQueue", attributes: .concurrent) // Concurrent queue with barriers
    
    // Message state tracking for better duplicate detection
    private struct MessageState {
        let firstSeen: Date
        var lastSeen: Date
        var seenCount: Int
        var relayed: Bool
        var acknowledged: Bool
        
        mutating func updateSeen() {
            lastSeen = Date()
            seenCount += 1
        }
    }
    
    private var processedMessages = [String: MessageState]()  // Track full message state
    private let processedMessagesLock = NSLock()
    private let maxProcessedMessages = 10000
    
    // Special handling for identity announces to prevent duplicates
    private var recentIdentityAnnounces = [String: Date]()  // peerID -> last seen time
    private let identityAnnounceDuplicateWindow: TimeInterval = 30.0  // 30 second window
    
    // MARK: - Network State Management
    
    private let maxTTL: UInt8 = 7  // Maximum hops for long-distance delivery
    private var hasNotifiedNetworkAvailable = false  // Track if we've notified about network availability
    private var lastNetworkNotificationTime: Date?  // Track when we last sent a network notification
    private var networkBecameEmptyTime: Date?  // Track when the network became empty
    private let networkNotificationCooldown: TimeInterval = 300  // 5 minutes between notifications
    private let networkEmptyResetDelay: TimeInterval = 60  // 1 minute before resetting notification flag
    private var intentionalDisconnects = Set<String>()  // Track peripherals we're disconnecting intentionally
    private var gracefullyLeftPeers = Set<String>()  // Track peers that sent leave messages
    private var gracefulLeaveTimestamps: [String: Date] = [:]  // Track when peers left
    private let gracefulLeaveExpirationTime: TimeInterval = 300.0  // 5 minutes
    private var recentDisconnectNotifications: [String: Date] = [:]  // Track recent disconnect notifications to prevent duplicates
    private let disconnectNotificationDedupeWindow: TimeInterval = 2.0  // 2 seconds window for deduplication
    private var peerLastSeenTimestamps = LRUCache<String, Date>(maxSize: 100)  // Bounded cache for peer timestamps
    private var cleanupTimer: Timer?  // Timer to clean up stale peers
    
    // MARK: - Store-and-Forward Cache
    
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
    
    // MARK: - Battery and Performance Optimization
    
    // Battery and range optimizations
    private var scanDutyCycleTimer: Timer?
    private var isActivelyScanning = true
    private var activeScanDuration: TimeInterval = 5.0  // will be adjusted based on battery
    private var scanPauseDuration: TimeInterval = 10.0  // will be adjusted based on battery
    private var batteryMonitorTimer: Timer?
    private var currentBatteryLevel: Float = 1.0  // Default to full battery
    
    // App state tracking
    private var isAppInForeground = true
    
    // Background task management
    #if os(iOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var scanBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var advertiseBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    
    // Core Bluetooth state restoration identifiers
    private static let centralManagerRestorationID = "com.bitchat.central"
    private static let peripheralManagerRestorationID = "com.bitchat.peripheral"
    
    // Battery optimizer integration
    private let batteryOptimizer = BatteryOptimizer.shared
    private var batteryOptimizerCancellables = Set<AnyCancellable>()
    
    // Rescan rate limiting
    private var lastRescanTime: Date = Date.distantPast
    private let minRescanInterval: TimeInterval = 2.0
    
    // Peer list update debouncing
    private var peerListUpdateTimer: Timer?
    private let peerListUpdateDebounceInterval: TimeInterval = 0.1  // 100ms debounce for more responsive updates
    
    // Track when we last sent identity announcements to prevent flooding
    private var lastIdentityAnnounceTimes: [String: Date] = [:]
    private let identityAnnounceMinInterval: TimeInterval = 10.0  // Minimum 10 seconds between announcements per peer
    
    // Track handshake attempts to handle timeouts
    private var handshakeAttemptTimes: [String: Date] = [:]
    private let handshakeTimeout: TimeInterval = 5.0  // 5 seconds before retrying
    
    // Pending private messages waiting for handshake
    private var pendingPrivateMessages: [String: [(content: String, recipientNickname: String, messageID: String)]] = [:]
    
    // MARK: - Noise Protocol State
    
    // Noise session state tracking for lazy handshakes
    private var noiseSessionStates: [String: LazyHandshakeState] = [:]
    
    // MARK: - Connection State
    
    // Connection state tracking
    private var peerConnectionStates: [String: PeerConnectionState] = [:]
    private let connectionStateQueue = DispatchQueue(label: "chat.bitchat.connectionState", attributes: .concurrent)
    
    // MARK: - Protocol ACK Tracking
    
    // Protocol-level ACK tracking
    private var pendingAcks: [String: (packet: BitchatPacket, timestamp: Date, retries: Int)] = [:]
    private let ackTimeout: TimeInterval = 5.0  // 5 seconds to receive ACK
    private let maxAckRetries = 3
    private var ackTimer: Timer?
    private var advertisingTimer: Timer?  // Timer for interval-based advertising
    private var connectionKeepAliveTimer: Timer?  // Timer to send keepalive pings
    private let keepAliveInterval: TimeInterval = 20.0  // Send keepalive every 20 seconds
    
    // MARK: - Timing and Delays
    
    // Timing randomization for privacy (now with exponential distribution)
    private let minMessageDelay: TimeInterval = 0.01  // 10ms minimum for faster sync
    private let maxMessageDelay: TimeInterval = 0.1   // 100ms maximum for faster sync
    
    // MARK: - Fragment Handling
    
    // Fragment handling with security limits
    private var incomingFragments: [String: [Int: Data]] = [:]  // fragmentID -> [index: data]
    private var fragmentMetadata: [String: (originalType: UInt8, totalFragments: Int, timestamp: Date)] = [:]
    private let maxFragmentSize = 469 // 512 bytes max MTU - 43 bytes for headers and metadata
    private let maxConcurrentFragmentSessions = 20  // Limit concurrent fragment sessions to prevent DoS
    private let fragmentTimeout: TimeInterval = 30  // 30 seconds timeout for incomplete fragments
    
    // MARK: - Peer Identity
    
    var myPeerID: String {
        didSet {
            if oldValue != "" && oldValue != myPeerID {
                SecureLogger.log("📍 MY PEER ID CHANGED: \(oldValue) -> \(myPeerID)", 
                               category: SecureLogger.security, level: .warning)
            }
        }
    }
    
    // MARK: - Scaling Optimizations
    
    // Connection pooling
    private var connectionPool: [String: CBPeripheral] = [:]
    private var connectionAttempts: [String: Int] = [:]
    private var connectionBackoff: [String: TimeInterval] = [:]
    private var lastActivityByPeripheralID: [String: Date] = [:]  // Track last activity for LRU
    private var peerIDByPeripheralID: [String: String] = [:]  // Map peripheral ID to peer ID
    private var lastVersionHelloTime: [String: Date] = [:]  // Track when version hello received from peer
    private let maxConnectionAttempts = 3
    private let baseBackoffInterval: TimeInterval = 1.0
    
    // MARK: - Peripheral Mapping
    
    // Simplified peripheral mapping system
    private struct PeripheralMapping {
        let peripheral: CBPeripheral
        var peerID: String?  // nil until we receive announce
        var lastActivity: Date
        
        var isIdentified: Bool { peerID != nil }
    }
    private var peripheralMappings: [String: PeripheralMapping] = [:]  // peripheralID -> mapping
    
    // Helper methods for peripheral mapping
    private func registerPeripheral(_ peripheral: CBPeripheral) {
        let peripheralID = peripheral.identifier.uuidString
        peripheralMappings[peripheralID] = PeripheralMapping(
            peripheral: peripheral,
            peerID: nil,
            lastActivity: Date()
        )
    }
    
    private func updatePeripheralMapping(peripheralID: String, peerID: String) {
        SecureLogger.log("[MAPPING] updatePeripheralMapping called: peripheralID=\(peripheralID.prefix(8)) -> peerID=\(peerID)", 
                       category: SecureLogger.session, level: .debug)
        
        guard var mapping = peripheralMappings[peripheralID] else { 
            SecureLogger.log("[WARNING] No peripheral mapping found for \(peripheralID.prefix(8))", 
                           category: SecureLogger.session, level: .warning)
            return 
        }
        
        // Remove old temp mapping if it exists
        let tempID = peripheralID
        if connectedPeripherals[tempID] != nil {
            connectedPeripherals.removeValue(forKey: tempID)
        }
        
        mapping.peerID = peerID
        mapping.lastActivity = Date()
        peripheralMappings[peripheralID] = mapping
        
        // Update legacy mappings
        peerIDByPeripheralID[peripheralID] = peerID
        updatePeripheralConnection(peerID, peripheral: mapping.peripheral)
        
        SecureLogger.log("[SUCCESS] Successfully mapped peripheral \(peripheralID.prefix(8)) to peer \(peerID)", 
                       category: SecureLogger.session, level: .info)
        
        // Update PeerSession
        if let session = peerSessions[peerID] {
            let wasConnected = session.isConnected
            session.updateBluetoothConnection(peripheral: mapping.peripheral, characteristic: nil)
            SecureLogger.log("[UPDATE] Updated existing PeerSession for \(peerID): wasConnected=\(wasConnected)", 
                           category: SecureLogger.session, level: .debug)
        } else {
            let nickname = getBestAvailableNickname(for: peerID)
            let session = PeerSession(peerID: peerID, nickname: nickname)
            session.updateBluetoothConnection(peripheral: mapping.peripheral, characteristic: nil)
            peerSessions[peerID] = session
            SecureLogger.log("[NEW] Created new PeerSession for \(peerID) with peripheral", 
                           category: SecureLogger.session, level: .info)
        }
    }
    
    private func findPeripheralForPeerID(_ peerID: String) -> CBPeripheral? {
        for (_, mapping) in peripheralMappings {
            if mapping.peerID == peerID {
                return mapping.peripheral
            }
        }
        return nil
    }
    
    // MARK: - Probabilistic Flooding
    
    // Probabilistic flooding
    private var relayProbability: Double = 1.0  // Start at 100%, decrease with peer count
    private let minRelayProbability: Double = 0.4  // Minimum 40% relay chance - ensures coverage
    
    // MARK: - Message Aggregation
    
    // Message aggregation
    private var pendingMessages: [(message: BitchatPacket, destination: String?)] = []
    private var aggregationTimer: Timer?
    private var aggregationWindow: TimeInterval = 0.1  // 100ms window
    private let maxAggregatedMessages = 5
    
    // MARK: - Bloom Filter
    
    // Optimized Bloom filter for efficient duplicate detection
    private var messageBloomFilter = OptimizedBloomFilter(expectedItems: 2000, falsePositiveRate: 0.01)
    private var bloomFilterResetTimer: Timer?
    
    // MARK: - Consolidated Timers
    
    // Consolidated timers for better performance
    private var highFrequencyTimer: Timer?    // 2s - critical real-time tasks
    private var mediumFrequencyTimer: Timer?  // 20s - regular maintenance 
    private var lowFrequencyTimer: Timer?     // 5min - cleanup and optimization
    
    // Track execution counters for tasks that don't run every timer tick
    private var mediumTimerTickCount = 0
    private var lowTimerTickCount = 0
    
    // MARK: - Network Size Estimation
    
    // Network size estimation
    private var estimatedNetworkSize: Int {
        return collectionsQueue.sync {
            let activePeerCount = peerSessions.values.filter { $0.isActivePeer }.count
            let peripheralCount = connectedPeripherals.count
            let result = max(activePeerCount, peripheralCount)
            SecureLogger.log("[NETWORK-SIZE] Network size calculation: activePeers=\(activePeerCount), peripherals=\(peripheralCount), result=\(result)", 
                           category: SecureLogger.session, level: .debug)
            return result
        }
    }
    
    // Dynamic connection limit calculation based on network size and battery mode
    private func calculateDynamicConnectionLimit() -> Int {
        let powerMode = batteryOptimizer.currentPowerMode
        let baseLimit = powerMode.maxConnections
        let nearbyPeers = estimatedNetworkSize
        
        // For small groups, try to maintain full mesh connectivity
        if nearbyPeers > 0 && nearbyPeers < 10 {
            // Override battery limits for small groups to prevent thrashing
            let dynamicLimit = max(baseLimit, nearbyPeers + 1)
            if dynamicLimit != baseLimit {
                SecureLogger.log("[CONN-LIMIT] Dynamic connection limit: \(dynamicLimit) (base: \(baseLimit), peers: \(nearbyPeers)) - maintaining full mesh", 
                               category: SecureLogger.session, level: .info)
            }
            return dynamicLimit
        }
        
        // For larger groups, scale up the limit but cap it reasonably
        let groupMultiplier = min(2.0, 1.0 + (Double(nearbyPeers) / 10.0))
        let scaledLimit = Int(Double(baseLimit) * groupMultiplier)
        
        // Cap at a reasonable maximum to prevent resource exhaustion
        let finalLimit = min(scaledLimit, 30)
        
        if finalLimit != baseLimit {
            SecureLogger.log("[CONN-LIMIT] Dynamic connection limit: \(finalLimit) (base: \(baseLimit), peers: \(nearbyPeers), multiplier: \(String(format: "%.2f", groupMultiplier)))", 
                           category: SecureLogger.session, level: .info)
        }
        
        return finalLimit
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
        // Adjust relay probability based on network size
        // Small networks don't need 100% relay
        let networkSize = estimatedNetworkSize
        if networkSize <= 2 {
            let prob = 0.3   // 30% for 2 nodes - helps with discovery and relay-only connections
            SecureLogger.log("[RELAY-PROB] Relay probability for size \(networkSize): \(prob)", 
                           category: SecureLogger.session, level: .debug)
            return prob
        } else if networkSize <= 5 {
            return 0.5   // 50% for very small networks
        } else if networkSize <= 10 {
            return 0.6   // 60% for small networks
        } else if networkSize <= 30 {
            return 0.7   // 70% for medium networks
        } else if networkSize <= 50 {
            return 0.6   // 60% for larger networks
        } else if networkSize <= 100 {
            return 0.5   // 50% for big networks
        } else {
            return 0.4   // 40% minimum for very large networks
        }
    }
    
    // MARK: - Relay Cancellation
    
    // Relay cancellation mechanism to prevent duplicate relays
    private var pendingRelays: [String: DispatchWorkItem] = [:]  // messageID -> relay task
    private let pendingRelaysLock = NSLock()
    private let relayCancellationWindow: TimeInterval = 0.05  // 50ms window to detect other relays
    
    // MARK: - Memory Management
    
    // Global memory limits to prevent unbounded growth
    private let maxPendingPrivateMessages = 100
    private let maxCachedMessagesSentToPeer = 1000
    private let maxMemoryUsageBytes = 50 * 1024 * 1024  // 50MB limit
    private var memoryCleanupTimer: Timer?
    
    // Track acknowledged packets to prevent unnecessary retries
    private var acknowledgedPackets = Set<String>()
    private let acknowledgedPacketsLock = NSLock()
    
    // MARK: - Rate Limiting
    
    // Rate limiting for flood control with separate limits for different message types
    private var messageRateLimiter: [String: [Date]] = [:]  // peerID -> recent message timestamps
    private var protocolMessageRateLimiter: [String: [Date]] = [:]  // peerID -> protocol msg timestamps
    private let rateLimiterLock = NSLock()
    private let rateLimitWindow: TimeInterval = 60.0  // 1 minute window
    private let maxChatMessagesPerPeerPerMinute = 300  // Allow fast typing (5 msgs/sec)
    private let maxProtocolMessagesPerPeerPerMinute = 100  // Protocol messages
    private let maxTotalMessagesPerMinute = 2000  // Increased for legitimate use
    private var totalMessageTimestamps: [Date] = []
    
    // MARK: - BLE Advertisement
    
    // BLE advertisement for lightweight presence
    private var advertisementData: [String: Any] = [:]
    private var isAdvertising = false
    
    // MARK: - Message Aggregation Implementation
    
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
                              let characteristic = self.peripheralCharacteristics[peripheral] {
                        if let data = messages[0].toBinaryData() {
                            self.writeToPeripheral(data, peripheral: peripheral, characteristic: characteristic, peerID: dest)
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
                                    self?.writeToPeripheral(data, peripheral: peripheral, characteristic: characteristic, peerID: dest)
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
    
    // MARK: - Peer Identity Mapping
    
    /// Retrieves the cryptographic fingerprint for a given peer.
    /// - Parameter peerID: The ephemeral peer ID
    /// - Returns: The peer's Noise static key fingerprint if known, nil otherwise
    /// - Note: This fingerprint remains stable across peer ID rotations
    func getPeerFingerprint(_ peerID: String) -> String? {
        // Check PeerSession first for O(1) lookup
        if let fingerprint = collectionsQueue.sync(execute: { 
            peerSessions[peerID]?.fingerprint 
        }) {
            return fingerprint
        }
        
        // Fallback to noise service
        return noiseService.getPeerFingerprint(peerID)
    }
    
    // Get fingerprint for a peer ID
    func getFingerprint(for peerID: String) -> String? {
        return collectionsQueue.sync {
            // Check PeerSession first for O(1) lookup
            if let fingerprint = peerSessions[peerID]?.fingerprint {
                return fingerprint
            }
            
            // Fallback to peerIDToFingerprint map
            return peerIDToFingerprint[peerID]
        }
    }
    
    /// Checks if a given peer ID belongs to the local device.
    /// - Parameter peerID: The peer ID to check
    /// - Returns: true if this is our current or recent peer ID, false otherwise
    /// - Note: Accounts for grace period during peer ID rotation
    func isPeerIDOurs(_ peerID: String) -> Bool {
        if peerID == myPeerID {
            return true
        }
        
        return false
    }
    
    // MARK: - Peer Session Management
    
    /// Get or create a peer session
    private func getPeerSession(_ peerID: String) -> PeerSession {
        return collectionsQueue.sync(flags: .barrier) {
            if let session = peerSessions[peerID] {
                return session
            }
            // Try to get a better nickname from various sources before defaulting to "Unknown"
            let nickname = getBestAvailableNickname(for: peerID)
            let newSession = PeerSession(peerID: peerID, nickname: nickname)
            peerSessions[peerID] = newSession
            return newSession
        }
    }
    
    /// Get peer session if it exists
    private func getExistingPeerSession(_ peerID: String) -> PeerSession? {
        return collectionsQueue.sync {
            return peerSessions[peerID]
        }
    }
    
    /// Update peer session with nickname
    private func updatePeerSessionNickname(_ peerID: String, nickname: String) {
        collectionsQueue.async(flags: .barrier) {
            if let session = self.peerSessions[peerID] {
                session.nickname = nickname
            } else {
                let session = PeerSession(peerID: peerID, nickname: nickname)
                self.peerSessions[peerID] = session
            }
        }
    }
    
    /// Get the best available nickname for a peer ID from various sources
    /// This method should be called from within collectionsQueue context
    private func getBestAvailableNickname(for peerID: String) -> String {
        // Check if ChatViewModel has peer information available
        if let chatViewModel = delegate as? ChatViewModel {
            let peers = chatViewModel.allPeers
            if let peer = peers.first(where: { $0.id == peerID }), !peer.displayName.isEmpty && peer.displayName != "Unknown" {
                return peer.displayName
            }
        }
        
        // Generate a more user-friendly temporary nickname based on peer ID
        // This is better than "Unknown" and helps users distinguish between different peers
        return "anon\(peerID.prefix(4))"
    }
    
    /// Create a peer session only if we have a valid connection
    /// This prevents ghost sessions from being created
    private func createPeerSessionIfValid(_ peerID: String, peripheral: CBPeripheral? = nil, nickname: String = "Unknown") -> PeerSession? {
        return collectionsQueue.sync(flags: .barrier) {
            // Check if we already have a session
            if let existingSession = self.peerSessions[peerID] {
                return existingSession
            }
            
            // Only create new sessions if we have a peripheral connection or it's for authenticated purposes
            guard peripheral != nil && peripheral?.state == .connected else {
                SecureLogger.log("Refusing to create session for \(peerID) without peripheral connection", 
                               category: SecureLogger.session, level: .debug)
                return nil
            }
            
            let session = PeerSession(peerID: peerID, nickname: nickname)
            if let peripheral = peripheral {
                session.updateBluetoothConnection(peripheral: peripheral, characteristic: nil)
            }
            self.peerSessions[peerID] = session
            return session
        }
    }
    
    /// Clean up Unknown peers that haven't announced themselves and old disconnected sessions
    private func cleanupUnknownPeers() {
        collectionsQueue.async(flags: .barrier) {
            let sessionsToRemove = self.peerSessions.filter { (peerID, session) in
                // Remove if it's an Unknown peer without a proper announcement
                if session.nickname == "Unknown" && 
                   !session.hasReceivedAnnounce &&
                   session.peripheral == nil &&
                   Date().timeIntervalSince(session.lastSeen) > 3.0 {
                    return true
                }
                
                // Remove disconnected non-favorite sessions after 5 minutes
                if !session.isConnected && !session.isActivePeer &&
                   Date().timeIntervalSince(session.lastSeen) > 300.0 {
                    // Non-favorites will be cleaned up
                    // Favorites are kept indefinitely
                    return true
                }
                
                return false
            }
            
            for (peerID, session) in sessionsToRemove {
                if session.nickname == "Unknown" {
                    SecureLogger.log("Removing Unknown peer \(peerID) - no announce received", 
                                   category: SecureLogger.session, level: .debug)
                } else {
                    SecureLogger.log("Removing disconnected non-favorite peer \(peerID) (\(session.nickname)) - disconnected too long", 
                                   category: SecureLogger.session, level: .debug)
                }
                self.peerSessions.removeValue(forKey: peerID)
            }
            
            if !sessionsToRemove.isEmpty {
                DispatchQueue.main.async {
                    self.notifyPeerListUpdate(immediate: true)
                }
            }
        }
    }
    
    /// Clean up stale peer sessions
    private func cleanupStaleSessions() {
        collectionsQueue.async(flags: .barrier) {
            // Remove stale sessions and ghost sessions without proper connections
            let sessionsToRemove = self.peerSessions.filter { (peerID, session) in
                // Remove if stale
                if session.isStale {
                    return true
                }
                // Remove if it's a ghost session (no peripheral, not authenticated, and has default nickname)
                if session.peripheral == nil && 
                   !session.isAuthenticated && 
                   !session.hasEstablishedNoiseSession &&
                   !session.hasReceivedAnnounce &&
                   (session.nickname == "Unknown" || session.nickname.isEmpty) {
                    return true
                }
                return false
            }
            
            for (peerID, session) in sessionsToRemove {
                SecureLogger.log("Removing stale/ghost session for \(peerID) (nickname: \(session.nickname))", 
                               category: SecureLogger.session, level: .debug)
                self.peerSessions.removeValue(forKey: peerID)
            }
        }
    }
    
    /// Updates the identity binding for a peer when they rotate their ephemeral ID.
    /// - Parameters:
    ///   - newPeerID: The peer's new ephemeral ID
    ///   - fingerprint: The peer's stable cryptographic fingerprint
    ///   - binding: The complete identity binding information
    /// - Note: This maintains continuity of identity across peer ID rotations
    func updatePeerBinding(_ newPeerID: String, fingerprint: String, binding: PeerIdentityBinding) {
        // Use async to ensure we're not blocking during view updates
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            var oldPeerID: String? = nil
            
            // Remove old peer ID mapping if exists
            if let existingPeerID = self.fingerprintToPeerID[fingerprint], existingPeerID != newPeerID {
                oldPeerID = existingPeerID
                SecureLogger.log("Peer ID rotation detected: \(existingPeerID) -> \(newPeerID) for fingerprint \(fingerprint)", category: SecureLogger.security, level: .info)
                
                // Transfer gracefullyLeftPeers state from old to new peer ID
                if self.gracefullyLeftPeers.contains(existingPeerID) {
                    self.gracefullyLeftPeers.remove(existingPeerID)
                    self.gracefullyLeftPeers.insert(newPeerID)
                    SecureLogger.log("Transferred gracefullyLeft state from \(existingPeerID) to \(newPeerID)", 
                                   category: SecureLogger.session, level: .debug)
                }
                
                self.peerIDToFingerprint.removeValue(forKey: existingPeerID)
                
                // Transfer session data from old to new peer ID
                if let oldSession = self.peerSessions[existingPeerID] {
                    // Extract all data from old session
                    let nickname = oldSession.nickname
                    let lastHeard = oldSession.lastHeardFromPeer
                    let peripheral = oldSession.peripheral
                    
                    // Create or update session for new peer ID
                    if let newSession = self.peerSessions[newPeerID] {
                        newSession.nickname = nickname
                        newSession.lastHeardFromPeer = lastHeard
                        if let peripheral = peripheral {
                            newSession.updateBluetoothConnection(peripheral: peripheral, characteristic: nil)
                        }
                    } else {
                        let newSession = PeerSession(peerID: newPeerID, nickname: nickname)
                        newSession.lastHeardFromPeer = lastHeard
                        if let peripheral = peripheral {
                            newSession.updateBluetoothConnection(peripheral: peripheral, characteristic: nil)
                        }
                        self.peerSessions[newPeerID] = newSession
                    }
                    
                    // Mark old session as inactive
                    oldSession.isActivePeer = false
                    oldSession.isConnected = false
                }
                
                // Transfer any connected peripherals in the legacy mapping
                if let peripheral = self.connectedPeripherals[existingPeerID] {
                    self.connectedPeripherals.removeValue(forKey: existingPeerID)
                    self.connectedPeripherals[newPeerID] = peripheral
                }
                
                // Clean up connection state for old peer ID
                self.peerConnectionStates.removeValue(forKey: existingPeerID)
                // Don't transfer connection state - let it be re-established naturally
                
                // Clean up any pending messages for old peer ID
                self.pendingPrivateMessages.removeValue(forKey: existingPeerID)
                // Don't transfer pending messages - they would be stale anyway
            }
            
            // Add new mapping
            self.peerIDToFingerprint[newPeerID] = fingerprint
            self.fingerprintToPeerID[fingerprint] = newPeerID
            self.peerIdentityBindings[fingerprint] = binding
            
            // Cache public keys to avoid keychain lookups
            self.peerPublicKeyCache[newPeerID] = binding.publicKey
            self.peerSigningKeyCache[newPeerID] = binding.signingPublicKey
            self.identityCacheTimestamps[newPeerID] = Date()
            
            // Also update nickname from binding
            if let session = self.peerSessions[newPeerID] {
                session.nickname = binding.nickname
            } else {
                let session = PeerSession(peerID: newPeerID, nickname: binding.nickname)
                self.peerSessions[newPeerID] = session
            }
            
            // Notify about the change if it's a rotation
            if let oldID = oldPeerID {
                // Clear the old session instead of migrating it
                // This ensures both peers do a fresh handshake after ID rotation
                self.cleanupPeerCryptoState(oldID)
                self.handshakeCoordinator.resetHandshakeState(for: newPeerID)
                
                // Log the peer ID rotation
                SecureLogger.log("Cleared session for peer ID rotation: \(oldID) -> \(newPeerID), will establish fresh handshake", 
                               category: SecureLogger.handshake, level: .info)
                
                self.notifyPeerIDChange(oldPeerID: oldID, newPeerID: newPeerID, fingerprint: fingerprint)
                
                // Remove the old peer session immediately to prevent "Unknown" peers
                self.peerSessions.removeValue(forKey: oldID)
                
                // Lazy handshake: No longer initiate handshake on peer ID rotation
                // Handshake will be initiated when first private message is sent
            }
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
            self?.collectionsQueue.sync(flags: .barrier) {
                if let session = self?.peerSessions[oldPeerID] {
                    session.isActivePeer = false
                }
                // Don't pre-insert the new peer ID - let the announce packet handle it
                // This ensures the connect message logic works properly
            }
            
            // Update PeerSession for old peer ID
            if let session = self?.peerSessions[oldPeerID] {
                session.hasReceivedAnnounce = false
            }
            
            // Update peer list
            self?.notifyPeerListUpdate(immediate: true)
            
            // Don't send disconnect/connect messages for peer ID rotation
            // The peer didn't actually disconnect, they just rotated their ID
            // This prevents confusing messages like "3a7e1c2c0d8943b9 disconnected"
            
            // Instead, notify the delegate about the peer ID change if needed
            // (Could add a new delegate method for this in the future)
        }
    }
    
    // MARK: - Peer Connection Management
    
    func getCachedPublicKey(for peerID: String) -> Data? {
        return collectionsQueue.sync {
            // Check if cache entry exists and is not expired
            if let timestamp = identityCacheTimestamps[peerID],
               Date().timeIntervalSince(timestamp) < identityCacheTTL {
                return peerPublicKeyCache[peerID]
            }
            return nil
        }
    }
    
    func getCachedSigningKey(for peerID: String) -> Data? {
        return collectionsQueue.sync {
            // Check if cache entry exists and is not expired
            if let timestamp = identityCacheTimestamps[peerID],
               Date().timeIntervalSince(timestamp) < identityCacheTTL {
                return peerSigningKeyCache[peerID]
            }
            return nil
        }
    }
    
    private func updatePeerConnectionState(_ peerID: String, state: PeerConnectionState) {
        connectionStateQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            let previousState = self.peerConnectionStates[peerID]
            self.peerConnectionStates[peerID] = state
            
            SecureLogger.log("Peer \(peerID) connection state: \(previousState?.description ?? "nil") -> \(state)", 
                           category: SecureLogger.session, level: .debug)
            
            // Update PeerSession based on authentication state
            self.collectionsQueue.async(flags: .barrier) {
                switch state {
                case .authenticated:
                    if self.peerSessions[peerID]?.isActivePeer != true {
                        // Update PeerSession
                        if let session = self.peerSessions[peerID] {
                            session.isActivePeer = true
                        }
                        SecureLogger.log("Marked \(peerID) as active (authenticated)", 
                                       category: SecureLogger.session, level: .info)
                        
                        // Update PeerSession authentication state
                        if let session = self.peerSessions[peerID] {
                            session.updateAuthenticationState(authenticated: true, noiseSession: true)
                        } else {
                            let nickname = self.getBestAvailableNickname(for: peerID)
                            let session = PeerSession(peerID: peerID, nickname: nickname)
                            session.updateAuthenticationState(authenticated: true, noiseSession: true)
                            self.peerSessions[peerID] = session
                        }
                        
                    }
                case .disconnected:
                    if self.peerSessions[peerID]?.isActivePeer == true {
                        // Update PeerSession
                        if let session = self.peerSessions[peerID] {
                            session.isActivePeer = false
                        }
                        SecureLogger.log("Marked \(peerID) as inactive (disconnected)", 
                                       category: SecureLogger.session, level: .info)
                    }
                    
                    // Update PeerSession to disconnected state
                    if let session = self.peerSessions[peerID] {
                        session.updateAuthenticationState(authenticated: false, noiseSession: false)
                        session.updateBluetoothConnection(peripheral: nil, characteristic: nil)
                        session.isConnected = false
                        session.isActivePeer = false
                        // Keep the session but mark it as disconnected
                        // This allows us to detect reconnections
                        SecureLogger.log("Marked \(peerID) (\(session.nickname)) as disconnected in peerSessions", 
                                       category: SecureLogger.session, level: .info)
                    }
                    
                    // Note: PeerSession is already updated in the disconnect case above
                    // Clean up old mappings
                default:
                    break
                }
                
                // Always notify peer list update when connection state changes
                DispatchQueue.main.async {
                    self.notifyPeerListUpdate(immediate: true)
                }
            }
        }
    }
    
    // Get peer connection state
    func getPeerConnectionState(_ peerID: String) -> PeerConnectionState {
        return connectionStateQueue.sync {
            peerConnectionStates[peerID] ?? .disconnected
        }
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
            
            // Save current peer ID
            let oldID = self.myPeerID
            self.rotationTimestamp = Date()
            
            // Generate new peer ID
            self.myPeerID = self.generateNewPeerID()
            
            SecureLogger.log("Peer ID rotated from \(oldID) to \(self.myPeerID)", category: SecureLogger.security, level: .info)
            
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
    
    // MARK: - Initialization
    
    override init() {
        // Generate ephemeral peer ID for each session to prevent tracking
        self.myPeerID = ""
        super.init()
        self.myPeerID = generateNewPeerID()
        
        // Set up queue-specific key for deadlock prevention
        collectionsQueue.setSpecific(key: collectionsQueueKey, value: ())
        
        // Initialize Bluetooth managers with state restoration
        centralManager = CBCentralManager(
            delegate: self, 
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.centralManagerRestorationID]
        )
        peripheralManager = CBPeripheralManager(
            delegate: self, 
            queue: nil,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: Self.peripheralManagerRestorationID]
        )
        
        // Setup app state notifications
        setupAppStateNotifications()
        
        // Setup consolidated timers for better performance
        setupConsolidatedTimers()
        
        /* OLD TIMER SETUP - REPLACED BY CONSOLIDATED TIMERS
        bloomFilterResetTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.messageQueue.async(flags: .barrier) {
                guard let self = self else { return }
                
                // Adapt Bloom filter size based on network size
                let networkSize = self.estimatedNetworkSize
                self.messageBloomFilter = OptimizedBloomFilter.adaptive(for: networkSize)
                
                // Clean up old processed messages (keep last 10 minutes of messages)
                self.processedMessagesLock.lock()
                let cutoffTime = Date().addingTimeInterval(-600) // 10 minutes ago
                let originalCount = self.processedMessages.count
                self.processedMessages = self.processedMessages.filter { _, state in
                    state.firstSeen > cutoffTime
                }
                
                // Also enforce max size limit during cleanup
                if self.processedMessages.count > self.maxProcessedMessages {
                    let targetSize = Int(Double(self.maxProcessedMessages) * 0.8)
                    let sortedByFirstSeen = self.processedMessages.sorted { $0.value.firstSeen < $1.value.firstSeen }
                    let toKeep = Array(sortedByFirstSeen.suffix(targetSize))
                    self.processedMessages = Dictionary(uniqueKeysWithValues: toKeep)
                }
                
                let removedCount = originalCount - self.processedMessages.count
                self.processedMessagesLock.unlock()
                
                if removedCount > 0 {
                    SecureLogger.log("🧹 Cleaned up \(removedCount) old processed messages (kept \(self.processedMessages.count) from last 10 minutes)", 
                                    category: SecureLogger.session, level: .debug)
                }
            }
        }
        
        // Start stale peer cleanup timer (every 30 seconds)
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.cleanupStalePeers()
        }
        
        // Start more aggressive cleanup for Unknown peers (every 2 seconds)
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.cleanupUnknownPeers()
        }
        
        // Start ACK timeout checking timer (every 2 seconds for timely retries)
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkAckTimeouts()
        }
        
        // Start peer availability checking timer (every 15 seconds)
        availabilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.checkPeerAvailability()
        }
        
        // Start write queue cleanup timer (every 30 seconds)
        writeQueueTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.cleanExpiredWriteQueues()
        }
        
        // Start identity cache cleanup timer (every hour)
        Timer.scheduledTimer(withTimeInterval: 3600.0, repeats: true) { [weak self] _ in
            self?.cleanExpiredIdentityCache()
        }
        
        // Start memory cleanup timer (every minute)
        startMemoryCleanupTimer()
        
        // Start connection keep-alive timer to prevent iOS BLE timeouts
        connectionKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: keepAliveInterval, repeats: true) { [weak self] _ in
            self?.sendKeepAlivePings()
        }
        
        // Clean up stale handshake states periodically
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Clean up expired version cache
            self.cleanupExpiredVersionCache()
            
            // Clean up expired dedup entries
            self.cleanupExpiredDedupEntries()
            
            // Clean up stale handshakes
            let stalePeerIDs = self.handshakeCoordinator.cleanupStaleHandshakes()
            if !stalePeerIDs.isEmpty {
                for peerID in stalePeerIDs {
                    // Also remove from noise service
                    self.cleanupPeerCryptoState(peerID)
                    SecureLogger.log("Cleaned up stale handshake for peer: \(peerID)", 
                                   category: SecureLogger.handshake, level: .info)
                }
            }
            
            #if DEBUG
            self.handshakeCoordinator.logHandshakeStates()
            #endif
        }
        END OF OLD TIMER SETUP */
        
        // Schedule first peer ID rotation
        scheduleNextRotation()
        
        // Setup noise callbacks
        noiseService.onPeerAuthenticated = { [weak self] peerID, fingerprint in
            guard let self = self else { return }
            
            // Store fingerprint in PeerSession for fast lookups
            self.collectionsQueue.async(flags: .barrier) {
                if let session = self.peerSessions[peerID] {
                    session.fingerprint = fingerprint
                    session.updateAuthenticationState(authenticated: true, noiseSession: true)
                } else {
                    let nickname = self.getBestAvailableNickname(for: peerID)
                    let session = PeerSession(peerID: peerID, nickname: nickname)
                    session.fingerprint = fingerprint
                    session.updateAuthenticationState(authenticated: true, noiseSession: true)
                    self.peerSessions[peerID] = session
                }
            }
            
            // Get peer's public key data from noise service
            if let publicKeyData = self.noiseService.getPeerPublicKeyData(peerID) {
                // Register with ChatViewModel for verification tracking
                DispatchQueue.main.async {
                    (self.delegate as? ChatViewModel)?.registerPeerPublicKey(peerID: peerID, publicKeyData: publicKeyData)
                    
                    // Force UI to update encryption status for this specific peer
                    (self.delegate as? ChatViewModel)?.updateEncryptionStatusForPeer(peerID)
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
    
    // MARK: - Deinitialization and Cleanup
    
    deinit {
        cleanup()
        
        // Invalidate consolidated timers
        highFrequencyTimer?.invalidate()
        mediumFrequencyTimer?.invalidate()
        lowFrequencyTimer?.invalidate()
        
        // Invalidate other timers
        scanDutyCycleTimer?.invalidate()
        batteryMonitorTimer?.invalidate()
        bloomFilterResetTimer?.invalidate()
        aggregationTimer?.invalidate()
        cleanupTimer?.invalidate()
        rotationTimer?.invalidate()
        memoryCleanupTimer?.invalidate()
        connectionKeepAliveTimer?.invalidate()
        availabilityCheckTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func appWillTerminate() {
        cleanup()
    }
    
    // MARK: - Background Task Management
    
    #if os(iOS)
    private func beginBackgroundTask() -> UIBackgroundTaskIdentifier {
        return UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask(self?.backgroundTask ?? .invalid)
        }
    }
    
    private func endBackgroundTask(_ taskID: UIBackgroundTaskIdentifier) {
        if taskID != .invalid {
            UIApplication.shared.endBackgroundTask(taskID)
        }
    }
    
    private func beginScanBackgroundTask() {
        guard scanBackgroundTask == .invalid else { return }
        
        scanBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "BluetoothScan") { [weak self] in
            self?.endScanBackgroundTask()
        }
    }
    
    private func endScanBackgroundTask() {
        if scanBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(scanBackgroundTask)
            scanBackgroundTask = .invalid
        }
    }
    
    private func beginAdvertiseBackgroundTask() {
        guard advertiseBackgroundTask == .invalid else { return }
        
        advertiseBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "BluetoothAdvertise") { [weak self] in
            self?.endAdvertiseBackgroundTask()
        }
    }
    
    private func endAdvertiseBackgroundTask() {
        if advertiseBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(advertiseBackgroundTask)
            advertiseBackgroundTask = .invalid
        }
    }
    #endif
    
    // MARK: - App State Management
    
    private func setupAppStateNotifications() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        #elseif os(macOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
        #endif
    }
    
    @objc private func appDidBecomeActive() {
        isAppInForeground = true
        // App became active
    }
    
    @objc private func appWillResignActive() {
        isAppInForeground = false
        // App will resign active
    }
    
    @objc private func appDidEnterBackground() {
        isAppInForeground = false
        SecureLogger.log("[APP-STATE] App entered background - switching to background scanning mode", level: .info)
        
        #if os(iOS)
        // Begin background tasks for critical operations
        beginScanBackgroundTask()
        beginAdvertiseBackgroundTask()
        #endif
        
        // Switch to background scanning mode (continuous with battery-efficient options)
        switchToBackgroundScanning()
        
        // Update advertising for background mode
        updateAdvertisingForBackgroundMode()
    }
    
    @objc private func appWillEnterForeground() {
        isAppInForeground = true
        SecureLogger.log("[APP-STATE] App entering foreground - switching to foreground scanning mode", level: .info)
        
        #if os(iOS)
        // End background tasks as app is coming to foreground
        endScanBackgroundTask()
        endAdvertiseBackgroundTask()
        #endif
        
        // Switch to foreground scanning mode (with duty cycling)
        switchToForegroundScanning()
        
        // Update advertising for foreground mode
        updateAdvertisingForForegroundMode()
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
            // Clear isActivePeer flag for all sessions
            for session in self.peerSessions.values {
                session.isActivePeer = false
            }
        }
        // Note: PeerSession hasReceivedAnnounce states are cleared when sessions are removed
        // For normal disconnect, respect the timing
        networkBecameEmptyTime = Date()
        
        // Clear announcement tracking in PeerSessions
        collectionsQueue.sync(flags: .barrier) {
            for session in self.peerSessions.values {
                session.hasAnnounced = false
            }
        }
        
        // Clear last seen timestamps
        peerLastSeenTimestamps.removeAll()
        
        // Clear all encryption queues
        encryptionQueuesLock.lock()
        peerEncryptionQueues.removeAll()
        encryptionQueuesLock.unlock()
        
        // Clear peer tracking
        // Time tracking removed - now in PeerSession
        
    }
    
    // MARK: - Service Management
    
    /// Starts the Bluetooth mesh networking services.
    /// This initializes both central (scanning) and peripheral (advertising) modes,
    /// enabling the device to both discover peers and be discovered.
    /// Call this method after setting the delegate and localUserID.
    func startServices() {
        // Clean up any stale/ghost sessions from previous runs
        cleanupStaleSessions()
        cleanupUnknownPeers()
        
        // Report initial Bluetooth state to delegate
        if let chatViewModel = delegate as? ChatViewModel {
            // Use the central manager state as primary indicator
            let currentState = centralManager?.state ?? .unknown
            Task { @MainActor in
                chatViewModel.updateBluetoothState(currentState)
            }
        }
        
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
    }
    
    // MARK: - Consolidated Timer Management
    
    private func setupConsolidatedTimers() {
        // High-frequency timer (2s) - critical real-time tasks
        highFrequencyTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Critical real-time tasks that need frequent checking
            self.cleanupUnknownPeers()
            self.checkAckTimeouts()
        }
        
        // Medium-frequency timer (20s) - regular maintenance
        mediumFrequencyTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.mediumTimerTickCount += 1
            
            // Every 20s: Connection keep-alive
            self.sendKeepAlivePings()
            
            // Every 20s: Peer availability check
            self.checkPeerAvailability()
            
            // Every 40s (every 2 ticks): Stale peer cleanup & write queue cleanup
            if self.mediumTimerTickCount % 2 == 0 {
                self.cleanupStalePeers()
                self.cleanExpiredWriteQueues()
            }
        }
        
        // Low-frequency timer (5min) - cleanup and optimization
        lowFrequencyTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.lowTimerTickCount += 1
            
            // Every 5min: Bloom filter reset and processed message cleanup
            self.messageQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else { return }
                
                // Adapt Bloom filter size based on network size
                let networkSize = self.estimatedNetworkSize
                self.messageBloomFilter = OptimizedBloomFilter.adaptive(for: networkSize)
                
                // Clean up old processed messages (keep last 10 minutes of messages)
                self.processedMessagesLock.lock()
                let cutoffTime = Date().addingTimeInterval(-600) // 10 minutes ago
                let originalCount = self.processedMessages.count
                self.processedMessages = self.processedMessages.filter { _, state in
                    state.firstSeen > cutoffTime
                }
                
                // Also enforce max size limit during cleanup
                if self.processedMessages.count > self.maxProcessedMessages {
                    let targetSize = Int(Double(self.maxProcessedMessages) * 0.8)
                    let sortedByFirstSeen = self.processedMessages.sorted { $0.value.firstSeen < $1.value.firstSeen }
                    let toKeep = Array(sortedByFirstSeen.suffix(targetSize))
                    self.processedMessages = Dictionary(uniqueKeysWithValues: toKeep)
                }
                
                let removedCount = originalCount - self.processedMessages.count
                self.processedMessagesLock.unlock()
                
                if removedCount > 0 {
                    SecureLogger.log("🧹 Cleaned up \(removedCount) old processed messages (kept \(self.processedMessages.count) from last 10 minutes)", 
                                    category: SecureLogger.session, level: .debug)
                }
            }
            
            // Every 5min: Memory cleanup
            self.performMemoryCleanup()
            
            // Every 10min (every 2 ticks): Version cache and dedup cleanup
            if self.lowTimerTickCount % 2 == 0 {
                self.cleanupExpiredVersionCache()
                self.cleanupExpiredDedupEntries()
                
                // Clean up stale handshakes
                let stalePeerIDs = self.handshakeCoordinator.cleanupStaleHandshakes()
                if !stalePeerIDs.isEmpty {
                    for peerID in stalePeerIDs {
                        // Also remove from noise service
                        self.cleanupPeerCryptoState(peerID)
                        SecureLogger.log("Cleaned up stale handshake for peer: \(peerID)", 
                                       category: SecureLogger.handshake, level: .info)
                    }
                }
            }
            
            // Every 60min (every 12 ticks): Identity cache cleanup
            if self.lowTimerTickCount % 12 == 0 {
                self.cleanExpiredIdentityCache()
            }
        }
    }
    
    // MARK: - Message Sending
    
    func sendBroadcastAnnounce() {
        guard let vm = delegate as? ChatViewModel else { return }
        
        // Check for duplicate suppression
        let contentHash = vm.nickname.hashValue
        if shouldSuppressProtocolMessage(to: "broadcast", type: .announce, contentHash: contentHash) {
            return
        }
        
        let announcePacket = BitchatPacket(
            type: MessageType.announce.rawValue,
            ttl: 3,  // Increase TTL so announce reaches all peers
            senderID: myPeerID,
            payload: Data(vm.nickname.utf8)        )
        
        
        // Single send with smart collision avoidance
        let initialDelay = self.smartCollisionAvoidanceDelay(baseDelay: self.randomDelay())
        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
            self?.broadcastPacket(announcePacket)
            // Record that we sent this message
            self?.recordProtocolMessageSent(to: "broadcast", type: .announce, contentHash: contentHash)
            
            // Don't automatically send identity announcement on startup
            // Let it happen naturally when peers connect
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
    
    private func updateAdvertisingForBackgroundMode() {
        // Check if we should skip advertising in critically low battery
        if batteryOptimizer.currentPowerMode == .ultraLowPower && batteryOptimizer.batteryLevel < 0.1 {
            // Only skip advertising if battery is critically low (<10%)
            if isAdvertising {
                peripheralManager?.stopAdvertising()
                isAdvertising = false
                SecureLogger.log("⚡ Stopped advertising due to critically low battery", level: .info)
            }
            return
        }
        
        // Continue advertising in background mode with battery considerations
        if !isAdvertising && peripheralManager?.state == .poweredOn {
            startAdvertising()
            SecureLogger.log("[ADVERTISE] Continued advertising in background mode", level: .info)
        }
    }
    
    private func updateAdvertisingForForegroundMode() {
        // Always start advertising when in foreground if possible
        if !isAdvertising && peripheralManager?.state == .poweredOn {
            startAdvertising()
            SecureLogger.log("[ADVERTISE] Started advertising in foreground mode", level: .info)
        }
    }
    
    func startScanning() {
        guard centralManager?.state == .poweredOn else { 
            SecureLogger.log("[WARNING] Cannot start scanning - central manager not powered on", 
                           category: SecureLogger.session, level: .warning)
            return 
        }
        
        SecureLogger.log("[SCAN-START] Starting Bluetooth scanning for peripherals", 
                       category: SecureLogger.session, level: .info)
        
        // Optimize scan options based on foreground/background state
        // macOS fix: Always allow duplicates to ensure we catch all advertisements
        let scanOptions: [String: Any] = [
            CBCentralManagerScanOptionAllowDuplicatesKey: (isAppInForeground || getPlatformString() == "macOS") ? true : false
        ]
        
        centralManager?.scanForPeripherals(
            withServices: [BluetoothMeshService.serviceUUID],
            options: scanOptions
        )
        
        // Update scan parameters based on battery before starting
        updateScanParametersForBattery()
        
        // Implement scan duty cycling for battery efficiency (only in foreground)
        if isAppInForeground {
            scheduleScanDutyCycle()
        }
    }
    
    func triggerRescan() {
        guard centralManager?.state == .poweredOn else { return }
        
        // Rate limit rescans to prevent excessive battery drain
        let now = Date()
        guard now.timeIntervalSince(lastRescanTime) >= minRescanInterval else {
            SecureLogger.log("Skipping rescan - too soon after last rescan", category: SecureLogger.session, level: .debug)
            return
        }
        lastRescanTime = now
        
        // Stop and restart scanning to trigger new discoveries
        centralManager?.stopScan()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.startScanning()
        }
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
    
    /// Sends a message through the mesh network.
    /// - Parameters:
    ///   - content: The message content to send
    ///   - mentions: Array of user IDs being mentioned in the message
    ///   - recipientID: Optional recipient ID for directed messages (nil for broadcast)
    ///   - messageID: Optional custom message ID (auto-generated if nil)
    ///   - timestamp: Optional custom timestamp (current time if nil)
    /// - Note: Messages are automatically routed through the mesh using TTL-based forwarding
    func sendMessage(_ content: String, mentions: [String] = [], to recipientID: String? = nil, messageID: String? = nil, timestamp: Date? = nil) {
        // Defensive check for empty content
        guard !content.isEmpty else { return }
        
        #if os(iOS)
        let backgroundTask = beginBackgroundTask()
        #endif
        
        messageQueue.async { [weak self] in
            guard let self = self else {
                #if os(iOS)
                self?.endBackgroundTask(backgroundTask)
                #endif
                return
            }
            
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
                mentions: mentions.isEmpty ? nil : mentions
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
                    ttl: self.adaptiveTTL                )
                
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
                    
                    // Single send with smart collision avoidance
                    let initialDelay = self.smartCollisionAvoidanceDelay(baseDelay: self.randomDelay())
                    DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
                        self?.broadcastPacket(packet)
                        #if os(iOS)
                        self?.endBackgroundTask(backgroundTask)
                        #endif
                    }
                } else {
                    #if os(iOS)
                    self.endBackgroundTask(backgroundTask)
                    #endif
                }
            }
        }
    }
    
    
    /// Sends an end-to-end encrypted private message to a specific peer.
    /// - Parameters:
    ///   - content: The message content to encrypt and send
    ///   - recipientPeerID: The peer ID of the recipient
    ///   - recipientNickname: The nickname of the recipient (for UI display)
    ///   - messageID: Optional custom message ID (auto-generated if nil)
    /// - Note: This method automatically handles Noise handshake if not already established
    func sendPrivateMessage(_ content: String, to recipientPeerID: String, recipientNickname: String, messageID: String? = nil) {
        // Defensive checks
        guard !content.isEmpty, !recipientPeerID.isEmpty, !recipientNickname.isEmpty else { 
            return 
        }
        
        let msgID = messageID ?? UUID().uuidString
        
        #if os(iOS)
        let backgroundTask = beginBackgroundTask()
        #endif
        
        messageQueue.async { [weak self] in
            guard let self = self else {
                #if os(iOS)
                self?.endBackgroundTask(backgroundTask)
                #endif
                return
            }
            
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
            
            #if os(iOS)
            self.endBackgroundTask(backgroundTask)
            #endif
        }
    }
    
    func sendDeliveryAck(_ ack: DeliveryAck, to recipientID: String) {
        // Use per-peer encryption queue to prevent nonce desynchronization
        let encryptionQueue = getEncryptionQueue(for: recipientID)
        
        encryptionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Encode the ACK
            let ackData = ack.toBinaryData()
            
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
                        ttl: 3                    )
                    
                    // Try direct delivery first for delivery ACKs
                    if !self.sendDirectToRecipient(outerPacket, recipientPeerID: recipientID) {
                        // Recipient not directly connected, use selective relay
                        // Using relay for delivery ACK
                        self.sendViaSelectiveRelay(outerPacket, recipientPeerID: recipientID)
                    }
                } catch {
                    SecureLogger.logError(error, context: "Failed to encrypt delivery ACK via Noise for \(recipientID)", category: SecureLogger.encryption)
                }
            } else {
                // Lazy handshake: No session available, drop the ACK
                // No session for delivery ACK, dropping
            }
        }
    }
    
    private func getEncryptionQueue(for peerID: String) -> DispatchQueue {
        encryptionQueuesLock.lock()
        defer { encryptionQueuesLock.unlock() }
        
        if let queue = peerEncryptionQueues[peerID] {
            return queue
        }
        
        let queue = DispatchQueue(label: "bitchat.encryption.\(peerID)", qos: .userInitiated)
        peerEncryptionQueues[peerID] = queue
        return queue
    }
    
    private func removeEncryptionQueue(for peerID: String) {
        encryptionQueuesLock.lock()
        defer { encryptionQueuesLock.unlock() }
        
        peerEncryptionQueues.removeValue(forKey: peerID)
    }
    
    // Centralized cleanup for peer crypto state
    private func cleanupPeerCryptoState(_ peerID: String) {
        noiseService.removePeer(peerID)
        handshakeCoordinator.resetHandshakeState(for: peerID)
        removeEncryptionQueue(for: peerID)
    }
    
    func sendReadReceipt(_ receipt: ReadReceipt, to recipientID: String) {
        // Use per-peer encryption queue to prevent nonce desynchronization
        let encryptionQueue = getEncryptionQueue(for: recipientID)
        
        encryptionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Encode the receipt
            let receiptData = receipt.toBinaryData()
            
            // Check if we have a Noise session with this peer
            // Use noiseService directly
            if self.noiseService.hasEstablishedSession(with: recipientID) {
                // Use Noise encryption - encrypt only the receipt payload directly
                do {
                    // Create a special payload that indicates this is a read receipt
                    // Format: [1 byte type marker] + [receipt binary data]
                    var receiptPayload = Data()
                    receiptPayload.append(MessageType.readReceipt.rawValue) // Type marker
                    receiptPayload.append(receiptData) // Receipt binary data
                    
                    // Encrypt only the payload (not a full packet)
                    let encryptedPayload = try noiseService.encrypt(receiptPayload, for: recipientID)
                    
                    // Create outer Noise packet with the encrypted payload
                    let outerPacket = BitchatPacket(
                        type: MessageType.noiseEncrypted.rawValue,
                        senderID: Data(hexString: self.myPeerID) ?? Data(),
                        recipientID: Data(hexString: recipientID) ?? Data(),
                        timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                        payload: encryptedPayload,
                        signature: nil,
                        ttl: 3                    )
                    
                    // Sending encrypted read receipt
                    
                    // Try direct delivery first for read receipts
                    if !self.sendDirectToRecipient(outerPacket, recipientPeerID: recipientID) {
                        // Recipient not directly connected, use selective relay
                        SecureLogger.log("Recipient \(recipientID) not directly connected for read receipt, using relay", 
                                       category: SecureLogger.session, level: .info)
                        self.sendViaSelectiveRelay(outerPacket, recipientPeerID: recipientID)
                    }
                } catch {
                    SecureLogger.logError(error, context: "Failed to encrypt read receipt via Noise for \(recipientID)", category: SecureLogger.encryption)
                }
            } else {
                // Lazy handshake: No session available, drop the read receipt
                SecureLogger.log("No Noise session with \(recipientID) for read receipt - dropping (lazy handshake mode)", 
                               category: SecureLogger.noise, level: .info)
            }
        }
    }
    
    /// Send a favorite/unfavorite notification to a specific peer
    func sendFavoriteNotification(to peerID: String, isFavorite: Bool) {
        // Create notification payload with Nostr public key
        var content = isFavorite ? "SYSTEM:FAVORITED" : "SYSTEM:UNFAVORITED"
        
        // Add our Nostr public key if we have one
        if let myNostrIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() {
            // Include our Nostr npub in the message
            content += ":" + myNostrIdentity.npub
            SecureLogger.log("[NOSTR] Including our Nostr npub in favorite notification: \(myNostrIdentity.npub)", 
                            category: SecureLogger.session, level: .info)
        }
        
        SecureLogger.log("📤 Sending \(isFavorite ? "favorite" : "unfavorite") notification to \(peerID) via mesh", 
                        category: SecureLogger.session, level: .info)
        
        // Use existing message infrastructure
        if let recipientNickname = getPeerNicknames()[peerID] {
            sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname)
            SecureLogger.log("[SUCCESS] Sent favorite notification as private message", 
                            category: SecureLogger.session, level: .info)
        } else {
            SecureLogger.log("[ERROR] Failed to send favorite notification - peer not found", 
                            category: SecureLogger.session, level: .error)
        }
    }
    
    private func sendAnnouncementToPeer(_ peerID: String) {
        guard let vm = delegate as? ChatViewModel else { return }
        
        // Check for duplicate suppression
        let contentHash = vm.nickname.hashValue
        if shouldSuppressProtocolMessage(to: peerID, type: .announce, contentHash: contentHash) {
            return
        }
        
        // Always send announce, don't check if already announced
        // This ensures peers get our nickname even if they reconnect
        
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            ttl: 3,  // Allow relay for better reach
            senderID: myPeerID,
            payload: Data(vm.nickname.utf8)        )
        
        if let data = packet.toBinaryData() {
            // Try both broadcast and targeted send
            broadcastPacket(packet)
            
            // Also try targeted send if we have the peripheral
            if let peripheral = connectedPeripherals[peerID],
               peripheral.state == .connected,
               let characteristic = peripheral.services?.first(where: { $0.uuid == BluetoothMeshService.serviceUUID })?.characteristics?.first(where: { $0.uuid == BluetoothMeshService.characteristicUUID }) {
                writeToPeripheral(data, peripheral: peripheral, characteristic: characteristic, peerID: peerID)
            } else {
            }
        } else {
        }
        
        // Record that we sent this message
        recordProtocolMessageSent(to: peerID, type: .announce, contentHash: contentHash)
        
        // Update PeerSession
        collectionsQueue.sync(flags: .barrier) {
            if let session = self.peerSessions[peerID] {
                session.hasAnnounced = true
            } else {
                // Create session if it doesn't exist
                let nickname = self.getBestAvailableNickname(for: peerID)
                let session = PeerSession(peerID: peerID, nickname: nickname)
                session.hasAnnounced = true
                self.peerSessions[peerID] = session
            }
        }
    }
    
    private func sendLeaveAnnouncement() {
        guard let vm = delegate as? ChatViewModel else { return }
        
        let packet = BitchatPacket(
            type: MessageType.leave.rawValue,
            ttl: 1,  // Don't relay leave messages
            senderID: myPeerID,
            payload: Data(vm.nickname.utf8)        )
        
        broadcastPacket(packet)
    }
    
    // Get Noise session state for UI display
    func getNoiseSessionState(for peerID: String) -> LazyHandshakeState {
        return collectionsQueue.sync {
            // First check our tracked state
            if let state = noiseSessionStates[peerID] {
                return state
            }
            
            // If no tracked state, check if we have an established session
            if noiseService.hasEstablishedSession(with: peerID) {
                return .established
            }
            
            // Default to none
            return .none
        }
    }
    
    // Trigger handshake with a peer (for UI)
    func triggerHandshake(with peerID: String) {
        // UI triggered handshake
        
        // Check if we already have a session
        if noiseService.hasEstablishedSession(with: peerID) {
            // Already have session, skipping handshake
            return
        }
        
        // Update state to handshakeQueued
        collectionsQueue.sync(flags: .barrier) {
            noiseSessionStates[peerID] = .handshakeQueued
        }
        
        // Always initiate handshake when triggered by UI
        // This ensures immediate handshake when opening PM
        initiateNoiseHandshake(with: peerID)
    }
    
    func getPeerNicknames() -> [String: String] {
        return collectionsQueue.sync {
            var nicknames: [String: String] = [:]
            
            // Get nicknames from PeerSessions only (including disconnected ones)
            // This allows proper nickname resolution for reconnecting peers
            for (peerID, session) in self.peerSessions {
                // If we have an "Unknown" nickname, try to resolve a better one before returning
                if session.nickname == "Unknown" {
                    let betterNickname = getBestAvailableNickname(for: peerID)
                    if betterNickname != "Unknown" {
                        // Update the session with the better nickname
                        session.nickname = betterNickname
                        SecureLogger.log("Updated nickname for \(peerID) from 'Unknown' to '\(betterNickname)'", 
                                       category: SecureLogger.session, level: .info)
                    }
                }
                nicknames[peerID] = session.nickname
            }
            
            return nicknames
        }
    }
    
    func isPeerConnected(_ peerID: String) -> Bool {
        return collectionsQueue.sync {
            guard let session = self.peerSessions[peerID] else { return false }
            return session.isConnected && session.isActivePeer
        }
    }
    
    func isPeerKnown(_ peerID: String) -> Bool {
        return collectionsQueue.sync {
            guard let session = self.peerSessions[peerID] else { return false }
            return session.hasReceivedAnnounce
        }
    }
    
    // MARK: - Consolidated Peer Info Methods
    
    /// Get comprehensive peer info from PeerSession (replaces multiple dictionary lookups)
    func getPeerInfo(_ peerID: String) -> (nickname: String?, isActive: Bool, isAuthenticated: Bool) {
        return collectionsQueue.sync {
            if let session = peerSessions[peerID] {
                return (
                    nickname: session.nickname.isEmpty ? nil : session.nickname,
                    isActive: session.isActivePeer,
                    isAuthenticated: session.isAuthenticated
                )
            }
            // No session exists
            return (
                nickname: nil,
                isActive: false,
                isAuthenticated: false
            )
        }
    }
    
    /// Get all connected peers with their info
    func getAllConnectedPeers() -> [(peerID: String, nickname: String)] {
        return collectionsQueue.sync {
            var peers: [(String, String)] = []
            
            // Get all connected peers from PeerSessions
            for (peerID, session) in peerSessions where session.isConnected {
                peers.append((peerID, session.nickname))
            }
            
            return peers
        }
    }
    
    // Emergency disconnect for panic situations
    func emergencyDisconnectAll() {
        SecureLogger.log("Emergency disconnect triggered", category: SecureLogger.security, level: .warning)
        
        // Stop advertising immediately
        if peripheralManager?.isAdvertising == true {
            peripheralManager?.stopAdvertising()
        }
        
        // Stop scanning
        centralManager?.stopScan()
        scanDutyCycleTimer?.invalidate()
        scanDutyCycleTimer = nil
        
        // Disconnect all peripherals
        for (peerID, peripheral) in connectedPeripherals {
            SecureLogger.log("Emergency disconnect peer: \(peerID)", category: SecureLogger.session, level: .warning)
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        
        // Clear all peer data
        connectedPeripherals.removeAll()
        peripheralCharacteristics.removeAll()
        discoveredPeripherals.removeAll()
        subscribedCentrals.removeAll()
        // Clear all peer sessions on reset
        // Clear PeerSession states
        collectionsQueue.sync(flags: .barrier) {
            self.peerSessions.removeAll()
        }
        // For emergency/panic, reset immediately
        hasNotifiedNetworkAvailable = false
        networkBecameEmptyTime = nil
        lastNetworkNotificationTime = nil
        processedMessagesLock.lock()
        processedMessages.removeAll()
        processedMessagesLock.unlock()
        incomingFragments.removeAll()
        
        // Clear all encryption queues
        encryptionQueuesLock.lock()
        peerEncryptionQueues.removeAll()
        encryptionQueuesLock.unlock()
        fragmentMetadata.removeAll()
        
        // Cancel all pending relays
        pendingRelaysLock.lock()
        for (_, relay) in pendingRelays {
            relay.cancel()
        }
        pendingRelays.removeAll()
        pendingRelaysLock.unlock()
        
        // Clear peer tracking
        // Time tracking removed - now in PeerSession
        
        // Clear persistent identity
        noiseService.clearPersistentIdentity()
        
        // Clear all handshake coordinator states
        handshakeCoordinator.clearAllHandshakeStates()
        
        // Clear handshake attempt times
        handshakeAttemptTimes.removeAll()
        
        // Notify UI that all peers are disconnected
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didUpdatePeerList([])
        }
        
        // Restart services after a short delay to create new identity
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.restartAfterPanic()
        }
    }
    
    private func restartAfterPanic() {
        SecureLogger.log("Restarting mesh services after panic mode", category: SecureLogger.session, level: .info)
        
        // Regenerate peer ID with new identity
        myPeerID = generateNewPeerID()
        
        // Reset identity tracking since we have a new identity
        peerIDToFingerprint.removeAll()
        fingerprintToPeerID.removeAll()
        peerIdentityBindings.removeAll()
        
        // Reset rotation tracking
        rotationTimestamp = nil
        rotationLocked = false
        
        // Restart advertising if peripheral is powered on
        if peripheralManager?.state == .poweredOn {
            setupPeripheral()
            startAdvertising()
            
            // Send announce after restart with new identity
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.sendBroadcastAnnounce()
            }
        }
        
        // Restart scanning if central is powered on
        if centralManager?.state == .poweredOn {
            startScanning()
        }
        
        SecureLogger.log("Mesh services restarted with new peer ID: \(myPeerID)", category: SecureLogger.session, level: .info)
    }
    
    private func getAllConnectedPeerIDs() -> [String] {
        // Return all valid active peers
        let peersCopy = collectionsQueue.sync {
            return Array(self.peerSessions.compactMap { (peerID, session) in
                session.isActivePeer ? peerID : nil
            })
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
        let activePeerCount = collectionsQueue.sync { peerSessions.values.filter { $0.isActivePeer }.count }
        let connectedPeripheralCount = collectionsQueue.sync { connectedPeripherals.count }
        SecureLogger.log("[PEER-UPDATE] notifyPeerListUpdate called: immediate=\(immediate), activePeers=\(activePeerCount), connectedPeripherals=\(connectedPeripheralCount)", 
                       category: SecureLogger.session, level: .debug)
        
        if immediate {
            // For initial connections, update immediately
            let connectedPeerIDs = self.getAllConnectedPeerIDs()
            SecureLogger.log("[IMMEDIATE] Immediate update with peerIDs: \(connectedPeerIDs)", 
                           category: SecureLogger.session, level: .info)
            
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
    
    // Clean up expired version cache entries
    private func cleanupExpiredVersionCache() {
        let expiredPeers = versionCache.compactMap { (peerID, cached) in
            cached.isExpired ? peerID : nil
        }
        
        if !expiredPeers.isEmpty {
            for peerID in expiredPeers {
                versionCache.removeValue(forKey: peerID)
            }
            SecureLogger.log("🗑️ Cleaned up \(expiredPeers.count) expired version cache entries", 
                           category: SecureLogger.session, level: .debug)
        }
    }
    
    // Invalidate cached version for a peer (used on protocol errors)
    private func invalidateVersionCache(for peerID: String) {
        if versionCache.removeValue(forKey: peerID) != nil {
            SecureLogger.log("[ERROR] Invalidated cached version for \(peerID) due to protocol error", 
                           category: SecureLogger.session, level: .warning)
        }
        // Also clear negotiated version to force re-negotiation
        negotiatedVersions.removeValue(forKey: peerID)
        versionNegotiationState.removeValue(forKey: peerID)
    }
    
    // MARK: - Protocol Message Deduplication
    
    // Check if a protocol message should be suppressed as duplicate
    private func shouldSuppressProtocolMessage(to peerID: String, type: MessageType, contentHash: Int? = nil) -> Bool {
        let key = DedupKey(peerID: peerID, messageType: type, contentHash: contentHash)
        
        // Check if we have a recent entry
        if let entry = protocolMessageDedup[key], !isExpired(entry) {
            let timeSince = Date().timeIntervalSince(entry.sentAt)
            SecureLogger.log("[DEDUP] Suppressing duplicate \(type) to \(peerID) (sent \(String(format: "%.1f", timeSince))s ago)", 
                           category: SecureLogger.session, level: .debug)
            return true
        }
        
        return false
    }
    
    // Record that a protocol message was sent
    private func recordProtocolMessageSent(to peerID: String, type: MessageType, contentHash: Int? = nil) {
        guard let duration = dedupDurations[type] else { return }
        
        let key = DedupKey(peerID: peerID, messageType: type, contentHash: contentHash)
        let now = Date()
        let entry = DedupEntry(sentAt: now, expiresAt: now.addingTimeInterval(duration))
        
        protocolMessageDedup[key] = entry
    }
    
    // Check if a dedup entry is expired
    private func isExpired(_ entry: DedupEntry) -> Bool {
        return Date() > entry.expiresAt
    }
    
    // Clean up expired dedup entries
    private func cleanupExpiredDedupEntries() {
        let expiredKeys = protocolMessageDedup.compactMap { (key, entry) in
            isExpired(entry) ? key : nil
        }
        
        if !expiredKeys.isEmpty {
            for key in expiredKeys {
                protocolMessageDedup.removeValue(forKey: key)
            }
            SecureLogger.log("🗑️ Cleaned up \(expiredKeys.count) expired dedup entries", 
                           category: SecureLogger.session, level: .debug)
        }
    }
    
    // Clean up stale peers that haven't been seen in a while
    private func cleanupStalePeers() {
        // First clean up stale/ghost sessions
        cleanupStaleSessions()
        
        let staleThreshold: TimeInterval = 300.0 // 5 minutes - increased for better network stability
        let now = Date()
        
        // Clean up expired gracefully left peers
        let expiredGracefulPeers = gracefulLeaveTimestamps.filter { (_, timestamp) in
            now.timeIntervalSince(timestamp) > gracefulLeaveExpirationTime
        }.map { $0.key }
        
        for peerID in expiredGracefulPeers {
            gracefullyLeftPeers.remove(peerID)
            gracefulLeaveTimestamps.removeValue(forKey: peerID)
            SecureLogger.log("Cleaned up expired gracefullyLeft entry for \(peerID)", 
                           category: SecureLogger.session, level: .debug)
        }
        
        // Clean up old disconnect notifications
        let oldDisconnectNotifications = recentDisconnectNotifications.filter { (_, timestamp) in
            now.timeIntervalSince(timestamp) > 60.0  // Clean up after 1 minute
        }.map { $0.key }
        
        for peerID in oldDisconnectNotifications {
            recentDisconnectNotifications.removeValue(forKey: peerID)
        }
        
        // Clean up old version hello times
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            let oldVersionHellos = self.lastVersionHelloTime.filter { (_, timestamp) in
                now.timeIntervalSince(timestamp) > 60.0  // Clean up after 1 minute
            }.map { $0.key }
            
            for peerID in oldVersionHellos {
                self.lastVersionHelloTime.removeValue(forKey: peerID)
            }
        }
        
        // Clean up encryption queues for disconnected peers
        encryptionQueuesLock.lock()
        let disconnectedPeerQueues = peerEncryptionQueues.filter { peerID, _ in
            // Remove queue if peer is not connected
            let isConnected = connectedPeripherals[peerID]?.state == .connected
            return !isConnected
        }
        for (peerID, _) in disconnectedPeerQueues {
            peerEncryptionQueues.removeValue(forKey: peerID)
        }
        encryptionQueuesLock.unlock()
        
        let peersToRemove = collectionsQueue.sync(flags: .barrier) {
            let toRemove = self.peerSessions.compactMap { (peerID, session) -> String? in
                guard session.isActivePeer else { return nil }
                if let lastSeen = peerLastSeenTimestamps.get(peerID) {
                    return now.timeIntervalSince(lastSeen) > staleThreshold ? peerID : nil
                }
                return nil // Keep peers we haven't tracked yet
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
                
                let nickname = self.peerSessions[peerID]?.nickname ?? "unknown"
                // Mark as inactive in PeerSession
                if let session = self.peerSessions[peerID] {
                    session.isActivePeer = false
                }
                peerLastSeenTimestamps.remove(peerID)
                SecureLogger.log("📴 Removed stale peer from network: \(peerID) (\(nickname))", category: SecureLogger.session, level: .info)
                
                // Clean up all associated data
                connectedPeripherals.removeValue(forKey: peerID)
                // Update PeerSession
                if let session = self.peerSessions[peerID] {
                    session.hasReceivedAnnounce = false
                    session.hasAnnounced = false
                }
                // hasAnnounced already updated in PeerSession above
                // Time tracking removed - now in PeerSession
                
                actuallyRemoved.append(peerID)
                // Removed stale peer
            }
            return actuallyRemoved
        }
        
        if !peersToRemove.isEmpty {
            notifyPeerListUpdate()
            
            // Mark when network became empty, but don't reset flag immediately
            let currentNetworkSize = collectionsQueue.sync { 
                peerSessions.values.filter { $0.isActivePeer }.count 
            }
            if currentNetworkSize == 0 && networkBecameEmptyTime == nil {
                networkBecameEmptyTime = Date()
            }
        }
        
        // Check if we should reset the notification flag
        if let emptyTime = networkBecameEmptyTime {
            let currentNetworkSize = collectionsQueue.sync { 
                peerSessions.values.filter { $0.isActivePeer }.count 
            }
            if currentNetworkSize == 0 {
                // Network is still empty, check if enough time has passed
                let timeSinceEmpty = Date().timeIntervalSince(emptyTime)
                if timeSinceEmpty >= networkEmptyResetDelay {
                    // Reset the flag after network has been empty for the delay period
                    hasNotifiedNetworkAvailable = false
                    // Keep the empty time set so we don't immediately notify again
                }
            } else {
                // Network is no longer empty, clear the empty time
                networkBecameEmptyTime = nil
            }
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
                if let fingerprint = self.getPeerFingerprint(recipientPeerID) {
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
                
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak peripheral] in
                    guard let peripheral = peripheral,
                          peripheral.state == .connected else {
                        return
                    }
                    
                    // Send the original packet with preserved timestamp
                    let packetToSend = storedMessage.packet
                    
                    if let data = packetToSend.toBinaryData(),
                       characteristic.properties.contains(.writeWithoutResponse) {
                        self?.writeToPeripheral(data, peripheral: peripheral, characteristic: characteristic, peerID: peerID)
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
                    isPrivate: message.isPrivate,
                    recipientPeerID: nil,
                    recipientNickname: message.recipientNickname,
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
        
        // Track which peers we've sent to (to avoid duplicates)
        var sentToPeers = Set<String>()
        
        // Send to connected peripherals (as central)
        var sentToPeripherals = 0
        
        // Log if this is a private message being broadcast
        if packet.type == MessageType.noiseEncrypted.rawValue,
           let recipientID = packet.recipientID?.hexEncodedString(),
           !recipientID.isEmpty {
            SecureLogger.log("WARNING: Broadcasting private message intended for \(recipientID) to all peers", 
                           category: SecureLogger.session, level: .warning)
        }
        
        // Broadcasting to connected peripherals
        for (peerID, peripheral) in connectedPeripherals {
            if let characteristic = peripheralCharacteristics[peripheral] {
                // Check if peripheral is connected before writing
                if peripheral.state == .connected {
                    // Additional safety check for characteristic properties
                    if characteristic.properties.contains(.write) || 
                       characteristic.properties.contains(.writeWithoutResponse) {
                        // Writing packet to peripheral
                        writeToPeripheral(data, peripheral: peripheral, characteristic: characteristic, peerID: peerID)
                        sentToPeripherals += 1
                        sentToPeers.insert(peerID)
                    }
                } else {
                    if let peerID = connectedPeripherals.first(where: { $0.value == peripheral })?.key {
                        connectedPeripherals.removeValue(forKey: peerID)
                        peripheralCharacteristics.removeValue(forKey: peripheral)
                    }
                }
            }
        }
        
        // Send to subscribed centrals (as peripheral) - but only if we didn't already send via peripheral connections
        var sentToCentrals = 0
        if let char = characteristic, !subscribedCentrals.isEmpty && sentToPeripherals == 0 {
            // Only send to centrals if we haven't sent via peripheral connections
            // This prevents duplicate sends in 2-peer networks where peers connect both ways
            // Broadcasting to subscribed centrals
            let success = peripheralManager?.updateValue(data, for: char, onSubscribedCentrals: nil) ?? false
            if success {
                sentToCentrals = subscribedCentrals.count
            }
        } else if sentToPeripherals > 0 && !subscribedCentrals.isEmpty {
            // Skip central broadcast - already sent via peripherals
        }
        
        // If no peers received the message, add to retry queue ONLY if it's our own message
        if sentToPeripherals == 0 && sentToCentrals == 0 {
            // Check if this packet originated from us
            let senderID = packet.senderID.hexEncodedString()
            if senderID == self.myPeerID {
                // This is our own message that failed to send
                if packet.type == MessageType.message.rawValue,
                   let message = BitchatMessage.fromBinaryPayload(packet.payload) {
                    MessageRetryService.shared.addMessageForRetry(
                        content: message.content,
                        mentions: message.mentions,
                        isPrivate: message.isPrivate,
                        recipientPeerID: nil,
                        recipientNickname: message.recipientNickname,
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
            
            // Track that we heard from this peer
            let senderID = packet.senderID.hexEncodedString()
            if !senderID.isEmpty && senderID != self.myPeerID {
                // Update peer availability
                self.updatePeerAvailability(senderID)
                
                // IMPORTANT: Update peripheral mapping for ALL message types including handshakes
                // This ensures disconnect messages work even if peer disconnects right after handshake
                if let peripheral = peripheral {
                    let peripheralID = peripheral.identifier.uuidString
                    
                    // Check if we need to update the mapping
                    if peerIDByPeripheralID[peripheralID] != senderID {
                        SecureLogger.log("Updating peripheral mapping: \(peripheralID) -> \(senderID)", 
                                       category: SecureLogger.session, level: .debug)
                        peerIDByPeripheralID[peripheralID] = senderID
                        
                        // Also ensure connectedPeripherals has the correct mapping
                        // Remove any temp ID mapping if it exists
                        let tempIDToRemove = connectedPeripherals.first(where: { $0.value == peripheral && $0.key != senderID })?.key
                        if let tempID = tempIDToRemove {
                            SecureLogger.log("Removing temp ID mapping: \(tempID) -> \(peripheralID)", 
                                           category: SecureLogger.session, level: .debug)
                            connectedPeripherals.removeValue(forKey: tempID)
                            // Also remove any peer session created with temp ID
                            if peerSessions[tempID] != nil {
                                SecureLogger.log("Removing temp peer session for \(tempID)", 
                                               category: SecureLogger.session, level: .debug)
                                peerSessions.removeValue(forKey: tempID)
                            }
                        }
                        updatePeripheralConnection(senderID, peripheral: peripheral)
                        
                        // Update the peripheral mapping to use the real peer ID
                        updatePeripheralMapping(peripheralID: peripheralID, peerID: senderID)
                    }
                }
                
                // Check if this is a reconnection after a long silence
                let wasReconnection: Bool
                if let session = self.peerSessions[senderID] {
                    if let lastHeard = session.lastHeardFromPeer {
                        let timeSinceLastHeard = Date().timeIntervalSince(lastHeard)
                        wasReconnection = timeSinceLastHeard > 30.0
                    } else {
                        wasReconnection = true
                    }
                    session.lastHeardFromPeer = Date()
                } else {
                    // Don't create a session just from hearing a packet - wait for proper connection
                    wasReconnection = false
                }
                
                // If this is a reconnection, send our identity announcement
                if wasReconnection && packet.type != MessageType.noiseIdentityAnnounce.rawValue {
                    // Detected reconnection, sending identity
                    DispatchQueue.main.async { [weak self] in
                        self?.sendNoiseIdentityAnnounce(to: senderID)
                    }
                }
            }
            
            
            // Log specific Noise packet types
            
            guard packet.ttl > 0 else { 
                return 
            }
            
            // Validate packet has payload
            guard !packet.payload.isEmpty else {
                return
            }
            
            // Update last seen timestamp for this peer
            if senderID != "unknown" && senderID != self.myPeerID {
                peerLastSeenTimestamps.set(senderID, value: Date())
            }
            
            // Replay attack protection: Check timestamp is within reasonable window (5 minutes)
            let currentTime = UInt64(Date().timeIntervalSince1970 * 1000) // milliseconds
            let timeDiff = abs(Int64(currentTime) - Int64(packet.timestamp))
            if timeDiff > 300000 { // 5 minutes in milliseconds
                SecureLogger.log("Replay attack detected - timestamp from \(senderID)", category: SecureLogger.security, level: .warning)
                SecureLogger.log("Dropped message with stale timestamp. Age: \(timeDiff/1000)s from \(senderID)", category: SecureLogger.security, level: .warning)
                return
            }
            
            // Log message type for debugging
            let messageTypeName: String
            switch MessageType(rawValue: packet.type) {
            case .message:
                messageTypeName = "MESSAGE"
            case .protocolAck:
                messageTypeName = "PROTOCOL_ACK"
            case .protocolNack:
                messageTypeName = "PROTOCOL_NACK"
            case .noiseHandshakeInit:
                messageTypeName = "NOISE_HANDSHAKE_INIT"
            case .noiseHandshakeResp:
                messageTypeName = "NOISE_HANDSHAKE_RESP"
            case .noiseIdentityAnnounce:
                messageTypeName = "NOISE_IDENTITY_ANNOUNCE"
            case .noiseEncrypted:
                messageTypeName = "NOISE_ENCRYPTED"
            case .leave:
                messageTypeName = "LEAVE"
            case .readReceipt:
                messageTypeName = "READ_RECEIPT"
            case .versionHello:
                messageTypeName = "VERSION_HELLO"
            case .versionAck:
                messageTypeName = "VERSION_ACK"
            case .systemValidation:
                messageTypeName = "SYSTEM_VALIDATION"
            case .handshakeRequest:
                messageTypeName = "HANDSHAKE_REQUEST"
            default:
                messageTypeName = "UNKNOWN(\(packet.type))"
            }
            
            // Processing packet
            
            // Rate limiting check with message type awareness
            let isHighPriority = [MessageType.protocolAck.rawValue,
                                MessageType.protocolNack.rawValue,
                                MessageType.noiseHandshakeInit.rawValue,
                                MessageType.noiseHandshakeResp.rawValue,
                                MessageType.noiseIdentityAnnounce.rawValue,
                                MessageType.leave.rawValue].contains(packet.type)
            
            
            if senderID != self.myPeerID && isRateLimited(peerID: senderID, messageType: packet.type) {
                if !isHighPriority {
                    SecureLogger.log("RATE_LIMITED: Dropped \(messageTypeName) from \(senderID)", 
                                   category: SecureLogger.security, level: .warning)
                    return
                } else {
                    SecureLogger.log("RATE_LIMITED: Allowing high-priority \(messageTypeName) from \(senderID)", 
                                   category: SecureLogger.security, level: .info)
                }
            }
            
            // Record message for rate limiting based on type
            if senderID != self.myPeerID && !isHighPriority {
                recordMessage(from: senderID, messageType: packet.type)
            }
        
        // Content-based duplicate detection using packet ID
        let messageID = generatePacketID(for: packet)
        
        // Check if we've seen this exact message before
        processedMessagesLock.lock()
        if let existingState = processedMessages[messageID] {
            // Update the state
            var updatedState = existingState
            updatedState.updateSeen()
            processedMessages[messageID] = updatedState
            processedMessagesLock.unlock()
            
            // Dropped duplicate message
            // Cancel any pending relay for this message
            cancelPendingRelay(messageID: messageID)
            return
        }
        processedMessagesLock.unlock()
        
        // Use bloom filter for efficient duplicate detection
        if messageBloomFilter.contains(messageID) {
            // Double check with exact set (bloom filter can have false positives)
            processedMessagesLock.lock()
            let isProcessed = processedMessages[messageID] != nil
            processedMessagesLock.unlock()
            if !isProcessed {
                // Bloom filter false positive
            }
        }
        
        // Record this message as processed
        messageBloomFilter.insert(messageID)
        processedMessagesLock.lock()
        processedMessages[messageID] = MessageState(
            firstSeen: Date(),
            lastSeen: Date(),
            seenCount: 1,
            relayed: false,
            acknowledged: false
        )
        
        // Prune old entries if needed (more efficient approach)
        if processedMessages.count > maxProcessedMessages {
            // Remove oldest 20% to avoid frequent pruning
            let targetSize = Int(Double(maxProcessedMessages) * 0.8)
            let cutoffTime = Date().addingTimeInterval(-3600) // 1 hour ago
            
            // First try removing old messages
            processedMessages = processedMessages.filter { _, state in
                state.firstSeen > cutoffTime
            }
            
            // If still too many, remove oldest entries
            if processedMessages.count > targetSize {
                let sortedByFirstSeen = processedMessages.sorted { $0.value.firstSeen < $1.value.firstSeen }
                let toKeep = Array(sortedByFirstSeen.suffix(targetSize))
                processedMessages = Dictionary(uniqueKeysWithValues: toKeep)
            }
        }
        processedMessagesLock.unlock()
        
        
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
                            // Update PeerSession
                            if let session = self.peerSessions[senderID] {
                                session.nickname = message.sender
                            } else {
                                let session = PeerSession(peerID: senderID, nickname: message.sender)
                                self.peerSessions[senderID] = session
                            }
                        }
                        
                        let finalContent = message.content
                        
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
                            mentions: message.mentions
                        )
                        
                        // Track last message time from this peer
                        let peerID = packet.senderID.hexEncodedString()
                        self.lastMessageFromPeer.set(peerID, value: Date())
                        
                        DispatchQueue.main.async {
                            self.delegate?.didReceiveMessage(messageWithPeerID)
                        }
                        
                    }
                    
                    // Relay broadcast messages
                    var relayPacket = packet
                    relayPacket.ttl -= 1
                    if relayPacket.ttl > 0 {
                        // Use adaptive relay probability directly
                        let relayProb = self.adaptiveRelayProbability
                        
                        // Relay based on probability only - no TTL boost if base probability is 0
                        let effectiveProb = relayProb > 0 ? relayProb : 0.0
                        let shouldRelay = effectiveProb > 0 && Double.random(in: 0...1) < effectiveProb
                        
                        if shouldRelay {
                            // Relaying broadcast
                            // High priority messages relay immediately, others use exponential delay
                            if self.isHighPriorityMessage(type: relayPacket.type) {
                                self.broadcastPacket(relayPacket)
                            } else {
                                let delay = self.exponentialRelayDelay()
                                self.scheduleRelay(relayPacket, messageID: messageID, delay: delay)
                            }
                        } else {
                            // Dropped broadcast relay
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
                        
                        // Check if this is a favorite/unfavorite notification
                        if message.content.hasPrefix("SYSTEM:FAVORITED") || message.content.hasPrefix("SYSTEM:UNFAVORITED") {
                            let parts = message.content.split(separator: ":")
                            let isFavorite = parts.count >= 2 && parts[0] == "SYSTEM" && parts[1] == "FAVORITED"
                            let action = isFavorite ? "favorited" : "unfavorited"
                            let nostrNpub = parts.count > 2 ? String(parts[2]) : nil
                            
                            SecureLogger.log("[NOTIFICATION] Received \(action) notification from \(senderID)", category: SecureLogger.session, level: .info)
                            if nostrNpub != nil {
                                // Peer's Nostr npub recorded
                            }
                            
                            // Handle favorite notification
                            DispatchQueue.main.async {
                                Task { @MainActor in
                                    let vm = self.delegate as? ChatViewModel
                                    let nickname = message.sender
                                    
                                    if isFavorite {
                                        vm?.handlePeerFavoritedUs(peerID: senderID, favorited: true, nickname: nickname, nostrNpub: nostrNpub)
                                    } else {
                                        vm?.handlePeerFavoritedUs(peerID: senderID, favorited: false, nickname: nickname, nostrNpub: nostrNpub)
                                    }
                                    
                                    // Send system message to user
                                    let systemMessage = BitchatMessage(
                                        sender: "system",
                                        content: "\(nickname) \(action) you.",
                                        timestamp: Date(),
                                        isRelay: false
                                    )
                                    self.delegate?.didReceiveMessage(systemMessage)
                                }
                            }
                            return
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
                            if self.peerSessions[senderID] == nil {
                                let session = PeerSession(peerID: senderID, nickname: message.sender)
                                self.peerSessions[senderID] = session
                            } else if self.peerSessions[senderID]?.nickname == "Unknown" {
                                self.peerSessions[senderID]?.nickname = message.sender
                            }
                            
                            // PeerSession already updated if nickname not set
                            if let session = self.peerSessions[senderID] {
                                if session.nickname.isEmpty || session.nickname == "Unknown" {
                                    session.nickname = message.sender
                                }
                            } else {
                                let session = PeerSession(peerID: senderID, nickname: message.sender)
                                self.peerSessions[senderID] = session
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
                        SecureLogger.log("Failed to parse private message from binary, size: \(decryptedPayload.count)", category: SecureLogger.encryption, level: .error)
                    }
                    
                } else if packet.ttl > 0 {
                    // RELAY PRIVATE MESSAGE (not for us)
                    var relayPacket = packet
                    relayPacket.ttl -= 1
                    
                    // Check if this message is for an offline favorite and cache it
                    let recipientIDString = recipientID.hexEncodedString()
                    if let fingerprint = self.getPeerFingerprint(recipientIDString) {
                        // Only cache if recipient is a favorite AND is currently offline
                        let isActive = self.peerSessions[recipientIDString]?.isActivePeer ?? false
                        if (self.delegate?.isFavorite(fingerprint: fingerprint) ?? false) && !isActive {
                            self.cacheMessage(relayPacket, messageID: messageID)
                        }
                    }
                    
                    // Private messages are important - use relay with boost
                    let baseProb = min(self.adaptiveRelayProbability + 0.15, 1.0)  // Boost by 15%
                    let relayProb = baseProb
                    
                    // Relay based on probability only - no forced relay for small networks
                    let shouldRelay = Double.random(in: 0...1) < relayProb
                    
                    if shouldRelay {
                        // High priority messages relay immediately, others use exponential delay
                        if self.isHighPriorityMessage(type: relayPacket.type) {
                            self.broadcastPacket(relayPacket)
                        } else {
                            let delay = self.exponentialRelayDelay()
                            self.scheduleRelay(relayPacket, messageID: messageID, delay: delay)
                        }
                    }
                } else {
                    // Message has recipient ID but not for us and TTL is 0
                    // Message not for us - will be relayed if TTL > 0
                }
            } else {
                // No recipient ID - this shouldn't happen for messages
                SecureLogger.log("Message packet with no recipient ID from \(senderID)", category: SecureLogger.security, level: .warning)
            }
            
        // Note: 0x02 was legacy keyExchange - removed
            
        case .announce:
            if let rawNickname = String(data: packet.payload, encoding: .utf8) {
                // Trim whitespace from received nickname
                let nickname = rawNickname.trimmingCharacters(in: .whitespacesAndNewlines)
                let senderID = packet.senderID.hexEncodedString()
                
                // Received announce from peer
                
                // Ignore if it's from ourselves (including previous peer IDs)
                if isPeerIDOurs(senderID) {
                    return
                }
                
                // Check if we've already announced this peer
                let isFirstAnnounce = collectionsQueue.sync {
                    if let session = self.peerSessions[senderID] {
                        return !session.hasReceivedAnnounce
                    } else {
                        return true
                    }
                }
                
                // Check if this is a reconnection after disconnect
                let wasDisconnected = collectionsQueue.sync {
                    if let session = self.peerSessions[senderID] {
                        return !session.isConnected && !session.isActivePeer && session.hasReceivedAnnounce
                    }
                    return false
                }
                
                // Clean up stale peer IDs with the same nickname
                collectionsQueue.sync(flags: .barrier) {
                    var stalePeerIDs: [String] = []
                    for (existingPeerID, existingSession) in self.peerSessions {
                        if existingSession.nickname == nickname && existingPeerID != senderID {
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
                        self.peerSessions.removeValue(forKey: stalePeerID)
                        
                        // Mark as inactive in PeerSession
                        if let session = self.peerSessions[stalePeerID] {
                            session.isActivePeer = false
                        }
                        
                        // Remove from announced peers
                        // Update PeerSession for stale peer
                        if let session = self.peerSessions[stalePeerID] {
                            session.hasReceivedAnnounce = false
                            session.hasAnnounced = false
                        }
                        
                        // Clear tracking data - now handled by removing PeerSession
                        
                        // Disconnect any peripherals associated with stale ID
                        if let peripheral = self.connectedPeripherals[stalePeerID] {
                            self.intentionalDisconnects.insert(peripheral.identifier.uuidString)
                            self.centralManager?.cancelPeripheralConnection(peripheral)
                            self.connectedPeripherals.removeValue(forKey: stalePeerID)
                            self.peripheralCharacteristics.removeValue(forKey: peripheral)
                        }
                        
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
                    
                    // Only update peer session if we already have one (from a real connection)
                    // Don't create sessions from relayed announces
                    if let session = self.peerSessions[senderID] {
                        session.nickname = nickname
                        session.hasReceivedAnnounce = true
                        session.lastSeen = Date()
                        
                        // Check if this peer's noise public key has an existing favorite with a different nickname
                        if let noisePublicKey = Data(hexString: senderID) {
                            DispatchQueue.main.async {
                                FavoritesPersistenceService.shared.updateNickname(for: noisePublicKey, newNickname: nickname)
                            }
                        }
                    }
                    // Note: We'll create the session later if the peer passes the peripheral connection check
                }
                
                // Update peripheral mapping if we have it
                // If peripheral is nil (e.g., from relay), try to find it
                var peripheralToUpdate = peripheral
                if peripheralToUpdate == nil {
                    // Look for any peripheral that might be this peer
                    // First check if we already have a mapping for this peer ID
                    peripheralToUpdate = self.connectedPeripherals[senderID]
                    
                    if peripheralToUpdate == nil {
                        // No peripheral mapping found
                        
                        // Try to find an unidentified peripheral that might be this peer
                        // This handles case where announce is relayed and we need to update peripheral mapping
                        var unmappedPeripherals: [(String, CBPeripheral)] = []
                        for (tempID, peripheral) in self.connectedPeripherals {
                            // Check if this is a temp ID (UUID format, not a peer ID)
                            if tempID.count == 36 && tempID.contains("-") { // UUID length with dashes
                                unmappedPeripherals.append((tempID, peripheral))
                                // Found unmapped peripheral
                            }
                        }
                        
                        // If we have exactly one unmapped peripheral, it's likely this one
                        if unmappedPeripherals.count == 1 {
                            let (tempID, peripheral) = unmappedPeripherals[0]
                            // Mapping peripheral to sender
                            peripheralToUpdate = peripheral
                            
                            // Remove temp mapping and add real mapping
                            self.connectedPeripherals.removeValue(forKey: tempID)
                            self.updatePeripheralConnection(senderID, peripheral: peripheral)
                            
                        } else if unmappedPeripherals.count > 1 {
                            // Multiple unmapped peripherals
                            // TODO: Could use timing heuristics or other methods to match
                        }
                    }
                }
                
                if let peripheral = peripheralToUpdate {
                    let peripheralID = peripheral.identifier.uuidString
                    SecureLogger.log("Updating peripheral \(peripheralID) mapping to peer ID \(senderID)", 
                                   category: SecureLogger.session, level: .info)
                    
                    // Update simplified mapping
                    updatePeripheralMapping(peripheralID: peripheralID, peerID: senderID)
                    
                    // Find and remove any temp ID mapping for this peripheral
                    var tempIDToRemove: String? = nil
                    for (id, per) in self.connectedPeripherals {
                        if per == peripheral && id != senderID && id == peripheralID {
                            tempIDToRemove = id
                            break
                        }
                    }
                    
                    if let tempID = tempIDToRemove {
                        
                        // IMPORTANT: Mark old peer ID as inactive to prevent duplicates
                        collectionsQueue.sync(flags: .barrier) {
                            if let session = self.peerSessions[tempID], session.isActivePeer {
                                session.isActivePeer = false
                            }
                        }
                        
                        // Don't notify about disconnect - this is just cleanup of temporary ID
                    } else {
                        // Direct mapping peripheral
                        // No temp ID found, just add the mapping
                        self.updatePeripheralConnection(senderID, peripheral: peripheral)
                        self.peerIDByPeripheralID[peripheral.identifier.uuidString] = senderID
                        
                        
                        // If peer was previously relay-connected, update to direct connection
                        if let session = self.peerSessions[senderID], !session.isConnected && session.hasReceivedAnnounce {
                            SecureLogger.log("Upgrading peer \(senderID) from relay to direct connection", 
                                           category: SecureLogger.session, level: .info)
                            session.isConnected = true
                            session.updateBluetoothConnection(peripheral: peripheral, characteristic: nil)
                            
                        }
                    }
                }
                
                // Add to active peers if not already there
                if senderID != "unknown" && senderID != self.myPeerID {
                    // Check for duplicate nicknames and remove old peer IDs
                    collectionsQueue.sync(flags: .barrier) {
                        // Find any existing peers with the same nickname
                        var oldPeerIDsToRemove: [String] = []
                        for (existingPeerID, session) in self.peerSessions {
                            if existingPeerID != senderID && session.isActivePeer {
                                let existingNickname = session.nickname
                                if existingNickname == nickname && !existingNickname.isEmpty && existingNickname != "unknown" {
                                    oldPeerIDsToRemove.append(existingPeerID)
                                }
                            }
                        }
                        
                        // Remove old peer IDs with same nickname
                        for oldPeerID in oldPeerIDsToRemove {
                            // Remove the entire session for duplicate nicknames
                            self.peerSessions.removeValue(forKey: oldPeerID)
                            self.connectedPeripherals.removeValue(forKey: oldPeerID)
                            
                            // Don't notify about disconnect - this is just cleanup of duplicate
                        }
                    }
                    
                    var wasUpgradedFromRelay = false
                    
                    // Check if we have a peripheral connection before sync block
                    let hasPeripheralConnection = self.connectedPeripherals[senderID] != nil || 
                                                (peripheral != nil && peripheral?.state == .connected)
                    
                    let wasInserted = collectionsQueue.sync(flags: .barrier) {
                        // Final safety check
                        if senderID == self.myPeerID {
                            SecureLogger.log("Blocked self from being marked as active", category: SecureLogger.noise, level: .error)
                            return false
                        }
                        
                        // Check if we should mark as active despite no peripheral
                        // This can happen during reconnection when announces arrive before peripheral mapping
                        let shouldMarkActive: Bool
                        
                        if hasPeripheralConnection {
                            shouldMarkActive = true
                        } else {
                            // Check if we recently had activity suggesting a direct connection
                            let recentVersionHello = (self.lastVersionHelloTime[senderID] != nil && 
                                                   Date().timeIntervalSince(self.lastVersionHelloTime[senderID]!) < 5.0)
                            
                            // Check for unmapped peripherals
                            var hasUnmappedPeripheral = false
                            for (tempID, _) in self.connectedPeripherals {
                                if tempID.count == 36 && tempID.contains("-") { // UUID format
                                    hasUnmappedPeripheral = true
                                    break
                                }
                            }
                            
                            if recentVersionHello || hasUnmappedPeripheral {
                                SecureLogger.log("Marking \(senderID) as active despite no peripheral - recent version hello or unmapped peripheral exists", 
                                               category: SecureLogger.session, level: .info)
                                shouldMarkActive = true
                                
                                // Trigger a rescan to establish peripheral mapping
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                                    SecureLogger.log("Triggering rescan to find peripheral for \(senderID)", 
                                                   category: SecureLogger.session, level: .info)
                                    self?.triggerRescan()
                                }
                            } else {
                                SecureLogger.log("[WARNING] Not marking \(senderID) as active - no peripheral connection and no recent activity", 
                                               category: SecureLogger.session, level: .warning)
                                // Still update/create session to track the peer, but don't mark as connected
                                if let session = self.peerSessions[senderID] {
                                    session.nickname = nickname  // Update nickname from announce
                                    session.hasReceivedAnnounce = true
                                    session.lastSeen = Date()
                                    // Don't set isConnected or isActivePeer without peripheral
                                    SecureLogger.log("[RELAY-SESSION] Updated relay-only session for \(senderID) (\(nickname))", 
                                                   category: SecureLogger.session, level: .info)
                                } else {
                                    // Create new session but not connected
                                    let session = PeerSession(peerID: senderID, nickname: nickname)
                                    session.hasReceivedAnnounce = true
                                    session.lastSeen = Date()
                                    // Don't set isConnected or isActivePeer without peripheral
                                    self.peerSessions[senderID] = session
                                    SecureLogger.log("[NEW-RELAY] Created new relay-only session for \(senderID) (\(nickname))", 
                                                   category: SecureLogger.session, level: .info)
                                }
                                shouldMarkActive = false
                            }
                        }
                        
                        if !shouldMarkActive {
                            return false
                        }
                        
                        let result: Bool
                        
                        if let session = self.peerSessions[senderID] {
                            // Check if we're upgrading from relay-only to direct connection
                            wasUpgradedFromRelay = !session.isConnected && session.hasReceivedAnnounce
                            
                            result = !session.isActivePeer
                            session.isActivePeer = true
                            session.isConnected = true
                            session.nickname = nickname  // Update nickname from announce
                            session.hasReceivedAnnounce = true
                            session.lastSeen = Date()
                            if let peripheral = peripheral {
                                session.updateBluetoothConnection(peripheral: peripheral, characteristic: nil)
                            }
                        } else {
                            // Create new session with the nickname from the announce
                            let session = PeerSession(peerID: senderID, nickname: nickname)
                            session.isActivePeer = true
                            session.isConnected = true
                            session.hasReceivedAnnounce = true
                            session.lastSeen = Date()
                            if let peripheral = peripheral {
                                session.updateBluetoothConnection(peripheral: peripheral, characteristic: nil)
                            }
                            self.peerSessions[senderID] = session
                            result = true
                        }
                        
                        return result
                    }
                    if wasInserted {
                        SecureLogger.log("[JOINED] Peer joined network: \(senderID) (\(nickname))", category: SecureLogger.session, level: .info)
                    }
                    
                    // Show join message only once per peer connection session
                    // For direct connections: show on first announce with peripheral
                    // For relay connections: show on first announce when no peripheral available
                    let shouldShowConnectMessage = (isFirstAnnounce && wasInserted) || 
                                                 (wasDisconnected && hasPeripheralConnection)
                    
                    SecureLogger.log("[CONNECT-CHECK] Connect message check for \(senderID): isFirstAnnounce=\(isFirstAnnounce), wasInserted=\(wasInserted), wasDisconnected=\(wasDisconnected), hasPeripheralConnection=\(hasPeripheralConnection), shouldShow=\(shouldShowConnectMessage)", 
                                   category: SecureLogger.session, level: .debug)
                    
                    if shouldShowConnectMessage {
                        if wasUpgradedFromRelay {
                            SecureLogger.log("[UPGRADE] Peer upgraded from relay to direct: \(senderID) (\(nickname))", 
                                           category: SecureLogger.session, level: .info)
                        } else if wasDisconnected {
                            SecureLogger.log("[RECONNECT] Peer reconnected: \(senderID) (\(nickname))", 
                                           category: SecureLogger.session, level: .info)
                        }
                        
                        // Delay the connect message slightly to allow identity announcement to be processed
                        // This helps ensure fingerprint mappings are available for nickname resolution
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            SecureLogger.log("[NOTIFY] Sending connected notification for \(senderID)", 
                                           category: SecureLogger.session, level: .info)
                            self.delegate?.didConnectToPeer(senderID)
                        }
                        self.notifyPeerListUpdate(immediate: true)
                        
                        // Send network available notification if appropriate
                        let currentNetworkSize = collectionsQueue.sync { 
                            self.peerSessions.values.filter { $0.isActivePeer }.count 
                        }
                        if currentNetworkSize > 0 {
                            // Clear empty time since network is active
                            networkBecameEmptyTime = nil
                            
                            if !hasNotifiedNetworkAvailable {
                                // Check if enough time has passed since last notification
                                let now = Date()
                                var shouldSendNotification = true
                                
                                if let lastNotification = lastNetworkNotificationTime {
                                    let timeSinceLastNotification = now.timeIntervalSince(lastNotification)
                                    if timeSinceLastNotification < networkNotificationCooldown {
                                        // Too soon to send another notification
                                        shouldSendNotification = false
                                    }
                                }
                                
                                if shouldSendNotification {
                                    hasNotifiedNetworkAvailable = true
                                    lastNetworkNotificationTime = now
                                    NotificationService.shared.sendNetworkAvailableNotification(peerCount: currentNetworkSize)
                                }
                            }
                        }
                        
                        DispatchQueue.main.async {
                            // Check if this is a favorite peer and send notification
                            // Note: This might not work immediately if key exchange hasn't happened yet
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                                guard let self = self else { return }
                                
                                // Check if this is a favorite using their public key fingerprint
                                if let fingerprint = self.getPeerFingerprint(senderID) {
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
                }
                
                // Relay announce if TTL > 0
                if packet.ttl > 1 {
                    var relayPacket = packet
                    relayPacket.ttl -= 1
                    
                    // Add small delay to prevent collision
                    let delay = Double.random(in: 0.1...0.3)
                    self.scheduleRelay(relayPacket, messageID: messageID, delay: delay)
                }
            }
            
        case .leave:
            let senderID = packet.senderID.hexEncodedString()
            // Legacy peer disconnect (keeping for backwards compatibility)
            if String(data: packet.payload, encoding: .utf8) != nil {
                // Remove from active peers with proper locking
                collectionsQueue.sync(flags: .barrier) {
                    let wasRemoved = self.peerSessions[senderID]?.isActivePeer == true
                    let nickname = self.peerSessions.removeValue(forKey: senderID)?.nickname ?? "unknown"
                    
                    if wasRemoved {
                        // Mark as gracefully left to prevent duplicate disconnect message
                        self.gracefullyLeftPeers.insert(senderID)
                        self.gracefulLeaveTimestamps[senderID] = Date()
                        
                        // Update PeerSession to reflect disconnect
                        if let session = self.peerSessions[senderID] {
                            session.isActivePeer = false
                            session.isConnected = false
                            session.updateBluetoothConnection(peripheral: nil, characteristic: nil)
                            session.updateAuthenticationState(authenticated: false, noiseSession: false)
                        }
                        
                        SecureLogger.log("📴 Peer left network: \(senderID) (\(nickname)) - marked as gracefully left", category: SecureLogger.session, level: .info)
                    }
                }
                
                // Update PeerSession
                collectionsQueue.sync(flags: .barrier) {
                    if let session = self.peerSessions[senderID] {
                        session.hasReceivedAnnounce = false
                        session.isActivePeer = false
                        session.isConnected = false
                    }
                }
                
                // Show disconnect message immediately when peer leaves
                DispatchQueue.main.async {
                    self.delegate?.didDisconnectFromPeer(senderID)
                }
                self.notifyPeerListUpdate()
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
                let delay = self.exponentialRelayDelay()
                self.scheduleRelay(relayPacket, messageID: messageID, delay: delay)
            }
            
            
        case .deliveryAck:
            // Handle delivery acknowledgment
            if let recipientIDData = packet.recipientID,
               isPeerIDOurs(recipientIDData.hexEncodedString()) {
                // This ACK is for us
                let senderID = packet.senderID.hexEncodedString()
                // Check if payload is already decrypted (came through Noise)
                    if let ack = DeliveryAck.fromBinaryData(packet.payload) {
                        // Already decrypted - process directly
                        DeliveryTracker.shared.processDeliveryAck(ack)
                        
                        
                        // Notify delegate
                        DispatchQueue.main.async {
                            self.delegate?.didReceiveDeliveryAck(ack)
                        }
                    } else if let ack = DeliveryAck.decode(from: packet.payload) {
                        // Fallback to JSON for backward compatibility
                        DeliveryTracker.shared.processDeliveryAck(ack)
                        
                        // Notify delegate
                        DispatchQueue.main.async {
                            self.delegate?.didReceiveDeliveryAck(ack)
                        }
                    } else {
                        // Try legacy decryption
                        do {
                            let decryptedData = try noiseService.decrypt(packet.payload, from: senderID)
                            if let ack = DeliveryAck.fromBinaryData(decryptedData) {
                                // Process the ACK
                                DeliveryTracker.shared.processDeliveryAck(ack)
                                
                                
                                // Notify delegate
                                DispatchQueue.main.async {
                                    self.delegate?.didReceiveDeliveryAck(ack)
                                }
                            } else if let ack = DeliveryAck.decode(from: decryptedData) {
                                // Fallback to JSON
                                DeliveryTracker.shared.processDeliveryAck(ack)
                                
                                // Notify delegate
                                DispatchQueue.main.async {
                                    self.delegate?.didReceiveDeliveryAck(ack)
                                }
                            }
                        } catch {
                            SecureLogger.log("Failed to decrypt delivery ACK from \(senderID): \(error)", 
                                             category: SecureLogger.encryption, level: .error)
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
                let delay = self.exponentialRelayDelay()
                self.scheduleRelay(relayPacket, messageID: messageID, delay: delay)
            }
            
        case .readReceipt:
            // Handle read receipt
            if let recipientIDData = packet.recipientID,
               isPeerIDOurs(recipientIDData.hexEncodedString()) {
                // This read receipt is for us
                let senderID = packet.senderID.hexEncodedString()
                // Received read receipt
                // Check if payload is already decrypted (came through Noise)
                    if let receipt = ReadReceipt.fromBinaryData(packet.payload) {
                        // Already decrypted - process directly
                        // Processing read receipt
                        DispatchQueue.main.async {
                            self.delegate?.didReceiveReadReceipt(receipt)
                        }
                    } else if let receipt = ReadReceipt.decode(from: packet.payload) {
                        // Fallback to JSON for backward compatibility
                        // Processing read receipt (JSON)
                        DispatchQueue.main.async {
                            self.delegate?.didReceiveReadReceipt(receipt)
                        }
                    } else {
                        // Try legacy decryption
                        do {
                            let decryptedData = try noiseService.decrypt(packet.payload, from: senderID)
                            if let receipt = ReadReceipt.fromBinaryData(decryptedData) {
                                // Process the read receipt
                                DispatchQueue.main.async {
                                    self.delegate?.didReceiveReadReceipt(receipt)
                                }
                            } else if let receipt = ReadReceipt.decode(from: decryptedData) {
                                // Fallback to JSON
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
                let delay = self.exponentialRelayDelay()
                self.scheduleRelay(relayPacket, messageID: messageID, delay: delay)
            }
            
        case .noiseIdentityAnnounce:
            // Handle Noise identity announcement
            let senderID = packet.senderID.hexEncodedString()
            
            // Check if this identity announce is targeted to someone else
            if let recipientID = packet.recipientID,
               !isPeerIDOurs(recipientID.hexEncodedString()) {
                // Not for us, relay if TTL > 0
                if packet.ttl > 0 {
                    // Relay identity announce
                    var relayPacket = packet
                    relayPacket.ttl -= 1
                    let delay = self.exponentialRelayDelay()
                    self.scheduleRelay(relayPacket, messageID: messageID, delay: delay)
                }
                return
            }
            
            // Special duplicate detection for identity announces
            processedMessagesLock.lock()
            if let lastSeenTime = recentIdentityAnnounces[senderID] {
                let timeSince = Date().timeIntervalSince(lastSeenTime)
                if timeSince < identityAnnounceDuplicateWindow {
                    processedMessagesLock.unlock()
                    SecureLogger.log("Dropped duplicate identity announce from \(senderID) (last seen \(timeSince)s ago)", 
                                   category: SecureLogger.security, level: .debug)
                    return
                }
            }
            recentIdentityAnnounces[senderID] = Date()
            processedMessagesLock.unlock()
            
            if senderID != myPeerID && !isPeerIDOurs(senderID) {
                // Create defensive copy and validate
                let payloadCopy = Data(packet.payload)
                
                guard !payloadCopy.isEmpty else {
                    SecureLogger.log("Received empty NoiseIdentityAnnouncement from \(senderID)", category: SecureLogger.noise, level: .error)
                    return
                }
                
                // Decode the announcement
                let announcement: NoiseIdentityAnnouncement?
                if let firstByte = payloadCopy.first, firstByte == 0x7B { // '{' character - JSON
                    announcement = NoiseIdentityAnnouncement.decode(from: payloadCopy) ?? NoiseIdentityAnnouncement.fromBinaryData(payloadCopy)
                } else {
                    announcement = NoiseIdentityAnnouncement.fromBinaryData(payloadCopy) ?? NoiseIdentityAnnouncement.decode(from: payloadCopy)
                }
                
                guard let announcement = announcement else {
                    SecureLogger.log("Failed to decode NoiseIdentityAnnouncement from \(senderID), size: \(payloadCopy.count)", category: SecureLogger.noise, level: .error)
                    // Invalidate version cache as this might be a protocol mismatch
                    invalidateVersionCache(for: senderID)
                    return
                }
                
                // Verify the signature using the signing public key
                let timestampData = String(Int64(announcement.timestamp.timeIntervalSince1970 * 1000)).data(using: .utf8)!
                let bindingData = announcement.peerID.data(using: .utf8)! + announcement.publicKey + timestampData
                if !noiseService.verifySignature(announcement.signature, for: bindingData, publicKey: announcement.signingPublicKey) {
                    SecureLogger.log("Signature verification failed for \(senderID)", category: SecureLogger.noise, level: .warning)
                    return  // Reject announcements with invalid signatures
                }
                
                // Calculate fingerprint from public key
                let hash = SHA256.hash(data: announcement.publicKey)
                let fingerprint = hash.map { String(format: "%02x", $0) }.joined()
                
                // Log receipt of identity announce
                SecureLogger.log("Received identity announce from \(announcement.peerID) (\(announcement.nickname))", 
                               category: SecureLogger.noise, level: .info)
                
                // Create the binding
                let binding = PeerIdentityBinding(
                    currentPeerID: announcement.peerID,
                    fingerprint: fingerprint,
                    publicKey: announcement.publicKey,
                    signingPublicKey: announcement.signingPublicKey,
                    nickname: announcement.nickname,
                    bindingTimestamp: announcement.timestamp,
                    signature: announcement.signature
                )
                
                SecureLogger.log("Creating identity binding for \(announcement.peerID) -> \(fingerprint)", category: SecureLogger.security, level: .info)
                
                // Update our mappings
                updatePeerBinding(announcement.peerID, fingerprint: fingerprint, binding: binding)
                
                // Update connection state only if we're not already authenticated
                let currentState = peerConnectionStates[announcement.peerID] ?? .disconnected
                if currentState != .authenticated {
                    // Check if we have a direct peripheral connection or if this is relayed
                    let hasDirectConnection = collectionsQueue.sync {
                        // Check if any connected peripheral maps to this peer
                        for (_, mapping) in self.peripheralMappings where mapping.peerID == announcement.peerID {
                            if self.connectedPeripherals[announcement.peerID] != nil {
                                return true
                            }
                        }
                        return false
                    }
                    
                    if hasDirectConnection {
                        updatePeerConnectionState(announcement.peerID, state: .connected)
                    } else {
                        // This is a relayed identity announce - don't mark as directly connected
                        SecureLogger.log("Received relayed identity announce from \(announcement.peerID) - not marking as directly connected", 
                                       category: SecureLogger.noise, level: .debug)
                    }
                }
                
                // Register the peer's public key with ChatViewModel for verification tracking
                DispatchQueue.main.async { [weak self] in
                    (self?.delegate as? ChatViewModel)?.registerPeerPublicKey(peerID: announcement.peerID, publicKeyData: announcement.publicKey)
                }
                
                // Lazy handshake: No longer initiate handshake on identity announcement
                // Just respond with our own identity announcement
                if !noiseService.hasEstablishedSession(with: announcement.peerID) {
                    // Send our identity back so they know we're here
                    SecureLogger.log("Responding to identity announce from \(announcement.peerID) with our own (lazy handshake mode)", 
                                   category: SecureLogger.noise, level: .info)
                    sendNoiseIdentityAnnounce(to: announcement.peerID)
                } else {
                    // We already have a session, ensure ChatViewModel knows about the fingerprint
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
            SecureLogger.logHandshake("initiation received", peerID: senderID, success: true)
            
            // Check if this handshake is for us or broadcast
            if let recipientID = packet.recipientID,
               !isPeerIDOurs(recipientID.hexEncodedString()) {
                // Not for us, relay if TTL > 0
                if packet.ttl > 0 {
                    // Relay handshake init
                    var relayPacket = packet
                    relayPacket.ttl -= 1
                    broadcastPacket(relayPacket)
                }
                return
            }
            if !isPeerIDOurs(senderID) {
                // Check if we already have an established session
                if noiseService.hasEstablishedSession(with: senderID) {
                    // Determine who should be initiator based on peer ID comparison
                    let shouldBeInitiator = myPeerID < senderID
                    
                    if shouldBeInitiator {
                        // We should be initiator but peer is initiating - likely they had a session failure
                        SecureLogger.log("Received handshake init from \(senderID) who should be responder - likely session mismatch, clearing and accepting", category: SecureLogger.noise, level: .warning)
                        cleanupPeerCryptoState(senderID)
                    } else {
                        // Check if we've heard from this peer recently
                        let lastHeard = self.peerSessions[senderID]?.lastHeardFromPeer ?? Date.distantPast
                        let timeSinceLastHeard = Date().timeIntervalSince(lastHeard)
                        
                        // Check session validity before clearing
                        let lastSuccess = self.peerSessions[senderID]?.lastSuccessfulMessageTime ?? Date.distantPast
                        let sessionAge = Date().timeIntervalSince(lastSuccess)
                        
                        // If the peer is initiating a handshake despite us having a valid session,
                        // they must have cleared their session for a good reason (e.g., decryption failure).
                        // We should always accept the handshake to re-establish encryption.
                        SecureLogger.log("Received handshake init from \(senderID) with existing session (age: \(Int(sessionAge))s, last heard: \(Int(timeSinceLastHeard))s ago) - accepting to re-establish encryption", 
                                       category: SecureLogger.handshake, level: .info)
                        cleanupPeerCryptoState(senderID)
                    }
                }
                
                // If we have a handshaking session, reset it to allow new handshake
                if noiseService.hasSession(with: senderID) && !noiseService.hasEstablishedSession(with: senderID) {
                    SecureLogger.log("Received handshake init from \(senderID) while already handshaking - resetting to allow new handshake", category: SecureLogger.noise, level: .info)
                    cleanupPeerCryptoState(senderID)
                }
                
                // Check if we've completed version negotiation with this peer
                if negotiatedVersions[senderID] == nil {
                    // Legacy peer - assume version 1 for backward compatibility
                    SecureLogger.log("Received Noise handshake from \(senderID) without version negotiation, assuming v1", 
                                      category: SecureLogger.session, level: .debug)
                    negotiatedVersions[senderID] = 1
                    versionNegotiationState[senderID] = .ackReceived(version: 1)
                }
                handleNoiseHandshakeMessage(from: senderID, message: packet.payload, isInitiation: true)
                
                // Send protocol ACK for successfully processed handshake initiation
                sendProtocolAck(for: packet, to: senderID)
            }
            
        case .noiseHandshakeResp:
            // Handle Noise handshake response
            let senderID = packet.senderID.hexEncodedString()
            SecureLogger.logHandshake("response received", peerID: senderID, success: true)
            
            // Check if this handshake response is for us
            if let recipientID = packet.recipientID {
                let recipientIDStr = recipientID.hexEncodedString()
                // Response targeted check
                if !isPeerIDOurs(recipientIDStr) {
                    // Not for us, relay if TTL > 0
                    if packet.ttl > 0 {
                        // Relay handshake response
                        var relayPacket = packet
                        relayPacket.ttl -= 1
                        broadcastPacket(relayPacket)
                    }
                    return
                }
            }
            
            if !isPeerIDOurs(senderID) {
                // Check our current handshake state
                let _ = handshakeCoordinator.getHandshakeState(for: senderID)
                // Processing handshake response
                
                // Process the response - this could be message 2 or message 3 in the XX pattern
                handleNoiseHandshakeMessage(from: senderID, message: packet.payload, isInitiation: false)
                
                // Send protocol ACK for successfully processed handshake response
                sendProtocolAck(for: packet, to: senderID)
            }
            
        case .noiseEncrypted:
            // Handle Noise encrypted message
            let senderID = packet.senderID.hexEncodedString()
            if !isPeerIDOurs(senderID) {
                let recipientID = packet.recipientID?.hexEncodedString() ?? ""
                
                // Check if this message is for us
                if isPeerIDOurs(recipientID) {
                    // Message is for us, try to decrypt
                    handleNoiseEncryptedMessage(from: senderID, encryptedData: packet.payload, originalPacket: packet, peripheral: peripheral)
                } else if packet.ttl > 1 {
                    // Message is not for us but has TTL > 1, consider relaying
                    // Only relay if we think we might be able to reach the recipient
                    
                    // Check if recipient is directly connected to us
                    let canReachDirectly = connectedPeripherals[recipientID] != nil
                    
                    // Check if we've seen this recipient recently (might be reachable via relay)
                    let seenRecently = collectionsQueue.sync {
                        if let lastSeen = self.peerLastSeenTimestamps.get(recipientID) {
                            return Date().timeIntervalSince(lastSeen) < 180.0  // Seen in last 3 minutes
                        }
                        return false
                    }
                    
                    if canReachDirectly || seenRecently {
                        // Relay the message with reduced TTL
                        var relayPacket = packet
                        relayPacket.ttl = min(packet.ttl - 1, 2)  // Decrement TTL, max 2 for relayed private messages
                        
                        SecureLogger.log("Relaying private message from \(senderID) to \(recipientID) (TTL: \(relayPacket.ttl))", 
                                       category: SecureLogger.session, level: .debug)
                        
                        if canReachDirectly {
                            // Send directly to recipient
                            _ = sendDirectToRecipient(relayPacket, recipientPeerID: recipientID)
                        } else {
                            // Use selective relay
                            sendViaSelectiveRelay(relayPacket, recipientPeerID: recipientID)
                        }
                    } else {
                        SecureLogger.log("Not relaying private message to \(recipientID) - recipient not reachable", 
                                       category: SecureLogger.session, level: .debug)
                    }
                } else {
                    // recipientID is empty or invalid, try to decrypt anyway (backwards compatibility)
                    handleNoiseEncryptedMessage(from: senderID, encryptedData: packet.payload, originalPacket: packet, peripheral: peripheral)
                }
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
            
        case .protocolAck:
            // Handle protocol-level acknowledgment
            let senderID = packet.senderID.hexEncodedString()
            if !isPeerIDOurs(senderID) {
                handleProtocolAck(from: senderID, data: packet.payload)
            }
            
        case .protocolNack:
            // Handle protocol-level negative acknowledgment
            let senderID = packet.senderID.hexEncodedString()
            if let recipientIDData = packet.recipientID,
               isPeerIDOurs(recipientIDData.hexEncodedString())
               && !isPeerIDOurs(senderID) {
                handleProtocolNack(from: senderID, data: packet.payload)
            }
            
        case .systemValidation:
            // Handle system validation ping (for session sync verification)
            let senderID = packet.senderID.hexEncodedString()
            if !isPeerIDOurs(senderID) {
                // Try to decrypt the validation ping
                do {
                    let decrypted = try noiseService.decrypt(packet.payload, from: senderID)
                    SecureLogger.log("Successfully validated session with \(senderID) - ping: \(String(data: decrypted, encoding: .utf8) ?? "?")", 
                                   category: SecureLogger.session, level: .debug)
                    
                    // Session is valid, update last successful message time
                    updateLastSuccessfulMessageTime(senderID)
                    
                    // Note: PeerSession already updated in helper
                    if let session = self.peerSessions[senderID] {
                        session.lastSuccessfulMessageTime = Date()
                    }
                } catch {
                    // Validation failed - session is out of sync
                    SecureLogger.log("Session validation failed with \(senderID): \(error)", 
                                   category: SecureLogger.session, level: .warning)
                    
                    // Send NACK to trigger session re-establishment
                    sendProtocolNack(for: packet, to: senderID, 
                                   reason: "Session validation failed", 
                                   errorCode: .decryptionFailed)
                }
            }
            
        case .handshakeRequest:
            // Handle handshake request for pending messages
            let senderID = packet.senderID.hexEncodedString()
            if !isPeerIDOurs(senderID) {
                handleHandshakeRequest(from: senderID, data: packet.payload)
            }
            
        case .favorited:
            // Now handled as private messages with "SYSTEM:FAVORITED" content
            // See handleReceivedPacket for MESSAGE type handling
            break
            
        case .unfavorited:
            // Now handled as private messages with "SYSTEM:UNFAVORITED" content
            // See handleReceivedPacket for MESSAGE type handling
            break
            
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
                ttl: packet.ttl            )
            
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
}  // End of BluetoothMeshService class

extension BluetoothMeshService: CBCentralManagerDelegate {
    // MARK: - CBCentralManagerDelegate
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Central manager state updated
        let stateString: String
        switch central.state {
        case .unknown: stateString = "unknown"
        case .resetting: stateString = "resetting"
        case .unsupported: stateString = "unsupported"
        case .unauthorized: stateString = "unauthorized"
        case .poweredOff: stateString = "poweredOff"
        case .poweredOn: stateString = "poweredOn"
        @unknown default: stateString = "unknown default"
        }
        
        SecureLogger.log("[BT-STATE] Central manager state changed to: \(stateString)", 
                       category: SecureLogger.session, level: .info)
        
        // Notify ChatViewModel of Bluetooth state change
        if let chatViewModel = delegate as? ChatViewModel {
            Task { @MainActor in
                chatViewModel.updateBluetoothState(central.state)
            }
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
    
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        // Restore central manager state after app backgrounding
        SecureLogger.log("[RESTORE] Restoring CBCentralManager state", level: .info)
        
        // Restore scanned services
        if let services = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] {
            SecureLogger.log("[RESTORE] Restoring scanned services: \(services)", level: .info)
        }
        
        // Restore scan options
        if let scanOptions = dict[CBCentralManagerRestoredStateScanOptionsKey] as? [String: Any] {
            SecureLogger.log("[RESTORE] Restoring scan options: \(scanOptions)", level: .info)
        }
        
        // Restore peripherals
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            SecureLogger.log("[RESTORE] Restoring \(peripherals.count) peripherals", level: .info)
            
            collectionsQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else { return }
                
                // Restore discovered peripherals list
                self.discoveredPeripherals = peripherals
                
                // Restore connections for connected peripherals
                for peripheral in peripherals {
                    if peripheral.state == .connected {
                        // Find the peerID for this peripheral
                        let peerID = peripheral.identifier.uuidString
                        
                        // Update our tracking
                        self.updatePeripheralConnection(peerID, peripheral: peripheral)
                        
                        // Set delegate and discover services
                        peripheral.delegate = self
                        peripheral.discoverServices([BluetoothMeshService.serviceUUID])
                        
                        SecureLogger.log("[RESTORE] Restored connection to peer: \(peerID)", level: .info)
                    }
                }
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        
        let peripheralID = peripheral.identifier.uuidString
        SecureLogger.log("[DISCOVERY] Discovered peripheral \(peripheralID.prefix(8)): name=\(peripheral.name ?? "nil"), adData=\(advertisementData)", 
                       category: SecureLogger.session, level: .debug)
        
        // Extract peer ID from name or advertisement data (macOS compatibility)
        // Peer IDs are 8 bytes = 16 hex characters
        var discoveredPeerID: String? = nil
        
        // First try peripheral name
        if let name = peripheral.name, name.count == 16 {
            discoveredPeerID = name
        }
        
        // macOS fix: Also check advertisement data local name
        if discoveredPeerID == nil,
           let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
           localName.count == 16 {
            discoveredPeerID = localName
        }
        
        if let peerID = discoveredPeerID {
            // Found peer ID
            SecureLogger.log("[SUCCESS] Extracted peer ID \(peerID) from peripheral \(peripheralID.prefix(8))", 
                           category: SecureLogger.session, level: .info)
            
            // Don't process our own advertisements (including previous peer IDs)
            if isPeerIDOurs(peerID) {
                SecureLogger.log("[SKIP] Ignoring our own peer ID \(peerID)", 
                               category: SecureLogger.session, level: .debug)
                return
            }
            
            // Discovered potential peer
            SecureLogger.log("[PROCESS] Processing discovered peer \(peerID)", 
                           category: SecureLogger.session, level: .info)
            
            // Check if we have a relay-only session for this peer that needs upgrading
            collectionsQueue.sync {
                if let session = self.peerSessions[peerID],
                   !session.isConnected && session.hasReceivedAnnounce {
                    SecureLogger.log("Found relay-only session for \(peerID), will upgrade to direct connection", 
                                   category: SecureLogger.session, level: .info)
                }
            }
        } else {
            SecureLogger.log("[WARNING] No peer ID found in peripheral \(peripheralID.prefix(8)): name=\(peripheral.name ?? "nil"), localName=\(advertisementData[CBAdvertisementDataLocalNameKey] ?? "nil")", 
                           category: SecureLogger.session, level: .warning)
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
                // Reconnect if disconnected with optimized parameters
                let connectionOptions: [String: Any] = [
                    CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnNotificationKey: true
                ]
                
                // Smart compromise: would set low latency for small networks if API supported it
                // iOS/macOS don't expose connection interval control in public API
                
                central.connect(pooledPeripheral, options: connectionOptions)
            }
            return
        }
        
        // New peripheral - add to pool and connect
        if !discoveredPeripherals.contains(peripheral) {
            // Check connection pool limits
            let connectedCount = connectionPool.values.filter { $0.state == .connected }.count
            if connectedCount >= maxConnectedPeripherals {
                // Connection pool is full - find least recently used peripheral to disconnect
                if let lruPeripheralID = findLeastRecentlyUsedPeripheral() {
                    if let lruPeripheral = connectionPool[lruPeripheralID] {
                        SecureLogger.log("Connection pool full, disconnecting LRU peripheral: \(lruPeripheralID)", 
                                       category: SecureLogger.session, level: .debug)
                        central.cancelPeripheralConnection(lruPeripheral)
                        connectionPool.removeValue(forKey: lruPeripheralID)
                    }
                }
            }
            
            discoveredPeripherals.append(peripheral)
            peripheral.delegate = self
            connectionPool[peripheralID] = peripheral
            
            // Track connection attempts
            let attempts = connectionAttempts[peripheralID] ?? 0
            connectionAttempts[peripheralID] = attempts + 1
            
            // Only attempt if under max attempts
            if attempts < maxConnectionAttempts {
                // Use optimized connection parameters based on peer count
                let connectionOptions: [String: Any] = [
                    CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnNotificationKey: true
                ]
                
                // Smart compromise: would set low latency for small networks if API supported it
                // iOS/macOS don't expose connection interval control in public API
                
                SecureLogger.log("[CONNECT] Attempting to connect to peripheral \(peripheralID.prefix(8))", 
                               category: SecureLogger.session, level: .info)
                central.connect(peripheral, options: connectionOptions)
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let peripheralID = peripheral.identifier.uuidString
        SecureLogger.log("[CONNECTED] Connected to peripheral \(peripheralID) - awaiting peer ID", 
                       category: SecureLogger.session, level: .info)
        
        // Log current peripheral mappings
        let mappingCount = collectionsQueue.sync { peripheralMappings.count }
        let poolCount = connectionPool.count
        SecureLogger.log("[STATE] Current state: peripheralMappings=\(mappingCount), connectionPool=\(poolCount)", 
                       category: SecureLogger.session, level: .debug)
        
        peripheral.delegate = self
        peripheral.discoverServices([BluetoothMeshService.serviceUUID])
        
        // Register peripheral in simplified mapping system
        registerPeripheral(peripheral)
        
        // Store peripheral temporarily until we get the real peer ID
        updatePeripheralConnection(peripheralID, peripheral: peripheral)
        
        SecureLogger.log("Connected to peripheral \(peripheralID) - awaiting peer ID", 
                       category: SecureLogger.session, level: .debug)
        
        // Update connection state to connected (but not authenticated yet)
        // We don't know the real peer ID yet, so we can't update the state
        
        // Don't show connected message yet - wait for key exchange
        // This prevents the connect/disconnect/connect pattern
        
        
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
            // Intentional disconnect
            // Don't process this disconnect further
            return
        }
        
        // Log disconnect with error if present
        if let error = error {
            SecureLogger.logError(error, context: "Peripheral disconnected: \(peripheralID)", category: SecureLogger.session)
        } else {
            // Peripheral disconnected normally
        }
        
        // Find the real peer ID using simplified mapping
        var realPeerID: String? = nil
        
        if let mapping = peripheralMappings[peripheralID], let peerID = mapping.peerID {
            realPeerID = peerID
            SecureLogger.log("Found peer ID \(peerID) for peripheral \(peripheralID)", 
                           category: SecureLogger.session, level: .debug)
        } else if let peerID = peerIDByPeripheralID[peripheralID] {
            // Fallback to legacy mapping
            realPeerID = peerID
            SecureLogger.log("Found peer ID \(peerID) from legacy mapping for peripheral \(peripheralID)", 
                           category: SecureLogger.session, level: .debug)
        } else {
            SecureLogger.log("No peer ID mapping found for peripheral \(peripheralID)", 
                           category: SecureLogger.session, level: .debug)
            
            // Fallback: check if we have a direct mapping from peripheral to peer ID
            for (peerID, connectedPeripheral) in connectedPeripherals {
                if connectedPeripheral.identifier == peripheral.identifier {
                    // Check if this is a real peer ID (16 hex chars) not a temp ID
                    if peerID.count == 16 && peerID.allSatisfy({ $0.isHexDigit }) {
                        realPeerID = peerID
                        SecureLogger.log("Found peer ID \(peerID) from connectedPeripherals fallback", 
                                       category: SecureLogger.session, level: .debug)
                        break
                    } else {
                        SecureLogger.log("Skipping non-peer ID '\(peerID)' (length: \(peerID.count))", 
                                       category: SecureLogger.session, level: .debug)
                    }
                }
            }
        }
        
        // Update connection state immediately if we have a real peer ID
        if let peerID = realPeerID {
            // Update peer connection state
            updatePeerConnectionState(peerID, state: .disconnected)
            
            // Update PeerSession to reflect disconnect
            collectionsQueue.async(flags: .barrier) { [weak self] in
                if let session = self?.peerSessions[peerID] {
                    session.updateBluetoothConnection(peripheral: nil, characteristic: nil)
                    session.isConnected = false
                    session.updateAuthenticationState(authenticated: false, noiseSession: false)
                }
            }
            
            // Clear pending messages for disconnected peer to prevent retry loops
            collectionsQueue.async(flags: .barrier) { [weak self] in
                if let pendingCount = self?.pendingPrivateMessages[peerID]?.count, pendingCount > 0 {
                    SecureLogger.log("Clearing \(pendingCount) pending messages for disconnected peer \(peerID)", 
                                   category: SecureLogger.session, level: .info)
                    self?.pendingPrivateMessages[peerID]?.removeAll()
                }
            }
            
            // Clean up crypto state and handshake state on disconnect
            cleanupPeerCryptoState(peerID)
            
            // Check if peer gracefully left and notify delegate
            let shouldNotifyDisconnect = collectionsQueue.sync {
                let isGracefullyLeft = self.gracefullyLeftPeers.contains(peerID)
                
                // Check if we recently sent a disconnect notification for this peer
                let now = Date()
                if let lastNotification = self.recentDisconnectNotifications[peerID] {
                    let timeSinceLastNotification = now.timeIntervalSince(lastNotification)
                    if timeSinceLastNotification < self.disconnectNotificationDedupeWindow {
                        // Duplicate disconnect, not notifying
                        return false
                    }
                }
                
                // Check if this is an Unknown peer that never properly connected
                if let session = self.peerSessions[peerID] {
                    if session.nickname == "Unknown" && !session.hasReceivedAnnounce {
                        // Unknown peer disconnect, not notifying
                        return false
                    }
                }
                
                if isGracefullyLeft {
                    // Graceful disconnect, not notifying
                    return false
                } else {
                    // Ungraceful disconnect, will notify
                    // Track this notification
                    self.recentDisconnectNotifications[peerID] = now
                    return true
                }
            }
            
            if shouldNotifyDisconnect {
                DispatchQueue.main.async {
                    self.delegate?.didDisconnectFromPeer(peerID)
                }
            }
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
        
        // Clean up peripheral tracking
        peripheralMappings.removeValue(forKey: peripheralID)
        peerIDByPeripheralID.removeValue(forKey: peripheralID)
        lastActivityByPeripheralID.removeValue(forKey: peripheralID)
        
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
            
            // Don't clear Noise session on disconnect - sessions should survive disconnects
            // The Noise protocol is designed to maintain sessions across network interruptions
            // Only clear sessions on authentication failure
            if peerID.count == 16 {  // Real peer ID
                // Clear connection time and last heard tracking on disconnect to properly detect stale sessions
                // Time tracking removed - now in PeerSession
                // Time tracking removed - now in PeerSession
                // Keep lastSuccessfulMessageTime to validate session on reconnect
                let lastSuccess = self.peerSessions[peerID]?.lastSuccessfulMessageTime ?? Date.distantPast
                let _ = Date().timeIntervalSince(lastSuccess)
                // Keeping Noise session on disconnect
            }
            
            // Only remove from active peers if it's not a temp ID
            // Temp IDs shouldn't be marked as active anyway
            let (removed, _) = collectionsQueue.sync(flags: .barrier) {
                var removed = false
                if peerID.count == 16 {  // Real peer ID (8 bytes = 16 hex chars)
                    removed = self.peerSessions[peerID]?.isActivePeer == true
                    if removed, let session = self.peerSessions[peerID] {
                        session.isActivePeer = false
                    }
                    if removed {
                        // Only log disconnect if peer didn't gracefully leave
                        if !self.gracefullyLeftPeers.contains(peerID) {
                            let nickname = self.peerSessions[peerID]?.nickname ?? "unknown"
                            SecureLogger.log("📴 Peer disconnected from network: \(peerID) (\(nickname))", category: SecureLogger.session, level: .info)
                        } else {
                            // Peer gracefully left, just clean up the tracking
                            self.gracefullyLeftPeers.remove(peerID)
                            self.gracefulLeaveTimestamps.removeValue(forKey: peerID)
                            // Cleaning up gracefullyLeftPeers
                        }
                    }
                    
                    // Update PeerSession
                    if let session = self.peerSessions[peerID] {
                        session.hasReceivedAnnounce = false
                        session.hasAnnounced = false
                    }
                    // hasAnnounced already updated in PeerSession above
                } else {
                }
                
                // Clear cached messages tracking for this peer to allow re-sending if they reconnect
                cachedMessagesSentToPeer.remove(peerID)
                
                // Clear version negotiation state
                versionNegotiationState.removeValue(forKey: peerID)
                negotiatedVersions.removeValue(forKey: peerID)
                
                // Peer disconnected
                
                return (removed, self.peerSessions[peerID]?.nickname)
            }
            
            // Always notify peer list update on disconnect, regardless of whether peer was active
            // This ensures UI stays in sync even if there was a state mismatch
            self.notifyPeerListUpdate(immediate: true)
            
            if removed {
                // Mark when network became empty, but don't reset flag immediately
                let currentNetworkSize = collectionsQueue.sync { 
                    peerSessions.values.filter { $0.isActivePeer }.count 
                }
                if currentNetworkSize == 0 && networkBecameEmptyTime == nil {
                    networkBecameEmptyTime = Date()
                }
            }
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
    // MARK: - CBPeripheralDelegate
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            SecureLogger.log("Error discovering services: \(error)", 
                             category: SecureLogger.encryption, level: .error)
            return
        }
        
        guard let services = peripheral.services else { return }
        
        
        for service in services {
            peripheral.discoverCharacteristics([BluetoothMeshService.characteristicUUID], for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            SecureLogger.log("Error discovering characteristics: \(error)", 
                             category: SecureLogger.encryption, level: .error)
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
                // Pass the peripheral ID so we can check cache by peer ID if available
                let peripheralID = peripheral.identifier.uuidString
                self.sendVersionHello(to: peripheral, peripheralID: peripheralID)
                
                // Send announce packet after version negotiation completes
                if let vm = self.delegate as? ChatViewModel {
                    // Send single announce with slight delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self = self else { return }
                        let announcePacket = BitchatPacket(
                            type: MessageType.announce.rawValue,
                            ttl: 3,
                            senderID: self.myPeerID,
                            payload: Data(vm.nickname.utf8)                        )
                        self.broadcastPacket(announcePacket)
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
                            payload: Data(vm.nickname.utf8)                        )
                        if let data = announcePacket.toBinaryData() {
                            self.writeToPeripheral(data, peripheral: peripheral, characteristic: characteristic, peerID: nil)
                        }
                    }
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            SecureLogger.log("[ERROR] Error receiving data from peripheral: \(error.localizedDescription)", 
                           category: SecureLogger.session, level: .error)
            return
        }
        
        guard let data = characteristic.value else {
            return
        }
        
        SecureLogger.log("[DATA-RX] Received \(data.count) bytes from peripheral \(peripheral.identifier.uuidString.prefix(8))", 
                       category: SecureLogger.session, level: .debug)
        
        // Update activity tracking for this peripheral
        updatePeripheralActivity(peripheral.identifier.uuidString)
        
        
        guard let packet = BitchatPacket.from(data) else { 
            SecureLogger.log("[ERROR] Failed to parse packet from peripheral \(peripheral.identifier.uuidString.prefix(8))", 
                           category: SecureLogger.session, level: .error)
            return 
        }
        
        
        // Use the sender ID from the packet, not our local mapping which might still be a temp ID
        let _ = connectedPeripherals.first(where: { $0.value == peripheral })?.key ?? "unknown"
        let packetSenderID = packet.senderID.hexEncodedString()
        
        SecureLogger.log("[MAPPING] Updating peripheral mapping: peripheral=\(peripheral.identifier.uuidString.prefix(8)) -> peerID=\(packetSenderID)", 
                       category: SecureLogger.session, level: .info)
        
        
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
}

extension BluetoothMeshService: CBPeripheralManagerDelegate {
    // MARK: - CBPeripheralManagerDelegate
    
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
        
        // Notify ChatViewModel of Bluetooth state change
        if let chatViewModel = delegate as? ChatViewModel {
            Task { @MainActor in
                chatViewModel.updateBluetoothState(peripheral.state)
            }
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
    
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String : Any]) {
        // Restore peripheral manager state after app backgrounding
        SecureLogger.log("[RESTORE] Restoring CBPeripheralManager state", level: .info)
        
        // Restore services
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            SecureLogger.log("[RESTORE] Restoring \(services.count) services", level: .info)
            
            // Services are automatically restored by Core Bluetooth
            // We just need to ensure our internal state is consistent
            DispatchQueue.main.async { [weak self] in
                self?.isAdvertising = false
                // Will be set to true when advertising starts
            }
        }
        
        // Restore advertisement data
        if let advertisementData = dict[CBPeripheralManagerRestoredStateAdvertisementDataKey] as? [String: Any] {
            SecureLogger.log("[RESTORE] Restoring advertisement data: \(advertisementData)", level: .info)
            self.advertisementData = advertisementData
            
            DispatchQueue.main.async { [weak self] in
                self?.isAdvertising = true
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        // Service added
    }
    
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        // Advertising state changed
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        SecureLogger.log("[INCOMING] Received \(requests.count) write requests as peripheral", 
                       category: SecureLogger.session, level: .debug)
        
        for request in requests {
            if let data = request.value {
                SecureLogger.log("[DATA-IN] Processing \(data.count) bytes from central \(request.central.identifier.uuidString.prefix(8))", 
                               category: SecureLogger.session, level: .debug)
                        
                if let packet = BitchatPacket.from(data) {
                    let peerID = packet.senderID.hexEncodedString()
                    SecureLogger.log("[PACKET] Packet from peer \(peerID) via central \(request.central.identifier.uuidString.prefix(8))", 
                                   category: SecureLogger.session, level: .info)
                    
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
                    // peerID already declared above
                    
                    // Store the central for updates
                if !subscribedCentrals.contains(request.central) {
                    subscribedCentrals.append(request.central)
                }
                
                // Track this peer as connected
                if peerID != "unknown" && peerID != myPeerID {
                    // Double-check we're not adding ourselves
                    if peerID == self.myPeerID {
                        SecureLogger.log("Preventing self from being added as peer (peripheral manager)", category: SecureLogger.noise, level: .warning)
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
            SecureLogger.log("[SUBSCRIBE] Central subscribed: \(central.identifier.uuidString.prefix(8)), total centrals: \(subscribedCentrals.count)", 
                           category: SecureLogger.session, level: .info)
            
            // Only send identity announcement if we haven't recently
            // This reduces spam when multiple centrals connect quickly
            // sendNoiseIdentityAnnounce() will check rate limits internally
            
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
        
        // Update max connections using dynamic calculation
        let dynamicMaxConnections = calculateDynamicConnectionLimit()
        
        // If we have too many connections, disconnect from the least important ones
        if connectedPeripherals.count > dynamicMaxConnections {
            disconnectLeastImportantPeripherals(keepCount: dynamicMaxConnections)
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
    
    private func switchToBackgroundScanning() {
        guard centralManager?.state == .poweredOn else { return }
        
        // Stop existing scanning and duty cycling
        centralManager?.stopScan()
        scanDutyCycleTimer?.invalidate()
        scanDutyCycleTimer = nil
        
        // Use continuous scanning with battery-efficient options in background
        let backgroundScanOptions: [String: Any] = [
            CBCentralManagerScanOptionAllowDuplicatesKey: false  // Battery efficient
        ]
        
        centralManager?.scanForPeripherals(
            withServices: [BluetoothMeshService.serviceUUID],
            options: backgroundScanOptions
        )
        
        SecureLogger.log("[SCAN-MODE] Switched to continuous background scanning", level: .info)
    }
    
    private func switchToForegroundScanning() {
        guard centralManager?.state == .poweredOn else { return }
        
        // Stop existing scanning
        centralManager?.stopScan()
        scanDutyCycleTimer?.invalidate()
        scanDutyCycleTimer = nil
        
        // Use foreground scanning with duty cycling and allow duplicates for faster discovery
        let foregroundScanOptions: [String: Any] = [
            CBCentralManagerScanOptionAllowDuplicatesKey: true  // Faster discovery
        ]
        
        centralManager?.scanForPeripherals(
            withServices: [BluetoothMeshService.serviceUUID],
            options: foregroundScanOptions
        )
        
        // Re-enable duty cycling for foreground operation
        scheduleScanDutyCycle()
        
        SecureLogger.log("[SCAN-MODE] Switched to foreground scanning with duty cycling", level: .info)
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
    
    // MARK: - Range Optimization Methods
    
    
    // Exponential delay distribution to prevent synchronized collision storms
    private func exponentialRelayDelay() -> TimeInterval {
        // Use exponential distribution with mean of (min + max) / 2
        let meanDelay = (minMessageDelay + maxMessageDelay) / 2.0
        let lambda = 1.0 / meanDelay
        
        // Generate exponential random value
        let u = Double.random(in: 0..<1)
        let exponentialDelay = -log(1.0 - u) / lambda
        
        // Clamp to our bounds
        return min(maxMessageDelay, max(minMessageDelay, exponentialDelay))
    }
    
    // Check if message type is high priority (should bypass aggregation)
    private func isHighPriorityMessage(type: UInt8) -> Bool {
        switch MessageType(rawValue: type) {
        case .noiseHandshakeInit, .noiseHandshakeResp, .protocolAck,
             .versionHello, .versionAck, .deliveryAck, .systemValidation,
             .handshakeRequest:
            return true
        case .message, .announce, .leave, .readReceipt, .deliveryStatusRequest,
             .fragmentStart, .fragmentContinue, .fragmentEnd,
             .noiseIdentityAnnounce, .noiseEncrypted, .protocolNack, 
             .favorited, .unfavorited, .none:
            return false
        }
    }
    
    // Calculate exponential backoff for retries
    private func calculateExponentialBackoff(retry: Int) -> TimeInterval {
        // Start with 1s, double each time: 1s, 2s, 4s, 8s, 16s, max 30s
        let baseDelay = 1.0
        let maxDelay = 30.0
        let delay = min(maxDelay, baseDelay * pow(2.0, Double(retry - 1)))
        
        // Add 10% jitter to prevent synchronized retries
        let jitter = delay * 0.1 * (Double.random(in: -1...1))
        return delay + jitter
    }
    
    // MARK: - Collision Avoidance
    
    // Calculate jitter based on node ID to spread transmissions
    private func calculateNodeIDJitter() -> TimeInterval {
        // Use hash of peer ID to generate consistent jitter for this node
        let hashValue = myPeerID.hash
        let normalizedHash = Double(abs(hashValue % 1000)) / 1000.0  // 0.0 to 0.999
        
        // Jitter range: 0-20ms based on node ID
        let jitterRange: TimeInterval = 0.02  // 20ms max jitter
        return normalizedHash * jitterRange
    }
    
    // Add smart delay to avoid collisions
    private func smartCollisionAvoidanceDelay(baseDelay: TimeInterval) -> TimeInterval {
        // Add node-specific jitter to base delay
        let nodeJitter = calculateNodeIDJitter()
        
        // Add small random component to avoid perfect synchronization
        let randomJitter = TimeInterval.random(in: 0...0.005)  // 0-5ms additional random
        
        return baseDelay + nodeJitter + randomJitter
    }
    
    // MARK: - Relay Cancellation
    
    private func scheduleRelay(_ packet: BitchatPacket, messageID: String, delay: TimeInterval) {
        pendingRelaysLock.lock()
        defer { pendingRelaysLock.unlock() }
        
        // Cancel any existing relay for this message
        if let existingRelay = pendingRelays[messageID] {
            existingRelay.cancel()
        }
        
        // Apply smart collision avoidance to delay
        let adjustedDelay = smartCollisionAvoidanceDelay(baseDelay: delay)
        
        // Create new relay task
        let relayTask = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            // Remove from pending when executed
            self.pendingRelaysLock.lock()
            self.pendingRelays.removeValue(forKey: messageID)
            self.pendingRelaysLock.unlock()
            
            // Mark this message as relayed
            self.processedMessagesLock.lock()
            if var state = self.processedMessages[messageID] {
                state.relayed = true
                self.processedMessages[messageID] = state
            }
            self.processedMessagesLock.unlock()
            
            // Actually relay the packet
            self.broadcastPacket(packet)
        }
        
        // Store the task
        pendingRelays[messageID] = relayTask
        
        // Schedule it with adjusted delay
        DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + adjustedDelay, execute: relayTask)
    }
    
    private func cancelPendingRelay(messageID: String) {
        pendingRelaysLock.lock()
        defer { pendingRelaysLock.unlock() }
        
        if let pendingRelay = pendingRelays[messageID] {
            pendingRelay.cancel()
            pendingRelays.removeValue(forKey: messageID)
            // Cancelled pending relay - another node handled it
        }
    }
    
    // MARK: - Memory Management
    
    private func startMemoryCleanupTimer() {
        memoryCleanupTimer?.invalidate()
        memoryCleanupTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.performMemoryCleanup()
        }
    }
    
    private func performMemoryCleanup() {
        messageQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            let startTime = Date()
            
            // Clean up old fragments
            let fragmentTimeout = Date().addingTimeInterval(-self.fragmentTimeout)
            var expiredFragments = [String]()
            for (fragmentID, metadata) in self.fragmentMetadata {
                if metadata.timestamp < fragmentTimeout {
                    expiredFragments.append(fragmentID)
                }
            }
            for fragmentID in expiredFragments {
                self.incomingFragments.removeValue(forKey: fragmentID)
                self.fragmentMetadata.removeValue(forKey: fragmentID)
            }
            
            // Limit pending private messages
            if self.pendingPrivateMessages.count > self.maxPendingPrivateMessages {
                let excess = self.pendingPrivateMessages.count - self.maxPendingPrivateMessages
                let keysToRemove = Array(self.pendingPrivateMessages.keys.prefix(excess))
                for key in keysToRemove {
                    self.pendingPrivateMessages.removeValue(forKey: key)
                }
                SecureLogger.log("Removed \(excess) oldest pending private message queues", 
                               category: SecureLogger.session, level: .info)
            }
            
            // Limit cached messages sent to peer
            if self.cachedMessagesSentToPeer.count > self.maxCachedMessagesSentToPeer {
                let excess = self.cachedMessagesSentToPeer.count - self.maxCachedMessagesSentToPeer
                let toRemove = self.cachedMessagesSentToPeer.prefix(excess)
                self.cachedMessagesSentToPeer.subtract(toRemove)
                SecureLogger.log("Removed \(excess) oldest cached message tracking entries", 
                               category: SecureLogger.session, level: .debug)
            }
            
            // Clean up pending relays
            self.pendingRelaysLock.lock()
            _ = self.pendingRelays.count
            self.pendingRelaysLock.unlock()
            
            // Clean up rate limiters
            self.cleanupRateLimiters()
            
            // Log memory status
            _ = Date().timeIntervalSince(startTime)
            // Memory cleanup completed
            
            // Estimate current memory usage and log if high
            let estimatedMemory = self.estimateMemoryUsage()
            if estimatedMemory > self.maxMemoryUsageBytes {
                SecureLogger.log("Warning: Estimated memory usage \(estimatedMemory / 1024 / 1024)MB exceeds limit", 
                               category: SecureLogger.session, level: .warning)
            }
        }
    }
    
    private func estimateMemoryUsage() -> Int {
        // Rough estimates based on typical sizes
        let messageSize = 512  // Average message size
        let fragmentSize = 512  // Average fragment size
        
        var totalBytes = 0
        
        // Processed messages (string storage + MessageState)
        processedMessagesLock.lock()
        totalBytes += processedMessages.count * 150  // messageID strings + MessageState struct
        processedMessagesLock.unlock()
        
        // Fragments
        for (_, fragments) in incomingFragments {
            totalBytes += fragments.count * fragmentSize
        }
        
        // Pending private messages
        for (_, messages) in pendingPrivateMessages {
            totalBytes += messages.count * messageSize
        }
        
        // Other caches
        totalBytes += cachedMessagesSentToPeer.count * 50  // peerID strings
        totalBytes += deliveredMessages.count * 100  // messageID strings
        totalBytes += recentlySentMessages.count * 100  // messageID strings
        
        return totalBytes
    }
    
    // MARK: - Rate Limiting
    
    private func isRateLimited(peerID: String, messageType: UInt8) -> Bool {
        rateLimiterLock.lock()
        defer { rateLimiterLock.unlock() }
        
        let now = Date()
        let cutoff = now.addingTimeInterval(-rateLimitWindow)
        
        // Clean old timestamps from total counter
        totalMessageTimestamps.removeAll { $0 < cutoff }
        
        // Check global rate limit with progressive throttling
        if totalMessageTimestamps.count >= maxTotalMessagesPerMinute {
            // Apply progressive throttling for global limit
            let overageRatio = Double(totalMessageTimestamps.count - maxTotalMessagesPerMinute) / Double(maxTotalMessagesPerMinute)
            let dropProbability = min(0.95, 0.5 + overageRatio * 0.5) // 50% to 95% drop rate
            
            if Double.random(in: 0...1) < dropProbability {
                SecureLogger.log("Global rate limit throttling: \(totalMessageTimestamps.count) messages, drop prob: \(Int(dropProbability * 100))%", 
                               category: SecureLogger.security, level: .warning)
                return true
            }
        }
        
        // Determine which rate limiter to use based on message type
        let isChatMessage = messageType == MessageType.message.rawValue
        
        let limiter = isChatMessage ? messageRateLimiter : protocolMessageRateLimiter
        let maxPerMinute = isChatMessage ? maxChatMessagesPerPeerPerMinute : maxProtocolMessagesPerPeerPerMinute
        
        // Clean old timestamps for this peer
        if var timestamps = limiter[peerID] {
            timestamps.removeAll { $0 < cutoff }
            
            // Update the appropriate limiter
            if isChatMessage {
                messageRateLimiter[peerID] = timestamps
            } else {
                protocolMessageRateLimiter[peerID] = timestamps
            }
            
            // Progressive throttling for per-peer limit
            if timestamps.count >= maxPerMinute {
                // Calculate how much over the limit we are
                let overageRatio = Double(timestamps.count - maxPerMinute) / Double(maxPerMinute)
                
                // Progressive drop probability: starts at 30% when just over limit, increases to 90%
                let dropProbability = min(0.9, 0.3 + overageRatio * 0.6)
                
                if Double.random(in: 0...1) < dropProbability {
                    let messageTypeStr = isChatMessage ? "chat" : "protocol"
                    SecureLogger.log("Peer \(peerID) \(messageTypeStr) rate throttling: \(timestamps.count) msgs/min, drop prob: \(Int(dropProbability * 100))%", 
                                   category: SecureLogger.security, level: .info)
                    return true
                } else {
                    SecureLogger.log("Peer \(peerID) rate throttling: allowing message (\(timestamps.count) msgs/min)", 
                                   category: SecureLogger.security, level: .debug)
                }
            }
        }
        
        return false
    }
    
    private func recordMessage(from peerID: String, messageType: UInt8) {
        rateLimiterLock.lock()
        defer { rateLimiterLock.unlock() }
        
        let now = Date()
        
        // Record in global counter
        totalMessageTimestamps.append(now)
        
        // Determine which rate limiter to use based on message type
        let isChatMessage = messageType == MessageType.message.rawValue
        
        // Record for specific peer in the appropriate limiter
        if isChatMessage {
            if messageRateLimiter[peerID] == nil {
                messageRateLimiter[peerID] = []
            }
            messageRateLimiter[peerID]?.append(now)
        } else {
            if protocolMessageRateLimiter[peerID] == nil {
                protocolMessageRateLimiter[peerID] = []
            }
            protocolMessageRateLimiter[peerID]?.append(now)
        }
    }
    
    private func cleanupRateLimiters() {
        rateLimiterLock.lock()
        defer { rateLimiterLock.unlock() }
        
        let cutoff = Date().addingTimeInterval(-rateLimitWindow)
        
        // Clean global timestamps
        totalMessageTimestamps.removeAll { $0 < cutoff }
        
        // Clean up old identity announce tracking
        processedMessagesLock.lock()
        let identityCutoff = Date().addingTimeInterval(-identityAnnounceDuplicateWindow * 2)
        recentIdentityAnnounces = recentIdentityAnnounces.filter { $0.value > identityCutoff }
        processedMessagesLock.unlock()
        
        // Clean per-peer chat message timestamps
        for (peerID, timestamps) in messageRateLimiter {
            let filtered = timestamps.filter { $0 >= cutoff }
            if filtered.isEmpty {
                messageRateLimiter.removeValue(forKey: peerID)
            } else {
                messageRateLimiter[peerID] = filtered
            }
        }
        
        // Clean per-peer protocol message timestamps
        for (peerID, timestamps) in protocolMessageRateLimiter {
            let filtered = timestamps.filter { $0 >= cutoff }
            if filtered.isEmpty {
                protocolMessageRateLimiter.removeValue(forKey: peerID)
            } else {
                protocolMessageRateLimiter[peerID] = filtered
            }
        }
        
        SecureLogger.log("Rate limiter cleanup: tracking \(messageRateLimiter.count) chat peers, \(protocolMessageRateLimiter.count) protocol peers, \(totalMessageTimestamps.count) total messages", 
                       category: SecureLogger.session, level: .debug)
    }
    
    
    private func updatePeerLastSeen(_ peerID: String) {
        peerLastSeenTimestamps.set(peerID, value: Date())
    }
    
    private func sendPendingPrivateMessages(to peerID: String) {
        messageQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            // Get pending messages with proper queue synchronization
            let pendingMessages = self.collectionsQueue.sync {
                return self.pendingPrivateMessages[peerID]
            }
            
            guard let messages = pendingMessages else { return }
            
            // Sending pending private messages
            
            // Clear pending messages for this peer
            self.collectionsQueue.sync(flags: .barrier) {
                _ = self.pendingPrivateMessages.removeValue(forKey: peerID)
            }
            
            // Send each pending message
            for (content, recipientNickname, messageID) in messages {
                // Check if this is a read receipt
                if content.hasPrefix("READ_RECEIPT:") {
                    // Extract the original message ID
                    let originalMessageID = String(content.dropFirst("READ_RECEIPT:".count))
                    // Sending queued read receipt
                    
                    // Create and send the actual read receipt
                    let receipt = ReadReceipt(
                        originalMessageID: originalMessageID,
                        readerID: self.myPeerID,
                        readerNickname: recipientNickname // This is actually the reader's nickname
                    )
                    
                    // Send the read receipt using the normal method
                    DispatchQueue.global().async { [weak self] in
                        self?.sendReadReceipt(receipt, to: peerID)
                    }
                } else {
                    // Regular message
                    // Sending pending message
                    // Use async to avoid blocking the queue
                    DispatchQueue.global().async { [weak self] in
                        self?.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
                    }
                }
            }
        }
    }
    
    // MARK: - Noise Protocol Support
    
    private func attemptHandshakeIfNeeded(with peerID: String, forceIfStale: Bool = false) {
        // Check if we already have an established session
        if noiseService.hasEstablishedSession(with: peerID) {
            SecureLogger.log("Already have established session with \(peerID), skipping handshake", 
                           category: SecureLogger.handshake, level: .debug)
            return
        }
        
        // Check if we should initiate using the handshake coordinator
        if !handshakeCoordinator.shouldInitiateHandshake(
            myPeerID: myPeerID, 
            remotePeerID: peerID,
            forceIfStale: forceIfStale
        ) {
            SecureLogger.log("Should not initiate handshake with \(peerID) at this time", 
                           category: SecureLogger.handshake, level: .debug)
            return
        }
        
        // Initiate the handshake
        initiateNoiseHandshake(with: peerID)
    }
    
    // Send keep-alive pings to all connected peers to prevent iOS BLE timeouts
    private func sendKeepAlivePings() {
        let connectedPeers = collectionsQueue.sync {
            return self.peerSessions.compactMap { (peerID, session) -> String? in
                guard session.isActivePeer else { return nil }
                
                // Only send keepalive to authenticated peers that still exist
                // Check if this peer ID is still current (not rotated)
                guard let fingerprint = peerIDToFingerprint[peerID],
                      let currentPeerID = fingerprintToPeerID[fingerprint],
                      currentPeerID == peerID else {
                    // This peer ID has rotated, skip it
                    return nil
                }
                
                // Check if we actually have a Noise session with this peer
                guard noiseService.hasEstablishedSession(with: peerID) else {
                    return nil
                }
                
                return peerConnectionStates[peerID] == .authenticated ? peerID : nil
            }
        }
        
        
        for peerID in connectedPeers {
            // Don't spam if we recently heard from them
            let lastHeard = self.peerSessions[peerID]?.lastHeardFromPeer
            if let lastHeard = lastHeard, 
               Date().timeIntervalSince(lastHeard) < keepAliveInterval / 2 {
                continue  // Skip if we heard from them in the last 10 seconds
            }
            
            validateNoiseSession(with: peerID)
        }
    }
    
    // Validate an existing Noise session by sending an encrypted ping
    private func validateNoiseSession(with peerID: String) {
        let encryptionQueue = getEncryptionQueue(for: peerID)
        
        encryptionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Create a ping packet with minimal data
            let pingData = "ping:\(Date().timeIntervalSince1970)".data(using: .utf8)!
            
            do {
                // Try to encrypt a small ping message
                let encrypted = try self.noiseService.encrypt(pingData, for: peerID)
                
                // Create a validation packet (won't be displayed to user)
                let packet = BitchatPacket(
                    type: MessageType.systemValidation.rawValue,
                    senderID: Data(hexString: self.myPeerID) ?? Data(),
                    recipientID: Data(hexString: peerID),
                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                    payload: encrypted,
                    signature: nil,
                    ttl: 1                )
                
                // System validation should go directly to the peer when possible
                if !self.sendDirectToRecipient(packet, recipientPeerID: peerID) {
                    // Fall back to selective relay if direct delivery fails
                    self.sendViaSelectiveRelay(packet, recipientPeerID: peerID)
                }
                
                SecureLogger.log("Sent session validation ping to \(peerID)", 
                               category: SecureLogger.session, level: .debug)
            } catch {
                // Encryption failed - session is invalid
                SecureLogger.log("Session validation failed for \(peerID): \(error)", 
                               category: SecureLogger.session, level: .warning)
                
                // Clear the invalid session
                self.cleanupPeerCryptoState(peerID)
                
                // Initiate fresh handshake
                DispatchQueue.main.async { [weak self] in
                    self?.attemptHandshakeIfNeeded(with: peerID, forceIfStale: true)
                }
            }
        }
    }
    
    private func initiateNoiseHandshake(with peerID: String) {
        // Use noiseService directly
        
        // Initiating Noise handshake
        
        // Safety check: Don't handshake with ourselves
        if peerID == myPeerID {
            SecureLogger.log("[CRITICAL] Attempted to handshake with self! peerID=\(peerID), myPeerID=\(myPeerID)", 
                           category: SecureLogger.handshake, level: .error)
            return
        }
        
        // Check if we already have an established session
        if noiseService.hasEstablishedSession(with: peerID) {
            // Already have established session
            // Clear any lingering handshake attempt time
            handshakeAttemptTimes.removeValue(forKey: peerID)
            handshakeCoordinator.recordHandshakeSuccess(peerID: peerID)
            
            // Update session state to established
            collectionsQueue.sync(flags: .barrier) {
                self.noiseSessionStates[peerID] = .established
            }
            
            // Update connection state to authenticated
            updatePeerConnectionState(peerID, state: .authenticated)
            
            // Force UI update since we have an existing session
            DispatchQueue.main.async { [weak self] in
                (self?.delegate as? ChatViewModel)?.updateEncryptionStatusForPeers()
            }
            
            return
        }
        
        // Update state to handshaking
        collectionsQueue.sync(flags: .barrier) {
            self.noiseSessionStates[peerID] = .handshaking
        }
        
        // Check if we have pending messages
        let hasPendingMessages = collectionsQueue.sync {
            return pendingPrivateMessages[peerID]?.isEmpty == false
        }
        
        // Check with coordinator if we should initiate
        if !handshakeCoordinator.shouldInitiateHandshake(myPeerID: myPeerID, remotePeerID: peerID, forceIfStale: hasPendingMessages) {
            // Coordinator says no handshake
            
            if hasPendingMessages {
                // Check if peer is still connected before retrying
                let connectionState = collectionsQueue.sync { peerConnectionStates[peerID] ?? .disconnected }
                
                if connectionState == .disconnected {
                    // Peer is disconnected - clear pending messages and stop retrying
                    // Peer disconnected, clearing pending
                    collectionsQueue.async(flags: .barrier) { [weak self] in
                        self?.pendingPrivateMessages[peerID]?.removeAll()
                    }
                    handshakeCoordinator.resetHandshakeState(for: peerID)
                } else {
                    // Peer is still connected but handshake is stuck
                    // Send identity announce to prompt them to initiate if they have lower ID
                    // Handshake stuck, sending identity
                    sendNoiseIdentityAnnounce(to: peerID)
                    
                    // Only retry if we haven't retried too many times
                    let retryCount = handshakeCoordinator.getRetryCount(for: peerID)
                    if retryCount < 3 {
                        handshakeCoordinator.incrementRetryCount(for: peerID)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                            self?.initiateNoiseHandshake(with: peerID)
                        }
                    } else {
                        SecureLogger.log("Max retries reached for \(peerID), clearing pending messages", category: SecureLogger.handshake, level: .warning)
                        collectionsQueue.async(flags: .barrier) { [weak self] in
                            self?.pendingPrivateMessages[peerID]?.removeAll()
                        }
                        handshakeCoordinator.resetHandshakeState(for: peerID)
                    }
                }
            }
            return
        }
        
        // Check if there's a retry delay
        if let retryDelay = handshakeCoordinator.getRetryDelay(for: peerID), retryDelay > 0 {
            // Waiting before retry
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                self?.initiateNoiseHandshake(with: peerID)
            }
            return
        }
        
        // Record that we're initiating
        handshakeCoordinator.recordHandshakeInitiation(peerID: peerID)
        handshakeAttemptTimes[peerID] = Date()
        
        // Update connection state to authenticating
        updatePeerConnectionState(peerID, state: .authenticating)
        
        do {
            // Generate handshake initiation message
            let handshakeData = try noiseService.initiateHandshake(with: peerID)
            SecureLogger.logHandshake("initiated", peerID: peerID, success: true)
            
            // Send handshake initiation
            let packet = BitchatPacket(
                type: MessageType.noiseHandshakeInit.rawValue,
                senderID: Data(hexString: myPeerID) ?? Data(),
                recipientID: Data(hexString: peerID) ?? Data(), // Add recipient ID for targeted delivery
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: handshakeData,
                signature: nil,
                ttl: 6 // Increased TTL for better delivery on startup
            )
            
            // Track packet for ACK
            trackPacketForAck(packet)
            
            // Try direct delivery first for handshake init
            if !sendDirectToRecipient(packet, recipientPeerID: peerID) {
                // Handshakes are critical - use broadcast as fallback to ensure delivery
                SecureLogger.log("Recipient \(peerID) not directly connected for handshake init, using broadcast", 
                               category: SecureLogger.session, level: .info)
                broadcastPacket(packet)
            }
            
            // Schedule a retry check after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self = self else { return }
                // Check if handshake completed
                if !self.noiseService.hasEstablishedSession(with: peerID) {
                    let state = self.handshakeCoordinator.getHandshakeState(for: peerID)
                    if case .initiating = state {
                        SecureLogger.log("Handshake with \(peerID) not completed after 5s, will retry", category: SecureLogger.handshake, level: .warning)
                        // The handshake coordinator will handle retry logic
                    }
                }
            }
            
        } catch NoiseSessionError.alreadyEstablished {
            // Session already established, no need to handshake
            handshakeCoordinator.recordHandshakeSuccess(peerID: peerID)
        } catch {
            // Failed to initiate handshake
            handshakeCoordinator.recordHandshakeFailure(peerID: peerID, reason: error.localizedDescription)
            SecureLogger.logSecurityEvent(.handshakeFailed(peerID: peerID, error: error.localizedDescription))
        }
    }
    
    private func handleNoiseHandshakeMessage(from peerID: String, message: Data, isInitiation: Bool) {
        // Use noiseService directly
        SecureLogger.logHandshake("processing \(isInitiation ? "init" : "response")", peerID: peerID, success: true)
        
        // Get current handshake state before processing
        let _ = handshakeCoordinator.getHandshakeState(for: peerID)
        let _ = noiseService.hasEstablishedSession(with: peerID)
        // Current handshake state check
        
        // Check for duplicate handshake messages
        if handshakeCoordinator.isDuplicateHandshakeMessage(message) {
            // Duplicate handshake message, ignoring
            return
        }
        
        // If this is an initiation, check if we should accept it
        if isInitiation {
            if !handshakeCoordinator.shouldAcceptHandshakeInitiation(myPeerID: myPeerID, remotePeerID: peerID) {
                // Coordinator says no accept
                return
            }
            // Record that we're responding
            handshakeCoordinator.recordHandshakeResponse(peerID: peerID)
            
            // Update connection state to authenticating
            updatePeerConnectionState(peerID, state: .authenticating)
        }
        
        do {
            // Process handshake message
            if let response = try noiseService.processHandshakeMessage(from: peerID, message: message) {
                // Handshake response ready to send
                
                // Always send responses as handshake response type
                let packet = BitchatPacket(
                    type: MessageType.noiseHandshakeResp.rawValue,
                    senderID: Data(hexString: myPeerID) ?? Data(),
                    recipientID: Data(hexString: peerID) ?? Data(), // Add recipient ID for targeted delivery
                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                    payload: response,
                    signature: nil,
                    ttl: 6  // Increased TTL for better delivery on startup
                )
                
                // Track packet for ACK
                trackPacketForAck(packet)
                
                // Try direct delivery first for handshake response
                if !sendDirectToRecipient(packet, recipientPeerID: peerID) {
                    // Handshakes are critical - use broadcast as fallback to ensure delivery
                    SecureLogger.log("Recipient \(peerID) not directly connected for handshake response, using broadcast", 
                                   category: SecureLogger.session, level: .info)
                    broadcastPacket(packet)
                }
            } else {
                // No response needed
            }
            
            // Check if handshake is complete
            let sessionEstablished = noiseService.hasEstablishedSession(with: peerID)
            _ = handshakeCoordinator.getHandshakeState(for: peerID)
            // Handshake state updated
            
            if sessionEstablished {
                SecureLogger.logSecurityEvent(.handshakeCompleted(peerID: peerID))
                // Unlock rotation now that handshake is complete
                unlockRotation()
                
                // Session established successfully
                handshakeCoordinator.recordHandshakeSuccess(peerID: peerID)
                
                // Update session state to established
                collectionsQueue.sync(flags: .barrier) {
                    self.noiseSessionStates[peerID] = .established
                }
                
                // Update connection state to authenticated
                updatePeerConnectionState(peerID, state: .authenticated)
                
                // Clear handshake attempt time on success
                handshakeAttemptTimes.removeValue(forKey: peerID)
                
                // Initialize last successful message time
                updateLastSuccessfulMessageTime(peerID)
                // Initialized message time
                
                // Update PeerSession
                if let session = self.peerSessions[peerID] {
                    session.lastSuccessfulMessageTime = Date()
                } else {
                    let nickname = self.getBestAvailableNickname(for: peerID)
                    let session = PeerSession(peerID: peerID, nickname: nickname)
                    session.lastSuccessfulMessageTime = Date()
                    self.peerSessions[peerID] = session
                }
                
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
            // Handshake already established
            handshakeCoordinator.recordHandshakeSuccess(peerID: peerID)
            
            // Update session state to established
            collectionsQueue.sync(flags: .barrier) {
                self.noiseSessionStates[peerID] = .established
            }
        } catch {
            // Handshake failed
            handshakeCoordinator.recordHandshakeFailure(peerID: peerID, reason: error.localizedDescription)
            SecureLogger.logSecurityEvent(.handshakeFailed(peerID: peerID, error: error.localizedDescription))
            SecureLogger.log("Handshake failed with \(peerID): \(error)", category: SecureLogger.noise, level: .error)
            
            // Update session state to failed
            collectionsQueue.sync(flags: .barrier) {
                self.noiseSessionStates[peerID] = .failed(error)
            }
            
            // If handshake failed due to authentication error, clear the session to allow retry
            if case NoiseError.authenticationFailure = error {
                SecureLogger.log("Handshake failed with \(peerID): authenticationFailure - clearing session", category: SecureLogger.noise, level: .warning)
                cleanupPeerCryptoState(peerID)
            }
        }
    }
    
    private func handleNoiseEncryptedMessage(from peerID: String, encryptedData: Data, originalPacket: BitchatPacket, peripheral: CBPeripheral? = nil) {
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
            // Attempting to decrypt
            let decryptedData = try noiseService.decrypt(encryptedData, from: peerID)
            // Successfully decrypted message
            
            // Update last successful message time
            updateLastSuccessfulMessageTime(peerID)
            
            // Note: PeerSession already updated in helper
            if let session = self.peerSessions[peerID] {
                session.lastSuccessfulMessageTime = Date()
            }
            
            // Send protocol ACK after successful decryption (only once per encrypted packet)
            sendProtocolAck(for: originalPacket, to: peerID)
            
            // If we can decrypt messages from this peer, they should be marked as active
            let wasAdded = collectionsQueue.sync(flags: .barrier) {
                let isActive = self.peerSessions[peerID]?.isActivePeer ?? false
                if !isActive {
                    // Marking peer as active
                    // Update PeerSession
                    if let session = self.peerSessions[peerID] {
                        session.isActivePeer = true
                    } else {
                        let nickname = self.getBestAvailableNickname(for: peerID)
                        let session = PeerSession(peerID: peerID, nickname: nickname)
                        session.isActivePeer = true
                        self.peerSessions[peerID] = session
                    }
                    // Mark as active and return true if newly activated
                    let wasActive = self.peerSessions[peerID]?.isActivePeer ?? false
                    self.peerSessions[peerID]?.isActivePeer = true
                    return !wasActive
                }
                return false
            }
            
            if wasAdded {
                // Notify about peer list update
                self.notifyPeerListUpdate()
            }
            
            // Check if this is a special format message (type marker + payload)
            if decryptedData.count > 1 {
                let typeMarker = decryptedData[0]
                
                // Check if this is a delivery ACK with the new format
                if typeMarker == MessageType.deliveryAck.rawValue {
                    // Extract the ACK JSON data (skip the type marker)
                    let ackData = decryptedData.dropFirst()
                    
                    // Decode the delivery ACK - try binary first, then JSON
                    if let ack = DeliveryAck.fromBinaryData(ackData) {
                        // Received binary delivery ACK
                        
                        // Process the ACK
                        DeliveryTracker.shared.processDeliveryAck(ack)
                        
                        // Notify delegate
                        DispatchQueue.main.async {
                            self.delegate?.didReceiveDeliveryAck(ack)
                        }
                        return
                    } else if let ack = DeliveryAck.decode(from: ackData) {
                        // Received JSON delivery ACK
                        
                        // Process the ACK
                        DeliveryTracker.shared.processDeliveryAck(ack)
                        
                        // Notify delegate
                        DispatchQueue.main.async {
                            self.delegate?.didReceiveDeliveryAck(ack)
                        }
                        return
                    } else {
                        SecureLogger.log("Failed to decode delivery ACK via Noise - data size: \(ackData.count)", category: SecureLogger.session, level: .warning)
                    }
                }
                
                // Check if this is a read receipt with the new format
                else if typeMarker == MessageType.readReceipt.rawValue {
                    // Extract the receipt binary data (skip the type marker)
                    let receiptData = decryptedData.dropFirst()
                    
                    // Decode the read receipt from binary
                    if let receipt = ReadReceipt.fromBinaryData(receiptData) {
                        // Received binary read receipt
                        
                        // Process the read receipt
                        DispatchQueue.main.async {
                            self.delegate?.didReceiveReadReceipt(receipt)
                        }
                        return
                    } else {
                        SecureLogger.log("Failed to decode read receipt via Noise - data size: \(receiptData.count)", category: SecureLogger.session, level: .warning)
                    }
                }
            }
            
            // Try to parse as a full inner packet (for backward compatibility and other message types)
            if let innerPacket = BitchatPacket.from(decryptedData) {
                // Successfully parsed inner packet
                
                // Process the decrypted inner packet
                // The packet will be handled according to its recipient ID
                // If it's for us, it won't be relayed
                // Pass the peripheral context for proper ACK routing
                handleReceivedPacket(innerPacket, from: peerID, peripheral: peripheral)
            } else {
                SecureLogger.log("Failed to parse inner packet from decrypted data", category: SecureLogger.encryption, level: .warning)
            }
        } catch {
            // Failed to decrypt - might need to re-establish session
            SecureLogger.log("Failed to decrypt Noise message from \(peerID): \(error)", category: SecureLogger.encryption, level: .error)
            if !noiseService.hasEstablishedSession(with: peerID) {
                // No Noise session, attempting handshake
                attemptHandshakeIfNeeded(with: peerID, forceIfStale: true)
            } else {
                SecureLogger.log("Have session with \(peerID) but decryption failed", category: SecureLogger.encryption, level: .warning)
                
                // Send a NACK to inform peer that decryption failed
                sendProtocolNack(for: originalPacket, to: peerID,
                               reason: "Decryption failed",
                               errorCode: .decryptionFailed)
                
                // The NACK handler will take care of clearing sessions and re-establishing
                // Don't initiate anything here to avoid race conditions
                
                // Update UI to show encryption is broken
                DispatchQueue.main.async { [weak self] in
                    if let chatVM = self?.delegate as? ChatViewModel {
                        chatVM.updateEncryptionStatusForPeer(peerID)
                    }
                }
            }
        }
    }
    
    
    // MARK: - Protocol Version Negotiation
    
    private func handleVersionHello(from peerID: String, data: Data, peripheral: CBPeripheral? = nil) {
        // Create a copy to avoid potential race conditions
        let dataCopy = Data(data)
        
        // Safety check for empty data
        guard !dataCopy.isEmpty else {
            SecureLogger.log("Received empty version hello data from \(peerID)", category: SecureLogger.session, level: .error)
            return
        }
        
        // Check if this peer is reconnecting after disconnect
        if let session = peerSessions[peerID], let lastConnected = session.lastConnectionTime {
            let timeSinceLastConnection = Date().timeIntervalSince(lastConnected)
            // Only clear truly stale sessions, not on every reconnect
            if timeSinceLastConnection > 86400.0 { // More than 24 hours since last connection
                // Clear any stale Noise session
                if noiseService.hasEstablishedSession(with: peerID) {
                    // Clearing stale session on reconnect
                    cleanupPeerCryptoState(peerID)
                }
            } else if timeSinceLastConnection > 5.0 {
                // Just log the reconnection, don't clear the session
                // Keeping existing session on reconnect
            }
        }
        
        // Update last connection time
        updateLastConnectionTime(peerID)
        
        // Note: PeerSession already updated in helper
        if let session = peerSessions[peerID] {
            session.lastConnectionTime = Date()
        } else {
            let nickname = getBestAvailableNickname(for: peerID)
            let session = PeerSession(peerID: peerID, nickname: nickname)
            session.lastConnectionTime = Date()
            peerSessions[peerID] = session
        }
        
        // Check if we've already negotiated version with this peer
        if let existingVersion = negotiatedVersions[peerID] {
            SecureLogger.log("Already negotiated version \(existingVersion) with \(peerID), skipping re-negotiation", 
                           category: SecureLogger.session, level: .debug)
            // If we have a session, validate it
            if noiseService.hasEstablishedSession(with: peerID) {
                validateNoiseSession(with: peerID)
            }
            return
        }
        
        // Try JSON first if it looks like JSON
        let hello: VersionHello?
        if let firstByte = dataCopy.first, firstByte == 0x7B { // '{' character
            // Version hello is JSON
            hello = VersionHello.decode(from: dataCopy) ?? VersionHello.fromBinaryData(dataCopy)
        } else {
            // Version hello is binary
            hello = VersionHello.fromBinaryData(dataCopy) ?? VersionHello.decode(from: dataCopy)
        }
        
        guard let hello = hello else {
            SecureLogger.log("Failed to decode version hello from \(peerID)", category: SecureLogger.session, level: .error)
            return
        }
        
        SecureLogger.log("Received version hello from \(peerID): supported versions \(hello.supportedVersions), preferred \(hello.preferredVersion)", 
                          category: SecureLogger.session, level: .debug)
        
        // Track when we received version hello from this peer
        collectionsQueue.async(flags: .barrier) { [weak self] in
            self?.lastVersionHelloTime[peerID] = Date()
        }
        
        // Find the best common version
        let ourVersions = Array(ProtocolVersion.supportedVersions)
        if let agreedVersion = ProtocolVersion.negotiateVersion(clientVersions: hello.supportedVersions, serverVersions: ourVersions) {
            // We can communicate! Send ACK
            // Version negotiation agreed
            negotiatedVersions[peerID] = agreedVersion
            versionNegotiationState[peerID] = .ackReceived(version: agreedVersion)
            
            // Cache the negotiated version for future connections
            let now = Date()
            versionCache[peerID] = CachedVersion(
                version: agreedVersion,
                cachedAt: now,
                expiresAt: now.addingTimeInterval(versionCacheDuration)
            )
            SecureLogger.log("📘 Cached version \(agreedVersion) for \(peerID)", 
                           category: SecureLogger.session, level: .debug)
            
            let ack = VersionAck(
                agreedVersion: agreedVersion,
                serverVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                platform: getPlatformString()
            )
            
            sendVersionAck(ack, to: peerID)
            
            // Lazy handshake: No longer initiate handshake after version negotiation
            // Just announce our identity
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                
                // Just announce our identity
                self.sendNoiseIdentityAnnounce()
                
                SecureLogger.log("Version negotiation complete with \(peerID) - lazy handshake mode", 
                               category: SecureLogger.handshake, level: .info)
            }
        } else {
            // No compatible version
            SecureLogger.log("Version negotiation failed with \(peerID): No compatible version (client supports: \(hello.supportedVersions))", category: SecureLogger.session, level: .warning)
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
        // Create a copy to avoid potential race conditions
        let dataCopy = Data(data)
        
        // Safety check for empty data
        guard !dataCopy.isEmpty else {
            SecureLogger.log("Received empty version ack data from \(peerID)", category: SecureLogger.session, level: .error)
            return
        }
        
        // Try JSON first if it looks like JSON
        let ack: VersionAck?
        if let firstByte = dataCopy.first, firstByte == 0x7B { // '{' character
            ack = VersionAck.decode(from: dataCopy) ?? VersionAck.fromBinaryData(dataCopy)
        } else {
            ack = VersionAck.fromBinaryData(dataCopy) ?? VersionAck.decode(from: dataCopy)
        }
        
        guard let ack = ack else {
            SecureLogger.log("Failed to decode version ack from \(peerID)", category: SecureLogger.session, level: .error)
            return
        }
        
        if ack.rejected {
            SecureLogger.log("Version negotiation rejected by \(peerID): \(ack.reason ?? "Unknown reason")", 
                              category: SecureLogger.session, level: .error)
            versionNegotiationState[peerID] = .failed(reason: ack.reason ?? "Version rejected")
            
            // Clean up state for incompatible peer
            collectionsQueue.sync(flags: .barrier) {
                _ = self.peerSessions.removeValue(forKey: peerID)
            }
            // Update PeerSession
            if let session = self.peerSessions[peerID] {
                session.hasReceivedAnnounce = false
            }
            
            // Clean up any Noise session
            cleanupPeerCryptoState(peerID)
            
            // Notify delegate about incompatible peer disconnection
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didDisconnectFromPeer(peerID)
            }
        } else {
            // Version negotiation successful
            negotiatedVersions[peerID] = ack.agreedVersion
            versionNegotiationState[peerID] = .ackReceived(version: ack.agreedVersion)
            
            // Cache the negotiated version for future connections
            let now = Date()
            versionCache[peerID] = CachedVersion(
                version: ack.agreedVersion,
                cachedAt: now,
                expiresAt: now.addingTimeInterval(versionCacheDuration)
            )
            SecureLogger.log("📘 Cached version \(ack.agreedVersion) for \(peerID)", 
                           category: SecureLogger.session, level: .debug)
            
            // If we were the initiator (sent hello first), proceed with Noise handshake
            // Note: Since we're handling their ACK, they initiated, so we should not initiate again
            // The peer who sent hello will initiate the Noise handshake
        }
    }
    
    private func sendVersionHello(to peripheral: CBPeripheral? = nil, peripheralID: String? = nil) {
        // Check if we have the peer ID for this peripheral
        if let peripheralID = peripheralID,
           let peerID = peerIDByPeripheralID[peripheralID] {
            // Check version cache for this peer
            if let cached = versionCache[peerID], !cached.isExpired {
                // Skip negotiation - use cached version
                negotiatedVersions[peerID] = cached.version
                versionNegotiationState[peerID] = .ackReceived(version: cached.version)
                
                // Proceed directly to Noise handshake
                if peripheral != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.initiateNoiseHandshake(with: peerID)
                    }
                }
                return
            }
            
            // Check for duplicate version hello
            if shouldSuppressProtocolMessage(to: peerID, type: .versionHello) {
                return
            }
        }
        
        let hello = VersionHello(
            clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            platform: getPlatformString()
        )
        
        let helloData = hello.toBinaryData()
        
        let packet = BitchatPacket(
            type: MessageType.versionHello.rawValue,
            ttl: 1,  // Version negotiation is direct, no relay
            senderID: myPeerID,
            payload: helloData        )
        
        // Mark that we initiated version negotiation
        // We don't know the peer ID yet from peripheral, so we'll track it when we get the response
        
        if let peripheral = peripheral,
           let characteristic = peripheralCharacteristics[peripheral] {
            // Send directly to specific peripheral
            if let data = packet.toBinaryData() {
                writeToPeripheral(data, peripheral: peripheral, characteristic: characteristic, peerID: nil)
                
                // Record if we know the peer ID
                if let peripheralID = peripheralID,
                   let peerID = peerIDByPeripheralID[peripheralID] {
                    recordProtocolMessageSent(to: peerID, type: .versionHello)
                }
            }
        } else {
            // Broadcast to all
            broadcastPacket(packet)
            recordProtocolMessageSent(to: "broadcast", type: .versionHello)
        }
    }
    
    private func sendVersionAck(_ ack: VersionAck, to peerID: String) {
        // Check for duplicate suppression
        if shouldSuppressProtocolMessage(to: peerID, type: .versionAck) {
            return
        }
        
        let ackData = ack.toBinaryData()
        
        let packet = BitchatPacket(
            type: MessageType.versionAck.rawValue,
            senderID: Data(myPeerID.utf8),
            recipientID: Data(peerID.utf8),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: ackData,
            signature: nil,
            ttl: 1  // Direct response, no relay
        )
        
        // Version ACKs should go directly to the peer when possible
        if !sendDirectToRecipient(packet, recipientPeerID: peerID) {
            // Fall back to selective relay if direct delivery fails
            sendViaSelectiveRelay(packet, recipientPeerID: peerID)
        }
        
        // Record that we sent this message
        recordProtocolMessageSent(to: peerID, type: .versionAck)
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
    
    // MARK: - Protocol ACK/NACK Handling
    
    private func handleProtocolAck(from peerID: String, data: Data) {
        guard let ack = ProtocolAck.fromBinaryData(data) else {
            SecureLogger.log("Failed to decode protocol ACK from \(peerID)", category: SecureLogger.session, level: .error)
            return
        }
        
        SecureLogger.log("Received protocol ACK from \(peerID) for packet \(ack.originalPacketID), type: \(ack.packetType), ackID: \(ack.ackID)", 
                       category: SecureLogger.session, level: .debug)
        
        // Remove from pending ACKs and mark as acknowledged
        // Note: readUUID returns uppercase, but we track with lowercase
        let normalizedPacketID = ack.originalPacketID.lowercased()
        _ = collectionsQueue.sync(flags: .barrier) {
            pendingAcks.removeValue(forKey: normalizedPacketID)
        }
        
        // Track this packet as acknowledged to prevent future retries
        acknowledgedPacketsLock.lock()
        acknowledgedPackets.insert(ack.originalPacketID)
        // Keep only recent acknowledged packets (last 1000)
        if acknowledgedPackets.count > 1000 {
            // Remove oldest entries (this is approximate since Set doesn't maintain order)
            acknowledgedPackets = Set(Array(acknowledgedPackets).suffix(1000))
        }
        acknowledgedPacketsLock.unlock()
        
        // Handle specific packet types that need ACK confirmation
        if let messageType = MessageType(rawValue: ack.packetType) {
            switch messageType {
            case .noiseHandshakeInit, .noiseHandshakeResp:
                // Handshake confirmed
                break
            case .noiseEncrypted:
                // Encrypted message confirmed
                break
            default:
                break
            }
        }
    }
    
    private func handleProtocolNack(from peerID: String, data: Data) {
        guard let nack = ProtocolNack.fromBinaryData(data) else {
            SecureLogger.log("Failed to decode protocol NACK from \(peerID)", category: SecureLogger.session, level: .error)
            return
        }
        
        SecureLogger.log("Received protocol NACK from \(peerID) for packet \(nack.originalPacketID): \(nack.reason)", 
                       category: SecureLogger.session, level: .warning)
        
        // Invalidate version cache on protocol NACK as it might indicate version mismatch
        if nack.reason.lowercased().contains("version") || nack.reason.lowercased().contains("protocol") {
            invalidateVersionCache(for: peerID)
        }
        
        // Remove from pending ACKs
        _ = collectionsQueue.sync(flags: .barrier) {
            pendingAcks.removeValue(forKey: nack.originalPacketID)
        }
        
        // Handle specific error codes
        if let errorCode = ProtocolNack.ErrorCode(rawValue: nack.errorCode) {
            switch errorCode {
            case .decryptionFailed:
                // Session is out of sync - both sides need to clear and re-establish
                SecureLogger.log("Decryption failed at \(peerID), clearing session and re-establishing", 
                               category: SecureLogger.encryption, level: .warning)
                
                // Clear our session state and handshake coordinator state
                cleanupPeerCryptoState(peerID)
                handshakeCoordinator.resetHandshakeState(for: peerID)
                
                // Update connection state
                updatePeerConnectionState(peerID, state: .connected)
                
                // Use deterministic role assignment to prevent race conditions
                let shouldInitiate = handshakeCoordinator.determineHandshakeRole(
                    myPeerID: myPeerID,
                    remotePeerID: peerID
                ) == .initiator
                
                if shouldInitiate {
                    // Small delay to ensure both sides have cleared state
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self = self else { return }
                        SecureLogger.log("Initiating handshake after decryption failure with \(peerID)", 
                                       category: SecureLogger.session, level: .info)
                        self.attemptHandshakeIfNeeded(with: peerID, forceIfStale: true)
                    }
                } else {
                    // Send identity announcement to signal we're ready
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self = self else { return }
                        SecureLogger.log("Sending identity announcement after decryption failure to \(peerID)", 
                                       category: SecureLogger.session, level: .info)
                        self.sendNoiseIdentityAnnounce(to: peerID)
                    }
                }
            case .sessionExpired:
                // Clear session and re-handshake
                SecureLogger.log("Session expired at \(peerID), clearing and re-handshaking", 
                               category: SecureLogger.session, level: .warning)
                cleanupPeerCryptoState(peerID)
                handshakeCoordinator.resetHandshakeState(for: peerID)
                attemptHandshakeIfNeeded(with: peerID, forceIfStale: true)
            default:
                break
            }
        }
    }
    
    private func handleHandshakeRequest(from peerID: String, data: Data) {
        guard let request = HandshakeRequest.fromBinaryData(data) else {
            SecureLogger.log("Failed to decode handshake request from \(peerID)", category: SecureLogger.noise, level: .error)
            return
        }
        
        // Verify this request is for us
        guard request.targetID == myPeerID else {
            // This request is not for us, might need to relay
            return
        }
        
        SecureLogger.log("Received handshake request from \(request.requesterID) (\(request.requesterNickname)) with \(request.pendingMessageCount) pending messages", 
                       category: SecureLogger.noise, level: .info)
        
        // Don't show handshake request notification in UI
        // User requested to remove this notification
        /*
        DispatchQueue.main.async { [weak self] in
            if let chatVM = self?.delegate as? ChatViewModel {
                // Notify the UI that someone wants to send messages
                chatVM.handleHandshakeRequest(from: request.requesterID, 
                                            nickname: request.requesterNickname,
                                            pendingCount: request.pendingMessageCount)
            }
        }
        */
        
        // Check if we already have a session
        if noiseService.hasEstablishedSession(with: peerID) {
            // We already have a session, no action needed
            // Already have session, ignoring request
            return
        }
        
        // Apply tie-breaker logic for handshake initiation
        if myPeerID < peerID {
            // We have lower ID, initiate handshake
            // Initiating handshake in response
            initiateNoiseHandshake(with: peerID)
        } else {
            // We have higher ID, send identity announce to prompt them
            // Sending identity announce
            sendNoiseIdentityAnnounce(to: peerID)
        }
    }
    
    // Send protocol ACK for important packets
    private func sendProtocolAck(for packet: BitchatPacket, to peerID: String, hopCount: UInt8 = 0) {
        // Generate packet ID from packet content hash
        let packetID = generatePacketID(for: packet)
        
        // Debug: log packet details
        _ = packet.senderID.prefix(4).hexEncodedString()
        _ = packet.recipientID?.prefix(4).hexEncodedString() ?? "nil"
        // Send protocol ACK
        
        let ack = ProtocolAck(
            originalPacketID: packetID,
            senderID: packet.senderID.hexEncodedString(),
            receiverID: myPeerID,
            packetType: packet.type,
            hopCount: hopCount
        )
        
        let ackPacket = BitchatPacket(
            type: MessageType.protocolAck.rawValue,
            senderID: Data(hexString: myPeerID) ?? Data(),
            recipientID: Data(hexString: peerID) ?? Data(),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: ack.toBinaryData(),
            signature: nil,
            ttl: 3  // ACKs don't need to travel far
        )
        
        // Protocol ACKs should go directly to the sender when possible
        if !sendDirectToRecipient(ackPacket, recipientPeerID: peerID) {
            // Fall back to selective relay if direct delivery fails
            sendViaSelectiveRelay(ackPacket, recipientPeerID: peerID)
        }
    }
    
    // Send protocol NACK for failed packets
    private func sendProtocolNack(for packet: BitchatPacket, to peerID: String, reason: String, errorCode: ProtocolNack.ErrorCode) {
        let packetID = generatePacketID(for: packet)
        
        let nack = ProtocolNack(
            originalPacketID: packetID,
            senderID: packet.senderID.hexEncodedString(),
            receiverID: myPeerID,
            packetType: packet.type,
            reason: reason,
            errorCode: errorCode
        )
        
        let nackPacket = BitchatPacket(
            type: MessageType.protocolNack.rawValue,
            senderID: Data(hexString: myPeerID) ?? Data(),
            recipientID: Data(hexString: peerID) ?? Data(),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: nack.toBinaryData(),
            signature: nil,
            ttl: 3  // NACKs don't need to travel far
        )
        
        // Protocol NACKs should go directly to the sender when possible
        if !sendDirectToRecipient(nackPacket, recipientPeerID: peerID) {
            // Fall back to selective relay if direct delivery fails
            sendViaSelectiveRelay(nackPacket, recipientPeerID: peerID)
        }
    }
    
    // Generate unique packet ID from immutable packet fields
    private func generatePacketID(for packet: BitchatPacket) -> String {
        // Use only immutable fields for ID generation to ensure consistency
        // across network hops (TTL changes, so can't use full packet data)
        
        // Create a deterministic ID using SHA256 of immutable fields
        var data = Data()
        data.append(packet.senderID)
        data.append(contentsOf: withUnsafeBytes(of: packet.timestamp) { Array($0) })
        data.append(packet.type)
        // Add first 32 bytes of payload for uniqueness
        data.append(packet.payload.prefix(32))
        
        let hash = SHA256.hash(data: data)
        let hashData = Data(hash)
        
        // Take first 16 bytes for UUID format
        let bytes = Array(hashData.prefix(16))
        
        // Format as UUID
        let p1 = String(format: "%02x%02x%02x%02x", bytes[0], bytes[1], bytes[2], bytes[3])
        let p2 = String(format: "%02x%02x", bytes[4], bytes[5])
        let p3 = String(format: "%02x%02x", bytes[6], bytes[7])
        let p4 = String(format: "%02x%02x", bytes[8], bytes[9])
        let p5 = String(format: "%02x%02x%02x%02x%02x%02x", bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        
        let result = "\(p1)-\(p2)-\(p3)-\(p4)-\(p5)"
        
        // Generated packet ID for tracking
        
        return result
    }
    
    // Track packets that need ACKs
    private func trackPacketForAck(_ packet: BitchatPacket) {
        let packetID = generatePacketID(for: packet)
        
        // Debug: log packet details
        _ = packet.senderID.prefix(4).hexEncodedString()
        _ = packet.recipientID?.prefix(4).hexEncodedString() ?? "nil"
        // Track packet for ACK
        
        collectionsQueue.sync(flags: .barrier) {
            pendingAcks[packetID] = (packet: packet, timestamp: Date(), retries: 0)
        }
        
        // Schedule timeout check with initial delay (using exponential backoff starting at 1s)
        let initialDelay = calculateExponentialBackoff(retry: 1) // 1 second initial delay
        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
            self?.checkAckTimeout(for: packetID)
        }
    }
    
    // Check for ACK timeout and retry if needed
    private func checkAckTimeout(for packetID: String) {
        // Check if already acknowledged
        acknowledgedPacketsLock.lock()
        let isAcknowledged = acknowledgedPackets.contains(packetID)
        acknowledgedPacketsLock.unlock()
        
        if isAcknowledged {
            // Already acknowledged, remove from pending and don't retry
            _ = collectionsQueue.sync(flags: .barrier) {
                pendingAcks.removeValue(forKey: packetID)
            }
            SecureLogger.log("Packet \(packetID) already acknowledged, cancelling retries", 
                           category: SecureLogger.session, level: .debug)
            return
        }
        
        collectionsQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self,
                  let pending = self.pendingAcks[packetID] else { return }
            
            // Check if this is a handshake packet and we already have an established session
            if pending.packet.type == MessageType.noiseHandshakeInit.rawValue ||
               pending.packet.type == MessageType.noiseHandshakeResp.rawValue {
                // Extract peer ID from packet
                let peerID = pending.packet.recipientID?.hexEncodedString() ?? ""
                if !peerID.isEmpty && self.noiseService.hasEstablishedSession(with: peerID) {
                    // We have an established session, don't retry handshake packets
                    SecureLogger.log("Not retrying handshake packet \(packetID) - session already established with \(peerID)", 
                                   category: SecureLogger.handshake, level: .info)
                    self.pendingAcks.removeValue(forKey: packetID)
                    return
                }
            }
            
            if pending.retries < self.maxAckRetries {
                // Retry sending the packet
                SecureLogger.log("ACK timeout for packet \(packetID), retrying (attempt \(pending.retries + 1))", 
                               category: SecureLogger.session, level: .warning)
                
                self.pendingAcks[packetID] = (packet: pending.packet, 
                                              timestamp: Date(), 
                                              retries: pending.retries + 1)
                
                // Resend the packet
                SecureLogger.log("Resending packet due to ACK timeout (retry \(pending.retries + 1))", 
                               category: SecureLogger.session, level: .debug)
                DispatchQueue.main.async {
                    self.broadcastPacket(pending.packet)
                }
                
                // Schedule next timeout check with exponential backoff
                let backoffDelay = self.calculateExponentialBackoff(retry: pending.retries + 1)
                DispatchQueue.main.asyncAfter(deadline: .now() + backoffDelay) {
                    self.checkAckTimeout(for: packetID)
                }
            } else {
                // Max retries reached, give up
                SecureLogger.log("Max ACK retries reached for packet \(packetID), giving up", 
                               category: SecureLogger.session, level: .error)
                self.pendingAcks.removeValue(forKey: packetID)
                
                // Could notify upper layer about delivery failure here
            }
        }
    }
    
    // Check all pending ACKs for timeouts (called by timer)
    private func checkAckTimeouts() {
        let now = Date()
        var timedOutPackets: [String] = []
        
        collectionsQueue.sync {
            for (packetID, pending) in pendingAcks {
                if now.timeIntervalSince(pending.timestamp) > ackTimeout {
                    timedOutPackets.append(packetID)
                }
            }
        }
        
        // Process timeouts outside the sync block
        for packetID in timedOutPackets {
            checkAckTimeout(for: packetID)
        }
    }
    
    // Check peer availability based on last heard time
    private func checkPeerAvailability() {
        let now = Date()
        var stateChanges: [(peerID: String, available: Bool)] = []
        
        collectionsQueue.sync(flags: .barrier) {
            // Check all active peers
            for (peerID, session) in peerSessions where session.isActivePeer {
                // Get last heard time from PeerSession or legacy tracking
                let lastHeard: Date
                if let session = peerSessions[peerID] {
                    lastHeard = session.lastHeardFromPeer ?? Date.distantPast
                } else {
                    lastHeard = self.peerSessions[peerID]?.lastHeardFromPeer ?? Date.distantPast
                }
                
                let timeSinceLastHeard = now.timeIntervalSince(lastHeard)
                let wasAvailable = peerSessions[peerID]?.isAvailable ?? true
                
                // Check connection state
                let connectionState = peerConnectionStates[peerID] ?? .disconnected
                let hasConnection = connectionState == .connected || connectionState == .authenticating || connectionState == .authenticated
                
                // Peer is available if:
                // 1. We have an active connection (regardless of last heard time), OR
                // 2. We're authenticated and heard from them within timeout period
                let isAvailable = hasConnection || 
                                (connectionState == .authenticated && timeSinceLastHeard < peerAvailabilityTimeout)
                
                if wasAvailable != isAvailable {
                    // Availability is now tracked in PeerSession
                    
                    // Update PeerSession availability
                    if let session = peerSessions[peerID] {
                        session.isAvailable = isAvailable
                    } else {
                        // Create session if needed
                        let nickname = self.getBestAvailableNickname(for: peerID)
                        let session = PeerSession(peerID: peerID, nickname: nickname)
                        session.isAvailable = isAvailable
                        peerSessions[peerID] = session
                    }
                    
                    stateChanges.append((peerID: peerID, available: isAvailable))
                }
            }
            
            // Remove availability state for peers no longer active
            // Availability state cleanup no longer needed - tracked in PeerSession
        }
        
        // Notify about availability changes
        for change in stateChanges {
            SecureLogger.log("Peer \(change.peerID) availability changed to: \(change.available)", 
                           category: SecureLogger.session, level: .info)
            
            // Notify delegate about availability change
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.peerAvailabilityChanged(change.peerID, available: change.available)
            }
        }
    }
    
    // Update peer availability when we hear from them
    private func updatePeerAvailability(_ peerID: String) {
        updateLastHeardFromPeer(peerID)
        
        collectionsQueue.sync(flags: .barrier) {
            // Note: lastHeardFromPeer already updated in helper above
            var needsNotification = false
            if let session = self.peerSessions[peerID] {
                session.lastHeardFromPeer = Date()
                if !session.isAvailable {
                    session.isAvailable = true
                    needsNotification = true
                }
            }
            // Don't create sessions without peripheral connections
            // No notification needed if we're not tracking this peer yet
            
            // Update legacy state
            if peerSessions[peerID]?.isAvailable != true {
                // Availability updated in PeerSession already
                needsNotification = true
            }
            
            if needsNotification {
                SecureLogger.log("Peer \(peerID) marked as available after hearing from them", 
                               category: SecureLogger.session, level: .info)
                
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.peerAvailabilityChanged(peerID, available: true)
                }
            }
        }
    }
    
    // Check if a peer is currently available
    func isPeerAvailable(_ peerID: String) -> Bool {
        return collectionsQueue.sync {
            // Check PeerSession first
            if let session = peerSessions[peerID] {
                return session.isAvailable
            }
            // Fallback to legacy state
            return false  // If no session exists, peer is not available
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
        
        // Get our Noise static public key and signing public key
        let staticKey = noiseService.getStaticPublicKeyData()
        let signingKey = noiseService.getSigningPublicKeyData()
        
        // Get nickname from delegate
        let nickname = (delegate as? ChatViewModel)?.nickname ?? "Anonymous"
        
        // Create the binding data to sign (peerID + publicKey + timestamp)
        let timestampData = String(Int64(now.timeIntervalSince1970 * 1000)).data(using: .utf8)!
        let bindingData = myPeerID.data(using: .utf8)! + staticKey + timestampData
        
        // Sign the binding with our Ed25519 signing key
        let signature = noiseService.signData(bindingData) ?? Data()
        
        // Create the identity announcement
        let announcement = NoiseIdentityAnnouncement(
            peerID: myPeerID,
            publicKey: staticKey,
            signingPublicKey: signingKey,
            nickname: nickname,
            timestamp: now,
            previousPeerID: nil,
            signature: signature
        )
        
        // Encode the announcement
        let announcementData = announcement.toBinaryData()
        
        let packet = BitchatPacket(
            type: MessageType.noiseIdentityAnnounce.rawValue,
            senderID: Data(hexString: myPeerID) ?? Data(),
            recipientID: specificPeerID.flatMap { Data(hexString: $0) },  // Targeted or broadcast
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: announcementData,
            signature: nil,
            ttl: adaptiveTTL        )
        
        if let targetPeer = specificPeerID {
            SecureLogger.log("Sending targeted identity announce to \(targetPeer)", 
                           category: SecureLogger.noise, level: .info)
            
            // Try direct delivery for targeted announces
            if !sendDirectToRecipient(packet, recipientPeerID: targetPeer) {
                // Fall back to selective relay if direct delivery fails
                SecureLogger.log("Recipient \(targetPeer) not directly connected for identity announce, using relay", 
                               category: SecureLogger.session, level: .info)
                sendViaSelectiveRelay(packet, recipientPeerID: targetPeer)
            }
        } else {
            SecureLogger.log("Broadcasting identity announce to all peers", 
                           category: SecureLogger.noise, level: .info)
            broadcastPacket(packet)
        }
    }
    
    // Removed sendPacket method - all packets should use broadcastPacket to ensure mesh delivery
    
    // Send private message using Noise Protocol
    private func sendPrivateMessageViaNoise(_ content: String, to recipientPeerID: String, recipientNickname: String, messageID: String? = nil) {
        SecureLogger.log("sendPrivateMessageViaNoise called - content: '\(content.prefix(50))...', to: \(recipientPeerID), messageID: \(messageID ?? "nil")", 
                       category: SecureLogger.noise, level: .info)
        
        // Use per-peer encryption queue to prevent nonce desynchronization
        let encryptionQueue = getEncryptionQueue(for: recipientPeerID)
        
        encryptionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Use noiseService directly
            
            // Check if we have a Noise session with this peer
            let hasSession = self.noiseService.hasEstablishedSession(with: recipientPeerID)
            
            // Check if session is stale (no successful communication for a while)
            var sessionIsStale = false
            if hasSession {
                let lastSuccess = self.peerSessions[recipientPeerID]?.lastSuccessfulMessageTime ?? Date.distantPast
                let sessionAge = Date().timeIntervalSince(lastSuccess)
                // Increase session validity to 24 hours - sessions should persist across temporary disconnects
                if sessionAge > 86400.0 { // More than 24 hours since last successful message
                    sessionIsStale = true
                    // Session stale, will re-establish
                }
            }
            
            if !hasSession || sessionIsStale {
            if sessionIsStale {
                // Clear stale session first
                cleanupPeerCryptoState(recipientPeerID)
            }
            
            // Update state to handshakeQueued
            collectionsQueue.sync(flags: .barrier) {
                self.noiseSessionStates[recipientPeerID] = .handshakeQueued
            }
            
            // No valid session, initiating handshake
            
            // Notify UI that we're establishing encryption
            DispatchQueue.main.async { [weak self] in
                if let chatVM = self?.delegate as? ChatViewModel {
                    // This will update the UI to show "establishing encryption" state
                    chatVM.updateEncryptionStatusForPeer(recipientPeerID)
                }
            }
            
            // Queue message for sending after handshake completes
            collectionsQueue.sync(flags: .barrier) { [weak self] in
                guard let self = self else { return }
                if self.pendingPrivateMessages[recipientPeerID] == nil {
                    self.pendingPrivateMessages[recipientPeerID] = []
                }
                self.pendingPrivateMessages[recipientPeerID]?.append((content, recipientNickname, messageID ?? UUID().uuidString))
                let _ = self.pendingPrivateMessages[recipientPeerID]?.count ?? 0
                // Queued private message
            }
            
            // Send handshake request to notify recipient of pending messages
            sendHandshakeRequest(to: recipientPeerID, pendingCount: UInt8(pendingPrivateMessages[recipientPeerID]?.count ?? 1))
            
            // Apply tie-breaker logic for handshake initiation
            if myPeerID < recipientPeerID {
                // We have lower ID, initiate handshake
                initiateNoiseHandshake(with: recipientPeerID)
            } else {
                // We have higher ID, send targeted identity announce to prompt them to initiate
                sendNoiseIdentityAnnounce(to: recipientPeerID)
            }
            
            return
        }
        
        // Use provided message ID or generate a new one
        let msgID = messageID ?? UUID().uuidString
        
        // Check if we're already processing this message
        let sendKey = "\(msgID)-\(recipientPeerID)"
        let alreadySending = self.collectionsQueue.sync(flags: .barrier) {
            if self.recentlySentMessages.contains(sendKey) {
                return true
            }
            self.recentlySentMessages.insert(sendKey)
            // Clean up old entries after 10 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                self?.collectionsQueue.sync(flags: .barrier) {
                    _ = self?.recentlySentMessages.remove(sendKey)
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
            // Encrypting private message
            let encryptedData = try noiseService.encrypt(innerData, for: recipientPeerID)
            // Successfully encrypted
            
            // Update last successful message time
            updateLastSuccessfulMessageTime(recipientPeerID)
            
            // Note: PeerSession already updated in helper
            if let session = peerSessions[recipientPeerID] {
                session.lastSuccessfulMessageTime = Date()
            }
            
            // Send as Noise encrypted message
            let outerPacket = BitchatPacket(
                type: MessageType.noiseEncrypted.rawValue,
                senderID: Data(hexString: myPeerID) ?? Data(),
                recipientID: Data(hexString: recipientPeerID) ?? Data(),
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: encryptedData,
                signature: nil,
                ttl: adaptiveTTL            )
            
            // Sending encrypted private message
            
            // Track packet for ACK
            trackPacketForAck(outerPacket)
            
            // Try direct delivery first
            if !sendDirectToRecipient(outerPacket, recipientPeerID: recipientPeerID) {
                // Recipient not directly connected, use selective relay
                SecureLogger.log("Recipient \(recipientPeerID) not directly connected, using relay strategy", 
                               category: SecureLogger.session, level: .info)
                sendViaSelectiveRelay(outerPacket, recipientPeerID: recipientPeerID)
            }
        } catch {
            // Failed to encrypt message
            SecureLogger.log("Failed to encrypt private message \(msgID) for \(recipientPeerID): \(error)", category: SecureLogger.encryption, level: .error)
        }
        } // End of encryptionQueue.async
    }
    
    // MARK: - Targeted Message Delivery
    
    private func sendDirectToRecipient(_ packet: BitchatPacket, recipientPeerID: String) -> Bool {
        // Try to send directly to the recipient if they're connected
        if let peripheral = connectedPeripherals[recipientPeerID],
           let characteristic = peripheralCharacteristics[peripheral],
           peripheral.state == .connected {
            
            guard let data = packet.toBinaryData() else { return false }
            
            // Send only to the intended recipient
            writeToPeripheral(data, peripheral: peripheral, characteristic: characteristic, peerID: recipientPeerID)
            // Sent message directly
            return true
        }
        
        // Check if recipient is connected as a central (we're peripheral)
        if !subscribedCentrals.isEmpty {
            // We can't target specific centrals, so return false to trigger relay
            return false
        }
        
        return false
    }
    
    private func sendHandshakeRequest(to targetPeerID: String, pendingCount: UInt8) {
        // Create handshake request
        let request = HandshakeRequest(requesterID: myPeerID,
                                      requesterNickname: (delegate as? ChatViewModel)?.nickname ?? myPeerID,
                                      targetID: targetPeerID,
                                      pendingMessageCount: pendingCount)
        
        let requestData = request.toBinaryData()
        
        // Create packet for handshake request
        let packet = BitchatPacket(type: MessageType.handshakeRequest.rawValue,
                                  ttl: 6,
                                  senderID: myPeerID,
                                  payload: requestData)
        
        // Try direct delivery first
        if sendDirectToRecipient(packet, recipientPeerID: targetPeerID) {
            // Sent handshake directly
        } else {
            // Use selective relay if direct delivery fails
            sendViaSelectiveRelay(packet, recipientPeerID: targetPeerID)
            // Sent handshake via relay
        }
    }
    
    private func selectBestRelayPeers(excluding: String, maxPeers: Int = 3) -> [String] {
        // Select random peers for relay, excluding the target recipient
        var candidates: [String] = []
        
        for (peerID, _) in connectedPeripherals {
            if peerID != excluding && peerID != myPeerID {
                candidates.append(peerID)
            }
        }
        
        // Randomly select up to maxPeers peers
        return Array(candidates.shuffled().prefix(maxPeers))
    }
    
    private func sendViaSelectiveRelay(_ packet: BitchatPacket, recipientPeerID: String) {
        // Select best relay candidates
        let relayPeers = selectBestRelayPeers(excluding: recipientPeerID)
        
        if relayPeers.isEmpty {
            // No relay candidates, fall back to broadcast
            SecureLogger.log("No relay candidates for private message to \(recipientPeerID), using broadcast", 
                           category: SecureLogger.session, level: .warning)
            broadcastPacket(packet)
            return
        }
        
        // Limit TTL for relay
        var relayPacket = packet
        relayPacket.ttl = min(packet.ttl, 2)  // Max 2 hops for private message relay
        
        guard let data = relayPacket.toBinaryData() else { return }
        
        // Send to selected relay peers
        var sentCount = 0
        for relayPeerID in relayPeers {
            if let peripheral = connectedPeripherals[relayPeerID],
               let characteristic = peripheralCharacteristics[peripheral],
               peripheral.state == .connected {
                writeToPeripheral(data, peripheral: peripheral, characteristic: characteristic, peerID: relayPeerID)
                sentCount += 1
            }
        }
        
        SecureLogger.log("Sent private message to \(sentCount) relay peers (targeting \(recipientPeerID))", 
                       category: SecureLogger.session, level: .info)
        
        // If no relays worked, fall back to broadcast
        if sentCount == 0 {
            SecureLogger.log("Failed to send to relay peers, falling back to broadcast", 
                           category: SecureLogger.session, level: .warning)
            broadcastPacket(packet)
        }
    }
    
    // MARK: - Connection Pool Management
    
    private func findLeastRecentlyUsedPeripheral() -> String? {
        var lruPeripheralID: String?
        var oldestActivityTime = Date()
        
        for (peripheralID, peripheral) in connectionPool {
            // Only consider connected peripherals
            guard peripheral.state == .connected else { continue }
            
            // Skip if this peripheral has an active peer connection
            if let peerID = peerIDByPeripheralID[peripheralID],
               self.peerSessions[peerID]?.isActivePeer == true {
                continue
            }
            
            // Find the least recently used peripheral based on last activity
            if let lastActivity = lastActivityByPeripheralID[peripheralID],
               lastActivity < oldestActivityTime {
                oldestActivityTime = lastActivity
                lruPeripheralID = peripheralID
            } else if lastActivityByPeripheralID[peripheralID] == nil {
                // If no activity recorded, it's a candidate for removal
                lruPeripheralID = peripheralID
                break
            }
        }
        
        return lruPeripheralID
    }
    
    // Track activity for peripherals
    private func updatePeripheralActivity(_ peripheralID: String) {
        lastActivityByPeripheralID[peripheralID] = Date()
    }
}
