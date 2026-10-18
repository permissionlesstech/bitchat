import Foundation
import CoreBluetooth

/// Real Bluetooth LE link between nearby phones. Every phone advertises the Nearsend service (peripheral role)
/// and scans for it (central role), so two phones find each other without any pairing step.
/// Messages are written to the other phone's message characteristic. NOT encrypted yet.
final class BLETransport: NSObject {
    static let service = CBUUID(string: "7A3C5E10-9D2B-4F6A-8C1E-4E4541525345")
    static let identityChar = CBUUID(string: "7A3C5E11-9D2B-4F6A-8C1E-4E4541525345")
    static let messageChar = CBUUID(string: "7A3C5E12-9D2B-4F6A-8C1E-4E4541525345")

    private struct Identity: Codable { let id: String; let name: String }
    private struct Payload: Codable { let from: String; let name: String; let text: String }

    private final class Link {
        let peripheral: CBPeripheral
        var messageChar: CBCharacteristic?
        var peerID: String?
        var name = ""
        var rssi = -80
        var writes: [(Bool) -> Void] = []
        init(_ p: CBPeripheral) { peripheral = p }
    }

    var onPeers: (([Peer]) -> Void)?
    var onMessage: ((_ fromID: String, _ name: String, _ text: String) -> Void)?
    var onState: ((String) -> Void)?

    private var identity: Identity
    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var links: [UUID: Link] = [:]
    private var timer: Timer?

    init(id: String, name: String) {
        identity = Identity(id: id, name: name)
        super.init()
    }

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.links.values.forEach { if $0.peripheral.state == .connected { $0.peripheral.readRSSI() } }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        central?.stopScan()
        links.values.forEach { central?.cancelPeripheralConnection($0.peripheral) }
        links.removeAll()
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        central = nil; peripheralManager = nil
        onPeers?([])
    }

    func setName(_ name: String) {
        identity = Identity(id: identity.id, name: name)
        guard let pm = peripheralManager, pm.state == .poweredOn else { return }
        pm.stopAdvertising(); pm.removeAllServices(); addService()
    }

    /// Calls `completion(true)` once the other phone has acknowledged the write.
    func send(_ text: String, to peerID: String, completion: @escaping (Bool) -> Void) {
        guard let link = links.values.first(where: { $0.peerID == peerID && $0.messageChar != nil }),
              link.peripheral.state == .connected,
              let data = try? JSONEncoder().encode(Payload(from: identity.id, name: identity.name, text: String(text.prefix(300))))
        else { completion(false); return }
        link.writes.append(completion)
        link.peripheral.writeValue(data, for: link.messageChar!, type: .withResponse)
    }

    private func addService() {
        let idData = try? JSONEncoder().encode(identity)
        let idChar = CBMutableCharacteristic(type: Self.identityChar, properties: [.read], value: idData, permissions: [.readable])
        let msgChar = CBMutableCharacteristic(type: Self.messageChar, properties: [.write], value: nil, permissions: [.writeable])
        let svc = CBMutableService(type: Self.service, primary: true)
        svc.characteristics = [idChar, msgChar]
        peripheralManager?.add(svc)
    }

    private func startScan() {
        central?.scanForPeripherals(withServices: [Self.service], options: nil)
    }

    private func emitPeers() {
        let peers = links.values.compactMap { l -> Peer? in
            guard let id = l.peerID else { return nil }
            return Peer(id: id, name: l.name, hops: 1, rssi: l.rssi)
        }
        onPeers?(peers)
    }

    private func stateName(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: "ready"
        case .poweredOff: "off"
        case .unauthorized: "unauthorized"
        case .unsupported: "unsupported"
        default: "starting"
        }
    }
}

extension BLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        onState?(stateName(c.state))
        if c.state == .poweredOn { startScan() }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard links[p.identifier] == nil else { return }
        let link = Link(p)
        if RSSI.intValue != 127 { link.rssi = RSSI.intValue }
        links[p.identifier] = link
        p.delegate = self
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([Self.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { drop(p) }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { drop(p) }

    private func drop(_ p: CBPeripheral) {
        links[p.identifier]?.writes.forEach { $0(false) }
        links.removeValue(forKey: p.identifier)
        emitPeers()
        // Re-report the phone if it comes back into range.
        central?.stopScan(); startScan()
    }
}

extension BLETransport: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == Self.service }) else { return }
        p.discoverCharacteristics([Self.identityChar, Self.messageChar], for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let link = links[p.identifier] else { return }
        for ch in service.characteristics ?? [] {
            if ch.uuid == Self.messageChar { link.messageChar = ch }
            if ch.uuid == Self.identityChar { p.readValue(for: ch) }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == Self.identityChar, let link = links[p.identifier],
              let data = ch.value, let id = try? JSONDecoder().decode(Identity.self, from: data) else { return }
        link.peerID = id.id
        link.name = id.name
        emitPeers()
        p.readRSSI()
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, let link = links[p.identifier] else { return }
        link.rssi = RSSI.intValue
        emitPeers()
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        guard let link = links[p.identifier], !link.writes.isEmpty else { return }
        link.writes.removeFirst()(error == nil)
    }
}

extension BLETransport: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ pm: CBPeripheralManager) {
        if pm.state == .poweredOn { addService() }
    }

    func peripheralManager(_ pm: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { return }
        pm.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.service]])
    }

    func peripheralManager(_ pm: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests where r.characteristic.uuid == Self.messageChar {
            if let data = r.value, let m = try? JSONDecoder().decode(Payload.self, from: data) {
                onMessage?(m.from, m.name, m.text)
            }
        }
        if let first = requests.first { pm.respond(to: first, withResult: .success) }
    }
}
