import Foundation
import CoreBluetooth

/// Bluetooth LE link layer. Every phone advertises the Nearsend service (peripheral role) and scans for it
/// (central role), so two phones find each other without pairing. It only moves bytes: identities and packets
/// go up to `MeshRouter` (see PROTOCOL.md).
final class BLETransport: NSObject {
    static let service = CBUUID(string: "7A3C5E10-9D2B-4F6A-8C1E-4E4541525345")
    static let identityChar = CBUUID(string: "7A3C5E11-9D2B-4F6A-8C1E-4E4541525345")
    static let messageChar = CBUUID(string: "7A3C5E12-9D2B-4F6A-8C1E-4E4541525345")

    /// Lets iOS relaunch the app in the background and hand back our Bluetooth state if it terminated us (e.g. low memory).
    /// Does not apply after the user force-quits the app from the app switcher.
    private static let centralRestoreID = "app.nearsend.chat.central"
    private static let peripheralRestoreID = "app.nearsend.chat.peripheral"

    private struct Identity: Codable { let id: String; let name: String; let pk: String }

    private final class Link {
        let peripheral: CBPeripheral
        var messageChar: CBCharacteristic?
        var peerID: String?
        var writes: [(Bool) -> Void] = []
        init(_ p: CBPeripheral) { peripheral = p }
    }

    var onNeighbor: ((_ link: String, _ id: String, _ name: String, _ pk: Data) -> Void)?
    var onLost: ((_ link: String) -> Void)?
    var onPacket: ((_ data: Data) -> Void)?
    var onRSSI: ((_ link: String, _ rssi: Int) -> Void)?
    var onState: ((String) -> Void)?

    private var identity: Identity
    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var links: [UUID: Link] = [:]
    private var timer: Timer?

    init(id: String, name: String, publicKey: Data) {
        identity = Identity(id: id, name: name, pk: publicKey.base64EncodedString())
        super.init()
    }

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreID])
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main, options: [CBPeripheralManagerOptionRestoreIdentifierKey: Self.peripheralRestoreID])
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.links.values.forEach { if $0.peripheral.state == .connected { $0.peripheral.readRSSI() } }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        central?.stopScan()
        links.values.forEach { central?.cancelPeripheralConnection($0.peripheral) }
        for (id, l) in links { l.writes.forEach { $0(false) }; if l.peerID != nil { onLost?(id.uuidString) } }
        links.removeAll()
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        central = nil; peripheralManager = nil
    }

    func setName(_ name: String) {
        identity = Identity(id: identity.id, name: name, pk: identity.pk)
        guard let pm = peripheralManager, pm.state == .poweredOn else { return }
        pm.stopAdvertising(); pm.removeAllServices(); addService()
    }

    /// Writes one packet to a neighbour. `done(true)` once the other phone acknowledged the write.
    func write(link: String, data: Data, done: @escaping (Bool) -> Void) {
        guard let uuid = UUID(uuidString: link), let l = links[uuid], let ch = l.messageChar, l.peripheral.state == .connected else { done(false); return }
        l.writes.append(done)
        l.peripheral.writeValue(data, for: ch, type: .withResponse)
    }

    private func addService() {
        let idChar = CBMutableCharacteristic(type: Self.identityChar, properties: [.read], value: try? JSONEncoder().encode(identity), permissions: [.readable])
        let msgChar = CBMutableCharacteristic(type: Self.messageChar, properties: [.write], value: nil, permissions: [.writeable])
        let svc = CBMutableService(type: Self.service, primary: true)
        svc.characteristics = [idChar, msgChar]
        peripheralManager?.add(svc)
    }

    private func startScan() { central?.scanForPeripherals(withServices: [Self.service], options: nil) }

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

    /// Called first after a background relaunch: re-adopt the connections iOS kept alive for us and re-read their identities.
    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for p in restored where links[p.identifier] == nil {
            links[p.identifier] = Link(p)
            p.delegate = self
            switch p.state {
            case .connected: p.discoverServices([Self.service])
            case .disconnected: c.connect(p)
            default: break      // still connecting; iOS will report the result
            }
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard links[p.identifier] == nil else { return }
        links[p.identifier] = Link(p)
        p.delegate = self
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([Self.service]) }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { drop(p) }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { drop(p) }

    private func drop(_ p: CBPeripheral) {
        guard let l = links.removeValue(forKey: p.identifier) else { return }
        l.writes.forEach { $0(false) }
        if l.peerID != nil { onLost?(p.identifier.uuidString) }
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
        guard ch.uuid == Self.identityChar, let link = links[p.identifier], let data = ch.value,
              let id = try? JSONDecoder().decode(Identity.self, from: data), let pk = Data(base64Encoded: id.pk), pk.count == 32,
              id.id != identity.id else { return }
        link.peerID = id.id
        onNeighbor?(p.identifier.uuidString, id.id, id.name, pk)
        p.readRSSI()
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, links[p.identifier]?.peerID != nil else { return }
        onRSSI?(p.identifier.uuidString, RSSI.intValue)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        guard let link = links[p.identifier], !link.writes.isEmpty else { return }
        link.writes.removeFirst()(error == nil)
    }
}

extension BLETransport: CBPeripheralManagerDelegate {
    /// iOS may hand back the service we had published before termination. We always rebuild it (below) so the identity
    /// it serves matches the current nickname and we never publish the service twice.
    func peripheralManager(_ pm: CBPeripheralManager, willRestoreState dict: [String: Any]) {}

    func peripheralManagerDidUpdateState(_ pm: CBPeripheralManager) {
        guard pm.state == .poweredOn else { return }
        pm.stopAdvertising(); pm.removeAllServices()
        addService()
    }

    func peripheralManager(_ pm: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { return }
        pm.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.service]])
    }

    func peripheralManager(_ pm: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests where r.characteristic.uuid == Self.messageChar {
            if let data = r.value { onPacket?(data) }
        }
        if let first = requests.first { pm.respond(to: first, withResult: .success) }
    }
}
