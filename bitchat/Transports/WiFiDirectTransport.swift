//
// WiFiDirectTransport.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import MultipeerConnectivity
import CryptoKit
import Compression
#if os(iOS)
import UIKit
#elseif os(macOS)
import IOKit
#endif

// MARK: - WiFi Direct Transport Implementation

class WiFiDirectTransport: NSObject, TransportProtocol {
    // TransportProtocol requirements
    let transportType: TransportType = .wifiDirect
    private(set) var isAvailable: Bool = false
    private(set) var currentPeers: [PeerInfo] = []
    let capabilities = TransportCapabilities(
        maxMessageSize: 1_000_000,  // 1MB
        averageBandwidth: 25_000_000,  // ~200 Mbps = 25MB/s
        typicalRange: 100,  // meters
        powerConsumption: .medium
    )
    weak var delegate: TransportDelegate?
    
    // MultipeerConnectivity components
    private var peerID: MCPeerID!
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var myConsistentPeerID: String = ""  // Consistent ID used for signing
    
    // Constants
    private let serviceType = "bitchat-w"  // Must be 1-15 characters, lowercase letters, numbers, and hyphens
    
    // State tracking
    private var connectedPeers: [MCPeerID: PeerInfo] = [:]
    private var peerIDMapping: [String: MCPeerID] = [:]  // bitchat peerID -> MCPeerID
    private let queue = DispatchQueue(label: "bitchat.wifidirect", attributes: .concurrent)
    private let queueKey = DispatchSpecificKey<Void>()
    private var isAdvertising = false
    private var isBrowsing = false
    
    // Security
    private var peerPublicKeys: [String: P256.Signing.PublicKey] = [:]  // peerID -> public key
    private var messageSequenceNumbers: [String: UInt64] = [:]  // peerID -> last seen sequence
    private var mySequenceNumber: UInt64 = 0
    private let signingKey = P256.Signing.PrivateKey()
    private var nonceSeen = Set<Data>()  // Track seen nonces to prevent replay
    private let nonceExpirationTime: TimeInterval = 300  // 5 minutes
    private weak var nonceCleanupTimer: Timer?
    
    // Resource limits
    private let maxNonces = 10000
    private let maxCacheEntries = 1000
    private let maxPendingMessages = 100
    private let maxPeers = 50
    private let maxSequenceNumbers = 100
    
    // Routing and loop prevention
    private var messageHistory = Set<String>()  // Hash of messages we've seen
    private let maxMessageHistory = 5000
    private let messageHistoryTimeout: TimeInterval = 300  // 5 minutes
    private var routingTable: [String: (nextHop: String, cost: Int, timestamp: Date)] = [:]  // destination -> route info
    private let routingTimeout: TimeInterval = 120  // 2 minutes
    private weak var routingCleanupTimer: Timer?
    
    // Reliability and acknowledgments
    private var awaitingAcks: [String: (packet: BitchatPacket, timestamp: Date, retries: Int)] = [:]  // messageID -> pending ack
    private let ackTimeout: TimeInterval = 5  // 5 seconds
    private let maxAckRetries = 3
    private weak var ackTimer: Timer?
    private var connectionState: [MCPeerID: ConnectionState] = [:]
    private var reconnectionAttempts: [MCPeerID: Int] = [:]
    private let maxReconnectionAttempts = 5
    
    enum ConnectionState {
        case connecting
        case connected
        case disconnecting
        case disconnected
    }
    
    // Periodic discovery
    private weak var discoveryTimer: Timer?
    private let discoveryInterval: TimeInterval = 30  // Re-advertise every 30 seconds
    private let discoveryBurstInterval: TimeInterval = 5  // More frequent when no peers
    private var lastDiscoveryTime = Date()
    
    // Message handling
    private let maxRetries = 3
    private var pendingMessages: [String: (packet: BitchatPacket, retries: Int, timestamp: Date)] = [:]
    private weak var messageExpirationTimer: Timer?
    private let messageTimeout: TimeInterval = 30  // 30 seconds for pending messages
    
    // Performance optimization
    private var messageBatch: [(packet: BitchatPacket, peerID: String?)] = []
    private weak var batchTimer: Timer?
    private let batchInterval: TimeInterval = 0.1  // 100ms batching window
    private let maxBatchSize = 10  // Max messages per batch
    private let compressionThreshold = 1024  // Compress if > 1KB
    private var messageCache: [String: (data: Data, timestamp: Date)] = [:]  // Cache encoded messages
    private let cacheExpiration: TimeInterval = 60  // 1 minute cache
    
    override init() {
        super.init()
        // Set queue specific so we can detect if we're on this queue
        queue.setSpecific(key: queueKey, value: ())
        setupMultipeerConnectivity()
        
        // Monitor memory pressure
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        #elseif os(macOS)
        // macOS doesn't have a direct memory warning notification
        // Could use NSProcessInfo.processInfo.thermalState monitoring
        #endif
        
        startNonceCleanupTimer()
        startMessageExpirationTimer()
        startBatchTimer()
        startRoutingCleanupTimer()
        startAckTimer()
        // Start periodic discovery to find peers
        startDiscoveryTimer()
    }
    
    @objc private func handleMemoryWarning() {
        print("WiFiDirect: Memory warning received, cleaning up...")
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            // Aggressively clean caches
            self.messageCache.removeAll()
            
            // Keep only recent nonces
            if self.nonceSeen.count > 100 {
                self.nonceSeen = Set(self.nonceSeen.suffix(100))
            }
            
            // Remove old sequence numbers for disconnected peers
            let connectedPeerIDs = Set(self.connectedPeers.values.map { $0.peerID })
            self.messageSequenceNumbers = self.messageSequenceNumbers.filter { connectedPeerIDs.contains($0.key) }
            self.peerPublicKeys = self.peerPublicKeys.filter { connectedPeerIDs.contains($0.key) }
            
            print("WiFiDirect: Memory cleanup complete")
        }
    }
    
    private func setupMultipeerConnectivity() {
        // Create peer ID using hash of device identifier for consistency
        let deviceID = getDeviceIdentifier()
        let hashedID = SHA256.hash(data: deviceID.data(using: .utf8)!)
        let fullHashString = hashedID.compactMap { String(format: "%02x", $0) }.joined()
        let shortID = String(fullHashString.prefix(8))
        let displayName = "bitchat-\(shortID)"
        
        // Store the full hash as our consistent peer ID for signing
        myConsistentPeerID = String(fullHashString.prefix(16))
        
        peerID = MCPeerID(displayName: displayName)
        
        // Create session with optional encryption
        // We handle our own encryption/signing at the application layer
        session = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: .optional
        )
        session.delegate = self
        
        // Don't create advertiser and browser until needed
        // This prevents premature initialization issues
        
        isAvailable = true
    }
    
    // MARK: - TransportProtocol Methods
    
    func start() {
        // WiFi Direct starts with discovery
        isAvailable = true
        // Auto-start discovery when transport is started
        startDiscovery()
    }
    
    func stop() {
        stopDiscovery()
        session.disconnect()
        isAvailable = false
        
        queue.async(flags: .barrier) {
            self.connectedPeers.removeAll()
            self.peerIDMapping.removeAll()
            self.pendingMessages.removeAll()
            self.updateCurrentPeers()
        }
    }
    
    func startDiscovery() {
        queue.async(flags: .barrier) {
            // Check if we're already discovering
            if self.isAdvertising && self.isBrowsing {
                print("WiFiDirect: Discovery already active")
                return
            }
            
            // Stop any existing discovery first to avoid conflicts
            if self.isAdvertising {
                self.advertiser?.stopAdvertisingPeer()
                self.isAdvertising = false
            }
            if self.isBrowsing {
                self.browser?.stopBrowsingForPeers()
                self.isBrowsing = false
            }
            
            // Small delay to ensure cleanup
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.queue.async(flags: .barrier) {
                    guard let self = self else { return }
                    
                    // Create advertiser if needed
                    if self.advertiser == nil {
                        let publicKeyData = self.signingKey.publicKey.x963Representation
                        let discoveryInfo: [String: String] = [
                            "version": "1.0",
                            "transport": "wifi",
                            "pubkey": publicKeyData.base64EncodedString(),
                            "peerid": self.myConsistentPeerID  // Include our consistent peer ID
                        ]
                        self.advertiser = MCNearbyServiceAdvertiser(
                            peer: self.peerID,
                            discoveryInfo: discoveryInfo,
                            serviceType: self.serviceType
                        )
                        self.advertiser?.delegate = self
                    }
                    
                    // Create browser if needed
                    if self.browser == nil {
                        self.browser = MCNearbyServiceBrowser(
                            peer: self.peerID,
                            serviceType: self.serviceType
                        )
                        self.browser?.delegate = self
                    }
                    
                    // Start advertising
                    if !self.isAdvertising {
                        do {
                            self.advertiser?.startAdvertisingPeer()
                            self.isAdvertising = true
                            print("WiFiDirect: Started advertising with service type: \(self.serviceType)")
                        } catch {
                            print("WiFiDirect: Error starting advertiser: \(error)")
                            self.isAdvertising = false
                        }
                    }
                    
                    // Start browsing
                    if !self.isBrowsing {
                        do {
                            self.browser?.startBrowsingForPeers()
                            self.isBrowsing = true
                            print("WiFiDirect: Started browsing for peers with service type: \(self.serviceType)")
                        } catch {
                            print("WiFiDirect: Error starting browser: \(error)")
                            self.isBrowsing = false
                        }
                    }
                    
                    self.lastDiscoveryTime = Date()
                }
            }
        }
    }
    
    func stopDiscovery() {
        queue.async(flags: .barrier) {
            if self.isAdvertising {
                self.advertiser?.stopAdvertisingPeer()
                self.isAdvertising = false
                print("WiFiDirect: Stopped advertising")
            }
            if self.isBrowsing {
                self.browser?.stopBrowsingForPeers()
                self.isBrowsing = false
                print("WiFiDirect: Stopped browsing")
            }
        }
    }
    
    func send(_ packet: BitchatPacket, to peerID: String?) throws {
        // Create new packet with our WiFi Direct sender ID for proper signature verification
        let wifiPacket = BitchatPacket(
            type: packet.type,
            senderID: myConsistentPeerID.data(using: .utf8) ?? Data(),
            recipientID: packet.recipientID,
            timestamp: packet.timestamp,
            payload: packet.payload,
            signature: packet.signature,
            ttl: packet.ttl
        )
        
        // Check if this is a critical message that needs acknowledgment
        let needsAck = packet.type == MessageType.message.rawValue && peerID != nil
        
        if needsAck {
            // Generate message ID for tracking
            let messageID = "\(wifiPacket.timestamp)-\(wifiPacket.senderID.prefix(8).hexEncodedString())"
            
            queue.async(flags: .barrier) {
                // Track for acknowledgment
                self.awaitingAcks[messageID] = (wifiPacket, Date(), 0)
            }
        }
        
        // Add to batch for efficient sending
        queue.async(flags: .barrier) {
            self.messageBatch.append((wifiPacket, peerID))
            
            // Send immediately if batch is full
            if self.messageBatch.count >= self.maxBatchSize {
                self.processBatch()
            }
        }
    }
    
    private func processBatch() {
        guard !messageBatch.isEmpty else { return }
        
        // Group messages by destination
        var messagesByPeer: [String?: [BitchatPacket]] = [:]
        
        for (packet, peerID) in messageBatch {
            if messagesByPeer[peerID] == nil {
                messagesByPeer[peerID] = []
            }
            messagesByPeer[peerID]?.append(packet)
        }
        
        // Clear batch
        messageBatch.removeAll()
        
        // Process each peer's messages
        for (peerID, packets) in messagesByPeer {
            if let peerID = peerID {
                sendBatchedPackets(packets, to: peerID)
            } else {
                // Broadcast each packet
                for packet in packets {
                    broadcastPacket(packet)
                }
            }
        }
    }
    
    private func sendBatchedPackets(_ packets: [BitchatPacket], to peerID: String) {
        // Check routing table for better path
        let targetPeer: MCPeerID?
        if let nextHop = getNextHop(for: peerID), let hopPeer = getPeerMCID(for: nextHop) {
            targetPeer = hopPeer
        } else {
            targetPeer = getPeerMCID(for: peerID)
        }
        
        guard let peer = targetPeer else {
            // Queue for retry
            for packet in packets {
                // Enforce pending message limit
                if pendingMessages.count >= maxPendingMessages {
                    // Remove oldest pending messages
                    let toRemove = pendingMessages.count / 4
                    let oldestKeys = pendingMessages.sorted { $0.value.timestamp < $1.value.timestamp }.prefix(toRemove).map { $0.key }
                    for key in oldestKeys {
                        pendingMessages.removeValue(forKey: key)
                    }
                }
                
                let messageID = UUID().uuidString
                pendingMessages[messageID] = (packet, 0, Date())
            }
            return
        }
        
        do {
            // Encode and potentially compress multiple packets
            let batchData = try encodeBatch(packets)
            try session.send(batchData, toPeers: [peer], with: .reliable)
        } catch {
            // Store for retry
            for packet in packets {
                // Enforce pending message limit
                if pendingMessages.count >= maxPendingMessages {
                    // Remove oldest pending messages
                    let toRemove = pendingMessages.count / 4
                    let oldestKeys = pendingMessages.sorted { $0.value.timestamp < $1.value.timestamp }.prefix(toRemove).map { $0.key }
                    for key in oldestKeys {
                        pendingMessages.removeValue(forKey: key)
                    }
                    print("WiFiDirect: Trimmed pending messages to \(pendingMessages.count)")
                }
                
                let messageID = UUID().uuidString
                pendingMessages[messageID] = (packet, 0, Date())
                
                let failureID = "\(packet.timestamp)-\(packet.senderID.prefix(8).hexEncodedString())"
                delegate?.transport(self, didFailToSend: failureID, to: peerID, error: error)
            }
            print("WiFiDirect: Failed to send batch to \(peerID): \(error)")
        }
    }
    
    func broadcast(_ packet: BitchatPacket) throws {
        // Create new packet with our WiFi Direct sender ID for proper signature verification
        let wifiPacket = BitchatPacket(
            type: packet.type,
            senderID: myConsistentPeerID.data(using: .utf8) ?? Data(),
            recipientID: packet.recipientID,
            timestamp: packet.timestamp,
            payload: packet.payload,
            signature: packet.signature,
            ttl: packet.ttl
        )
        
        // Add to batch
        queue.async(flags: .barrier) {
            self.messageBatch.append((wifiPacket, nil))
            
            if self.messageBatch.count >= self.maxBatchSize {
                self.processBatch()
            }
        }
    }
    
    private func broadcastPacket(_ packet: BitchatPacket) {
        let peers = session.connectedPeers
        guard !peers.isEmpty else { 
            print("WiFiDirect: No connected peers to broadcast to")
            return 
        }
        
        print("WiFiDirect: Broadcasting to \(peers.count) peers: \(peers.map { $0.displayName })")
        
        do {
            let data = try encodePacketCached(packet)
            try session.send(data, toPeers: peers, with: .reliable)
            print("WiFiDirect: Sent \(data.count) bytes to peers")
        } catch {
            print("WiFiDirect: Broadcast failed: \(error)")
        }
    }
    
    func connect(to peerID: String) throws {
        // MultipeerConnectivity handles connection automatically during discovery
    }
    
    func disconnect(from peerID: String) {
        queue.async(flags: .barrier) {
            if let mcPeerID = self.peerIDMapping[peerID] {
                self.session.cancelConnectPeer(mcPeerID)
            }
        }
    }
    
    func requestHighBandwidth(for peerID: String) -> Bool {
        // WiFi Direct is already high bandwidth
        return true
    }
    
    func getConnectionQuality(for peerID: String) -> ConnectionQuality? {
        guard getPeerMCID(for: peerID) != nil else { return nil }
        
        return ConnectionQuality(
            rssi: nil,  // Not available for WiFi Direct
            packetLoss: 0.01,  // ~1% typical for WiFi
            averageLatency: 0.002,  // ~2ms typical for WiFi
            bandwidth: 25_000_000  // 200 Mbps
        )
    }
    
    // MARK: - Helper Methods
    
    private func getPeerMCID(for peerID: String) -> MCPeerID? {
        // If we're already on the queue, just access directly
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return peerIDMapping[peerID]
        } else {
            return queue.sync {
                peerIDMapping[peerID]
            }
        }
    }
    
    private func encodePacketCached(_ packet: BitchatPacket) throws -> Data {
        // Create cache key from packet content
        let cacheKey = "\(packet.type)-\(packet.timestamp)-\(packet.senderID.base64EncodedString())"
        
        // Check cache
        if let cached = messageCache[cacheKey],
           Date().timeIntervalSince(cached.timestamp) < cacheExpiration {
            return cached.data
        }
        
        // Encode packet
        let data = try encodePacket(packet)
        
        // Cache the result - we're already on the queue, so update directly
        // Enforce cache size limit
        if messageCache.count >= maxCacheEntries {
            // Remove oldest entries
            let toRemove = messageCache.count / 4
            let oldestKeys = messageCache.sorted { $0.value.timestamp < $1.value.timestamp }.prefix(toRemove).map { $0.key }
            for key in oldestKeys {
                messageCache.removeValue(forKey: key)
            }
        }
        
        messageCache[cacheKey] = (data, Date())
        
        return data
    }
    
    private func encodePacket(_ packet: BitchatPacket) throws -> Data {
        var data = Data()
        
        // Generate nonce (8 bytes)
        var nonce = Data(count: 8)
        let result = nonce.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, 8, baseAddress)
        }
        guard result == errSecSuccess else {
            throw TransportError.invalidData
        }
        data.append(nonce)
        
        // Sequence number - already on queue, just increment
        mySequenceNumber += 1
        data.append(UInt64(mySequenceNumber).bigEndianData)
        
        // Version
        data.append(packet.version)
        
        // Type
        data.append(packet.type)
        
        // Sender ID
        let senderData = packet.senderID
        data.append(UInt16(senderData.count).bigEndianData)
        data.append(senderData)
        
        // Recipient ID (optional)
        if let recipientID = packet.recipientID {
            data.append(1)  // Has recipient
            data.append(UInt16(recipientID.count).bigEndianData)
            data.append(recipientID)
        } else {
            data.append(0)  // No recipient
        }
        
        // Timestamp
        data.append(packet.timestamp.bigEndianData)
        
        // TTL
        data.append(packet.ttl)
        
        // Payload
        data.append(UInt32(packet.payload.count).bigEndianData)
        data.append(packet.payload)
        
        // Sign the entire message (excluding the signature itself)
        let signature = try signingKey.signature(for: data)
        
        // Append signature
        data.append(1)  // Has signature
        data.append(UInt16(signature.derRepresentation.count).bigEndianData)
        data.append(signature.derRepresentation)
        
        return data
    }
    
    private func decodePacket(_ data: Data) throws -> BitchatPacket {
        var offset = 0
        
        guard data.count > 26 else {  // Minimum size with security headers
            throw TransportError.invalidData
        }
        
        // Extract nonce (8 bytes)
        let nonce = data.subdata(in: offset..<offset+8)
        offset += 8
        
        // Check for replay attack
        var isReplay = false
        queue.sync {
            isReplay = nonceSeen.contains(nonce)
            if !isReplay {
                // Enforce nonce limit
                if nonceSeen.count >= maxNonces {
                    // Remove oldest nonces (approximation since Set doesn't maintain order)
                    let toRemove = nonceSeen.count / 4
                    nonceSeen = Set(nonceSeen.dropFirst(toRemove))
                    print("WiFiDirect: Trimmed nonce cache from \(nonceSeen.count + toRemove) to \(nonceSeen.count)")
                }
                nonceSeen.insert(nonce)
            }
        }
        
        if isReplay {
            throw TransportError.invalidData  // Replay attack detected
        }
        
        // Sequence number (8 bytes)
        let sequenceNumber = data.subdata(in: offset..<offset+8).uint64BigEndian
        offset += 8
        
        // Store position before reading packet data (for signature verification)
        let _ = offset  // Note: position tracked for future use
        
        // Version (currently unused but needed for protocol compatibility)
        _ = data[offset]
        offset += 1
        
        // Type
        let type = data[offset]
        offset += 1
        
        // Sender ID
        let senderLength = data.subdata(in: offset..<offset+2).uint16BigEndian
        offset += 2
        let senderID = data.subdata(in: offset..<offset+Int(senderLength))
        offset += Int(senderLength)
        
        // Recipient ID
        var recipientID: Data?
        if data[offset] == 1 {
            offset += 1
            let recipientLength = data.subdata(in: offset..<offset+2).uint16BigEndian
            offset += 2
            recipientID = data.subdata(in: offset..<offset+Int(recipientLength))
            offset += Int(recipientLength)
        } else {
            offset += 1
        }
        
        // Timestamp
        let timestamp = data.subdata(in: offset..<offset+8).uint64BigEndian
        offset += 8
        
        // TTL
        let ttl = data[offset]
        offset += 1
        
        // Payload
        let payloadLength = data.subdata(in: offset..<offset+4).uint32BigEndian
        offset += 4
        let payload = data.subdata(in: offset..<offset+Int(payloadLength))
        offset += Int(payloadLength)
        
        // Signature
        var signature: Data?
        if offset < data.count && data[offset] == 1 {
            offset += 1
            let signatureLength = data.subdata(in: offset..<offset+2).uint16BigEndian
            offset += 2
            let signatureData = data.subdata(in: offset..<offset+Int(signatureLength))
            
            // Verify signature
            let senderIDString = String(data: senderID, encoding: .utf8) ?? ""
            if let publicKey = peerPublicKeys[senderIDString] {
                // Data to verify is everything from nonce to before signature flag
                let dataToVerify = data.subdata(in: 0..<(offset - 3 - Int(signatureLength)))
                
                do {
                    let sig = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
                    if publicKey.isValidSignature(sig, for: dataToVerify) {
                        // Valid signature - check sequence number
                        var isSequenceValid = true
                        queue.sync(flags: .barrier) {
                            if let lastSeq = messageSequenceNumbers[senderIDString] {
                                if sequenceNumber <= lastSeq {
                                    // Sequence number replay - reject
                                    isSequenceValid = false
                                    return
                                }
                            }
                            
                            // Enforce sequence number limit
                            if messageSequenceNumbers.count >= maxSequenceNumbers {
                                // Remove oldest entries
                                let toRemove = messageSequenceNumbers.count / 4
                                let oldestKeys = messageSequenceNumbers.sorted { $0.value < $1.value }.prefix(toRemove).map { $0.key }
                                for key in oldestKeys {
                                    messageSequenceNumbers.removeValue(forKey: key)
                                }
                            }
                            
                            messageSequenceNumbers[senderIDString] = sequenceNumber
                        }
                        
                        if !isSequenceValid {
                            throw TransportError.invalidData
                        }
                        signature = signatureData
                    } else {
                        // Invalid signature
                        throw TransportError.invalidData
                    }
                } catch {
                    // Signature verification failed
                    print("WiFiDirect: Signature verification failed from \(senderIDString): \(error)")
                    throw TransportError.invalidData
                }
            } else {
                // No public key for sender yet
                // For the first message from a peer, we might not have their key yet
                // Look up the key by the MCPeerID's generated ID
                var foundKey: P256.Signing.PublicKey?
                
                // Try to find the public key - it might be stored under the MCPeerID
                // The sender ID in the packet is the device's ID, not the MCPeerID hash
                // So we need to try all stored keys until we find one that works
                print("WiFiDirect: Looking for public key for sender \(senderIDString)")
                print("WiFiDirect: Available keys: \(peerPublicKeys.keys.joined(separator: ", "))")
                
                // Try each stored key until we find one that verifies the signature
                let dataToVerify = data.subdata(in: 0..<(offset - 3 - Int(signatureLength)))
                
                for (keyID, candidateKey) in peerPublicKeys {
                    do {
                        let sig = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
                        if candidateKey.isValidSignature(sig, for: dataToVerify) {
                            // Found the right key!
                            foundKey = candidateKey
                            // Store it under the sender ID for faster lookup next time
                            peerPublicKeys[senderIDString] = candidateKey
                            print("WiFiDirect: Found valid key for sender \(senderIDString) (was stored as \(keyID))")
                            break
                        }
                    } catch {
                        // Try next key
                        continue
                    }
                }
                
                if foundKey == nil {
                    print("WiFiDirect: Tried all \(peerPublicKeys.count) keys, none verified the signature")
                }
                
                if let publicKey = foundKey {
                    // Verify with the found key
                    let dataToVerify = data.subdata(in: 0..<(offset - 3 - Int(signatureLength)))
                    do {
                        let sig = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
                        if publicKey.isValidSignature(sig, for: dataToVerify) {
                            signature = signatureData
                            print("WiFiDirect: Signature verified successfully using found key")
                        } else {
                            print("WiFiDirect: Signature invalid - data to verify: \(dataToVerify.count) bytes, sig: \(signatureData.count) bytes")
                            throw TransportError.invalidData
                        }
                    } catch {
                        print("WiFiDirect: Signature verification failed with found key: \(error)")
                        print("WiFiDirect: Signature data length: \(signatureData.count), expected DER format")
                        throw TransportError.invalidData
                    }
                } else {
                    // Still no key found - reject
                    print("WiFiDirect: No public key found for sender \(senderIDString) - rejecting message")
                    throw TransportError.invalidData
                }
            }
        }
        
        return BitchatPacket(
            type: type,
            senderID: senderID,
            recipientID: recipientID,
            timestamp: timestamp,
            payload: payload,
            signature: signature,
            ttl: ttl
        )
    }
    
    private func generateBitchatPeerID(for mcPeerID: MCPeerID) -> String {
        // Generate consistent ID from MCPeerID
        let data = mcPeerID.displayName.data(using: .utf8) ?? Data()
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }
    
    private func getDeviceIdentifier() -> String {
        #if os(iOS)
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #elseif os(macOS)
        // Use hardware UUID on macOS
        let mainPort: mach_port_t
        if #available(macOS 12.0, *) {
            mainPort = kIOMainPortDefault
        } else {
            mainPort = kIOMasterPortDefault
        }
        let platformExpert = IOServiceGetMatchingService(mainPort, IOServiceMatching("IOPlatformExpertDevice"))
        if platformExpert != 0 {
            defer { IOObjectRelease(platformExpert) }
            
            if let cfProperty = IORegistryEntryCreateCFProperty(
                platformExpert,
                kIOPlatformUUIDKey as CFString,
                kCFAllocatorDefault,
                0
            ) {
                let uuidString = (cfProperty.takeRetainedValue() as? String) ?? UUID().uuidString
                return uuidString
            }
        }
        return UUID().uuidString
        #endif
    }
    
    // MARK: - Periodic Discovery
    
    private func startDiscoveryTimer() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkDiscoveryStatus()
        }
        timer.tolerance = 0.5
        self.discoveryTimer = timer
    }
    
    private func checkDiscoveryStatus() {
        guard isAvailable else { return }
        
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let now = Date()
            let peerCount = self.connectedPeers.count
            
            // Determine discovery interval based on peer count
            let interval: TimeInterval
            if peerCount == 0 {
                // No peers - advertise more frequently
                interval = self.discoveryBurstInterval
            } else if peerCount < 3 {
                // Few peers - moderate frequency
                interval = self.discoveryInterval / 2
            } else {
                // Good number of peers - normal frequency
                interval = self.discoveryInterval
            }
            
            // Check if it's time to re-advertise
            if now.timeIntervalSince(self.lastDiscoveryTime) >= interval {
                // Restart discovery to refresh our presence
                if self.isAdvertising || self.isBrowsing {
                    print("WiFiDirect: Refreshing discovery (peers: \(peerCount))")
                    
                    // Don't stop/restart too quickly - this can cause crashes
                    // Instead, just update the timestamp
                    // The framework will handle refreshing on its own
                    
                    self.lastDiscoveryTime = now
                }
            }
        }
    }
    
    deinit {
        // Clean up timers
        nonceCleanupTimer?.invalidate()
        messageExpirationTimer?.invalidate()
        batchTimer?.invalidate()
        routingCleanupTimer?.invalidate()
        ackTimer?.invalidate()
        // discoveryTimer?.invalidate()
        
        // Remove observers
        NotificationCenter.default.removeObserver(self)
        
        // Clean up session
        if isAdvertising {
            advertiser?.stopAdvertisingPeer()
        }
        if isBrowsing {
            browser?.stopBrowsingForPeers()
        }
        
        // Nil out the delegates before releasing
        advertiser?.delegate = nil
        browser?.delegate = nil
        session?.delegate = nil
        
        // Disconnect session
        session?.disconnect()
        
        // Clear references
        advertiser = nil
        browser = nil
    }
}

// MARK: - MCSessionDelegate

extension WiFiDirectTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        print("WiFiDirect: Peer \(peerID.displayName) state changed to \(state.rawValue)")
        queue.async(flags: .barrier) {
            switch state {
            case .connected:
                print("WiFiDirect: Connected to peer \(peerID.displayName)")
                // Enforce peer limit
                if self.connectedPeers.count >= self.maxPeers {
                    // Reject new connection
                    self.session.cancelConnectPeer(peerID)
                    print("WiFiDirect: Rejected peer \(peerID.displayName) - max peers reached")
                    return
                }
                
                let bitchatPeerID = self.generateBitchatPeerID(for: peerID)
                self.peerIDMapping[bitchatPeerID] = peerID
                
                let peerInfo = PeerInfo(
                    peerID: bitchatPeerID,
                    nickname: nil,
                    publicKey: nil,
                    transportTypes: [.wifiDirect],
                    rssi: nil,
                    lastSeen: Date()
                )
                self.connectedPeers[peerID] = peerInfo
                self.connectionState[peerID] = .connected
                self.reconnectionAttempts.removeValue(forKey: peerID)
                self.updateCurrentPeers()
                
                DispatchQueue.main.async {
                    self.delegate?.transport(self, didDiscoverPeer: peerInfo)
                }
                
                // Retry any pending messages to this peer
                self.retryPendingMessages(for: bitchatPeerID)
                
            case .notConnected:
                print("WiFiDirect: Disconnected from peer \(peerID.displayName)")
                self.connectionState[peerID] = .disconnected
                
                if let peerInfo = self.connectedPeers[peerID] {
                    self.connectedPeers.removeValue(forKey: peerID)
                    self.peerIDMapping.removeValue(forKey: peerInfo.peerID)
                    self.updateCurrentPeers()
                    
                    // Clear any pending acks for this peer
                    self.clearPendingAcks(for: peerInfo.peerID)
                    
                    DispatchQueue.main.async {
                        self.delegate?.transport(self, didLosePeer: peerInfo.peerID)
                    }
                    
                    // Attempt reconnection if this was unexpected
                    self.attemptReconnection(to: peerID)
                }
                
            case .connecting:
                self.connectionState[peerID] = .connecting
                print("WiFiDirect: Connecting to peer \(peerID.displayName)")
                
            @unknown default:
                break
            }
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        print("WiFiDirect: Received \(data.count) bytes from \(peerID.displayName)")
        queue.async {
            do {
                // Check if this is a batch
                if self.isBatchedData(data) {
                    let packets = try self.decodeBatch(data)
                    if let peerInfo = self.connectedPeers[peerID] {
                        for packet in packets {
                            // Check for loops and update routing
                            if self.shouldProcessPacket(packet, from: peerInfo.peerID) {
                                self.updateRoutingInfo(for: packet, from: peerInfo.peerID)
                                
                                // Handle acknowledgments
                                if packet.type == MessageType.deliveryAck.rawValue {
                                    self.handleAcknowledgment(packet, from: peerInfo.peerID)
                                } else {
                                    // Send acknowledgment for regular messages
                                    if packet.type == MessageType.message.rawValue && packet.recipientID != nil {
                                        self.sendAcknowledgment(for: packet, to: peerInfo.peerID)
                                    }
                                    
                                    DispatchQueue.main.async {
                                        self.delegate?.transport(self, didReceivePacket: packet, from: peerInfo.peerID)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    // Single packet
                    let packet = try self.decodePacket(data)
                    if let peerInfo = self.connectedPeers[peerID] {
                        // Check for loops and update routing
                        if self.shouldProcessPacket(packet, from: peerInfo.peerID) {
                            self.updateRoutingInfo(for: packet, from: peerInfo.peerID)
                            
                            // Handle acknowledgments
                            if packet.type == MessageType.deliveryAck.rawValue {
                                self.handleAcknowledgment(packet, from: peerInfo.peerID)
                            } else {
                                // Send acknowledgment for regular messages
                                if packet.type == MessageType.message.rawValue && packet.recipientID != nil {
                                    self.sendAcknowledgment(for: packet, to: peerInfo.peerID)
                                }
                                
                                DispatchQueue.main.async {
                                    self.delegate?.transport(self, didReceivePacket: packet, from: peerInfo.peerID)
                                }
                            }
                        }
                    }
                }
            } catch {
                print("WiFiDirect: Failed to decode data: \(error)")
            }
        }
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Not used for now
    }
    
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        // Not used for now
    }
    
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // Not used for now
    }
    
    private func updateCurrentPeers() {
        currentPeers = Array(connectedPeers.values)
    }
    
    private func retryPendingMessages(for peerID: String) {
        let messagesToRetry = pendingMessages.filter { $0.value.retries < maxRetries }
        
        for (messageID, (packet, retries, timestamp)) in messagesToRetry {
            do {
                try send(packet, to: peerID)
                pendingMessages.removeValue(forKey: messageID)
            } catch {
                pendingMessages[messageID] = (packet, retries + 1, timestamp)
                print("WiFiDirect: Retry \(retries + 1) failed for message \(messageID)")
            }
        }
    }
    
    // MARK: - Timer Management
    
    private func startNonceCleanupTimer() {
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.cleanupExpiredNonces()
        }
        timer.tolerance = 10  // Allow 10 second tolerance for power efficiency
        self.nonceCleanupTimer = timer
    }
    
    private func startMessageExpirationTimer() {
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.cleanupExpiredMessages()
        }
        timer.tolerance = 1  // Allow 1 second tolerance
        self.messageExpirationTimer = timer
    }
    
    private func cleanupExpiredNonces() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            // For now, clear half the nonces when we hit 75% capacity
            // In a production app, you'd track timestamps per nonce
            if self.nonceSeen.count > Int(Double(self.maxNonces) * 0.75) {
                let toRemove = self.nonceSeen.count / 2
                self.nonceSeen = Set(self.nonceSeen.dropFirst(toRemove))
                print("WiFiDirect: Cleaned nonce cache to \(self.nonceSeen.count) entries")
            }
        }
    }
    
    private func cleanupExpiredMessages() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            let now = Date()
            
            // Clean expired pending messages
            let expiredMessages = self.pendingMessages.filter { (_, value) in
                now.timeIntervalSince(value.timestamp) > self.messageTimeout
            }
            
            for (messageID, _) in expiredMessages {
                self.pendingMessages.removeValue(forKey: messageID)
            }
            
            if !expiredMessages.isEmpty {
                print("WiFiDirect: Expired \(expiredMessages.count) pending messages")
            }
            
            // Clean expired cache entries
            let expiredCache = self.messageCache.filter { (_, value) in
                now.timeIntervalSince(value.timestamp) > self.cacheExpiration
            }
            
            for (cacheKey, _) in expiredCache {
                self.messageCache.removeValue(forKey: cacheKey)
            }
            
            // Also clean up old peer data
            if self.peerPublicKeys.count > self.maxPeers {
                // Remove keys for disconnected peers
                let connectedPeerIDs = Set(self.connectedPeers.values.map { $0.peerID })
                self.peerPublicKeys = self.peerPublicKeys.filter { connectedPeerIDs.contains($0.key) }
            }
        }
    }
    
    // MARK: - Batch Encoding/Decoding
    
    private func encodeBatch(_ packets: [BitchatPacket]) throws -> Data {
        var batchData = Data()
        
        // Batch header: magic bytes + count
        batchData.append(contentsOf: [0xBA, 0x7C])  // "BAtCh"
        batchData.append(UInt16(packets.count).bigEndianData)
        
        // Encode each packet
        for packet in packets {
            let packetData = try encodePacketCached(packet)
            batchData.append(UInt32(packetData.count).bigEndianData)
            batchData.append(packetData)
        }
        
        // Compress if beneficial
        if batchData.count > compressionThreshold {
            if let compressed = compress(data: batchData) {
                // Add compression header
                var result = Data([0xC0])  // Compressed flag
                result.append(UInt32(batchData.count).bigEndianData)  // Original size
                result.append(compressed)
                return result
            }
        }
        
        return batchData
    }
    
    private func isBatchedData(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        
        // Check for compression flag
        if data[0] == 0xC0 {
            return true
        }
        
        // Check for batch magic bytes
        return data[0] == 0xBA && data[1] == 0x7C
    }
    
    private func decodeBatch(_ data: Data) throws -> [BitchatPacket] {
        var offset = 0
        var workingData = data
        
        // Check for compression
        if data[0] == 0xC0 {
            offset = 1
            let originalSize = data.subdata(in: offset..<offset+4).uint32BigEndian
            offset += 4
            
            guard let decompressed = decompress(data: data.subdata(in: offset..<data.count),
                                               originalSize: Int(originalSize)) else {
                throw TransportError.invalidData
            }
            workingData = decompressed
            offset = 0
        }
        
        // Check batch header
        guard workingData.count >= 4,
              workingData[offset] == 0xBA,
              workingData[offset + 1] == 0x7C else {
            throw TransportError.invalidData
        }
        offset += 2
        
        let packetCount = workingData.subdata(in: offset..<offset+2).uint16BigEndian
        offset += 2
        
        var packets: [BitchatPacket] = []
        
        for _ in 0..<packetCount {
            guard offset + 4 <= workingData.count else {
                throw TransportError.invalidData
            }
            
            let packetSize = workingData.subdata(in: offset..<offset+4).uint32BigEndian
            offset += 4
            
            guard offset + Int(packetSize) <= workingData.count else {
                throw TransportError.invalidData
            }
            
            let packetData = workingData.subdata(in: offset..<offset+Int(packetSize))
            let packet = try decodePacket(packetData)
            packets.append(packet)
            offset += Int(packetSize)
        }
        
        return packets
    }
    
    // MARK: - Compression Helpers
    
    private func compress(data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        
        return data.withUnsafeBytes { srcBytes in
            guard let srcPtr = srcBytes.bindMemory(to: UInt8.self).baseAddress else { return nil }
            
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            defer { buffer.deallocate() }
            
            let compressedSize = compression_encode_buffer(
                buffer, data.count,
                srcPtr, data.count,
                nil, COMPRESSION_ZLIB
            )
            
            guard compressedSize > 0 && compressedSize < data.count else {
                return nil  // Compression not beneficial
            }
            
            return Data(bytes: buffer, count: compressedSize)
        }
    }
    
    private func decompress(data: Data, originalSize: Int) -> Data? {
        guard !data.isEmpty && originalSize > 0 else { return nil }
        
        return data.withUnsafeBytes { srcBytes in
            guard let srcPtr = srcBytes.bindMemory(to: UInt8.self).baseAddress else { return nil }
            
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: originalSize)
            defer { buffer.deallocate() }
            
            let decompressedSize = compression_decode_buffer(
                buffer, originalSize,
                srcPtr, data.count,
                nil, COMPRESSION_ZLIB
            )
            
            guard decompressedSize == originalSize else {
                return nil
            }
            
            return Data(bytes: buffer, count: decompressedSize)
        }
    }
    
    private func startBatchTimer() {
        let timer = Timer.scheduledTimer(withTimeInterval: batchInterval, repeats: true) { [weak self] _ in
            self?.queue.async(flags: .barrier) {
                self?.processBatch()
            }
        }
        timer.tolerance = 0.02  // 20ms tolerance
        self.batchTimer = timer
    }
    
    // MARK: - Routing and Loop Prevention
    
    private func shouldProcessPacket(_ packet: BitchatPacket, from peerID: String) -> Bool {
        // Create message hash for deduplication
        let messageHash = createMessageHash(packet)
        
        var shouldProcess = false
        queue.sync {
            // Check if we've seen this message before
            if messageHistory.contains(messageHash) {
                // Loop detected - drop the message
                shouldProcess = false
            } else {
                // New message - add to history
                messageHistory.insert(messageHash)
                
                // Enforce history size limit
                if messageHistory.count > maxMessageHistory {
                    // Remove oldest entries (approximation)
                    let toRemove = messageHistory.count / 4
                    messageHistory = Set(messageHistory.dropFirst(toRemove))
                }
                
                shouldProcess = true
            }
        }
        
        // Check TTL
        if packet.ttl == 0 {
            print("WiFiDirect: Dropping packet with TTL=0")
            return false
        }
        
        return shouldProcess
    }
    
    private func createMessageHash(_ packet: BitchatPacket) -> String {
        // Create a unique hash from packet content
        // Include sender, timestamp, and first 16 bytes of payload
        var hashData = Data()
        hashData.append(packet.senderID)
        hashData.append(packet.timestamp.bigEndianData)
        hashData.append(packet.payload.prefix(16))
        
        let hash = SHA256.hash(data: hashData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    private func updateRoutingInfo(for packet: BitchatPacket, from peerID: String) {
        guard let senderIDString = String(data: packet.senderID, encoding: .utf8) else { return }
        
        queue.async(flags: .barrier) {
            // Update routing table with path to sender
            let currentRoute = self.routingTable[senderIDString]
            let newCost = 1  // Direct connection has cost 1
            
            // Update if no route exists or new route is better
            if currentRoute == nil || currentRoute!.cost > newCost {
                self.routingTable[senderIDString] = (nextHop: peerID, cost: newCost, timestamp: Date())
                print("WiFiDirect: Updated route to \(senderIDString) via \(peerID) (cost: \(newCost))")
            }
        }
    }
    
    private func getNextHop(for destination: String) -> String? {
        return queue.sync {
            // Check if we have a route
            if let route = routingTable[destination] {
                // Check if route is still valid
                if Date().timeIntervalSince(route.timestamp) < routingTimeout {
                    return route.nextHop
                } else {
                    // Route expired
                    routingTable.removeValue(forKey: destination)
                }
            }
            return nil
        }
    }
    
    private func startRoutingCleanupTimer() {
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.cleanupRoutingTable()
        }
        timer.tolerance = 10
        self.routingCleanupTimer = timer
    }
    
    private func cleanupRoutingTable() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            let now = Date()
            
            // Remove expired routes
            let expiredRoutes = self.routingTable.filter { (_, route) in
                now.timeIntervalSince(route.timestamp) > self.routingTimeout
            }
            
            for (destination, _) in expiredRoutes {
                self.routingTable.removeValue(forKey: destination)
            }
            
            if !expiredRoutes.isEmpty {
                print("WiFiDirect: Cleaned \(expiredRoutes.count) expired routes")
            }
            
            // Also clean old message history periodically
            if self.messageHistory.count > Int(Double(self.maxMessageHistory) * 0.75) {
                let toRemove = self.messageHistory.count / 3
                self.messageHistory = Set(self.messageHistory.dropFirst(toRemove))
                print("WiFiDirect: Trimmed message history to \(self.messageHistory.count)")
            }
        }
    }
    
    // MARK: - Reliability and Acknowledgments
    
    private func sendAcknowledgment(for packet: BitchatPacket, to peerID: String) {
        // Create acknowledgment packet
        let messageID = "\(packet.timestamp)-\(packet.senderID.prefix(8).hexEncodedString())"
        let ackData = messageID.data(using: .utf8) ?? Data()
        
        let ackPacket = BitchatPacket(
            type: MessageType.deliveryAck.rawValue,
            senderID: getDeviceIdentifier().data(using: .utf8) ?? Data(),
            recipientID: packet.senderID,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: ackData,
            signature: nil,
            ttl: 3  // Low TTL for acks
        )
        
        // Send without batching for immediate delivery
        queue.async {
            if let senderString = String(data: packet.senderID, encoding: .utf8),
               let peer = self.getPeerMCID(for: senderString) {
                do {
                    let data = try self.encodePacketCached(ackPacket)
                    try self.session.send(data, toPeers: [peer], with: .reliable)
                } catch {
                    print("WiFiDirect: Failed to send ack: \(error)")
                }
            }
        }
    }
    
    private func handleAcknowledgment(_ packet: BitchatPacket, from peerID: String) {
        guard let messageID = String(data: packet.payload, encoding: .utf8) else { return }
        
        queue.async(flags: .barrier) {
            if let _ = self.awaitingAcks.removeValue(forKey: messageID) {
                print("WiFiDirect: Received ack for message \(messageID) from \(peerID)")
                
                // Notify delegate of successful delivery
                DispatchQueue.main.async {
                    self.delegate?.transport(self, didReceivePacket: packet, from: peerID)
                }
            }
        }
    }
    
    private func clearPendingAcks(for peerID: String) {
        queue.async(flags: .barrier) {
            // Remove acks waiting for this peer
            let keysToRemove = self.awaitingAcks.compactMap { (key, value) in
                if let recipientID = value.packet.recipientID,
                   let recipientString = String(data: recipientID, encoding: .utf8),
                   recipientString == peerID {
                    return key
                }
                return nil
            }
            
            for key in keysToRemove {
                self.awaitingAcks.removeValue(forKey: key)
            }
        }
    }
    
    private func attemptReconnection(to peerID: MCPeerID) {
        queue.async(flags: .barrier) {
            let attempts = self.reconnectionAttempts[peerID] ?? 0
            
            if attempts < self.maxReconnectionAttempts {
                self.reconnectionAttempts[peerID] = attempts + 1
                
                // Exponential backoff: 2^attempts seconds
                let delay = Double(1 << attempts)
                
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self else { return }
                    
                    // Check if still disconnected
                    if self.connectionState[peerID] == .disconnected {
                        print("WiFiDirect: Attempting reconnection to \(peerID.displayName) (attempt \(attempts + 1))")
                        
                        // Re-invite the peer
                        let ourPubKey = self.signingKey.publicKey.x963Representation
                        let contextData: [String: String] = [
                            "pubkey": ourPubKey.base64EncodedString(),
                            "peerid": self.myConsistentPeerID
                        ]
                        if let jsonData = try? JSONEncoder().encode(contextData) {
                            self.browser?.invitePeer(peerID, to: self.session, withContext: jsonData, timeout: 30)
                        }
                    }
                }
            } else {
                print("WiFiDirect: Max reconnection attempts reached for \(peerID.displayName)")
                self.reconnectionAttempts.removeValue(forKey: peerID)
            }
        }
    }
    
    private func startAckTimer() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkPendingAcks()
        }
        timer.tolerance = 0.2
        self.ackTimer = timer
    }
    
    private func checkPendingAcks() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            let now = Date()
            var timedOut: [(String, (BitchatPacket, Date, Int))] = []
            
            // Find timed out acks
            for (messageID, (packet, timestamp, retries)) in self.awaitingAcks {
                if now.timeIntervalSince(timestamp) > self.ackTimeout {
                    timedOut.append((messageID, (packet, timestamp, retries)))
                }
            }
            
            // Handle timeouts
            for (messageID, (packet, _, retries)) in timedOut {
                if retries < self.maxAckRetries {
                    // Retry
                    self.awaitingAcks[messageID] = (packet, Date(), retries + 1)
                    
                    // Resend the packet
                    if let recipientID = packet.recipientID,
                       let recipientString = String(data: recipientID, encoding: .utf8) {
                        print("WiFiDirect: Retrying message \(messageID) (attempt \(retries + 1))")
                        try? self.send(packet, to: recipientString)
                    }
                } else {
                    // Max retries reached
                    self.awaitingAcks.removeValue(forKey: messageID)
                    
                    if let recipientID = packet.recipientID,
                       let recipientString = String(data: recipientID, encoding: .utf8) {
                        print("WiFiDirect: Message \(messageID) failed after \(self.maxAckRetries) retries")
                        
                        DispatchQueue.main.async {
                            self.delegate?.transport(self, didFailToSend: messageID, to: recipientString, error: TransportError.timeout)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension WiFiDirectTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("WiFiDirect: Received invitation from \(peerID.displayName)")
        
        // Extract and store the inviter's public key from context
        if let contextData = context {
            do {
                // Try to decode as JSON first (new format)
                if let contextDict = try? JSONDecoder().decode([String: String].self, from: contextData),
                   let pubkeyString = contextDict["pubkey"],
                   let pubkeyData = Data(base64Encoded: pubkeyString),
                   let peerConsistentID = contextDict["peerid"] {
                    let publicKey = try P256.Signing.PublicKey(x963Representation: pubkeyData)
                    
                    // Store public key under the peer's consistent ID
                    queue.async(flags: .barrier) {
                        self.peerPublicKeys[peerConsistentID] = publicKey
                        
                        // Also store under MCPeerID-based hash for compatibility
                        let bitchatPeerID = self.generateBitchatPeerID(for: peerID)
                        self.peerPublicKeys[bitchatPeerID] = publicKey
                        
                        // Store under display name prefix
                        if peerID.displayName.hasPrefix("bitchat-") {
                            let deviceIDPrefix = String(peerID.displayName.dropFirst("bitchat-".count))
                            self.peerPublicKeys[deviceIDPrefix] = publicKey
                        }
                        
                        print("WiFiDirect: Stored public key for consistent ID \(peerConsistentID)")
                    }
                } else {
                    // Fall back to old format (raw public key data)
                    let publicKey = try P256.Signing.PublicKey(x963Representation: contextData)
                    let bitchatPeerID = generateBitchatPeerID(for: peerID)
                    
                    // Store public key under multiple IDs to handle lookup issues
                    queue.async(flags: .barrier) {
                        // Store by the MCPeerID-based hash
                        self.peerPublicKeys[bitchatPeerID] = publicKey
                        
                        // Also try to extract and store by the actual device ID if possible
                        // The display name format is "bitchat-XXXXXXXX" where X is first 8 chars of device ID hash
                        if peerID.displayName.hasPrefix("bitchat-") {
                            let deviceIDPrefix = String(peerID.displayName.dropFirst("bitchat-".count))
                            self.peerPublicKeys[deviceIDPrefix] = publicKey
                            print("WiFiDirect: Stored public key for \(bitchatPeerID) and prefix \(deviceIDPrefix)")
                        } else {
                            print("WiFiDirect: Stored public key for \(bitchatPeerID)")
                        }
                    }
                }
                
                // Accept the invitation
                invitationHandler(true, session)
            } catch {
                print("WiFiDirect: Invalid public key from inviter \(peerID.displayName): \(error)")
                invitationHandler(false, nil)
            }
        } else {
            print("WiFiDirect: No public key in invitation from \(peerID.displayName)")
            invitationHandler(false, nil)
        }
    }
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("WiFiDirect: Failed to start advertising: \(error)")
        print("WiFiDirect: Error domain: \((error as NSError).domain)")
        print("WiFiDirect: Error code: \((error as NSError).code)")
        print("WiFiDirect: Error details: \(error.localizedDescription)")
        
        queue.async(flags: .barrier) {
            self.isAvailable = false
            self.isAdvertising = false
        }
        
        // Notify delegate of state change
        delegate?.transport(self, didChangeState: false)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension WiFiDirectTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        print("WiFiDirect: Found peer: \(peerID.displayName)")
        
        // Don't invite ourselves
        guard peerID != self.peerID else { 
            print("WiFiDirect: Ignoring self")
            return 
        }
        
        // Check if already connected
        guard session.connectedPeers.contains(peerID) == false else { return }
        
        // Extract and validate peer's public key
        if let pubkeyString = info?["pubkey"],
           let pubkeyData = Data(base64Encoded: pubkeyString) {
            do {
                let publicKey = try P256.Signing.PublicKey(x963Representation: pubkeyData)
                let bitchatPeerID = generateBitchatPeerID(for: peerID)
                
                queue.async(flags: .barrier) {
                    // Store by the peer's consistent ID if provided
                    if let peerConsistentID = info?["peerid"] {
                        self.peerPublicKeys[peerConsistentID] = publicKey
                        print("WiFiDirect: Stored public key for \(peerConsistentID) from discovery")
                    }
                    
                    // Store by the MCPeerID-based hash
                    self.peerPublicKeys[bitchatPeerID] = publicKey
                    
                    // Also store by device ID prefix for easier lookup
                    if peerID.displayName.hasPrefix("bitchat-") {
                        let deviceIDPrefix = String(peerID.displayName.dropFirst("bitchat-".count))
                        self.peerPublicKeys[deviceIDPrefix] = publicKey
                    }
                }
                
                // Include our public key and peer ID in invitation context
                let ourPubKey = signingKey.publicKey.x963Representation
                let contextData: [String: String] = [
                    "pubkey": ourPubKey.base64EncodedString(),
                    "peerid": myConsistentPeerID
                ]
                let jsonData = try JSONEncoder().encode(contextData)
                
                // Invite the peer to join our session
                print("WiFiDirect: Inviting peer \(peerID.displayName) to join session")
                browser.invitePeer(peerID, to: session, withContext: jsonData, timeout: 30)
            } catch {
                // Invalid public key - don't connect
                print("WiFiDirect: Invalid public key from peer \(peerID.displayName)")
            }
        } else {
            // No public key - don't connect to unsigned peers
            print("WiFiDirect: No public key from peer \(peerID.displayName)")
        }
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // Peer is no longer available
        // The session delegate will handle the disconnection
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("WiFiDirect: Failed to start browsing: \(error)")
        print("WiFiDirect: Error domain: \((error as NSError).domain)")
        print("WiFiDirect: Error code: \((error as NSError).code)")
        print("WiFiDirect: Error details: \(error.localizedDescription)")
        
        // NSNetServicesErrorDomain -72008 means the service couldn't be resolved
        // This usually happens when:
        // 1. Service type is invalid
        // 2. Local network permission not granted
        // 3. Network is unavailable
        
        queue.async(flags: .barrier) {
            self.isAvailable = false
            self.isBrowsing = false
        }
        
        // Notify delegate of state change
        delegate?.transport(self, didChangeState: false)
    }
}

// MARK: - Data Extensions for Encoding

extension UInt16 {
    var bigEndianData: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: 2)
    }
}

extension UInt32 {
    var bigEndianData: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: 4)
    }
}

extension UInt64 {
    var bigEndianData: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: 8)
    }
}

extension Data {
    var uint16BigEndian: UInt16 {
        guard self.count >= 2 else { return 0 }
        return self.withUnsafeBytes { bytes in
            return bytes.bindMemory(to: UInt16.self).first?.bigEndian ?? 0
        }
    }
    
    var uint32BigEndian: UInt32 {
        guard self.count >= 4 else { return 0 }
        return self.withUnsafeBytes { bytes in
            return bytes.bindMemory(to: UInt32.self).first?.bigEndian ?? 0
        }
    }
    
    var uint64BigEndian: UInt64 {
        guard self.count >= 8 else { return 0 }
        return self.withUnsafeBytes { bytes in
            return bytes.bindMemory(to: UInt64.self).first?.bigEndian ?? 0
        }
    }
}