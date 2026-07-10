import BitFoundation
import CoreBluetooth
import Foundation

struct BLEPeripheralLinkState {
    let peripheral: CBPeripheral
    var characteristic: CBCharacteristic?
    var peerID: PeerID?
    var isConnecting: Bool
    var isConnected: Bool
    var lastConnectionAttempt: Date?
    var assembler: NotificationStreamAssembler
}

struct BLEDirectLinkState: Equatable {
    let hasPeripheral: Bool
    let hasCentral: Bool
}

struct BLESubscribedCentralSnapshot {
    let centrals: [CBCentral]
    let peerIDsByCentralUUID: [String: PeerID]

    func central(for peerID: PeerID) -> CBCentral? {
        centrals.first { peerIDsByCentralUUID[$0.identifier.uuidString] == peerID }
    }
}

/// Owns all BLE link state (peripheral connections we hold as central, and
/// central subscriptions we serve as peripheral). The store has no internal
/// locking: every access must happen on the single owning queue (the BLE
/// queue). Other queues must go through BLEService's `readLinkState`, which
/// hops to that queue. Call `assumeOwnership(of:)` to have debug builds trap
/// any access from the wrong queue.
final class BLELinkStateStore {
    private(set) var peripherals: [String: BLEPeripheralLinkState] = [:]
    private(set) var peerToPeripheralUUID: [PeerID: String] = [:]
    private(set) var subscribedCentrals: [CBCentral] = []
    private(set) var centralToPeerID: [String: PeerID] = [:]

    #if DEBUG
    private var ownerQueue: DispatchQueue?
    #endif

    /// Pin the store to its owning queue. Debug-only enforcement; release
    /// builds are unchanged.
    func assumeOwnership(of queue: DispatchQueue) {
        #if DEBUG
        ownerQueue = queue
        #endif
    }

    @inline(__always)
    private func assertOwned() {
        #if DEBUG
        if let queue = ownerQueue {
            dispatchPrecondition(condition: .onQueue(queue))
        }
        #endif
    }

    var peripheralStates: [BLEPeripheralLinkState] {
        assertOwned()
        return Array(peripherals.values)
    }

    var subscribedCentralSnapshot: BLESubscribedCentralSnapshot {
        assertOwned()
        return BLESubscribedCentralSnapshot(
            centrals: subscribedCentrals,
            peerIDsByCentralUUID: centralToPeerID
        )
    }

    var subscribedCentralCount: Int {
        assertOwned()
        return subscribedCentrals.count
    }

    var connectedOrConnectingPeripheralCount: Int {
        assertOwned()
        return peripherals.values.filter { $0.isConnected || $0.isConnecting }.count
    }

    func state(forPeripheralID peripheralID: String) -> BLEPeripheralLinkState? {
        assertOwned()
        return peripherals[peripheralID]
    }

    func setPeripheralState(_ state: BLEPeripheralLinkState, for peripheralID: String) {
        assertOwned()
        peripherals[peripheralID] = state
    }

    @discardableResult
    func updatePeripheral(
        _ peripheralID: String,
        _ update: (inout BLEPeripheralLinkState) -> Void
    ) -> BLEPeripheralLinkState? {
        assertOwned()
        guard var state = peripherals[peripheralID] else { return nil }
        update(&state)
        peripherals[peripheralID] = state
        return state
    }

    func beginConnecting(to peripheral: CBPeripheral, at date: Date) {
        setPeripheralState(
            BLEPeripheralLinkState(
                peripheral: peripheral,
                characteristic: nil,
                peerID: nil,
                isConnecting: true,
                isConnected: false,
                lastConnectionAttempt: date,
                assembler: NotificationStreamAssembler()
            ),
            for: peripheral.identifier.uuidString
        )
    }

    func markConnected(_ peripheral: CBPeripheral) {
        let peripheralID = peripheral.identifier.uuidString
        if updatePeripheral(peripheralID, {
            $0.isConnecting = false
            $0.isConnected = true
        }) == nil {
            setPeripheralState(
                BLEPeripheralLinkState(
                    peripheral: peripheral,
                    characteristic: nil,
                    peerID: nil,
                    isConnecting: false,
                    isConnected: true,
                    lastConnectionAttempt: nil,
                    assembler: NotificationStreamAssembler()
                ),
                for: peripheralID
            )
        }
    }

    func updateCharacteristic(_ characteristic: CBCharacteristic, forPeripheralID peripheralID: String) {
        updatePeripheral(peripheralID) {
            $0.characteristic = characteristic
        }
    }

    func directPeripheralState(for peerID: PeerID) -> BLEPeripheralLinkState? {
        assertOwned()
        return peerToPeripheralUUID[peerID].flatMap { peripherals[$0] }
    }

    func directLinkState(for peerID: PeerID) -> BLEDirectLinkState {
        assertOwned()
        let peripheralUUID = peerToPeripheralUUID[peerID]
        let hasPeripheral = peripheralUUID.flatMap { peripherals[$0]?.isConnected } ?? false
        let hasCentral = centralToPeerID.values.contains(peerID)
        return BLEDirectLinkState(hasPeripheral: hasPeripheral, hasCentral: hasCentral)
    }

    func links(to peerID: PeerID?) -> Set<BLEIngressLinkID> {
        assertOwned()
        guard let peerID else { return [] }

        var links: Set<BLEIngressLinkID> = []
        // Scan all states rather than the 1:1 reverse map: after a state
        // restoration the same device can hold several live peripheral links
        // bound to one peer (it reappears under a fresh UUID while the
        // restored connection lives on).
        for (peripheralUUID, state) in peripherals where state.peerID == peerID {
            links.insert(.peripheral(peripheralUUID))
        }
        for (centralUUID, mappedPeerID) in centralToPeerID where mappedPeerID == peerID {
            links.insert(.central(centralUUID))
        }
        return links
    }

    /// The peer's most recently bound peripheral link, per peer. Used to keep
    /// duplicate-link fanout collapse deterministic (see BLEFanoutSelector).
    var preferredPeripheralBindings: [PeerID: String] {
        assertOwned()
        return peerToPeripheralUUID
    }

    func peerID(forPeripheralID peripheralID: String) -> PeerID? {
        assertOwned()
        return peripherals[peripheralID]?.peerID
    }

    func peerID(forCentralUUID centralUUID: String) -> PeerID? {
        assertOwned()
        return centralToPeerID[centralUUID]
    }

    func addSubscribedCentral(_ central: CBCentral) {
        assertOwned()
        guard !subscribedCentrals.contains(central) else { return }
        subscribedCentrals.append(central)
    }

    func removeSubscribedCentral(_ central: CBCentral) -> PeerID? {
        assertOwned()
        let centralUUID = central.identifier.uuidString
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        return centralToPeerID.removeValue(forKey: centralUUID)
    }

    func bindCentral(_ centralUUID: String, to peerID: PeerID) {
        assertOwned()
        centralToPeerID[centralUUID] = peerID
    }

    func bindPeripheral(_ peripheralUUID: String, to peerID: PeerID) {
        assertOwned()
        var previousPeerID: PeerID?
        let updated = updatePeripheral(peripheralUUID) {
            previousPeerID = $0.peerID
            $0.peerID = peerID
        }
        guard updated != nil else { return }
        // Rebinding (peer-ID rotation): drop the retired ID's reverse mapping
        // so the old peer no longer claims this link.
        if let previousPeerID, previousPeerID != peerID,
           peerToPeripheralUUID[previousPeerID] == peripheralUUID {
            peerToPeripheralUUID.removeValue(forKey: previousPeerID)
        }
        peerToPeripheralUUID[peerID] = peripheralUUID
    }

    func removePeripheral(_ peripheralID: String) -> PeerID? {
        assertOwned()
        let peerID = peripherals.removeValue(forKey: peripheralID)?.peerID
        // Only clear (or repair) the reverse map when it points at the removed
        // link: with duplicate links to one peer, removing a stale duplicate
        // must not strand the peer's surviving bound link.
        if let peerID, peerToPeripheralUUID[peerID] == peripheralID {
            // Prefer a writable survivor: repairing onto a link that is
            // mid-service-rediscovery would strand directed sends until the
            // characteristic comes back.
            let survivors = peripherals.filter { $0.value.peerID == peerID && $0.value.isConnected }
            if let survivorUUID = survivors.first(where: { $0.value.characteristic != nil })?.key ?? survivors.first?.key {
                peerToPeripheralUUID[peerID] = survivorUUID
            } else {
                peerToPeripheralUUID.removeValue(forKey: peerID)
            }
        }
        return peerID
    }

    func clearPeripherals() -> [PeerID] {
        assertOwned()
        let peerIDs = peripherals.compactMap { $0.value.peerID }
        peripherals.removeAll()
        peerToPeripheralUUID.removeAll()
        return peerIDs
    }

    func clearCentrals() -> [PeerID] {
        assertOwned()
        let peerIDs = Array(centralToPeerID.values)
        subscribedCentrals.removeAll()
        centralToPeerID.removeAll()
        return peerIDs
    }

    func clearAll() {
        assertOwned()
        peripherals.removeAll()
        peerToPeripheralUUID.removeAll()
        subscribedCentrals.removeAll()
        centralToPeerID.removeAll()
    }
}
