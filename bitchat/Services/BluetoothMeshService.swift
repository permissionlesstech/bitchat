import Foundation
import CoreBluetooth
import Combine
#if os(macOS)
import AppKit
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
    
    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    private var discoveredPeripherals: [CBPeripheral] = []
    private var connectedPeripherals: [String: CBPeripheral] = [:]
    private var peripheralCharacteristics: [CBPeripheral: CBCharacteristic] = [:]
    private var characteristic: CBMutableCharacteristic!
    private var subscribedCentrals: [CBCentral] = []
    private var peerNicknames: [String: String] = [:]
    private var activePeers: Set<String> = []  // Track all active peers
    private var peerRSSI: [String: NSNumber] = [:] // Track RSSI values for peers
    private var peripheralRSSI: [String: NSNumber] = [:] // Track RSSI by peripheral ID during discovery
    
    weak var delegate: BitchatDelegate?
    private let encryptionService = EncryptionService()
    private let messageQueue = DispatchQueue(label: "bitchat.messageQueue", attributes: .concurrent)
    private var processedMessages = Set<String>()
    private let maxTTL: UInt8 = 5
    private var announcedToPeers = Set<String>()  // Track which peers we've announced to
    private var announcedPeers = Set<String>()  // Track peers who have already been announced
    
    // Fragment handling
    private var incomingFragments: [String: [Int: Data]] = [:]  // fragmentID -> [index: data]
    private var fragmentMetadata: [String: (originalType: UInt8, totalFragments: Int, timestamp: Date)] = [:]
    private let maxFragmentSize = 200  // Smaller fragments for better reliability
    
    let myPeerID: String
    
    override init() {
        self.myPeerID = UUID().uuidString.prefix(8).lowercased()
        super.init()
        print("[STARTUP] My Bluetooth ID (myPeerID): \(myPeerID)")
        
        centralManager = CBCentralManager(delegate: self, queue: nil)
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        
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
            centralManager.cancelPeripheralConnection(peripheral)
        }
        
        // Stop advertising
        if peripheralManager.isAdvertising {
            peripheralManager.stopAdvertising()
        }
        
        // Stop scanning
        centralManager.stopScan()
        
        // Remove all services - this will disconnect any connected centrals
        if peripheralManager.state == .poweredOn {
            peripheralManager.removeAllServices()
        }
        
        // Clear all tracking
        connectedPeripherals.removeAll()
        subscribedCentrals.removeAll()
        activePeers.removeAll()
        announcedPeers.removeAll()
        
        // Clear announcement tracking
        announcedToPeers.removeAll()
    }
    
    func startServices() {
        // Start both central and peripheral services
        if centralManager.state == .poweredOn {
            startScanning()
        }
        if peripheralManager.state == .poweredOn {
            setupPeripheral()
            startAdvertising()
        }
        
        // Don't send announcement here - wait for connections
    }
    
    func startAdvertising() {
        guard peripheralManager.state == .poweredOn else { 
            return 
        }
        
        let advertisementData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [BluetoothMeshService.serviceUUID],
            CBAdvertisementDataLocalNameKey: "bitchat-\(myPeerID)"
        ]
        print("[BLUETOOTH] Starting to advertise as: bitchat-\(myPeerID)")
        peripheralManager.startAdvertising(advertisementData)
    }
    
    func startScanning() {
        guard centralManager.state == .poweredOn else { 
            return 
        }
        centralManager.scanForPeripherals(withServices: [BluetoothMeshService.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
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
        
        peripheralManager.add(service)
        self.characteristic = characteristic
    }
    
    func sendMessage(_ content: String, mentions: [String] = [], to recipientID: String? = nil) {
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            let nickname = self.delegate as? ChatViewModel
            let senderNick = nickname?.nickname ?? self.myPeerID
            
            let message = BitchatMessage(
                sender: senderNick,
                content: content,
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                mentions: mentions.isEmpty ? nil : mentions
            )
            
            if let messageData = message.toBinaryPayload() {
                let packet = BitchatPacket(
                    type: MessageType.message.rawValue,
                    ttl: self.maxTTL,
                    senderID: self.myPeerID,
                    payload: messageData
                )
                
                self.broadcastPacket(packet)
            }
        }
    }
    
    func sendVoiceNote(_ audioData: Data, duration: TimeInterval) {
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            print("[VOICE] Sending voice note: audio size = \(audioData.count) bytes, duration = \(duration)s")
            
            let nickname = self.delegate as? ChatViewModel
            let senderNick = nickname?.nickname ?? self.myPeerID
            
            let message = BitchatMessage(
                sender: senderNick,
                content: "🎤 \(String(format: "%.1f", duration))s",
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                voiceNoteData: audioData,
                voiceNoteDuration: duration
            )
            
            if let messageData = message.toBinaryPayload() {
                print("[VOICE] Message payload size: \(messageData.count) bytes")
                let packet = BitchatPacket(
                    type: MessageType.voiceNote.rawValue,
                    ttl: self.maxTTL,
                    senderID: self.myPeerID,
                    payload: messageData
                )
                
                if let packetData = packet.toBinaryData() {
                    print("[VOICE] Final packet size: \(packetData.count) bytes")
                    // Check if packet exceeds safe BLE size (leave margin for overhead)
                    if packetData.count > 400 {
                        print("[VOICE] Packet size \(packetData.count) exceeds safe BLE limit")
                        print("[VOICE] Fragmenting voice note into smaller packets...")
                        self.sendFragmentedPacket(packet)
                    } else {
                        print("[VOICE] Sending voice note as single packet")
                        self.broadcastPacket(packet)
                    }
                } else {
                    print("[VOICE] ERROR: Failed to convert packet to binary data")
                }
            }
        }
    }
    
    func sendPrivateMessage(_ content: String, to recipientPeerID: String, recipientNickname: String) {
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            let nickname = self.delegate as? ChatViewModel
            let senderNick = nickname?.nickname ?? self.myPeerID
            
            let message = BitchatMessage(
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
                // Create packet with recipient ID for proper routing
                let packet = BitchatPacket(
                    type: MessageType.privateMessage.rawValue,
                    senderID: Data(self.myPeerID.utf8),
                    recipientID: Data(recipientPeerID.utf8),
                    timestamp: UInt64(Date().timeIntervalSince1970),
                    payload: messageData,
                    signature: nil,
                    ttl: self.maxTTL
                )
                
                print("[PRIVATE] Sending private message to \(recipientPeerID)")
                self.broadcastPacket(packet)
                
                // Don't call didReceiveMessage here - let the view model handle it directly
            }
        }
    }
    
    private func sendAnnouncementToPeer(_ peerID: String) {
        guard let vm = delegate as? ChatViewModel else { return }
        
        print("[ANNOUNCE] Sending announce to \(peerID) with nickname: \(vm.nickname)")
        
        // Always send announce, don't check if already announced
        // This ensures peers get our nickname even if they reconnect
        
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            ttl: 1,
            senderID: myPeerID,
            payload: Data(vm.nickname.utf8)
        )
        
        if let data = packet.toBinaryData() {
            print("[ANNOUNCE] Broadcasting announce packet")
            // Try both broadcast and targeted send
            broadcastPacket(packet)
            
            // Also try targeted send if we have the peripheral
            if let peripheral = connectedPeripherals[peerID],
               let characteristic = peripheral.services?.first(where: { $0.uuid == BluetoothMeshService.serviceUUID })?.characteristics?.first(where: { $0.uuid == BluetoothMeshService.characteristicUUID }) {
                print("[ANNOUNCE] Also sending targeted announce to peripheral \(peerID)")
                peripheral.writeValue(data, for: characteristic, type: .withResponse)
            } else {
                print("[ANNOUNCE] No peripheral found for targeted send to \(peerID)")
            }
        } else {
            print("[ANNOUNCE] Failed to create binary data for announce packet")
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
        return peerNicknames
    }
    
    func getPeerRSSI() -> [String: NSNumber] {
        return peerRSSI
    }
    
    private func getAllConnectedPeerIDs() -> [String] {
        // Return all active peers, even if they haven't announced yet
        let uniquePeers = Set(activePeers.filter { peerID in
            peerID != "unknown" && peerID != myPeerID && peerID.count <= 8  // Filter out temp IDs
        })
        print("[DEBUG] Active peers: \(activePeers), myPeerID: \(myPeerID), filtered: \(uniquePeers)")
        return Array(uniquePeers).sorted()
    }
    
    private func broadcastPacket(_ packet: BitchatPacket) {
        guard let data = packet.toBinaryData() else { 
            print("[ERROR] Failed to convert packet to binary data")
            return 
        }
        
        
        print("[BROADCAST] Broadcasting packet type: \(packet.type), data size: \(data.count)")
        
        // Send to connected peripherals (as central)
        var sentToPeripherals = 0
        for (peerID, peripheral) in connectedPeripherals {
            if let characteristic = peripheralCharacteristics[peripheral] {
                // Check if peripheral is connected before writing
                if peripheral.state == .connected {
                    // Always use withResponse for reliability, especially for background
                    peripheral.writeValue(data, for: characteristic, type: .withResponse)
                    sentToPeripherals += 1
                } else {
                    print("[BROADCAST] Peripheral \(peerID) not connected (state: \(peripheral.state.rawValue))")
                }
            } else {
                print("[BROADCAST] No characteristic found for peripheral \(peerID)")
            }
        }
        print("[BROADCAST] Sent to \(sentToPeripherals) connected peripherals")
        
        // Send to subscribed centrals (as peripheral)
        if characteristic != nil && !subscribedCentrals.isEmpty {
            let success = peripheralManager.updateValue(data, for: characteristic, onSubscribedCentrals: subscribedCentrals)
            if success {
                print("[BROADCAST] Successfully sent to \(subscribedCentrals.count) subscribed centrals")
            } else {
                print("[BROADCAST] Failed to send to centrals - queue full, will retry on delegate callback")
            }
        } else {
            if characteristic == nil {
                print("[BROADCAST] No characteristic available")
            }
            if subscribedCentrals.isEmpty {
                print("[BROADCAST] No subscribed centrals")
            }
        }
    }
    
    private func handleReceivedPacket(_ packet: BitchatPacket, from peerID: String, peripheral: CBPeripheral? = nil) {
        messageQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            guard packet.ttl > 0 else { 
                print("[PACKET] Dropping packet with TTL 0")
                return 
            }
            
            // Validate packet has payload
            guard !packet.payload.isEmpty else {
                print("[PACKET] Dropping packet with empty payload")
                return
            }
        
        let messageID = "\(packet.timestamp)-\(String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) ?? "")"
        guard !processedMessages.contains(messageID) else { 
            return 
        }
        processedMessages.insert(messageID)
        
        if processedMessages.count > 1000 {
            processedMessages.removeAll()
        }
        
        let _ = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) ?? "unknown"
        
        print("[PACKET] Received packet type: \(packet.type) from peerID: \(peerID)")
        
        // Note: We'll decode messages in the switch statement below, not here
        
        switch MessageType(rawValue: packet.type) {
        case .message:
            if let message = BitchatMessage.fromBinaryPayload(packet.payload) {
                // Ignore our own messages
                if let senderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8), senderID == myPeerID {
                    return
                }
                
                // Store nickname mapping
                if let senderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) {
                    peerNicknames[senderID] = message.sender
                }
                
                DispatchQueue.main.async {
                    self.delegate?.didReceiveMessage(message)
                }
                
                var relayPacket = packet
                relayPacket.ttl -= 1
                if relayPacket.ttl > 0 {
                    self.broadcastPacket(relayPacket)
                }
            }
            
        case .keyExchange:
            // Use senderID from packet for consistency
            if let senderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) {
                if packet.payload.count > 0 {
                    let publicKeyData = packet.payload
                    try? encryptionService.addPeerPublicKey(senderID, publicKeyData: publicKeyData)
                    
                    // Track this peer temporarily
                    if senderID != "unknown" && senderID != myPeerID {
                        // Check if we need to update peripheral mapping from the specific peripheral that sent this
                        if let peripheral = peripheral {
                            // Find if this peripheral is currently mapped with a temp ID
                            if let tempID = self.connectedPeripherals.first(where: { $0.value == peripheral })?.key,
                               tempID.count > 8 { // It's a temp ID
                                // Remove temp mapping and add real peer ID mapping
                                self.connectedPeripherals.removeValue(forKey: tempID)
                                self.connectedPeripherals[senderID] = peripheral
                                print("[KEY_EXCHANGE] Updated peripheral mapping from temp ID \(tempID) to \(senderID)")
                                
                                // Transfer RSSI from temp ID to peer ID
                                if let rssi = self.peripheralRSSI[tempID] {
                                    self.peerRSSI[senderID] = rssi
                                    self.peripheralRSSI.removeValue(forKey: tempID)
                                    print("[KEY_EXCHANGE] Transferred RSSI \(rssi) to peer \(senderID)")
                                }
                            }
                        }
                        
                        // Add to active peers immediately on key exchange
                        activePeers.insert(senderID)
                        let connectedPeerIDs = self.getAllConnectedPeerIDs()
                        DispatchQueue.main.async {
                            self.delegate?.didUpdatePeerList(connectedPeerIDs)
                        }
                    }
                    
                    // Send announce with our nickname immediately
                    print("[KEY_EXCHANGE] Calling sendAnnouncementToPeer for \(senderID)")
                    self.sendAnnouncementToPeer(senderID)
                }
            }
            
        case .announce:
            print("[ANNOUNCE] Processing announce packet, payload size: \(packet.payload.count)")
            if let nickname = String(data: packet.payload, encoding: .utf8), 
               let senderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) {
                print("[DEBUG] Received announce from \(senderID): \(nickname), myPeerID: \(myPeerID)")
                
                // Ignore if it's from ourselves
                if senderID == myPeerID {
                    return
                }
                
                // Check if we've already announced this peer
                let isFirstAnnounce = !announcedPeers.contains(senderID)
                
                // Store the nickname
                peerNicknames[senderID] = nickname
                print("[ANNOUNCE] Stored nickname for \(senderID): \(nickname)")
                print("[ANNOUNCE] Current nicknames: \(peerNicknames)")
                
                // Note: We can't update peripheral mapping here since we don't have 
                // access to which peripheral sent this announce. The mapping will be
                // updated when we receive key exchange packets where we do have the peripheral.
                
                // Add to active peers if not already there
                if senderID != "unknown" {
                    if !activePeers.contains(senderID) {
                        activePeers.insert(senderID)
                    }
                    
                    // Show join message only for first announce
                    if isFirstAnnounce {
                        announcedPeers.insert(senderID)
                        DispatchQueue.main.async {
                            self.delegate?.didConnectToPeer(nickname)
                            self.delegate?.didUpdatePeerList(self.getAllConnectedPeerIDs())
                        }
                    } else {
                        // Just update the peer list
                        DispatchQueue.main.async {
                            self.delegate?.didUpdatePeerList(self.getAllConnectedPeerIDs())
                        }
                    }
                } else {
                }
            } else {
                print("[ANNOUNCE] Failed to decode announce packet - senderID or nickname invalid")
            }
            
        case .leave:
            if let nickname = String(data: packet.payload, encoding: .utf8),
               let senderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) {
                
                // Remove from active peers
                activePeers.remove(senderID)
                announcedPeers.remove(senderID)
                
                // Show leave message
                DispatchQueue.main.async {
                    self.delegate?.didDisconnectFromPeer(nickname)
                    self.delegate?.didUpdatePeerList(self.getAllConnectedPeerIDs())
                }
                
                // Clean up peer data
                peerNicknames.removeValue(forKey: senderID)
            }
            
        case .privateMessage:
            print("[PRIVATE] Received private message packet")
            if let message = BitchatMessage.fromBinaryPayload(packet.payload) {
                // Check if this private message is for us
                if let recipientID = packet.recipientID,
                   let recipientIDString = String(data: recipientID.trimmingNullBytes(), encoding: .utf8) {
                    print("[PRIVATE] Message recipient: \(recipientIDString), myPeerID: \(myPeerID)")
                    
                    if recipientIDString == myPeerID {
                        // Get sender ID
                        if let senderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) {
                            // Ignore our own messages
                            if senderID == myPeerID {
                                print("[PRIVATE] Ignoring own message")
                                return
                            }
                            
                            print("[PRIVATE] Received private message from \(senderID): \(message.content)")
                            
                            // Store nickname mapping if we don't have it
                            if peerNicknames[senderID] == nil {
                                peerNicknames[senderID] = message.sender
                                
                                // Update peer list to show the new nickname
                                DispatchQueue.main.async {
                                    self.delegate?.didUpdatePeerList(self.getAllConnectedPeerIDs())
                                }
                            }
                            
                            
                            // Create a new message with the sender peer ID
                            let messageWithPeerID = BitchatMessage(
                                sender: message.sender,
                                content: message.content,
                                timestamp: message.timestamp,
                                isRelay: message.isRelay,
                                originalSender: message.originalSender,
                                isPrivate: message.isPrivate,
                                recipientNickname: message.recipientNickname,
                                senderPeerID: senderID
                            )
                            
                            DispatchQueue.main.async {
                                self.delegate?.didReceiveMessage(messageWithPeerID)
                            }
                        }
                    } else if packet.ttl > 0 {
                        // Relay private messages that aren't for us
                        print("[PRIVATE] Relaying message not meant for us (TTL: \(packet.ttl))")
                        var relayPacket = packet
                        relayPacket.ttl -= 1
                        self.broadcastPacket(relayPacket)
                    }
                } else {
                    print("[PRIVATE] No recipient ID in packet")
                }
            } else {
                print("[PRIVATE] Failed to decode message from payload")
            }
            
        case .voiceNote:
            if let message = BitchatMessage.fromBinaryPayload(packet.payload) {
                // Ignore our own messages
                if let senderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8), senderID == myPeerID {
                    return
                }
                
                // Store nickname mapping
                if let senderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) {
                    peerNicknames[senderID] = message.sender
                }
                
                DispatchQueue.main.async {
                    self.delegate?.didReceiveMessage(message)
                }
                
                var relayPacket = packet
                relayPacket.ttl -= 1
                if relayPacket.ttl > 0 {
                    self.broadcastPacket(relayPacket)
                }
            }
            
        case .fragmentStart, .fragmentContinue, .fragmentEnd:
            let fragmentTypeStr = packet.type == 10 ? "START" : (packet.type == 11 ? "CONTINUE" : "END")
            print("[PACKET] Handling fragment type: \(fragmentTypeStr) (\(packet.type)), payload size: \(packet.payload.count), from: \(peerID)")
            
            // Validate fragment has minimum required size
            if packet.payload.count < 13 {
                print("[PACKET] Fragment payload too small: \(packet.payload.count) bytes, dropping")
                return
            }
            
            handleFragment(packet, from: peerID)
            
            // Relay fragments if TTL > 0
            var relayPacket = packet
            relayPacket.ttl -= 1
            if relayPacket.ttl > 0 {
                print("[PACKET] Relaying fragment with TTL: \(relayPacket.ttl)")
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
        
        print("[FRAGMENT] Splitting into \(fragments.count) fragments of max \(maxFragmentSize) bytes")
        print("[FRAGMENT] Fragment ID: \(fragmentID.hexEncodedString())")
        print("[FRAGMENT] Original packet size: \(fullData.count) bytes")
        
        // Send fragments with delays to avoid congestion
        let delayBetweenFragments: TimeInterval = 0.1  // 100ms between fragments
        
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
                print("[FRAGMENT] Sent fragment \(index + 1)/\(fragments.count) type: \(fragmentType) at +\(totalDelay)s")
            }
        }
        
        let totalTime = Double(fragments.count - 1) * delayBetweenFragments
        print("[FRAGMENT] Total send time: \(totalTime)s for \(fragments.count) fragments")
    }
    
    private func handleFragment(_ packet: BitchatPacket, from peerID: String) {
        print("[FRAGMENT] Starting to handle fragment, payload size: \(packet.payload.count)")
        
        guard packet.payload.count >= 13 else { 
            print("[FRAGMENT] Payload too small: \(packet.payload.count) bytes (need at least 13)")
            return 
        }
        
        // Convert to array for safer access
        let payloadArray = Array(packet.payload)
        var offset = 0
        
        // Extract fragment ID as binary data (8 bytes)
        guard payloadArray.count >= 8 else {
            print("[FRAGMENT] Payload too small for fragment ID")
            return
        }
        
        let fragmentIDData = Data(payloadArray[0..<8])
        let fragmentID = fragmentIDData.hexEncodedString()
        print("[FRAGMENT] Fragment ID: \(fragmentID)")
        offset = 8
        
        // Safely extract index
        guard payloadArray.count >= offset + 2 else { 
            print("[FRAGMENT] Not enough data for index at offset \(offset)")
            return 
        }
        let index = Int(payloadArray[offset]) << 8 | Int(payloadArray[offset + 1])
        offset += 2
        print("[FRAGMENT] Index: \(index)")
        
        // Safely extract total
        guard payloadArray.count >= offset + 2 else { 
            print("[FRAGMENT] Not enough data for total at offset \(offset)")
            return 
        }
        let total = Int(payloadArray[offset]) << 8 | Int(payloadArray[offset + 1])
        offset += 2
        print("[FRAGMENT] Total fragments: \(total)")
        
        // Safely extract original type
        guard payloadArray.count >= offset + 1 else { 
            print("[FRAGMENT] Not enough data for type at offset \(offset)")
            return 
        }
        let originalType = payloadArray[offset]
        offset += 1
        print("[FRAGMENT] Original type: \(originalType)")
        
        // Extract fragment data
        let fragmentData: Data
        if payloadArray.count > offset {
            fragmentData = Data(payloadArray[offset...])
        } else {
            fragmentData = Data()
        }
        
        print("[FRAGMENT] Received fragment \(index + 1)/\(total) for ID: \(fragmentID), data size: \(fragmentData.count)")
        
        // Initialize fragment collection if needed
        if incomingFragments[fragmentID] == nil {
            incomingFragments[fragmentID] = [:]
            fragmentMetadata[fragmentID] = (originalType, total, Date())
            print("[FRAGMENT] Started collecting fragments for ID: \(fragmentID), expecting \(total) fragments")
        }
        
        // Store fragment
        incomingFragments[fragmentID]?[index] = fragmentData
        
        print("[FRAGMENT] Progress for ID \(fragmentID): \(incomingFragments[fragmentID]?.count ?? 0)/\(total) fragments collected")
        
        // Check if we have all fragments
        if let fragments = incomingFragments[fragmentID],
           fragments.count == total {
            
            // Reassemble the original packet
            var reassembledData = Data()
            for i in 0..<total {
                if let fragment = fragments[i] {
                    reassembledData.append(fragment)
                } else {
                    print("[FRAGMENT] Missing fragment \(i) for ID: \(fragmentID)")
                    return
                }
            }
            
            print("[FRAGMENT] Successfully reassembled \(total) fragments into \(reassembledData.count) bytes")
            
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
                print("[FRAGMENT] Cleaned up expired fragments for ID: \(fragID)")
            }
        }
    }
}

extension BluetoothMeshService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScanning()
            
            // Scanning will connect to peers and announce then
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        
        // Store RSSI by peripheral ID for later use
        peripheralRSSI[peripheral.identifier.uuidString] = RSSI
        
        // Extract peer ID and store RSSI
        if let name = peripheral.name, name.hasPrefix("bitchat-") {
            let peerID = String(name.dropFirst(8))
            peerRSSI[peerID] = RSSI
            print("[BLUETOOTH] Discovered peer: \(peerID) with RSSI: \(RSSI), my ID: \(myPeerID)")
        }
        
        // Connect to any device we discover - we'll filter by service later
        if !discoveredPeripherals.contains(peripheral) {
            discoveredPeripherals.append(peripheral)
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([BluetoothMeshService.serviceUUID])
        
        // Store peripheral by its system ID temporarily until we get the real peer ID
        let tempID = peripheral.identifier.uuidString
        connectedPeripherals[tempID] = peripheral
        
        print("[BLUETOOTH] Connected to peripheral (temp ID: \(tempID)), waiting for real peer ID...")
        
        // Request RSSI reading
        peripheral.readRSSI()
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        
        if let peerID = connectedPeripherals.first(where: { $0.value == peripheral })?.key {
            connectedPeripherals.removeValue(forKey: peerID)
            peripheralCharacteristics.removeValue(forKey: peripheral)
            
            // Remove from active peers
            activePeers.remove(peerID)
            announcedPeers.remove(peerID)
            announcedToPeers.remove(peerID)
            
            // Only show disconnect if we have a resolved nickname
            if let nickname = peerNicknames[peerID], nickname != peerID {
                DispatchQueue.main.async {
                    self.delegate?.didDisconnectFromPeer(nickname)
                    self.delegate?.didUpdatePeerList(self.getAllConnectedPeerIDs())
                }
            } else {
                DispatchQueue.main.async {
                    self.delegate?.didUpdatePeerList(self.getAllConnectedPeerIDs())
                }
            }
        }
        
        // Remove from discovered list to allow reconnection
        discoveredPeripherals.removeAll { $0 == peripheral }
        
        // Continue scanning for reconnection
        if centralManager.state == .poweredOn {
            // Stop and restart to ensure clean state
            centralManager.stopScan()
            centralManager.scanForPeripherals(withServices: [BluetoothMeshService.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
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
                
                // Send key exchange and announce immediately without any delay
                let publicKeyData = self.encryptionService.publicKey.rawRepresentation
                let packet = BitchatPacket(
                    type: MessageType.keyExchange.rawValue,
                    ttl: 1,
                    senderID: self.myPeerID,
                    payload: publicKeyData
                )
                
                if let data = packet.toBinaryData() {
                    peripheral.writeValue(data, for: characteristic, type: .withResponse)
                    print("[KEY_EXCHANGE] Sent key exchange to peripheral as central")
                }
                
                // Send announce packet immediately after key exchange
                // Send both broadcast and targeted announce for reliability
                if let vm = self.delegate as? ChatViewModel {
                    // First, send broadcast announce
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self = self else { return }
                        let announcePacket = BitchatPacket(
                            type: MessageType.announce.rawValue,
                            ttl: 1,
                            senderID: self.myPeerID,
                            payload: Data(vm.nickname.utf8)
                        )
                        self.broadcastPacket(announcePacket)
                    }
                    
                    // Also send targeted announce to this specific peripheral
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak peripheral] in
                        guard let self = self,
                              let peripheral = peripheral,
                              let characteristic = peripheral.services?.first(where: { $0.uuid == BluetoothMeshService.serviceUUID })?.characteristics?.first(where: { $0.uuid == BluetoothMeshService.characteristicUUID }) else { return }
                        
                        let announcePacket = BitchatPacket(
                            type: MessageType.announce.rawValue,
                            ttl: 1,
                            senderID: self.myPeerID,
                            payload: Data(vm.nickname.utf8)
                        )
                        if let data = announcePacket.toBinaryData() {
                            peripheral.writeValue(data, for: characteristic, type: .withResponse)
                            print("[KEY_EXCHANGE] Sent targeted announce to peripheral")
                        }
                    }
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else {
            print("[PERIPHERAL] No data in characteristic")
            return
        }
        
        guard let packet = BitchatPacket.from(data) else { 
            print("[PERIPHERAL] Failed to parse packet from data of size: \(data.count)")
            return 
        }
        
        // Use the sender ID from the packet, not our local mapping which might still be a temp ID
        let localPeerID = connectedPeripherals.first(where: { $0.value == peripheral })?.key ?? "unknown"
        let packetSenderID = String(data: packet.senderID.trimmingNullBytes(), encoding: .utf8) ?? "unknown"
        print("[PERIPHERAL] Received data from localPeerID: \(localPeerID), packetSenderID: \(packetSenderID), packet type: \(packet.type)")
        
        // Handle fragments directly if it's a fragment type
        if packet.type == MessageType.fragmentStart.rawValue || 
           packet.type == MessageType.fragmentContinue.rawValue || 
           packet.type == MessageType.fragmentEnd.rawValue {
            print("[PERIPHERAL] Processing fragment directly")
        }
        
        handleReceivedPacket(packet, from: packetSenderID, peripheral: peripheral)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("[PERIPHERAL] Write failed: \(error)")
        } else {
            print("[PERIPHERAL] Write completed successfully")
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
                    self.delegate?.didUpdatePeerList(self.getAllConnectedPeerIDs())
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
        switch peripheral.state {
        case .poweredOn:
            setupPeripheral()
            startAdvertising()
            
            // Scanning will connect to peers and announce then
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
                
                print("[PERIPHERAL_MANAGER] Received write from peer: \(peerID), packet type: \(packet.type)")
                
                // Store the central for updates
                if !subscribedCentrals.contains(request.central) {
                    subscribedCentrals.append(request.central)
                }
                
                // Track this peer as connected
                if peerID != "unknown" && peerID != myPeerID {
                    // Send key exchange back if we haven't already
                    if packet.type == MessageType.keyExchange.rawValue {
                        let publicKeyData = self.encryptionService.publicKey.rawRepresentation
                        let responsePacket = BitchatPacket(
                            type: MessageType.keyExchange.rawValue,
                            ttl: 1,
                            senderID: self.myPeerID,
                            payload: publicKeyData
                        )
                        if let data = responsePacket.toBinaryData() {
                            peripheral.updateValue(data, for: self.characteristic, onSubscribedCentrals: [request.central])
                            print("[KEY_EXCHANGE] Sent key exchange response as peripheral")
                        }
                        
                        // Send announce immediately after key exchange
                        // Broadcast announce to ensure all peers get it
                        if let vm = self.delegate as? ChatViewModel {
                            DispatchQueue.main.async { [weak self] in
                                guard let self = self else { return }
                                let announcePacket = BitchatPacket(
                                    type: MessageType.announce.rawValue,
                                    ttl: 1,
                                    senderID: self.myPeerID,
                                    payload: Data(vm.nickname.utf8)
                                )
                                if let data = announcePacket.toBinaryData() {
                                    peripheral.updateValue(data, for: self.characteristic, onSubscribedCentrals: nil)
                                    print("[ANNOUNCE] Sent broadcast announce as peripheral")
                                }
                            }
                        }
                    }
                    
                    DispatchQueue.main.async {
                        self.delegate?.didUpdatePeerList(self.getAllConnectedPeerIDs())
                    }
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
            let publicKeyData = encryptionService.publicKey.rawRepresentation
            let keyPacket = BitchatPacket(
                type: MessageType.keyExchange.rawValue,
                ttl: 1,
                senderID: myPeerID,
                payload: publicKeyData
            )
            
            if let data = keyPacket.toBinaryData() {
                peripheral.updateValue(data, for: self.characteristic, onSubscribedCentrals: [central])
                print("[KEY_EXCHANGE] Sent initial key exchange as peripheral to new subscriber")
                
                // We'll send announce when we receive their key exchange
            }
            
            // Update peer list to show we're connected (even without peer ID yet)
            DispatchQueue.main.async {
                self.delegate?.didUpdatePeerList(self.getAllConnectedPeerIDs())
            }
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeAll { $0 == central }
        
        // If no more centrals are subscribed, clear all central-connected peers
        if subscribedCentrals.isEmpty {
            // Find and remove peers that were connected as centrals only
            let peersToRemove = activePeers.filter { peerID in
                !connectedPeripherals.keys.contains(peerID)
            }
            
            for peerID in peersToRemove {
                activePeers.remove(peerID)
                announcedToPeers.remove(peerID)
                if let nickname = peerNicknames[peerID] {
                    DispatchQueue.main.async {
                        self.delegate?.didDisconnectFromPeer(nickname)
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.delegate?.didUpdatePeerList(self.getAllConnectedPeerIDs())
            }
        }
        
        // Ensure advertising continues for reconnection
        if peripheralManager.state == .poweredOn && !peripheralManager.isAdvertising {
            startAdvertising()
        }
    }
}