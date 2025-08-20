import Foundation
import CoreBluetooth
import Combine
import CryptoKit
#if os(iOS)
import UIKit
#endif

/// BLEService — Bluetooth Mesh Transport
/// - Emits events exclusively via `BitchatDelegate` for UI.
/// - ChatViewModel must consume delegate callbacks (`didReceivePublicMessage`, `didReceiveNoisePayload`).
/// - A lightweight `peerSnapshotPublisher` is provided for non-UI services.
final class BLEService: NSObject {
    
    // MARK: - Constants
    
    #if DEBUG
    static let serviceUUID = CBUUID(string: "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5A") // testnet
    #else
    static let serviceUUID = CBUUID(string: "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C") // mainnet
    #endif
    static let characteristicUUID = CBUUID(string: "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
    
    private let maxFragmentSize = 469 // 512 MTU - headers
    private let maxMessageLength = 10_000
    private let messageTTL: UInt8 = 7
    
    // MARK: - Core State (5 Essential Collections)
    
    // 1. Consolidated Peripheral Tracking
    private struct PeripheralState {
        let peripheral: CBPeripheral
        var characteristic: CBCharacteristic?
        var peerID: String?
        var isConnecting: Bool = false
        var isConnected: Bool = false
        var lastConnectionAttempt: Date? = nil
    }
    private var peripherals: [String: PeripheralState] = [:]  // UUID -> PeripheralState
    private var peerToPeripheralUUID: [String: String] = [:]  // PeerID -> Peripheral UUID
    
    // 2. BLE Centrals (when acting as peripheral)
    private var subscribedCentrals: [CBCentral] = []
    private var centralToPeerID: [String: String] = [:]  // Central UUID -> Peer ID mapping
    
    // 3. Peer Information (single source of truth)
    private struct PeerInfo {
        let id: String
        var nickname: String
        var isConnected: Bool
        var noisePublicKey: Data?
        var signingPublicKey: Data?
        var isVerifiedNickname: Bool
        var lastSeen: Date
    }
    private var peers: [String: PeerInfo] = [:]
    
    // 4. Efficient Message Deduplication
    private let messageDeduplicator = MessageDeduplicator()
    
    // 5. Fragment Reassembly (necessary for messages > MTU)
    private var incomingFragments: [String: [Int: Data]] = [:]
    private var fragmentMetadata: [String: (type: UInt8, total: Int, timestamp: Date)] = [:]
    // Backoff for peripherals that recently timed out connecting
    private var recentConnectTimeouts: [String: Date] = [:] // Peripheral UUID -> last timeout
    
    // Simple announce throttling
    private var lastAnnounceSent = Date.distantPast
    private let announceMinInterval: TimeInterval = 1.0
    
    // Application state tracking (thread-safe)
    #if os(iOS)
    private var isAppActive: Bool = true  // Assume active initially
    #endif
    
    // MARK: - Core BLE Objects
    
    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?
    
    // MARK: - Identity
    
    var myPeerID: String = ""
    var myNickname: String = "Anonymous"
    private let noiseService = NoiseEncryptionService()

    // MARK: - Advertising Privacy
    // No Local Name by default for maximum privacy. No rotating alias.
    
    // MARK: - Queues
    
    private let messageQueue = DispatchQueue(label: "mesh.message", attributes: .concurrent)
    private let collectionsQueue = DispatchQueue(label: "mesh.collections", attributes: .concurrent)
    private let messageQueueKey = DispatchSpecificKey<Void>()
    private let bleQueue = DispatchQueue(label: "mesh.bluetooth", qos: .userInitiated)
    
    // Queue for messages pending handshake completion
    private var pendingMessagesAfterHandshake: [String: [(content: String, messageID: String)]] = [:]
    
    // Queue for notifications that failed due to full queue
    private var pendingNotifications: [(data: Data, centrals: [CBCentral]?)] = []

    // Accumulate long write chunks per central until a full frame decodes
    private var pendingWriteBuffers: [String: Data] = [:]
    
    // MARK: - Maintenance Timer
    
    private weak var maintenanceTimer: Timer?  // Single timer for all maintenance tasks
    private var maintenanceCounter = 0  // Track maintenance cycles
    
    // MARK: - Peer snapshots publisher (non-UI convenience)
    private let peerSnapshotSubject = PassthroughSubject<[TransportPeerSnapshot], Never>()
    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
        peerSnapshotSubject.eraseToAnyPublisher()
    }

    func currentPeerSnapshots() -> [TransportPeerSnapshot] {
        collectionsQueue.sync {
            // Compute nickname collision counts for connected peers
            let connected = peers.values.filter { $0.isConnected }
            var counts: [String: Int] = [:]
            for p in connected { counts[p.nickname, default: 0] += 1 }
            // Include our own nickname in collision counts so remote matching ours gets suffixed
            counts[myNickname, default: 0] += 1
            return peers.values.map { info in
                var display = info.nickname
                if info.isConnected, (counts[info.nickname] ?? 0) > 1 {
                    display += "#" + String(info.id.prefix(4))
                }
                return TransportPeerSnapshot(
                    id: info.id,
                    nickname: display,
                    isConnected: info.isConnected,
                    noisePublicKey: info.noisePublicKey,
                    lastSeen: info.lastSeen
                )
            }
        }
    }
    
    // MARK: - Delegate
    
    weak var delegate: BitchatDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?
    
    // MARK: - Initialization
    
    /// Notify UI on the MainActor to satisfy Swift concurrency isolation
    private func notifyUI(_ block: @escaping () -> Void) {
        // Always hop onto the MainActor so calls to @MainActor delegates are safe
        Task { @MainActor in
            block()
        }
    }
    
    override init() {
        super.init()
        
        // Derive stable peer ID from Noise static public key fingerprint (first 8 bytes → 16 hex chars)
        let fingerprint = noiseService.getIdentityFingerprint() // 64 hex chars
        self.myPeerID = String(fingerprint.prefix(16))
        
        // Set queue key for identification
        messageQueue.setSpecific(key: messageQueueKey, value: ())
        
        // Set up Noise session establishment callback
        // This ensures we send pending messages only when session is truly established
        noiseService.onPeerAuthenticated = { [weak self] peerID, fingerprint in
            SecureLogger.log("🔐 Noise session authenticated with \(peerID), fingerprint: \(fingerprint.prefix(16))...", 
                            category: SecureLogger.noise, level: .debug)
            // Send any messages that were queued during handshake
            self?.messageQueue.async { [weak self] in
                self?.sendPendingMessagesAfterHandshake(for: peerID)
            }
        }
        
        // Set up application state tracking (iOS only)
        #if os(iOS)
        // Check initial state on main thread
        if Thread.isMainThread {
            isAppActive = UIApplication.shared.applicationState == .active
        } else {
            DispatchQueue.main.sync {
                isAppActive = UIApplication.shared.applicationState == .active
            }
        }
        
        // Observe application state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        #endif
        
        // Initialize BLE on background queue to prevent main thread blocking
        // This prevents app freezes during BLE operations
        centralManager = CBCentralManager(delegate: self, queue: bleQueue)
        peripheralManager = CBPeripheralManager(delegate: self, queue: bleQueue)
        
        // Single maintenance timer for all periodic tasks
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.performMaintenance()
        }
        
        // Publish initial empty state
        publishFullPeerData()
    }
    
    func setNickname(_ nickname: String) {
        self.myNickname = nickname
        // Send announce to notify peers of nickname change (force send)
        sendAnnounce(forceSend: true)
    }

    // No advertising policy to set; we never include Local Name in adverts.
    
    deinit {
        maintenanceTimer?.invalidate()
        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()
        #if os(iOS)
        NotificationCenter.default.removeObserver(self)
        #endif
    }
    
    // MARK: - Application State Handlers (iOS)
    
    #if os(iOS)
    @objc private func appDidBecomeActive() {
        isAppActive = true
        // Restart scanning with allow duplicates when app becomes active
        if centralManager?.state == .poweredOn {
            centralManager?.stopScan()
            startScanning()
        }
        // No Local Name; nothing to refresh for advertising policy
    }
    
    @objc private func appDidEnterBackground() {
        isAppActive = false
        // Restart scanning without allow duplicates in background
        if centralManager?.state == .poweredOn {
            centralManager?.stopScan()
            startScanning()
        }
        // No Local Name; nothing to refresh for advertising policy
    }
    #endif
    
    // MARK: - Helper Functions for Peripheral Management
    
    private func getConnectedPeripherals() -> [CBPeripheral] {
        return peripherals.values
            .filter { $0.isConnected }
            .map { $0.peripheral }
    }
    
    private func getPeripheral(for peerID: String) -> CBPeripheral? {
        guard let uuid = peerToPeripheralUUID[peerID],
              let state = peripherals[uuid],
              state.isConnected else { return nil }
        return state.peripheral
    }
    
    // MARK: - Core Public API
    
    func startServices() {
        // Start BLE services if not already running
        if centralManager?.state == .poweredOn {
            centralManager?.scanForPeripherals(
                withServices: [BLEService.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
        
        // Send initial announce after services are ready
        // Use longer delay to avoid conflicts with other announces
        messageQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.sendAnnounce(forceSend: true)
        }
    }

    // Transport protocol conformance helper: simplified public message send
    func sendMessage(_ content: String, mentions: [String]) {
        // Delegate to the full API with default routing
        sendMessage(content, mentions: mentions, to: nil, messageID: nil, timestamp: nil)
    }
    
    func stopServices() {
        // Send leave message synchronously to ensure delivery
        let leavePacket = BitchatPacket(
            type: MessageType.leave.rawValue,
            senderID: Data(hexString: myPeerID) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(),
            signature: nil,
            ttl: messageTTL
        )
        
        // Send immediately to all connected peers
        if let data = leavePacket.toBinaryData() {
            // Send to peripherals we're connected to as central
            for state in peripherals.values where state.isConnected {
                if let characteristic = state.characteristic {
                    state.peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                }
            }
            
            // Send to centrals subscribed to us as peripheral
            if subscribedCentrals.count > 0 && characteristic != nil {
                peripheralManager?.updateValue(data, for: characteristic!, onSubscribedCentrals: nil)
            }
        }
        
        // Give leave message a moment to send
        Thread.sleep(forTimeInterval: 0.05)
        
        // Clear pending notifications
        collectionsQueue.sync(flags: .barrier) {
            pendingNotifications.removeAll()
        }
        
        // Stop timer
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        
        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()
        
        // Disconnect all peripherals
        for state in peripherals.values {
            centralManager?.cancelPeripheralConnection(state.peripheral)
        }
    }
    
    func isPeerConnected(_ peerID: String) -> Bool {
        // Accept both 16-hex short IDs and 64-hex Noise keys
        let shortID: String = {
            if peerID.count == 64, let key = Data(hexString: peerID) {
                return PeerIDUtils.derivePeerID(fromPublicKey: key)
            }
            return peerID
        }()
        return collectionsQueue.sync { peers[shortID]?.isConnected ?? false }
    }

    func peerNickname(peerID: String) -> String? {
        collectionsQueue.sync {
            guard let peer = peers[peerID], peer.isConnected else { return nil }
            return peer.nickname
        }
    }

    func getPeerNicknames() -> [String: String] {
        return collectionsQueue.sync {
            // Only connected peers
            let connected = peers.filter { $0.value.isConnected }
            // Count collisions by nickname (include our own nickname)
            var counts: [String: Int] = [:]
            for (_, info) in connected { counts[info.nickname, default: 0] += 1 }
            counts[myNickname, default: 0] += 1
            // Build map with suffix for collisions
            var result: [String: String] = [:]
            for (id, info) in connected {
                var name = info.nickname
                if (counts[info.nickname] ?? 0) > 1 {
                    name += "#" + String(id.prefix(4))
                }
                result[id] = name
            }
            return result
        }
    }
    
    func sendPrivateMessage(_ content: String, to recipientID: String, recipientNickname: String, messageID: String) {
        sendPrivateMessage(content, to: recipientID, messageID: messageID)
    }
    
    func sendFavoriteNotification(to peerID: String, isFavorite: Bool) {
        SecureLogger.log("🔔 sendFavoriteNotification called - peerID: \(peerID), isFavorite: \(isFavorite)",
                        category: SecureLogger.session, level: .debug)
        
        // Include Nostr public key in the notification
        var content = isFavorite ? "[FAVORITED]" : "[UNFAVORITED]"
        
        // Add our Nostr public key if available
        if let myNostrIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() {
            content += ":" + myNostrIdentity.npub
            SecureLogger.log("📝 Sending favorite notification with Nostr npub: \(myNostrIdentity.npub)",
                            category: SecureLogger.session, level: .debug)
        }
        
        SecureLogger.log("📤 Sending favorite notification to \(peerID): \(content)",
                        category: SecureLogger.session, level: .debug)
        sendPrivateMessage(content, to: peerID, messageID: UUID().uuidString)
    }
    
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: String) {
        // Send encrypted read receipt
        guard noiseService.hasSession(with: peerID) else {
            SecureLogger.log("Cannot send read receipt - no Noise session with \(peerID)", category: SecureLogger.noise, level: .warning)
            return
        }
        
        SecureLogger.log("📤 Sending READ receipt for message \(receipt.originalMessageID) to \(peerID)", 
                        category: SecureLogger.session, level: .debug)
        
        // Create read receipt payload: [type byte] + [message ID]
        var receiptPayload = Data([NoisePayloadType.readReceipt.rawValue])
        receiptPayload.append(contentsOf: receipt.originalMessageID.utf8)
        
        do {
            let encrypted = try noiseService.encrypt(receiptPayload, for: peerID)
            let packet = BitchatPacket(
                type: MessageType.noiseEncrypted.rawValue,
                senderID: Data(hexString: myPeerID) ?? Data(),
                recipientID: Data(hexString: peerID),
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: encrypted,
                signature: nil,
                ttl: messageTTL
            )
            
            // If already on messageQueue, call directly
            if DispatchQueue.getSpecific(key: messageQueueKey) != nil {
                broadcastPacket(packet)
            } else {
                messageQueue.async { [weak self] in
                    self?.broadcastPacket(packet)
                }
            }
            
            // Read receipt sent
        } catch {
            SecureLogger.log("Failed to send read receipt: \(error)", category: SecureLogger.noise, level: .error)
        }
    }
    
    func sendBroadcastAnnounce() {
        sendAnnounce()
    }
    
    func getPeerFingerprint(_ peerID: String) -> String? {
        return collectionsQueue.sync {
            if let publicKey = peers[peerID]?.noisePublicKey {
                return publicKey.hexEncodedString()
            }
            return nil
        }
    }

    // Transport compatibility: generic naming
    
    
    func getNoiseSessionState(for peerID: String) -> LazyHandshakeState {
        if noiseService.hasEstablishedSession(with: peerID) {
            return .established
        } else if noiseService.hasSession(with: peerID) {
            return .handshaking
        } else {
            return .none
        }
    }
    
    func triggerHandshake(with peerID: String) {
        initiateNoiseHandshake(with: peerID)
    }
    
    func emergencyDisconnectAll() {
        stopServices()
        
        // Clear all sessions and peers
        collectionsQueue.sync(flags: .barrier) {
            peers.removeAll()
            incomingFragments.removeAll()
            fragmentMetadata.removeAll()
        }
        
        // Clear processed messages
        messageDeduplicator.reset()
        
        // Clear peripheral references
        peripherals.removeAll()
        peerToPeripheralUUID.removeAll()
        subscribedCentrals.removeAll()
        centralToPeerID.removeAll()
    }
    
    func getNoiseService() -> NoiseEncryptionService {
        return noiseService
    }
    
    func getFingerprint(for peerID: String) -> String? {
        return getPeerFingerprint(peerID)
    }
    
    func sendMessage(_ content: String, mentions: [String] = [], to recipientID: String? = nil, messageID: String? = nil, timestamp: Date? = nil) {
        // Ensure this runs on message queue to avoid main thread blocking
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard content.count <= self.maxMessageLength else {
                SecureLogger.log("Message too long: \(content.count) chars", category: SecureLogger.session, level: .error)
                return
            }
            
            let finalMessageID = messageID ?? UUID().uuidString
            let _ = UInt64(Date().timeIntervalSince1970 * 1000)
            
            if let recipientID = recipientID {
                // Private message
                self.sendPrivateMessage(content, to: recipientID, messageID: finalMessageID)
            } else {
                // Public broadcast
                // Public message - logged at relay point for mesh debugging
                let packet = BitchatPacket(
                    type: MessageType.message.rawValue,
                    ttl: self.messageTTL,
                    senderID: self.myPeerID,
                    payload: Data(content.utf8)
                )
                // Pre-mark our own broadcast as processed to avoid handling relayed self copy
                let senderHex = packet.senderID.hexEncodedString()
                let dedupID = "\(senderHex)-\(packet.timestamp)-\(packet.type)"
                self.messageDeduplicator.markProcessed(dedupID)
                // Call synchronously since we're already on background queue
                self.broadcastPacket(packet)
            }
        }
    }
    
    func getPeers() -> [String: String] {
        collectionsQueue.sync {
            Dictionary(uniqueKeysWithValues: peers.compactMap { (id, info) in
                info.isConnected ? (id, info.nickname) : nil
            })
        }
    }
    
    // MARK: - Private Message Handling
    
    private func sendPrivateMessage(_ content: String, to recipientID: String, messageID: String) {
        SecureLogger.log("📨 Sending PM to \(recipientID): \(content.prefix(30))...", category: SecureLogger.session, level: .debug)
        
        // Check if we have an established Noise session
        if noiseService.hasEstablishedSession(with: recipientID) {
            // Encrypt and send
            do {
                // Create TLV-encoded private message
                let privateMessage = PrivateMessagePacket(messageID: messageID, content: content)
                guard let tlvData = privateMessage.encode() else {
                    SecureLogger.log("Failed to encode private message with TLV", category: SecureLogger.noise, level: .error)
                    return
                }
                
                // Create message payload with TLV: [type byte] + [TLV data]
                var messagePayload = Data([NoisePayloadType.privateMessage.rawValue])
                messagePayload.append(tlvData)
                
                let encrypted = try noiseService.encrypt(messagePayload, for: recipientID)
                
                // Convert recipientID to Data (assuming it's a hex string)
                var recipientData = Data()
                var tempID = recipientID
                while tempID.count >= 2 {
                    let hexByte = String(tempID.prefix(2))
                    if let byte = UInt8(hexByte, radix: 16) {
                        recipientData.append(byte)
                    }
                    tempID = String(tempID.dropFirst(2))
                }
                if tempID.count == 1 {
                    if let byte = UInt8(tempID, radix: 16) {
                        recipientData.append(byte)
                    }
                }
                
            let packet = BitchatPacket(
                type: MessageType.noiseEncrypted.rawValue,
                senderID: Data(hexString: myPeerID) ?? Data(),
                recipientID: recipientData,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: encrypted,
                signature: nil,
                ttl: messageTTL
            )
                // Call directly if already on messageQueue, otherwise dispatch
                if DispatchQueue.getSpecific(key: messageQueueKey) != nil {
                    broadcastPacket(packet)
                } else {
                    messageQueue.async { [weak self] in
                        self?.broadcastPacket(packet)
                    }
                }
                
                // Notify delegate that message was sent
                notifyUI { [weak self] in
                    self?.delegate?.didUpdateMessageDeliveryStatus(messageID, status: .sent)
                }
            } catch {
                SecureLogger.log("Failed to encrypt message: \(error)", category: SecureLogger.noise, level: .error)
            }
        } else {
            // Queue message for sending after handshake completes
            SecureLogger.log("🤝 No session with \(recipientID), initiating handshake and queueing message", category: SecureLogger.session, level: .debug)
            
            // Queue the message (especially important for favorite notifications)
            collectionsQueue.sync(flags: .barrier) {
                if pendingMessagesAfterHandshake[recipientID] == nil {
                    pendingMessagesAfterHandshake[recipientID] = []
                }
                pendingMessagesAfterHandshake[recipientID]?.append((content, messageID))
            }
            
            initiateNoiseHandshake(with: recipientID)
            
            // Notify delegate that message is pending
            notifyUI { [weak self] in
                self?.delegate?.didUpdateMessageDeliveryStatus(messageID, status: .sending)
            }
        }
    }
    
    private func initiateNoiseHandshake(with peerID: String) {
        // Use NoiseEncryptionService for handshake
        guard !noiseService.hasSession(with: peerID) else { return }
        
        do {
            let handshakeData = try noiseService.initiateHandshake(with: peerID)
            
            // Send handshake init
            let packet = BitchatPacket(
                type: MessageType.noiseHandshake.rawValue,
                senderID: Data(hexString: myPeerID) ?? Data(),
                recipientID: Data(hexString: peerID),
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: handshakeData,
                signature: nil,
                ttl: messageTTL
            )
            // Call directly if on messageQueue, otherwise dispatch
            if DispatchQueue.getSpecific(key: messageQueueKey) != nil {
                broadcastPacket(packet)
            } else {
                messageQueue.async { [weak self] in
                    self?.broadcastPacket(packet)
                }
            }
        } catch {
            SecureLogger.log("Failed to initiate handshake: \(error)", category: SecureLogger.noise, level: .error)
        }
    }
    
    private func sendPendingMessagesAfterHandshake(for peerID: String) {
        // Get and clear pending messages for this peer
        let pendingMessages = collectionsQueue.sync(flags: .barrier) { () -> [(content: String, messageID: String)]? in
            let messages = pendingMessagesAfterHandshake[peerID]
            pendingMessagesAfterHandshake.removeValue(forKey: peerID)
            return messages
        }
        
        guard let messages = pendingMessages, !messages.isEmpty else { return }
        
        SecureLogger.log("📤 Sending \(messages.count) pending messages after handshake to \(peerID)", 
                        category: SecureLogger.session, level: .debug)
        
        // Send each pending message directly (we know session is established)
        for (content, messageID) in messages {
            do {
                // Use the same TLV format as normal sends to keep receiver decoding consistent
                let privateMessage = PrivateMessagePacket(messageID: messageID, content: content)
                guard let tlvData = privateMessage.encode() else {
                    SecureLogger.log("Failed to encode pending private message TLV", category: SecureLogger.noise, level: .error)
                    continue
                }

                var messagePayload = Data([NoisePayloadType.privateMessage.rawValue])
                messagePayload.append(tlvData)

                let encrypted = try noiseService.encrypt(messagePayload, for: peerID)

                let packet = BitchatPacket(
                    type: MessageType.noiseEncrypted.rawValue,
                    senderID: Data(hexString: myPeerID) ?? Data(),
                    recipientID: Data(hexString: peerID),
                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                    payload: encrypted,
                    signature: nil,
                    ttl: messageTTL
                )

                // We're already on messageQueue from the callback
                broadcastPacket(packet)

                // Notify delegate that message was sent
                notifyUI { [weak self] in
                    self?.delegate?.didUpdateMessageDeliveryStatus(messageID, status: .sent)
                }

                SecureLogger.log("✅ Sent pending message \(messageID) to \(peerID) after handshake", 
                                category: SecureLogger.session, level: .debug)
            } catch {
                SecureLogger.log("Failed to send pending message after handshake: \(error)", 
                                category: SecureLogger.noise, level: .error)

                // Notify delegate of failure
                notifyUI { [weak self] in
                    self?.delegate?.didUpdateMessageDeliveryStatus(messageID, status: .failed(reason: "Encryption failed"))
                }
            }
        }
    }
    
    // MARK: - Packet Broadcasting
    
    private func broadcastPacket(_ packet: BitchatPacket) {
        guard let rawData = packet.toBinaryData() else {
            SecureLogger.log("❌ Failed to convert packet to binary data", category: SecureLogger.session, level: .error)
            return
        }
        // Avoid sending padded data over BLE to reduce truncation risk
        let data = MessagePadding.unpad(rawData)
        
        // Only log broadcasts for non-announce packets
        // Log encrypted and relayed packets for debugging
        if packet.type == MessageType.noiseEncrypted.rawValue {
            SecureLogger.log("📡 Encrypted packet to \(packet.recipientID?.hexEncodedString() ?? "unknown")",
                            category: SecureLogger.session, level: .debug)
        } else if packet.ttl < messageTTL {
            // Relayed packet
        }
        
        // Check if application-level fragmentation needed for large messages
        // (CoreBluetooth only handles ATT-level fragmentation for single writes)
        if data.count > 512 && packet.type != MessageType.fragment.rawValue {
            sendFragmentedPacket(packet)
            return
        }
        
        // For private encrypted messages (not handshakes), send to specific peer only
        // Handshakes need broader delivery to establish encryption
        if packet.type == MessageType.noiseEncrypted.rawValue,
           let recipientID = packet.recipientID {
            let recipientPeerID = recipientID.hexEncodedString()
            var sentEncrypted = false
            
            // Check routing availability (only log if there's an issue)
            let hasPeripheral = peerToPeripheralUUID[recipientPeerID] != nil
            let hasCentral = centralToPeerID.values.contains(recipientPeerID)
            
            // Try to send directly to the specific peer as peripheral first
            if let peripheralUUID = peerToPeripheralUUID[recipientPeerID],
               let state = peripherals[peripheralUUID],
               state.isConnected,
               let characteristic = state.characteristic {
                state.peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                // Successfully routed via peripheral
                sentEncrypted = true
            }
            
            // Also try notification if peer is connected as central (dual-role support)
            if let characteristic = characteristic {
                // Find the specific central for this peer
                for central in subscribedCentrals {
                    if centralToPeerID[central.identifier.uuidString] == recipientPeerID {
                        let success = peripheralManager?.updateValue(data, for: characteristic, onSubscribedCentrals: [central]) ?? false
                        if success {
                            // Successfully routed via central notification
                            sentEncrypted = true
                        } else {
                            // Queue for retry when notification queue has space
                            collectionsQueue.async(flags: .barrier) { [weak self] in
                                guard let self = self else { return }
                                // Limit queue size to prevent memory issues
                                if self.pendingNotifications.count < 20 {
                                    self.pendingNotifications.append((data: data, centrals: [central]))
                                    SecureLogger.log("📋 Queued encrypted packet for retry (notification queue full)", 
                                                   category: SecureLogger.session, level: .debug)
                                } else {
                                    SecureLogger.log("⚠️ Pending notification queue full, dropping packet", 
                                                   category: SecureLogger.session, level: .warning)
                                }
                            }
                        }
                    }
                }
                
                // Do NOT broadcast encrypted messages to all centrals
                // Encrypted messages must only go to the intended recipient
            }
            
            if !sentEncrypted {
                // Log detailed routing failure for debugging
                SecureLogger.log("⚠️ Failed to route encrypted message to \(recipientPeerID) - peripheral=\(hasPeripheral) central=\(hasCentral)",
                               category: SecureLogger.session, level: .warning)
            }
            
            return
        }
        
        // For broadcast messages, use the original simple routing
        // This ensures announces can be sent before peer ID mappings are established
        var sentToPeripherals = 0
        var sentToCentrals = 0
        
        // 1. First try sending as central via writes to connected peripherals
        // This is the preferred path when we have direct peripheral connections
        for state in peripherals.values where state.isConnected {
                if let characteristic = state.characteristic {
                state.peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                sentToPeripherals += 1
            }
        }
        
        // 2. Also send via notifications to subscribed centrals
        // This ensures all connected peers receive the message regardless of their connection role
        // Broadcast message types that should go to all peers
        // Include handshakes since they need to reach peers to establish encryption
        let isBroadcastType = packet.type == MessageType.announce.rawValue ||
                             packet.type == MessageType.message.rawValue ||
                             packet.type == MessageType.leave.rawValue ||
                             packet.type == MessageType.noiseHandshake.rawValue
        if isBroadcastType, let characteristic = characteristic, !subscribedCentrals.isEmpty {
            // If value exceeds minimum allowed by connected centrals, handle per constraints
            let minAllowed = subscribedCentrals.map { $0.maximumUpdateValueLength }.min() ?? 20
            // Minimum BitChat frame = 13 (header) + 8 (senderID) = 21 bytes
            if minAllowed < 21 {
                // Cannot deliver any BitChat frame via notifications on this link; skip notify
                SecureLogger.log("⚠️ Skipping notify: central max update length (\(minAllowed)) < 21", category: SecureLogger.session, level: .debug)
            } else if data.count > minAllowed {
                // Fragment via protocol
                sendFragmentedPacket(packet)
                return
            }
            let success = peripheralManager?.updateValue(data, for: characteristic, onSubscribedCentrals: nil) ?? false
            if success {
                sentToCentrals = subscribedCentrals.count
                if packet.type == MessageType.message.rawValue {
                    // Broadcast message sent
                } else if packet.type == MessageType.noiseHandshake.rawValue {
                    // Handshake broadcast to centrals
                }
            } else {
                // Notification queue full - queue for retry on handshake and announce packets
                if packet.type == MessageType.noiseHandshake.rawValue || packet.type == MessageType.announce.rawValue {
                    collectionsQueue.async(flags: .barrier) { [weak self] in
                        guard let self = self else { return }
                        if self.pendingNotifications.count < 20 {
                            self.pendingNotifications.append((data: data, centrals: nil))
                            let kind = packet.type == MessageType.announce.rawValue ? "announce" : "handshake"
                            SecureLogger.log("📋 Queued \(kind) packet for retry (notification queue full)", 
                                           category: SecureLogger.session, level: .debug)
                        }
                    }
                } else {
                    SecureLogger.log("⚠️ Notification queue full for packet type \(packet.type)", 
                                   category: SecureLogger.session, level: .warning)
                }
            }
        }
        
        let totalSent = sentToPeripherals + sentToCentrals
        if totalSent == 0 {
            // No peers to send to - this is normal when isolated
        } else {
            // Broadcast sent
        }
    }
    
    private func sendData(_ data: Data, to peripheral: CBPeripheral) {
        // Fire-and-forget: Simple send without complex fallback logic
        guard peripheral.state == .connected else { return }
        
        let peripheralUUID = peripheral.identifier.uuidString
        guard let state = peripherals[peripheralUUID],
              let characteristic = state.characteristic else { return }
        
        // Fire-and-forget principle: always use .withoutResponse for speed
        // CoreBluetooth will handle fragmentation at L2CAP layer
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
    }
    
    // MARK: - Fragmentation (Required for messages > BLE MTU)
    
    private func sendFragmentedPacket(_ packet: BitchatPacket) {
        guard let encoded = packet.toBinaryData() else { return }
        // Fragment the unpadded frame; each fragment will be encoded (and padded) independently
        let fullData = MessagePadding.unpad(encoded)
        
        let fragmentID = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        let fragments = stride(from: 0, to: fullData.count, by: maxFragmentSize).map { offset in
            Data(fullData[offset..<min(offset + maxFragmentSize, fullData.count)])
        }
        
        for (index, fragment) in fragments.enumerated() {
            var payload = Data()
            payload.append(fragmentID)
            payload.append(contentsOf: withUnsafeBytes(of: UInt16(index).bigEndian) { Data($0) })
            payload.append(contentsOf: withUnsafeBytes(of: UInt16(fragments.count).bigEndian) { Data($0) })
            payload.append(packet.type)
            payload.append(fragment)
            
            let fragmentPacket = BitchatPacket(
                type: MessageType.fragment.rawValue,
                senderID: packet.senderID,
                recipientID: packet.recipientID,
                timestamp: packet.timestamp,
                payload: payload,
                signature: nil,
                ttl: packet.ttl
            )
            
            // Send immediately (should be on messageQueue already)
            broadcastPacket(fragmentPacket)
        }
    }
    
    private func handleFragment(_ packet: BitchatPacket, from peerID: String) {
        // Don't process our own fragments
        if peerID == myPeerID {
            return
        }
        
        // Minimum header: 8 bytes ID + 2 index + 2 total + 1 type
        guard packet.payload.count >= 13 else { return }

        let senderHex = packet.senderID.hexEncodedString()
        let fragmentID = packet.payload[0..<8].map { String(format: "%02x", $0) }.joined()
        // Parse big-endian UInt16 safely without alignment assumptions
        let idxHi = UInt16(packet.payload[8])
        let idxLo = UInt16(packet.payload[9])
        let index = Int((idxHi << 8) | idxLo)
        let totHi = UInt16(packet.payload[10])
        let totLo = UInt16(packet.payload[11])
        let total = Int((totHi << 8) | totLo)
        let originalType = packet.payload[12]
        let fragmentData = packet.payload.suffix(from: 13)

        // Sanity checks
        guard total > 0 && index >= 0 && index < total else { return }

        // Store fragment
        let key = "\(senderHex):\(fragmentID)"
        if incomingFragments[key] == nil {
            incomingFragments[key] = [:]
            fragmentMetadata[key] = (originalType, total, Date())
        }
        incomingFragments[key]?[index] = Data(fragmentData)

        // Check if complete
        if let fragments = incomingFragments[key],
           fragments.count == total {
            // Reassemble
            var reassembled = Data()
            for i in 0..<total {
                if let fragment = fragments[i] {
                    reassembled.append(fragment)
                }
            }
            
            // Decode the original packet bytes we reassembled, so flags/compression are preserved
            if let originalPacket = BinaryProtocol.decode(reassembled) {
                handleReceivedPacket(originalPacket, from: peerID)
            } else {
                SecureLogger.log("❌ Failed to decode reassembled packet (type=\(originalType), total=\(total))", category: SecureLogger.session, level: .error)
            }
            
            // Cleanup
            incomingFragments.removeValue(forKey: key)
            fragmentMetadata.removeValue(forKey: key)
        }
    }
    
    // MARK: - Packet Reception
    
    private func handleReceivedPacket(_ packet: BitchatPacket, from peerID: String) {
        // Deduplication (thread-safe)
                let senderID = packet.senderID.hexEncodedString()
        // Include packet type in message ID to prevent collisions between different packet types
        let messageID = "\(senderID)-\(packet.timestamp)-\(packet.type)"
        
        // Only log non-announce packets to reduce noise
        if packet.type != MessageType.announce.rawValue {
            // Log packet details for debugging
            SecureLogger.log("📦 Handling packet type \(packet.type) from \(senderID), messageID: \(messageID)", 
                            category: SecureLogger.session, level: .debug)
        }
        
        // Efficient deduplication
        // Important: do not dedup fragment packets globally (each piece must pass)
        if packet.type != MessageType.fragment.rawValue && messageDeduplicator.isDuplicate(messageID) {
            // Announce packets (type 1) are sent every 10 seconds for peer discovery
            // It's normal to see these as duplicates - don't log them to reduce noise
            if packet.type != MessageType.announce.rawValue {
                SecureLogger.log("⚠️ Duplicate packet ignored: \(messageID)", 
                                category: SecureLogger.session, level: .debug)
            }
            return // Duplicate ignored
        }
        
        // Update peer info without verbose logging - update the peer we received from, not the original sender
        updatePeerLastSeen(peerID)
        
        
        // Process by type
        switch MessageType(rawValue: packet.type) {
        case .announce:
            handleAnnounce(packet, from: senderID)
            
        case .message:
            handleMessage(packet, from: senderID)
            
        case .noiseHandshake:
            handleNoiseHandshake(packet, from: senderID)
            
        case .noiseEncrypted:
            handleNoiseEncrypted(packet, from: senderID)
            
        case .fragment:
            handleFragment(packet, from: senderID)
            
        case .leave:
            handleLeave(packet, from: senderID)
            
        default:
            SecureLogger.log("⚠️ Unknown message type: \(packet.type)", category: SecureLogger.session, level: .warning)
            break
        }
        
        // Relay if TTL > 1 and we're not the original sender
        // Do this asynchronously to avoid blocking and potential loops
        // BUT: Don't relay private encrypted messages (they have a specific recipient)
        let shouldRelay = packet.ttl > 1 &&
                         senderID != myPeerID &&
                         packet.type != MessageType.noiseEncrypted.rawValue
        
        if shouldRelay {
            messageQueue.async { [weak self] in
                var relayPacket = packet
                relayPacket.ttl -= 1
                // Relaying packet
                self?.broadcastPacket(relayPacket)
            }
        }
    }
    
    private func handleAnnounce(_ packet: BitchatPacket, from peerID: String) {
        guard let announcement = AnnouncementPacket.decode(from: packet.payload) else {
            SecureLogger.log("❌ Failed to decode announce packet from \(peerID)", category: SecureLogger.session, level: .error)
            return
        }
        
        // Verify that the sender's derived ID from the announced noise public key matches the packet senderID
        // This helps detect relayed or spoofed announces. Only warn in release; assert in debug.
        let derivedFromKey = PeerIDUtils.derivePeerID(fromPublicKey: announcement.noisePublicKey)
        if derivedFromKey != peerID {
            SecureLogger.log("⚠️ Announce sender mismatch: derived \(derivedFromKey.prefix(8))… vs packet \(peerID.prefix(8))…", category: SecureLogger.security, level: .warning)

        }
        
        // Don't add ourselves as a peer
        if peerID == myPeerID {
            return
        }
        
        // Suppress announce logs to reduce noise
        
        // Track if this is a new or reconnected peer
        var isNewPeer = false
        var isReconnectedPeer = false
        
        collectionsQueue.sync(flags: .barrier) {
            // Check if we have an actual BLE connection to this peer
            let peripheralUUID = peerToPeripheralUUID[peerID]
            _ = peripheralUUID != nil && peripherals[peripheralUUID!]?.isConnected == true  // hasPeripheralConnection
            
            // Check if this peer is subscribed to us as a central
            // Note: We can't identify which specific central is which peer without additional mapping
            _ = !subscribedCentrals.isEmpty  // hasCentralSubscription
            
            // Check if we already have this peer (might be reconnecting)
            let existingPeer = peers[peerID]
            let wasDisconnected = existingPeer?.isConnected == false
            
            // Set flags for use outside the sync block
            isNewPeer = (existingPeer == nil)
            isReconnectedPeer = wasDisconnected
            
            // Verify packet signature using the announced signing public key
            var verified = false
            if packet.signature != nil {
                // Verify that the packet was signed by the signing private key corresponding to the announced signing public key
                verified = noiseService.verifyPacketSignature(packet, publicKey: announcement.signingPublicKey)
                if !verified {
                    SecureLogger.log("⚠️ Signature verification for announce failed \(peerID.prefix(8))", category: SecureLogger.security, level: .warning)
                }
            }

            // If existing peer has a different noise public key, do not consider this verified
            if let existing = existingPeer, let existingKey = existing.noisePublicKey, existingKey != announcement.noisePublicKey {
                SecureLogger.log("⚠️ Announce key mismatch for \(peerID.prefix(8))… — keeping unverified", category: SecureLogger.security, level: .warning)
                verified = false
            }

            // Require verified announce; ignore otherwise (no backward compatibility)
            if !verified {
                SecureLogger.log("❌ Ignoring unverified announce from \(peerID.prefix(8))…", category: SecureLogger.security, level: .warning)
                return
            }

            // Update or create peer info
            if let existing = existingPeer, existing.isConnected {
                // Update lastSeen and identity info
                peers[peerID] = PeerInfo(
                    id: existing.id,
                    nickname: announcement.nickname,
                    isConnected: true,
                    noisePublicKey: announcement.noisePublicKey,
                    signingPublicKey: announcement.signingPublicKey,
                    isVerifiedNickname: true,
                    lastSeen: Date()
                )
            } else {
                // New peer or reconnecting peer
                peers[peerID] = PeerInfo(
                    id: peerID,
                    nickname: announcement.nickname,
                    isConnected: true,
                    noisePublicKey: announcement.noisePublicKey,
                    signingPublicKey: announcement.signingPublicKey,
                    isVerifiedNickname: true,
                    lastSeen: Date()
                )
            }
            
            // Log connection status
            if existingPeer == nil {
                SecureLogger.log("🆕 New peer: \(announcement.nickname)", category: SecureLogger.session, level: .debug)
            } else if wasDisconnected {
                SecureLogger.log("🔄 Peer \(announcement.nickname) reconnected", category: SecureLogger.session, level: .debug)
            } else if existingPeer?.nickname != announcement.nickname {
                SecureLogger.log("🔄 Peer \(peerID) changed nickname: \(existingPeer?.nickname ?? "Unknown") -> \(announcement.nickname)", category: SecureLogger.session, level: .debug)
            }
        }
        
        // Notify UI on main thread
        notifyUI { [weak self] in
            guard let self = self else { return }
            
            // Get current peer list (after addition)
            let currentPeerIDs = self.collectionsQueue.sync { Array(self.peers.keys) }
            
            // Only notify of connection for new or reconnected peers
            if isNewPeer || isReconnectedPeer {
                self.delegate?.didConnectToPeer(peerID)
            }
            
            self.publishFullPeerData()
            self.delegate?.didUpdatePeerList(currentPeerIDs)
        }
        
        // Send announce back for bidirectional discovery (only once per peer)
        let announceBackID = "announce-back-\(peerID)"
        let shouldSendBack = !messageDeduplicator.contains(announceBackID)
        if shouldSendBack {
            messageDeduplicator.markProcessed(announceBackID)
        }
        
        if shouldSendBack {
            // Reciprocate announce for bidirectional discovery
            // Force send to ensure the peer receives our announce
            sendAnnounce(forceSend: true)
        }
    }
    
    // Mention parsing moved to ChatViewModel
    
    private func handleMessage(_ packet: BitchatPacket, from peerID: String) {
        // Ignore self-origin public messages that may be seen again via relay
        if peerID == myPeerID { return }
        
        // Enforce: only accept public messages from verified peers we know
        guard let info = peers[peerID], info.isVerifiedNickname else {
            SecureLogger.log("🚫 Dropping public message from unverified or unknown peer \(peerID.prefix(8))…", category: SecureLogger.security, level: .warning)
            return
        }

        guard let content = String(data: packet.payload, encoding: .utf8) else {
            SecureLogger.log("❌ Failed to decode message payload as UTF-8", category: SecureLogger.session, level: .error)
            return
        }
        
        // Resolve display nickname; if collisions exist, append short peerID suffix
        var senderNickname = info.nickname
        // Treat a collision if another connected peer shares the nickname OR our own nickname matches
        let hasCollision = peers.values.contains { $0.isConnected && $0.nickname == info.nickname && $0.id != peerID } || (myNickname == info.nickname)
        if hasCollision {
            senderNickname += "#" + String(peerID.prefix(4))
        }

        SecureLogger.log("💬 [\(senderNickname)] TTL:\(packet.ttl): \(String(content.prefix(50)))\(content.count > 50 ? "..." : "")", category: SecureLogger.session, level: .debug)
        
        let ts = Date(timeIntervalSince1970: Double(packet.timestamp) / 1000)
        notifyUI { [weak self] in
            self?.delegate?.didReceivePublicMessage(from: peerID, nickname: senderNickname, content: content, timestamp: ts)
        }
    }
    
    private func handleNoiseHandshake(_ packet: BitchatPacket, from peerID: String) {
        // Use NoiseEncryptionService for handshake processing
        if let recipientID = packet.recipientID,
           recipientID.hexEncodedString() == myPeerID {
            // Handshake is for us
            do {
                if let response = try noiseService.processHandshakeMessage(from: peerID, message: packet.payload) {
                    // Send response
                    let responsePacket = BitchatPacket(
                        type: MessageType.noiseHandshake.rawValue,
                        senderID: Data(hexString: myPeerID) ?? Data(),
                        recipientID: Data(hexString: peerID),
                        timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                        payload: response,
                        signature: nil,
                        ttl: messageTTL
                    )
                    // We're on messageQueue from delegate callback
                    broadcastPacket(responsePacket)
                }
                
                // Session establishment will trigger onPeerAuthenticated callback
                // which will send any pending messages at the right time
            } catch {
                SecureLogger.log("Failed to process handshake: \(error)", category: SecureLogger.noise, level: .error)
                // Try initiating a new handshake
                if !noiseService.hasSession(with: peerID) {
                    initiateNoiseHandshake(with: peerID)
                }
            }
        }
    }
    
    private func handleNoiseEncrypted(_ packet: BitchatPacket, from peerID: String) {
        SecureLogger.log("🔐 handleNoiseEncrypted called for packet from \(peerID)", 
                        category: SecureLogger.noise, level: .debug)
        
        guard let recipientID = packet.recipientID else {
            SecureLogger.log("⚠️ Encrypted message has no recipient ID", category: SecureLogger.session, level: .warning)
            return
        }
        
        let recipientHex = recipientID.hexEncodedString()
        if recipientHex != myPeerID {
            SecureLogger.log("🔐 Encrypted message not for me (for \(recipientHex), I am \(myPeerID))", category: SecureLogger.session, level: .debug)
            return
        }
        
        // Update lastSeen for the peer we received from (important for private messages)
        updatePeerLastSeen(peerID)
        
        do {
            let decrypted = try noiseService.decrypt(packet.payload, from: peerID)
            guard decrypted.count > 0 else { return }
            
            // First byte indicates the payload type
            let payloadType = decrypted[0]
            let payloadData = decrypted.dropFirst()
            
            switch NoisePayloadType(rawValue: payloadType) {
            case .privateMessage:
                let ts = Date(timeIntervalSince1970: Double(packet.timestamp) / 1000)
                notifyUI { [weak self] in
                    self?.delegate?.didReceiveNoisePayload(from: peerID, type: .privateMessage, payload: Data(payloadData), timestamp: ts)
                }
            case .delivered:
                let ts = Date(timeIntervalSince1970: Double(packet.timestamp) / 1000)
                notifyUI { [weak self] in
                    self?.delegate?.didReceiveNoisePayload(from: peerID, type: .delivered, payload: Data(payloadData), timestamp: ts)
                }
            case .readReceipt:
                let ts = Date(timeIntervalSince1970: Double(packet.timestamp) / 1000)
                notifyUI { [weak self] in
                    self?.delegate?.didReceiveNoisePayload(from: peerID, type: .readReceipt, payload: Data(payloadData), timestamp: ts)
                }
            default:
                SecureLogger.log("⚠️ Unknown noise payload type: \(payloadType)", category: SecureLogger.noise, level: .warning)
            }
        } catch NoiseEncryptionError.sessionNotEstablished {
            // We received an encrypted message before establishing a session with this peer.
            // Trigger a handshake so future messages can be decrypted.
            SecureLogger.log("🔑 Encrypted message from \(peerID) without session; initiating handshake", 
                            category: SecureLogger.noise, level: .debug)
            if !noiseService.hasSession(with: peerID) {
                initiateNoiseHandshake(with: peerID)
            }
        } catch {
            SecureLogger.log("❌ Failed to decrypt message from \(peerID): \(error)", 
                            category: SecureLogger.noise, level: .error)
        }
    }
    
    private func handleLeave(_ packet: BitchatPacket, from peerID: String) {
        _ = collectionsQueue.sync(flags: .barrier) {
            // Remove the peer when they leave
            peers.removeValue(forKey: peerID)
        }
        // Send on main thread
        notifyUI { [weak self] in
            guard let self = self else { return }
            
            // Get current peer list (after removal)
            let currentPeerIDs = self.collectionsQueue.sync { Array(self.peers.keys) }
            
            self.delegate?.didDisconnectFromPeer(peerID)
            self.delegate?.didUpdatePeerList(currentPeerIDs)
        }
    }
    
    // MARK: - Helper Functions
    
    private func sendLeave() {
        SecureLogger.log("👋 Sending leave announcement", category: SecureLogger.session, level: .debug)
        let packet = BitchatPacket(
            type: MessageType.leave.rawValue,
            ttl: messageTTL,
            senderID: myPeerID,
            payload: Data(myNickname.utf8)
        )
        broadcastPacket(packet)
    }
    
    private func sendAnnounce(forceSend: Bool = false) {
        // Throttle announces to prevent flooding
        let now = Date()
        let timeSinceLastAnnounce = now.timeIntervalSince(lastAnnounceSent)
        
        // Even forced sends should respect a minimum interval to avoid overwhelming BLE
        let minInterval = forceSend ? 0.2 : announceMinInterval
        
        if timeSinceLastAnnounce < minInterval {
            // Skipping announce (rate limited)
            return
        }
        lastAnnounceSent = now
        
        // Reduced logging - only log errors, not every announce
        
        // Create announce payload with both noise and signing public keys
        let noisePub = noiseService.getStaticPublicKeyData()  // For noise handshakes and peer identification
        let signingPub = noiseService.getSigningPublicKeyData()  // For signature verification
        
        let announcement = AnnouncementPacket(
            nickname: myNickname,
            noisePublicKey: noisePub,
            signingPublicKey: signingPub
        )
        
        guard let payload = announcement.encode() else {
            SecureLogger.log("❌ Failed to encode announce packet", category: SecureLogger.session, level: .error)
            return
        }
        
        // Create packet with signature using the noise private key
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: myPeerID) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil, // Will be set by signPacket below
            ttl: messageTTL
        )
        
        // Sign the packet using the noise private key
        guard let signedPacket = noiseService.signPacket(packet) else {
            SecureLogger.log("❌ Failed to sign announce packet", category: SecureLogger.security, level: .error)
            return
        }
        
        // Call directly if on messageQueue, otherwise dispatch
        if DispatchQueue.getSpecific(key: messageQueueKey) != nil {
            broadcastPacket(signedPacket)
        } else {
            messageQueue.async { [weak self] in
                self?.broadcastPacket(signedPacket)
            }
        }
    }
    
    func sendDeliveryAck(for messageID: String, to peerID: String) {
        // Send encrypted delivery ACK
        guard noiseService.hasSession(with: peerID) else {
            SecureLogger.log("Cannot send ACK - no Noise session with \(peerID)", category: SecureLogger.noise, level: .warning)
            return
        }
        
        // Create ACK payload: [type byte] + [message ID]
        var ackPayload = Data([NoisePayloadType.delivered.rawValue])
        ackPayload.append(contentsOf: messageID.utf8)
        
        do {
            let encrypted = try noiseService.encrypt(ackPayload, for: peerID)
            let packet = BitchatPacket(
                type: MessageType.noiseEncrypted.rawValue,
                senderID: Data(hexString: myPeerID) ?? Data(),
                recipientID: Data(hexString: peerID),
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: encrypted,
                signature: nil,
                ttl: messageTTL
            )
            broadcastPacket(packet)
            // Delivery ACK sent
        } catch {
            SecureLogger.log("Failed to send delivery ACK: \(error)", category: SecureLogger.noise, level: .error)
        }
    }
    
    private func updatePeerLastSeen(_ peerID: String) {
        // Use async to avoid deadlock - we don't need immediate consistency for last seen updates
        collectionsQueue.async(flags: .barrier) {
            if var peer = self.peers[peerID] {
                peer.lastSeen = Date()
                self.peers[peerID] = peer
            }
        }
    }
    
    // NEW: Publish peer snapshots to subscribers and notify Transport delegates
    private func publishFullPeerData() {
        let transportPeers: [TransportPeerSnapshot] = collectionsQueue.sync {
            // Compute nickname collision counts for connected peers
            let connected = peers.values.filter { $0.isConnected }
            var counts: [String: Int] = [:]
            for p in connected { counts[p.nickname, default: 0] += 1 }
            counts[myNickname, default: 0] += 1
            return peers.values.map { info in
                var display = info.nickname
                if info.isConnected, (counts[info.nickname] ?? 0) > 1 {
                    display += "#" + String(info.id.prefix(4))
                }
                return TransportPeerSnapshot(
                    id: info.id,
                    nickname: display,
                    isConnected: info.isConnected,
                    noisePublicKey: info.noisePublicKey,
                    lastSeen: info.lastSeen
                )
            }
        }
        // Notify non-UI listeners
        peerSnapshotSubject.send(transportPeers)
        // Notify UI on MainActor via delegate
        Task { @MainActor [weak self] in
            self?.peerEventsDelegate?.didUpdatePeerSnapshots(transportPeers)
        }
    }
    
    // MARK: - Consolidated Maintenance
    
    private func performMaintenance() {
        maintenanceCounter += 1
        
        // Always: Send keep-alive announce (every 10 seconds)
        sendAnnounce(forceSend: true)
        
        // If we have no peers, ensure we're scanning and advertising
        if peers.isEmpty {
            // Ensure we're advertising as peripheral
            if let pm = peripheralManager, pm.state == .poweredOn && !pm.isAdvertising {
                pm.startAdvertising(buildAdvertisementData())
            }
        }
        
        // Every 20 seconds (2 cycles): Check peer connectivity
        if maintenanceCounter % 2 == 0 {
            checkPeerConnectivity()
        }
        
        // Every 30 seconds (3 cycles): Cleanup
        if maintenanceCounter % 3 == 0 {
            performCleanup()
        }
        
        // No rotating alias: nothing to refresh
        
        // Reset counter to prevent overflow (every 60 seconds)
        if maintenanceCounter >= 6 {
            maintenanceCounter = 0
        }
    }
    
    private func checkPeerConnectivity() {
        let now = Date()
        var disconnectedPeers: [String] = []
        
        collectionsQueue.sync(flags: .barrier) {
            for (peerID, peer) in peers {
                if peer.isConnected && now.timeIntervalSince(peer.lastSeen) > 20 {
                    // Check if we still have an active BLE connection to this peer
                    let hasPeripheralConnection = peerToPeripheralUUID[peerID] != nil &&
                                                 peripherals[peerToPeripheralUUID[peerID]!]?.isConnected == true
                    let hasCentralConnection = centralToPeerID.values.contains(peerID)
                    
                    // Only remove if we don't have an active BLE connection
                    if !hasPeripheralConnection && !hasCentralConnection {
                        // Remove the peer completely (they'll be re-added when they reconnect)
                        SecureLogger.log("⏱️ Peer timed out (no packets for 20s): \(peerID) (\(peer.nickname))",
                                       category: SecureLogger.session, level: .debug)
                        peers.removeValue(forKey: peerID)
                        disconnectedPeers.append(peerID)
                    }
                }
            }
        }
        
        // Update UI if any peers were disconnected
        if !disconnectedPeers.isEmpty {
            notifyUI { [weak self] in
                guard let self = self else { return }
                
                // Get current peer list (after removal)
                let currentPeerIDs = self.collectionsQueue.sync { Array(self.peers.keys) }
                
                for peerID in disconnectedPeers {
                    self.delegate?.didDisconnectFromPeer(peerID)
                }
                self.delegate?.didUpdatePeerList(currentPeerIDs)
            }
        }
    }
    
    private func performCleanup() {
        let now = Date()
        
        // Clean old processed messages efficiently
        messageDeduplicator.cleanup()
        
        // Clean old fragments (> 30 seconds old)
        collectionsQueue.sync(flags: .barrier) {
            let cutoff = now.addingTimeInterval(-30)
            let oldFragments = fragmentMetadata.filter { $0.value.timestamp < cutoff }.map { $0.key }
            for fragmentID in oldFragments {
                incomingFragments.removeValue(forKey: fragmentID)
                fragmentMetadata.removeValue(forKey: fragmentID)
            }
        }

        // Clean old connection timeout backoff entries (> 2 minutes)
        let timeoutCutoff = now.addingTimeInterval(-120)
        recentConnectTimeouts = recentConnectTimeouts.filter { $0.value >= timeoutCutoff }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            // Start scanning - use allow duplicates for faster discovery when active
            startScanning()
        }
    }
    
    private func startScanning() {
        guard let central = centralManager,
              central.state == .poweredOn,
              !central.isScanning else { return }
        
        // Use allow duplicates = true for faster discovery in foreground
        // This gives us discovery events immediately instead of coalesced
        #if os(iOS)
        let allowDuplicates = isAppActive  // Use our tracked state (thread-safe)
        #else
        let allowDuplicates = true  // macOS doesn't have background restrictions
        #endif
        
        central.scanForPeripherals(
                withServices: [BLEService.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
        )
        
        // Started BLE scanning
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let peripheralID = peripheral.identifier.uuidString
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? (peripheralID.prefix(6) + "…")
        let isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        let rssiValue = RSSI.intValue
        
        // Skip if peripheral is not connectable (per advertisement data)
        guard isConnectable else { return }

        // Skip if signal too weak - prevents connection attempts at extreme range
        guard rssiValue > -90 else {
            // Too far away, don't attempt connection
            return
        }
        
        // Check if we already have this peripheral
        if let state = peripherals[peripheralID] {
            if state.isConnected || state.isConnecting {
                return // Already connected or connecting
            }
            
            // Add backoff for reconnection attempts
            if let lastAttempt = state.lastConnectionAttempt {
                let timeSinceLastAttempt = Date().timeIntervalSince(lastAttempt)
                if timeSinceLastAttempt < 2.0 {
                    return // Wait at least 2 seconds between connection attempts
                }
            }
        }
        
        // Backoff if this peripheral recently timed out connection within the last 15 seconds
        if let lastTimeout = recentConnectTimeouts[peripheralID], Date().timeIntervalSince(lastTimeout) < 15 {
            return
        }

        // Check peripheral state - but cancel if stale
        if peripheral.state == .connecting || peripheral.state == .connected {
            // iOS might have stale state - force disconnect and retry
            central.cancelPeripheralConnection(peripheral)
            // Will retry on next discovery
            return
        }
        
        // Only log when we're actually attempting connection
        // Discovered BLE peripheral
        
        // Store the peripheral and mark as connecting
        peripherals[peripheralID] = PeripheralState(
            peripheral: peripheral,
            characteristic: nil,
            peerID: nil,
            isConnecting: true,
            isConnected: false,
            lastConnectionAttempt: Date()
        )
        peripheral.delegate = self
        
        // Connect to the peripheral with options for faster connection
        SecureLogger.log("📱 Connect: \(advertisedName) [RSSI:\(rssiValue)]",
                        category: SecureLogger.session, level: .debug)
        
        // Use connection options for faster reconnection
        let options: [String: Any] = [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ]
        central.connect(peripheral, options: options)
        
        // Set a timeout for the connection attempt (slightly longer for reliability)
        // Use BLE queue to mutate BLE-related state consistently
        bleQueue.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self = self,
                  let state = self.peripherals[peripheralID],
                  state.isConnecting && !state.isConnected else { return }
            
            // Connection timed out - cancel it
            SecureLogger.log("⏱️ Timeout: \(advertisedName)",
                            category: SecureLogger.session, level: .debug)
            central.cancelPeripheralConnection(peripheral)
            self.peripherals[peripheralID] = nil
            self.recentConnectTimeouts[peripheralID] = Date()
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let peripheralID = peripheral.identifier.uuidString
        
        // Update state to connected
        if var state = peripherals[peripheralID] {
            state.isConnecting = false
            state.isConnected = true
            peripherals[peripheralID] = state
        } else {
            // Create new state if not found
            peripherals[peripheralID] = PeripheralState(
                peripheral: peripheral,
                characteristic: nil,
                peerID: nil,
                isConnecting: false,
                isConnected: true
            )
        }
        
        SecureLogger.log("✅ Connected: \(peripheral.name ?? "Unknown") [\(peripheralID)]", category: SecureLogger.session, level: .debug)
        
        // Discover services
        peripheral.discoverServices([BLEService.serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let peripheralID = peripheral.identifier.uuidString
        
        // Find the peer ID if we have it
        let peerID = peripherals[peripheralID]?.peerID
        
        SecureLogger.log("📱 Disconnect: \(peerID ?? peripheralID)\(error != nil ? " (\(error!.localizedDescription))" : "")",
                        category: SecureLogger.session, level: .debug)
        
        // Clean up references
        peripherals.removeValue(forKey: peripheralID)
        
        // Clean up peer mappings
        if let peerID = peerID {
            peerToPeripheralUUID.removeValue(forKey: peerID)
            
            // Remove peer completely (they'll be re-added when they reconnect and announce)
            _ = collectionsQueue.sync(flags: .barrier) {
                peers.removeValue(forKey: peerID)
            }
        }
        
        // Restart scanning with allow duplicates for faster rediscovery
        if centralManager?.state == .poweredOn {
            // Stop and restart scanning to ensure we get fresh discovery events
            centralManager?.stopScan()
            bleQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.startScanning()
            }
        }
        
        // Notify delegate about disconnection on main thread
        notifyUI { [weak self] in
            guard let self = self else { return }
            
            // Get current peer list (after removal)
            let currentPeerIDs = self.collectionsQueue.sync { Array(self.peers.keys) }
            
            if let peerID = peerID {
                self.delegate?.didDisconnectFromPeer(peerID)
            }
            self.publishFullPeerData()
            self.delegate?.didUpdatePeerList(currentPeerIDs)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let peripheralID = peripheral.identifier.uuidString
        
        // Clean up the references
        peripherals.removeValue(forKey: peripheralID)
        
        SecureLogger.log("❌ Failed to connect to peripheral: \(peripheral.name ?? "Unknown") [\(peripheralID)] - Error: \(error?.localizedDescription ?? "Unknown")", category: SecureLogger.session, level: .error)
    }
}

#if DEBUG
// Test-only helper to inject packets into the receive pipeline
extension BLEService {
    func _test_handlePacket(_ packet: BitchatPacket, fromPeerID: String) {
        if DispatchQueue.getSpecific(key: messageQueueKey) != nil {
            handleReceivedPacket(packet, from: fromPeerID)
        } else {
            messageQueue.async { [weak self] in
                self?.handleReceivedPacket(packet, from: fromPeerID)
            }
        }
    }
}
#endif

// MARK: - CBPeripheralDelegate

extension BLEService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            SecureLogger.log("❌ Error discovering services for \(peripheral.name ?? "Unknown"): \(error.localizedDescription)", category: SecureLogger.session, level: .error)
            // Retry service discovery after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard peripheral.state == .connected else { return }
                peripheral.discoverServices([BLEService.serviceUUID])
            }
            return
        }
        
        guard let services = peripheral.services else {
            SecureLogger.log("⚠️ No services discovered for \(peripheral.name ?? "Unknown")", category: SecureLogger.session, level: .warning)
            return
        }
        
        guard let service = services.first(where: { $0.uuid == BLEService.serviceUUID }) else {
            // Not a BitChat peer - disconnect
            centralManager?.cancelPeripheralConnection(peripheral)
            return
        }
        
        // Discovering BLE characteristics
        peripheral.discoverCharacteristics([BLEService.characteristicUUID], for: service)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            SecureLogger.log("❌ Error discovering characteristics for \(peripheral.name ?? "Unknown"): \(error.localizedDescription)", category: SecureLogger.session, level: .error)
            return
        }
        
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == BLEService.characteristicUUID }) else {
            SecureLogger.log("⚠️ No matching characteristic found for \(peripheral.name ?? "Unknown")", category: SecureLogger.session, level: .warning)
            return
        }
        
        // Found characteristic
        
        // Log characteristic properties for debugging
        var properties: [String] = []
        if characteristic.properties.contains(.read) { properties.append("read") }
        if characteristic.properties.contains(.write) { properties.append("write") }
        if characteristic.properties.contains(.writeWithoutResponse) { properties.append("writeWithoutResponse") }
        if characteristic.properties.contains(.notify) { properties.append("notify") }
        if characteristic.properties.contains(.indicate) { properties.append("indicate") }
        // Characteristic properties: \(properties.joined(separator: ", "))
        
        // Verify characteristic supports reliable writes
        if !characteristic.properties.contains(.write) {
            SecureLogger.log("⚠️ Characteristic doesn't support reliable writes (withResponse)!", category: SecureLogger.session, level: .warning)
        }
        
        // Store characteristic in our consolidated structure
        let peripheralID = peripheral.identifier.uuidString
        if var state = peripherals[peripheralID] {
            state.characteristic = characteristic
            peripherals[peripheralID] = state
        }
        
        // Subscribe for notifications
        if characteristic.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: characteristic)
            SecureLogger.log("🔔 Subscribed to notifications from \(peripheral.name ?? "Unknown")", category: SecureLogger.session, level: .debug)
            
            // Send announce after subscription is confirmed (force send for new connection)
            messageQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.sendAnnounce(forceSend: true)
            }
        } else {
            SecureLogger.log("⚠️ Characteristic does not support notifications", category: SecureLogger.session, level: .warning)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            SecureLogger.log("❌ Error receiving notification: \(error.localizedDescription)", category: SecureLogger.session, level: .error)
            return
        }
        
        guard let data = characteristic.value else {
            SecureLogger.log("⚠️ No data in notification", category: SecureLogger.session, level: .warning)
            return
        }
        
        // Received BLE notification
        
        // Process directly on main thread to avoid deadlocks (matches original implementation)
        guard let packet = BinaryProtocol.decode(data) else {
            SecureLogger.log("❌ Failed to decode notification packet, full data: \(data.map { String(format: "%02x", $0) }.joined(separator: " "))",
                            category: SecureLogger.session, level: .error)
            return
        }
        
        // Use the packet's senderID as the peer identifier
        let senderID = packet.senderID.hexEncodedString()
        // Only log non-announce packets
    if packet.type != MessageType.announce.rawValue {
        SecureLogger.log("📦 Decoded notification packet type: \(packet.type) from sender: \(senderID)", category: SecureLogger.session, level: .debug)
    }
        
        let peripheralUUID = peripheral.identifier.uuidString
        
        // Update mapping ONLY for announce packets that come directly from the peer (not relayed)
        if packet.type == MessageType.announce.rawValue {
            // Only update mapping if this is a direct announce (TTL == messageTTL means not relayed)
            if packet.ttl == messageTTL {
                if var state = peripherals[peripheralUUID] {
                    state.peerID = senderID
                    peripherals[peripheralUUID] = state
                }
                peerToPeripheralUUID[senderID] = peripheralUUID
                // Mapping update - direct announce from peer
            }
            // Process the announce packet regardless of whether we updated the mapping
            handleReceivedPacket(packet, from: senderID)
        } else {
            // For non-announce packets, DO NOT update mappings
            // These could be relayed packets from other peers
            // Always use the packet's original senderID
            handleReceivedPacket(packet, from: senderID)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            SecureLogger.log("❌ Write failed to \(peripheral.name ?? peripheral.identifier.uuidString): \(error.localizedDescription)", category: SecureLogger.session, level: .error)
            // Don't retry - just log the error
        } else {
            SecureLogger.log("✅ Write confirmed to \(peripheral.name ?? peripheral.identifier.uuidString)", category: SecureLogger.session, level: .debug)
        }
    }
    
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // Suppress verbose ready logs
    }
    
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        SecureLogger.log("⚠️ Services modified for \(peripheral.name ?? peripheral.identifier.uuidString)", category: SecureLogger.session, level: .warning)
        
        // Check if our service was invalidated (peer app quit)
        let hasOurService = peripheral.services?.contains { $0.uuid == BLEService.serviceUUID } ?? false
        
        if !hasOurService {
            // Service is gone - disconnect
            SecureLogger.log("❌ BitChat service removed - disconnecting from \(peripheral.name ?? peripheral.identifier.uuidString)", category: SecureLogger.session, level: .warning)
            centralManager?.cancelPeripheralConnection(peripheral)
        } else {
            // Try to rediscover
            peripheral.discoverServices([BLEService.serviceUUID])
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            SecureLogger.log("❌ Error updating notification state: \(error.localizedDescription)", category: SecureLogger.session, level: .error)
        } else {
            SecureLogger.log("🔔 Notification state updated for \(peripheral.name ?? peripheral.identifier.uuidString): \(characteristic.isNotifying ? "ON" : "OFF")", category: SecureLogger.session, level: .debug)
            
            // If notifications are now on, send an announce to ensure this peer knows about us
            if characteristic.isNotifying {
                // Sending announce after subscription
                self.sendAnnounce(forceSend: true)
            }
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEService: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        SecureLogger.log("📡 Peripheral manager state: \(peripheral.state.rawValue)", category: SecureLogger.session, level: .debug)
        
        if peripheral.state == .poweredOn {
            // Remove all services first to ensure clean state
            peripheral.removeAllServices()
            
            // Create characteristic
            characteristic = CBMutableCharacteristic(
                type: BLEService.characteristicUUID,
                properties: [.notify, .write, .writeWithoutResponse, .read],
                value: nil,
                permissions: [.readable, .writeable]
            )
            
            // Create service
            let service = CBMutableService(type: BLEService.serviceUUID, primary: true)
            service.characteristics = [characteristic!]
            
            // Add service (advertising will start in didAdd delegate)
            SecureLogger.log("🔧 Adding BLE service...", category: SecureLogger.session, level: .debug)
            peripheral.add(service)
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            SecureLogger.log("❌ Failed to add service: \(error.localizedDescription)", category: SecureLogger.session, level: .error)
            return
        }
        
        SecureLogger.log("✅ Service added successfully, starting advertising", category: SecureLogger.session, level: .debug)
        
        // Start advertising after service is confirmed added
        let adData = buildAdvertisementData()
        peripheral.startAdvertising(adData)
        
        SecureLogger.log("📡 Started advertising (LocalName: \((adData[CBAdvertisementDataLocalNameKey] as? String) != nil ? "on" : "off"), ID: \(myPeerID.prefix(8))…)", category: SecureLogger.session, level: .debug)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        SecureLogger.log("📥 Central subscribed: \(central.identifier.uuidString)", category: SecureLogger.session, level: .debug)
        subscribedCentrals.append(central)
        // Send announce to the newly subscribed central after a small delay to avoid overwhelming
        messageQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.sendAnnounce(forceSend: true)
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        SecureLogger.log("📤 Central unsubscribed: \(central.identifier.uuidString)", category: SecureLogger.session, level: .debug)
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        
        // Ensure we're still advertising for other devices to find us
        if peripheral.isAdvertising == false {
            SecureLogger.log("📡 Restarting advertising after central unsubscribed", category: SecureLogger.session, level: .debug)
            peripheral.startAdvertising(buildAdvertisementData())
        }
        
        // Find and disconnect the peer associated with this central
        let centralUUID = central.identifier.uuidString
        if let peerID = centralToPeerID[centralUUID] {
            // Remove peer completely (they'll be re-added when they reconnect)
            _ = collectionsQueue.sync(flags: .barrier) {
                peers.removeValue(forKey: peerID)
            }
            
            // Clean up mappings
            centralToPeerID.removeValue(forKey: centralUUID)
            
            // Update UI immediately
            notifyUI { [weak self] in
                guard let self = self else { return }
                
                // Get current peer list (after removal)
                let currentPeerIDs = self.collectionsQueue.sync { Array(self.peers.keys) }
                
                self.delegate?.didDisconnectFromPeer(peerID)
                self.delegate?.didUpdatePeerList(currentPeerIDs)
            }
        }
    }
    
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        SecureLogger.log("📤 Peripheral manager ready to send more notifications", category: SecureLogger.session, level: .debug)
        
        // Retry pending notifications now that queue has space
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self,
                  let characteristic = self.characteristic,
                  !self.pendingNotifications.isEmpty else { return }
            
            let pending = self.pendingNotifications
            self.pendingNotifications.removeAll()
            
            // Try to send pending notifications
            for (data, centrals) in pending {
                if let centrals = centrals {
                    // Send to specific centrals
                    let success = self.peripheralManager?.updateValue(data, for: characteristic, onSubscribedCentrals: centrals) ?? false
                    if !success {
                        // Still full, re-queue
                        self.pendingNotifications.append((data: data, centrals: centrals))
                        SecureLogger.log("⚠️ Notification queue still full, re-queuing", 
                                       category: SecureLogger.session, level: .debug)
                        break  // Stop trying, wait for next ready callback
                    } else {
                        SecureLogger.log("✅ Sent pending notification from retry queue", 
                                       category: SecureLogger.session, level: .debug)
                    }
                } else {
                    // Broadcast to all
                    let success = self.peripheralManager?.updateValue(data, for: characteristic, onSubscribedCentrals: nil) ?? false
                    if !success {
                        // Still full, re-queue
                        self.pendingNotifications.append((data: data, centrals: nil))
                        break
                    }
                }
            }
            
            if !self.pendingNotifications.isEmpty {
                SecureLogger.log("📋 Still have \(self.pendingNotifications.count) pending notifications", 
                               category: SecureLogger.session, level: .debug)
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Suppress logs for single write requests to reduce noise
        if requests.count > 1 {
            SecureLogger.log("📥 Received \(requests.count) write requests from central", category: SecureLogger.session, level: .debug)
        }
        
        // IMPORTANT: Respond immediately to prevent timeouts!
        // We must respond within a few milliseconds or the central will timeout
        for request in requests {
            peripheral.respond(to: request, withResult: .success)
        }
        
        // Process writes. For long writes, CoreBluetooth may deliver multiple CBATTRequest values with offsets.
        // Combine per-central request values by offset before decoding.
        // Process directly on our message queue to match transport context
        let grouped = Dictionary(grouping: requests, by: { $0.central.identifier.uuidString })
        for (centralUUID, group) in grouped {
            // Sort by offset ascending
            let sorted = group.sorted { $0.offset < $1.offset }
            let hasMultiple = sorted.count > 1 || (sorted.first?.offset ?? 0) > 0

            // Always merge into a persistent per-central buffer to handle multi-callback long writes
            var combined = pendingWriteBuffers[centralUUID] ?? Data()
            var appendedBytes = 0
            var offsets: [Int] = []
            for r in sorted {
                guard let chunk = r.value, !chunk.isEmpty else { continue }
                offsets.append(r.offset)
                let end = r.offset + chunk.count
                if combined.count < end {
                    combined.append(Data(repeating: 0, count: end - combined.count))
                }
                // Write chunk into the correct position (supports out-of-order and overlapping writes)
                combined.replaceSubrange(r.offset..<end, with: chunk)
                appendedBytes += chunk.count
            }
            pendingWriteBuffers[centralUUID] = combined

            // Peek type byte for debug: version is at 0, type at 1 when well-formed
            if combined.count >= 2 {
                let peekType = combined[1]
                if peekType != MessageType.announce.rawValue {
                    SecureLogger.log("📥 Accumulated write from central \(centralUUID): size=\(combined.count) (+\(appendedBytes)) bytes (type=\(peekType)), offsets=\(offsets)", category: SecureLogger.session, level: .debug)
                }
            }

            // Try decode the accumulated buffer
            if let packet = BinaryProtocol.decode(combined) {
                // Clear buffer on success
                pendingWriteBuffers.removeValue(forKey: centralUUID)
                let senderID = packet.senderID.hexEncodedString()
                if packet.type != MessageType.announce.rawValue {
                    SecureLogger.log("📦 Decoded (combined) packet type: \(packet.type) from sender: \(senderID)", category: SecureLogger.session, level: .debug)
                }
                if !subscribedCentrals.contains(sorted[0].central) {
                    subscribedCentrals.append(sorted[0].central)
                }
                if packet.type == MessageType.announce.rawValue {
                    if packet.ttl == messageTTL { centralToPeerID[centralUUID] = senderID }
                    handleReceivedPacket(packet, from: senderID)
                } else {
                    handleReceivedPacket(packet, from: senderID)
                }
            } else {
                // If buffer grows suspiciously large, reset to avoid memory leak
                if combined.count > 1_000_000 { // 1MB cap for safety
                    pendingWriteBuffers.removeValue(forKey: centralUUID)
                    SecureLogger.log("⚠️ Dropping oversized pending write buffer (\(combined.count) bytes) for central \(centralUUID)", category: SecureLogger.session, level: .warning)
                }
                // If this was a single short write and still failed, log the raw chunk for debugging
                if !hasMultiple, let only = sorted.first, let raw = only.value {
                    SecureLogger.log("❌ Failed to decode packet from central, full data: \(raw.map { String(format: "%02x", $0) }.joined(separator: " "))", category: SecureLogger.session, level: .error)
                }
            }
        }
    }    
}

// MARK: - Advertising Builders & Alias Rotation

extension BLEService {
    private func buildAdvertisementData() -> [String: Any] {
        let data: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [BLEService.serviceUUID]
        ]
        // No Local Name for privacy
        return data
    }
    
    // No alias rotation or advertising restarts required.
}
