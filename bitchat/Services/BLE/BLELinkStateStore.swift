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

final class BLELinkStateStore {
    private(set) var peripherals: [String: BLEPeripheralLinkState] = [:]
    private(set) var peerToPeripheralUUID: [PeerID: String] = [:]
    private(set) var subscribedCentrals: [CBCentral] = []
    private(set) var centralToPeerID: [String: PeerID] = [:]

    var peripheralStates: [BLEPeripheralLinkState] {
        Array(peripherals.values)
    }

    var subscribedCentralSnapshot: BLESubscribedCentralSnapshot {
        BLESubscribedCentralSnapshot(
            centrals: subscribedCentrals,
            peerIDsByCentralUUID: centralToPeerID
        )
    }

    var subscribedCentralCount: Int {
        subscribedCentrals.count
    }

    var connectedOrConnectingPeripheralCount: Int {
        peripherals.values.filter { $0.isConnected || $0.isConnecting }.count
    }

    func state(forPeripheralID peripheralID: String) -> BLEPeripheralLinkState? {
        peripherals[peripheralID]
    }

    func setPeripheralState(_ state: BLEPeripheralLinkState, for peripheralID: String) {
        peripherals[peripheralID] = state
    }

    @discardableResult
    func updatePeripheral(
        _ peripheralID: String,
        _ update: (inout BLEPeripheralLinkState) -> Void
    ) -> BLEPeripheralLinkState? {
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
        peerToPeripheralUUID[peerID].flatMap { peripherals[$0] }
    }

    func directLinkState(for peerID: PeerID) -> BLEDirectLinkState {
        let peripheralUUID = peerToPeripheralUUID[peerID]
        let hasPeripheral = peripheralUUID.flatMap { peripherals[$0]?.isConnected } ?? false
        let hasCentral = centralToPeerID.values.contains(peerID)
        return BLEDirectLinkState(hasPeripheral: hasPeripheral, hasCentral: hasCentral)
    }

    func links(to peerID: PeerID?) -> Set<BLEIngressLinkID> {
        guard let peerID else { return [] }

        var links: Set<BLEIngressLinkID> = []
        if let peripheralUUID = peerToPeripheralUUID[peerID] {
            links.insert(.peripheral(peripheralUUID))
        }
        for (centralUUID, mappedPeerID) in centralToPeerID where mappedPeerID == peerID {
            links.insert(.central(centralUUID))
        }
        return links
    }

    func peerID(forPeripheralID peripheralID: String) -> PeerID? {
        peripherals[peripheralID]?.peerID
    }

    func peerID(forCentralUUID centralUUID: String) -> PeerID? {
        centralToPeerID[centralUUID]
    }

    func addSubscribedCentral(_ central: CBCentral) {
        guard !subscribedCentrals.contains(central) else { return }
        subscribedCentrals.append(central)
    }

    func removeSubscribedCentral(_ central: CBCentral) -> PeerID? {
        let centralUUID = central.identifier.uuidString
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        return centralToPeerID.removeValue(forKey: centralUUID)
    }

    func bindCentral(_ centralUUID: String, to peerID: PeerID) {
        centralToPeerID[centralUUID] = peerID
    }

    func bindPeripheral(_ peripheralUUID: String, to peerID: PeerID) {
        if updatePeripheral(peripheralUUID, { $0.peerID = peerID }) != nil {
            peerToPeripheralUUID[peerID] = peripheralUUID
        }
    }

    func removePeripheral(_ peripheralID: String) -> PeerID? {
        let peerID = peripherals.removeValue(forKey: peripheralID)?.peerID
        if let peerID {
            peerToPeripheralUUID.removeValue(forKey: peerID)
        }
        return peerID
    }

    func clearPeripherals() -> [PeerID] {
        let peerIDs = peripherals.compactMap { $0.value.peerID }
        peripherals.removeAll()
        peerToPeripheralUUID.removeAll()
        return peerIDs
    }

    func clearCentrals() -> [PeerID] {
        let peerIDs = Array(centralToPeerID.values)
        subscribedCentrals.removeAll()
        centralToPeerID.removeAll()
        return peerIDs
    }

    func clearAll() {
        peripherals.removeAll()
        peerToPeripheralUUID.removeAll()
        subscribedCentrals.removeAll()
        centralToPeerID.removeAll()
    }
}
