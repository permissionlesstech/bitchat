import BitFoundation
import CoreBluetooth
import Foundation

struct BLEPeripheralLinkState {
    let peripheral: CBPeripheral
    var characteristic: CBCharacteristic?
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

// BLEDirectLinkState and the identity↔link binding queries live on
// BLELinkBindings; this store owns only physical link state.

/// Owns the PHYSICAL BLE link state (peripheral connections we hold as
/// central, and central subscriptions we serve as peripheral) — CB object
/// handles, connect lifecycles, characteristics, and stream assemblers.
/// Identity↔link bindings live on `BLELinkBindings`. The store has no
/// internal locking: every access must happen on the single owning queue
/// (the BLE queue). Other queues must go through BLEService's
/// `readLinkState`, which hops to that queue. Call `assumeOwnership(of:)`
/// to have debug builds trap any access from the wrong queue.
final class BLELinkStateStore {
    private(set) var peripherals: [String: BLEPeripheralLinkState] = [:]
    private(set) var subscribedCentrals: [CBCentral] = []

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

    func addSubscribedCentral(_ central: CBCentral) {
        assertOwned()
        guard !subscribedCentrals.contains(central) else { return }
        subscribedCentrals.append(central)
    }

    func removeSubscribedCentral(_ central: CBCentral) {
        assertOwned()
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
    }

    func removePeripheral(_ peripheralID: String) {
        assertOwned()
        peripherals.removeValue(forKey: peripheralID)
    }

    func clearPeripherals() {
        assertOwned()
        peripherals.removeAll()
    }

    func clearCentrals() {
        assertOwned()
        subscribedCentrals.removeAll()
    }

    func clearAll() {
        assertOwned()
        peripherals.removeAll()
        subscribedCentrals.removeAll()
    }
}
