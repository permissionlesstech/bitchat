import Foundation
import CoreBluetooth
import Combine

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
    
    let myPeerID: String
    
    override init() {
        self.myPeerID = UUID().uuidString.prefix(8).lowercased()
        super.init()
        
        centralManager = CBCentralManager(delegate: self, queue: nil)
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
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
        print("[DEBUG] Starting scan for peers...")
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
            
            if let messageData = try? JSONEncoder().encode(message) {
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
    
    
    func getPeerNicknames() -> [String: String] {
        return peerNicknames
    }
    
    private func getAllConnectedPeerIDs() -> [String] {
        var peers = Set<String>()
        
        // Include connected peripherals (devices we connected to as central)
        peers.formUnion(connectedPeripherals.keys)
        
        // Include active peers (devices that have announced)
        peers.formUnion(activePeers)
        
        // Filter out invalid peers
        return peers.filter { $0 != "unknown" && $0 != myPeerID }
    }
    
    private func broadcastPacket(_ packet: BitchatPacket) {
        guard let data = packet.data else { return }
        
        // Send to connected peripherals (as central)
        for (_, peripheral) in connectedPeripherals {
            if let characteristic = peripheralCharacteristics[peripheral] {
                // Use withResponse for larger data for reliability
                let writeType: CBCharacteristicWriteType = data.count > 50000 ? .withResponse : .withoutResponse
                peripheral.writeValue(data, for: characteristic, type: writeType)
            }
        }
        
        // Send to subscribed centrals (as peripheral)
        if characteristic != nil && !subscribedCentrals.isEmpty {
            peripheralManager.updateValue(data, for: characteristic, onSubscribedCentrals: subscribedCentrals)
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
        
        print("[DEBUG] Received packet type: \(packet.type) from \(peerID)")
        
        switch MessageType(rawValue: packet.type) {
        case .message:
            if let message = try? JSONDecoder().decode(BitchatMessage.self, from: packet.payload) {
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
            print("[DEBUG] Received key exchange from \(peerID)")
            if let publicKeyData = try? JSONDecoder().decode(Data.self, from: packet.payload) {
                try? encryptionService.addPeerPublicKey(peerID, publicKeyData: publicKeyData)
                
                // Track this peer temporarily but don't announce until we get their name
                if peerID != "unknown" && peerID != myPeerID && !peerNicknames.keys.contains(peerID) {
                    // Just track them, don't announce yet
                    print("[DEBUG] Tracking peer \(peerID) after key exchange")
                    DispatchQueue.main.async {
                        self.delegate?.didUpdatePeerList(self.getAllConnectedPeerIDs())
                    }
                }
                
                // Send announce with our nickname immediately
                DispatchQueue.main.async { [weak self] in
                    if let self = self, let vm = self.delegate as? ChatViewModel {
                        print("[DEBUG] Sending announce to \(peerID)")
                        let announcePacket = BitchatPacket(
                            type: MessageType.announce.rawValue,
                            senderID: self.myPeerID.data(using: .utf8)!,
                            recipientID: peerID.data(using: .utf8),
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
            if let nickname = String(data: packet.payload, encoding: .utf8) {
                print("[DEBUG] Received announce from \(peerID): \(nickname)")
                
                // Check if this is the first time we're getting a nickname for this peer
                let isNewNickname = peerNicknames[peerID] == nil
                
                // Store the nickname
                peerNicknames[peerID] = nickname
                
                // Add to active peers if not already there
                if peerID != "unknown" && peerID != myPeerID {
                    if !activePeers.contains(peerID) {
                        print("[DEBUG] Adding new peer \(peerID) to active peers")
                        activePeers.insert(peerID)
                    }
                    
                    // Show join message if this is a new nickname
                    if isNewNickname {
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
                    print("[DEBUG] Peer \(peerID) is invalid (unknown or self)")
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
        
        // Extract peer ID from advertisement or generate one
        var peerID = peripheral.identifier.uuidString.prefix(8).lowercased()
        if let name = peripheral.name, name.hasPrefix("bitchat-") {
            peerID = String(name.dropFirst(8))
        }
        
        connectedPeripherals[String(peerID)] = peripheral
        print("[DEBUG] Connected to peer: \(peerID)")
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
            // Always restart scan to ensure we can reconnect
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
                
                // Wait a moment for subscription to complete before sending data
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self = self else { return }
                    
                    let publicKeyData = self.encryptionService.publicKey.rawRepresentation
                    let packet = BitchatPacket(
                        type: MessageType.keyExchange.rawValue,
                        senderID: self.myPeerID.data(using: .utf8)!,
                        recipientID: nil,
                        timestamp: UInt64(Date().timeIntervalSince1970),
                        payload: try! JSONEncoder().encode(publicKeyData),
                        signature: nil,
                        ttl: 1
                    )
                    
                    if let data = packet.data {
                        peripheral.writeValue(data, for: characteristic, type: .withResponse)
                    }
                    
                    // Also send announce packet immediately
                    if let vm = self.delegate as? ChatViewModel {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
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
                                peripheral.writeValue(data, for: characteristic, type: .withResponse)
                            }
                        }
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
        // Handle notification state update if needed
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
                            payload: try! JSONEncoder().encode(publicKeyData),
                            signature: nil,
                            ttl: 1
                        )
                        if let data = responsePacket.data {
                            peripheral.updateValue(data, for: self.characteristic, onSubscribedCentrals: [request.central])
                        }
                        
                        // Also send announce immediately after key exchange
                        if let vm = self.delegate as? ChatViewModel {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                                guard let self = self else { return }
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
                                    peripheral.updateValue(data, for: self.characteristic, onSubscribedCentrals: [request.central])
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
                
                // Also send announce after key exchange
                if let vm = delegate as? ChatViewModel {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
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