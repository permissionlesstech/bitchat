import Foundation
import CoreBluetooth
import Combine
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    
    weak var delegate: BitchatDelegate?
    private let encryptionService = EncryptionService()
    private let messageQueue = DispatchQueue(label: "bitchat.messageQueue", attributes: .concurrent)
    private var processedMessages = Set<String>()
    private let maxTTL: UInt8 = 5
    private var hasAnnounced = false
    private var announcementTimer: Timer?
    private var announcedPeers = Set<String>()  // Track peers who have already been announced
    
    let myPeerID: String
    
    override init() {
        self.myPeerID = UUID().uuidString.prefix(8).lowercased()
        super.init()
        
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
        print("[DEBUG] Cleaning up Bluetooth connections...")
        
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
        
        // Cancel announcement timer
        announcementTimer?.invalidate()
        announcementTimer = nil
    }
    
    func startServices() {
        print("[DEBUG] Starting services...")
        print("[DEBUG] Central state: \(centralManager.state.rawValue)")
        print("[DEBUG] Peripheral state: \(peripheralManager.state.rawValue)")
        
        // Start both central and peripheral services
        if centralManager.state == .poweredOn {
            startScanning()
        }
        if peripheralManager.state == .poweredOn {
            setupPeripheral()
            startAdvertising()
        }
        
        // Send initial announcement immediately if we have peers
        if !connectedPeripherals.isEmpty || !subscribedCentrals.isEmpty {
            sendInitialAnnouncement()
        }
    }
    
    func startAdvertising() {
        guard peripheralManager.state == .poweredOn else { 
            print("[DEBUG] Cannot advertise - peripheral not powered on")
            return 
        }
        
        let advertisementData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [BluetoothMeshService.serviceUUID],
            CBAdvertisementDataLocalNameKey: "bitchat-\(myPeerID)"
        ]
        print("[DEBUG] Starting advertising as: bitchat-\(myPeerID)")
        peripheralManager.startAdvertising(advertisementData)
    }
    
    func startScanning() {
        guard centralManager.state == .poweredOn else { 
            print("[DEBUG] Cannot scan - central not powered on")
            return 
        }
        print("[DEBUG] Starting scan for people...")
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
    
    func sendMessage(_ content: String, to recipientID: String? = nil) {
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            let nickname = self.delegate as? ChatViewModel
            let senderNick = nickname?.nickname ?? self.myPeerID
            
            let message = BitchatMessage(
                sender: senderNick,
                content: content,
                timestamp: Date(),
                isRelay: false,
                originalSender: nil
            )
            
            if let messageData = message.toBinaryPayload() {
                let packet = BitchatPacket(
                    type: MessageType.message.rawValue,
                    senderID: self.myPeerID.data(using: .utf8)!,
                    recipientID: recipientID?.data(using: .utf8),
                    timestamp: UInt64(Date().timeIntervalSince1970),
                    payload: messageData,
                    signature: try? self.encryptionService.sign(messageData),
                    ttl: self.maxTTL
                )
                
                print("[DEBUG] Sending message: \(content)")
                self.broadcastPacket(packet)
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
                let packet = BitchatPacket(
                    type: MessageType.privateMessage.rawValue,
                    senderID: self.myPeerID.data(using: .utf8)!,
                    recipientID: recipientPeerID.data(using: .utf8),
                    timestamp: UInt64(Date().timeIntervalSince1970),
                    payload: messageData,
                    signature: try? self.encryptionService.sign(messageData),
                    ttl: self.maxTTL
                )
                
                print("[DEBUG] Sending private message to \(recipientNickname): \(content)")
                self.broadcastPacket(packet)
                
                // Don't call didReceiveMessage here - let the view model handle it directly
            }
        }
    }
    
    private func sendInitialAnnouncement() {
        guard let vm = delegate as? ChatViewModel else { return }
        
        print("[DEBUG] Sending initial announcement to all peers")
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: myPeerID.data(using: .utf8)!,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970),
            payload: vm.nickname.data(using: .utf8)!,
            signature: nil,
            ttl: maxTTL
        )
        
        broadcastPacket(packet)
        hasAnnounced = true
    }
    
    private func sendLeaveAnnouncement() {
        guard let vm = delegate as? ChatViewModel else { return }
        
        print("[DEBUG] Sending leave announcement")
        let packet = BitchatPacket(
            type: MessageType.leave.rawValue,
            senderID: myPeerID.data(using: .utf8)!,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970),
            payload: vm.nickname.data(using: .utf8)!,
            signature: nil,
            ttl: 1  // Don't relay leave messages
        )
        
        broadcastPacket(packet)
    }
    
    
    func getPeerNicknames() -> [String: String] {
        return peerNicknames
    }
    
    private func getAllConnectedPeerIDs() -> [String] {
        // Return all active peers, even if they haven't announced yet
        let uniquePeers = Set(activePeers.filter { peerID in
            peerID != "unknown" && peerID != myPeerID
        })
        return Array(uniquePeers).sorted()
    }
    
    private func broadcastPacket(_ packet: BitchatPacket) {
        guard let data = packet.data else { 
            print("[DEBUG] Failed to encode packet data")
            return 
        }
        
        print("[DEBUG] Broadcasting packet type \(packet.type) to \(connectedPeripherals.count) peripherals and \(subscribedCentrals.count) centrals")
        
        // Send to connected peripherals (as central)
        for (peerID, peripheral) in connectedPeripherals {
            if let characteristic = peripheralCharacteristics[peripheral] {
                print("[DEBUG] Sending packet type \(packet.type) to peripheral \(peerID)")
                // Use withResponse for larger data for reliability
                let writeType: CBCharacteristicWriteType = data.count > 50000 ? .withResponse : .withoutResponse
                peripheral.writeValue(data, for: characteristic, type: writeType)
            }
        }
        
        // Send to subscribed centrals (as peripheral)
        if characteristic != nil && !subscribedCentrals.isEmpty {
            print("[DEBUG] Sending packet type \(packet.type) to \(subscribedCentrals.count) subscribed centrals")
            let success = peripheralManager.updateValue(data, for: characteristic, onSubscribedCentrals: subscribedCentrals)
            if !success {
                print("[DEBUG] Failed to send to centrals - queue full")
            }
        }
    }
    
    private func handleReceivedPacket(_ packet: BitchatPacket, from peerID: String) {
        guard packet.ttl > 0 else { return }
        
        let messageID = "\(packet.timestamp)-\(String(data: packet.senderID, encoding: .utf8) ?? "")"
        guard !processedMessages.contains(messageID) else { return }
        processedMessages.insert(messageID)
        
        if processedMessages.count > 1000 {
            processedMessages.removeAll()
        }
        
        let senderID = String(data: packet.senderID, encoding: .utf8) ?? "unknown"
        print("[DEBUG] Received packet type: \(packet.type) from peerID: \(peerID), senderID: \(senderID)")
        
        // For any message type, if we have a nickname in the payload, update it immediately
        if packet.type == MessageType.message.rawValue || packet.type == MessageType.privateMessage.rawValue {
            if let message = BitchatMessage.fromBinaryPayload(packet.payload),
               senderID != "unknown" && senderID != myPeerID {
                // Update nickname mapping immediately
                if peerNicknames[senderID] != message.sender {
                    peerNicknames[senderID] = message.sender
                    print("[DEBUG] Updated nickname for \(senderID): \(message.sender) from message")
                    
                    // Update peer list to show the new nickname
                    DispatchQueue.main.async {
                        self.delegate?.didUpdatePeerList(self.getAllConnectedPeerIDs())
                    }
                }
            }
        }
        
        switch MessageType(rawValue: packet.type) {
        case .message:
            if let message = BitchatMessage.fromBinaryPayload(packet.payload) {
                // Ignore our own messages
                if let senderID = String(data: packet.senderID, encoding: .utf8), senderID == myPeerID {
                    return
                }
                
                // Store nickname mapping
                if let senderID = String(data: packet.senderID, encoding: .utf8) {
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
            if let senderID = String(data: packet.senderID, encoding: .utf8) {
                print("[DEBUG] Received key exchange from \(senderID)")
                if packet.payload.count > 0 {
                    let publicKeyData = packet.payload
                    try? encryptionService.addPeerPublicKey(senderID, publicKeyData: publicKeyData)
                    
                    // Track this peer temporarily
                    if senderID != "unknown" && senderID != myPeerID {
                        // Add to active peers immediately on key exchange
                        activePeers.insert(senderID)
                        print("[DEBUG] Added peer \(senderID) to active peers after key exchange")
                        print("[DEBUG] Active peers now: \(activePeers)")
                        let connectedPeerIDs = self.getAllConnectedPeerIDs()
                        print("[DEBUG] Connected peer IDs: \(connectedPeerIDs)")
                        DispatchQueue.main.async {
                            self.delegate?.didUpdatePeerList(connectedPeerIDs)
                        }
                    }
                    
                    // Send announce with our nickname immediately
                    if let vm = self.delegate as? ChatViewModel {
                        print("[DEBUG] Sending announce to \(senderID)")
                        let announcePacket = BitchatPacket(
                            type: MessageType.announce.rawValue,
                            senderID: self.myPeerID.data(using: .utf8)!,
                            recipientID: senderID.data(using: .utf8),
                            timestamp: UInt64(Date().timeIntervalSince1970),
                            payload: vm.nickname.data(using: .utf8)!,
                            signature: nil,
                            ttl: 1
                        )
                        self.broadcastPacket(announcePacket)
                    }
                }
            }
            
        case .announce:
            if let nickname = String(data: packet.payload, encoding: .utf8), 
               let senderID = String(data: packet.senderID, encoding: .utf8) {
                print("[DEBUG] Received announce from \(senderID): \(nickname)")
                
                // Ignore if it's from ourselves
                if senderID == myPeerID {
                    return
                }
                
                // Check if we've already announced this peer
                let isFirstAnnounce = !announcedPeers.contains(senderID)
                
                // Store the nickname
                peerNicknames[senderID] = nickname
                print("[DEBUG] Stored nickname for \(senderID): \(nickname)")
                
                // Add to active peers if not already there
                if senderID != "unknown" {
                    if !activePeers.contains(senderID) {
                        print("[DEBUG] Adding new peer \(senderID) to active peers")
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
                    print("[DEBUG] Peer \(senderID) is invalid (unknown)")
                }
            }
            
        case .leave:
            if let nickname = String(data: packet.payload, encoding: .utf8),
               let senderID = String(data: packet.senderID, encoding: .utf8) {
                print("[DEBUG] Received leave from \(senderID): \(nickname)")
                
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
            if let message = BitchatMessage.fromBinaryPayload(packet.payload) {
                // Check if this private message is for us
                if let recipientID = packet.recipientID,
                   let recipientIDString = String(data: recipientID, encoding: .utf8),
                   recipientIDString == myPeerID {
                    
                    // Get sender ID
                    if let senderID = String(data: packet.senderID, encoding: .utf8) {
                        // Ignore our own messages
                        if senderID == myPeerID {
                            return
                        }
                        
                        // Store nickname mapping if we don't have it
                        if peerNicknames[senderID] == nil {
                            peerNicknames[senderID] = message.sender
                            print("[DEBUG] Updated nickname for \(senderID): \(message.sender)")
                            
                            // Update peer list to show the new nickname
                            DispatchQueue.main.async {
                                self.delegate?.didUpdatePeerList(self.getAllConnectedPeerIDs())
                            }
                        }
                        
                        print("[DEBUG] Received private message from \(message.sender) (peer: \(senderID))")
                        
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
                    var relayPacket = packet
                    relayPacket.ttl -= 1
                    self.broadcastPacket(relayPacket)
                }
            }
            
        default:
            break
        }
    }
}

extension BluetoothMeshService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("[DEBUG] Central state changed to: \(central.state.rawValue)")
        if central.state == .poweredOn {
            startScanning()
            
            // If we haven't announced yet and we're now powered on, schedule announcement
            if !hasAnnounced {
                announcementTimer?.invalidate()
                announcementTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                    self?.sendInitialAnnouncement()
                }
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        print("[DEBUG] Discovered peripheral: \(peripheral.name ?? "unknown") RSSI: \(RSSI)")
        
        // Connect to any device we discover - we'll filter by service later
        if !discoveredPeripherals.contains(peripheral) {
            print("[DEBUG] Connecting to peripheral...")
            discoveredPeripherals.append(peripheral)
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[DEBUG] Connected to peripheral: \(peripheral.name ?? "unknown")")
        peripheral.delegate = self
        peripheral.discoverServices([BluetoothMeshService.serviceUUID])
        
        // Extract peer ID from advertisement or use peripheral identifier
        let peerID: String
        if let name = peripheral.name, name.hasPrefix("bitchat-") {
            peerID = String(name.dropFirst(8))
        } else {
            peerID = peripheral.identifier.uuidString.prefix(8).lowercased()
        }
        
        connectedPeripherals[peerID] = peripheral
        print("[DEBUG] Connected to peer: \(peerID)")
        
        // Add to active peers immediately
        activePeers.insert(peerID)
        print("[DEBUG] Active peers: \(activePeers)")
        
        // Update peer list to show we're connecting
        DispatchQueue.main.async {
            self.delegate?.didUpdatePeerList(self.getAllConnectedPeerIDs())
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[DEBUG] Disconnected from peripheral: \(peripheral.name ?? "unknown"), error: \(error?.localizedDescription ?? "none")")
        
        if let peerID = connectedPeripherals.first(where: { $0.value == peripheral })?.key {
            connectedPeripherals.removeValue(forKey: peerID)
            peripheralCharacteristics.removeValue(forKey: peripheral)
            
            // Remove from active peers
            activePeers.remove(peerID)
            announcedPeers.remove(peerID)
            
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
            print("[DEBUG] Restarting scan after disconnect")
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
                print("[DEBUG] Found characteristic, subscribing to notifications...")
                peripheral.setNotifyValue(true, for: characteristic)
                peripheralCharacteristics[peripheral] = characteristic
                
                // Send key exchange and announce immediately without any delay
                let publicKeyData = self.encryptionService.publicKey.rawRepresentation
                let packet = BitchatPacket(
                    type: MessageType.keyExchange.rawValue,
                    senderID: self.myPeerID.data(using: .utf8)!,
                    recipientID: nil,
                    timestamp: UInt64(Date().timeIntervalSince1970),
                    payload: publicKeyData,
                    signature: nil,
                    ttl: 1
                )
                
                if let data = packet.data {
                    peripheral.writeValue(data, for: characteristic, type: .withResponse)
                }
                
                // Send announce packet immediately after key exchange
                if let vm = self.delegate as? ChatViewModel {
                    let announcePacket = BitchatPacket(
                        type: MessageType.announce.rawValue,
                        senderID: self.myPeerID.data(using: .utf8)!,
                        recipientID: nil,
                        timestamp: UInt64(Date().timeIntervalSince1970),
                        payload: vm.nickname.data(using: .utf8)!,
                        signature: nil,
                        ttl: 1
                    )
                    if let data = announcePacket.data {
                        peripheral.writeValue(data, for: characteristic, type: .withResponse)
                    }
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value,
              let packet = BitchatPacket.from(data) else { 
            return 
        }
        
        let peerID = connectedPeripherals.first(where: { $0.value == peripheral })?.key ?? "unknown"
        handleReceivedPacket(packet, from: peerID)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Handle write completion if needed
    }
    
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        peripheral.discoverServices([BluetoothMeshService.serviceUUID])
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("[DEBUG] Error updating notification state: \(error)")
        } else {
            print("[DEBUG] Notification state updated for characteristic: \(characteristic.isNotifying)")
        }
    }
}

extension BluetoothMeshService: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        print("[DEBUG] Peripheral state changed to: \(peripheral.state.rawValue)")
        switch peripheral.state {
        case .poweredOn:
            print("[DEBUG] Peripheral powered on, setting up...")
            setupPeripheral()
            startAdvertising()
            
            // If we haven't announced yet and we're now powered on, schedule announcement
            if !hasAnnounced {
                announcementTimer?.invalidate()
                announcementTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                    self?.sendInitialAnnouncement()
                }
            }
        default:
            break
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        // Handle service addition if needed
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        print("[DEBUG] Received write request")
        for request in requests {
            if let data = request.value,
               let packet = BitchatPacket.from(data) {
                // Try to identify peer from packet
                let peerID = String(data: packet.senderID, encoding: .utf8) ?? "unknown"
                print("[DEBUG] Write from peer: \(peerID)")
                
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
                            senderID: self.myPeerID.data(using: .utf8)!,
                            recipientID: peerID.data(using: .utf8),
                            timestamp: UInt64(Date().timeIntervalSince1970),
                            payload: publicKeyData,
                            signature: nil,
                            ttl: 1
                        )
                        if let data = responsePacket.data {
                            peripheral.updateValue(data, for: self.characteristic, onSubscribedCentrals: [request.central])
                        }
                        
                        // Send announce immediately after key exchange
                        if let vm = self.delegate as? ChatViewModel {
                            DispatchQueue.main.async { [weak self] in
                                guard let self = self else { return }
                                print("[DEBUG] Sending announce packet to central after key exchange")
                                let announcePacket = BitchatPacket(
                                    type: MessageType.announce.rawValue,
                                    senderID: self.myPeerID.data(using: .utf8)!,
                                    recipientID: peerID.data(using: .utf8),
                                    timestamp: UInt64(Date().timeIntervalSince1970),
                                    payload: vm.nickname.data(using: .utf8)!,
                                    signature: nil,
                                    ttl: 1
                                )
                                if let data = announcePacket.data {
                                    let success = peripheral.updateValue(data, for: self.characteristic, onSubscribedCentrals: nil)
                                    print("[DEBUG] Announce sent to all centrals: \(success)")
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
        print("[DEBUG] Central subscribed to notifications")
        if !subscribedCentrals.contains(central) {
            subscribedCentrals.append(central)
            print("[DEBUG] New central subscribed, total: \(subscribedCentrals.count)")
            
            // Send our public key to the newly connected central
            let publicKeyData = encryptionService.publicKey.rawRepresentation
            let keyPacket = BitchatPacket(
                type: MessageType.keyExchange.rawValue,
                senderID: myPeerID.data(using: .utf8)!,
                recipientID: nil,
                timestamp: UInt64(Date().timeIntervalSince1970),
                payload: try! JSONEncoder().encode(publicKeyData),
                signature: nil,
                ttl: 1
            )
            
            if let data = keyPacket.data {
                peripheral.updateValue(data, for: self.characteristic, onSubscribedCentrals: [central])
                
                // Send announce immediately after key exchange
                if let vm = delegate as? ChatViewModel {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        let announcePacket = BitchatPacket(
                            type: MessageType.announce.rawValue,
                            senderID: self.myPeerID.data(using: .utf8)!,
                            recipientID: nil,
                            timestamp: UInt64(Date().timeIntervalSince1970),
                            payload: vm.nickname.data(using: .utf8)!,
                            signature: nil,
                            ttl: 1
                        )
                        if let data = announcePacket.data {
                            peripheral.updateValue(data, for: self.characteristic, onSubscribedCentrals: [central])
                        }
                    }
                }
            }
            
            // Update peer list to show we're connected (even without peer ID yet)
            print("[DEBUG] Updating peer list after subscription")
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