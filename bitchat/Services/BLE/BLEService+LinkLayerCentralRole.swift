//
// BLEService+LinkLayerCentralRole.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import CoreBluetooth
import Foundation

// The bleQueue half of the link layer: CoreBluetooth delegate callbacks do
// physical bookkeeping (link-state store, buffers, radio policy) and report
// everything else to the engine through the link-event port
// (BLELinkEvent / emitLinkEvent). See docs/BLE-ARCHITECTURE-V3.md.

// MARK: - CBCentralManagerDelegate

extension BLEService: CBCentralManagerDelegate {
    #if os(iOS)
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restoredPeripherals = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        guard !isPanicSuspended else {
            central.stopScan()
            restoredPeripherals.forEach {
                central.cancelPeripheralConnection($0)
            }
            return
        }
        let restoredServices = (dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID]) ?? []
        let restoredOptions = (dict[CBCentralManagerRestoredStateScanOptionsKey] as? [String: Any]) ?? [:]
        let allowDuplicates = restoredOptions[CBCentralManagerScanOptionAllowDuplicatesKey] as? Bool

        SecureLogger.info(
            "♻️ Central restore: peripherals=\(restoredPeripherals.count) services=\(restoredServices.count) allowDuplicates=\(String(describing: allowDuplicates))",
            category: .session
        )

        for peripheral in restoredPeripherals {
            let identifier = peripheral.identifier.uuidString
            peripheral.delegate = self
            let existing = linkStateStore.state(forPeripheralID: identifier)
            let assembler = existing?.assembler ?? NotificationStreamAssembler()
            let characteristic = existing?.characteristic
            let wasConnecting = existing?.isConnecting ?? false
            let wasConnected = existing?.isConnected ?? false

            let restoredState = BLEPeripheralLinkState(
                peripheral: peripheral,
                characteristic: characteristic,
                isConnecting: wasConnecting || peripheral.state == .connecting,
                isConnected: wasConnected || peripheral.state == .connected,
                lastConnectionAttempt: existing?.lastConnectionAttempt,
                assembler: assembler
            )
            linkStateStore.setPeripheralState(restoredState, for: identifier)

            // Restored peripherals are the freshest wake-on-proximity
            // candidates we have after a relaunch — without this the cache
            // starts empty and backgrounding right after a restore arms
            // nothing. Service rediscovery for restored-connected links waits
            // for poweredOn: CoreBluetooth drops commands issued during
            // restoration (API MISUSE warnings).
            radio.recordRecentPeripheral(peripheral, peripheralID: identifier, at: Date())
        }

        // Via the sampler (not a direct capture): it refreshes the cached
        // background budget on main first, so the restore log shows the real
        // wake window instead of the init sentinel.
        logBluetoothStatus("central-restore")

        if central.state == .poweredOn {
            radio.startScanning()
        }
    }
    #endif

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emitTransportEvent(.bluetoothStateUpdated(central.state))

        switch central.state {
        case .poweredOn:
            guard !isPanicSuspended else {
                central.stopScan()
                return
            }
            // Links restored as connected have no characteristic in the new
            // process; without rediscovery they sit connected-but-unusable
            // until the peer disconnects. Runs here (not willRestoreState)
            // because commands issued before poweredOn are dropped.
            for state in linkStateStore.peripheralStates where state.isConnected
                && state.characteristic == nil
                && state.peripheral.state == .connected {
                SecureLogger.info("♻️ Rediscovering services on restored link: \(state.peripheral.identifier.uuidString.prefix(8))…", category: .session)
                state.peripheral.discoverServices([BLEService.serviceUUID])
            }

            // Start scanning - use allow duplicates for faster discovery when active
            radio.startScanning()

        case .poweredOff:
            // CoreBluetooth has already transitioned out of poweredOn. Do
            // not issue stop/cancel commands now; they are rejected as API
            // misuse. Retire our link state locally instead.
            SecureLogger.info("📴 Bluetooth powered off - cleaning up central state", category: .session)
            let peripheralIDs = linkStateStore.peripheralStates.map { $0.peripheral.identifier.uuidString }
            for peripheralID in peripheralIDs {
                pendingPeripheralWrites.discardAll(for: peripheralID)
            }
            linkStateStore.clearPeripherals()
            emitLinkEvent(.allPeripheralLinksEnded(peripheralIDs: peripheralIDs, retireProofsAndNotify: true))

        case .unauthorized:
            // User denied Bluetooth permission
            SecureLogger.warning("🚫 Bluetooth unauthorized - user denied permission", category: .session)
            linkStateStore.clearPeripherals()
            emitLinkEvent(.allPeripheralLinksEnded(peripheralIDs: [], retireProofsAndNotify: false))

        case .unsupported:
            // Device doesn't support BLE
            SecureLogger.error("❌ Bluetooth LE not supported on this device", category: .session)

        case .resetting:
            // Bluetooth stack is resetting - will get another state update when done
            SecureLogger.info("🔄 Bluetooth stack resetting...", category: .session)

        case .unknown:
            // Initial state before we know the actual state
            SecureLogger.debug("❓ Bluetooth state unknown (initializing)", category: .session)

        @unknown default:
            SecureLogger.warning("⚠️ Unknown Bluetooth state: \(central.state.rawValue)", category: .session)
        }
    }
    
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        radio.handleDiscovery(peripheral, advertisementData: advertisementData, rssi: RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !isPanicSuspended else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        let peripheralID = peripheral.identifier.uuidString

        #if os(iOS)
        // A connect completing while backgrounded is the wake-on-proximity
        // path doing its job — worth an info line for field verification.
        if !isAppActive {
            SecureLogger.info("🌙 Background wake: connected to \(peripheral.name ?? peripheralID) while backgrounded", category: .session)
        }
        #endif

        // Update state to connected
        linkStateStore.markConnected(peripheral)
        
        // Reset backoff state on success
        radio.recordConnectionSuccess(peripheralID: peripheralID)

        SecureLogger.debug("✅ Connected: \(peripheral.name ?? "Unknown") [\(peripheralID)]", category: .session)
        
        // Discover services
        peripheral.discoverServices([BLEService.serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let peripheralID = peripheral.identifier.uuidString

        SecureLogger.debug("📱 Disconnect: \(peripheralID)\(error != nil ? " (\(error!.localizedDescription))" : "")", category: .session)

        // If disconnect carried an error (often timeout), apply short backoff to avoid thrash
        if error != nil {
            radio.recordDisconnectError(peripheralID: peripheralID, at: Date())
        }

        // Retain the handle: a dropped link is the best wake-on-proximity
        // candidate if the app backgrounds before the peer returns.
        radio.recordRecentPeripheral(peripheral, peripheralID: peripheralID, at: Date())

        #if os(iOS)
        // Link lost while backgrounded (peer walked away): re-arm a pending
        // connect during this wake window so the peer's return wakes us again.
        // Delayed past the disconnect-settle window to avoid reconnect thrash
        // at range edge.
        if !isAppActive {
            bleQueue.asyncAfter(deadline: .now() + TransportConfig.bleDisconnectDiscoveryIgnoreSeconds) { [weak self] in
                guard let self, !self.isAppActive else { return }
                // Reserve 0: use the slot this disconnect freed even in a
                // dense mesh, so the lost peer can wake us when it returns.
                self.radio.armPendingBackgroundConnects(slotReserve: 0)
            }
        }
        #endif

        // Physical teardown now; identity retirement and peer-disconnect
        // bookkeeping ride the link-event port. The scan restart and
        // connect-slot refill below stay on bleQueue — they respond to
        // the physical drop regardless of remaining logical links.
        discardPeripheralLinkPhysical(peripheralID)
        emitLinkEvent(.peripheralLinkEnded(peripheralID: peripheralID, runPeerBookkeeping: true))

        // Restart scanning with allow duplicates for faster rediscovery
        if centralManager?.state == .poweredOn {
            // Stop and restart scanning to ensure we get fresh discovery events
            centralManager?.stopScan()
            bleQueue.asyncAfter(deadline: .now() + TransportConfig.bleRestartScanDelaySeconds) { [weak self] in
                self?.radio.startScanning()
            }
        }
        // Attempt to fill freed slot from queue
        bleQueue.async { [weak self] in self?.radio.tryConnectFromQueue() }
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let peripheralID = peripheral.identifier.uuidString

        // Clean up the references: physical now, identity via the port.
        discardPeripheralLinkPhysical(peripheralID)
        emitLinkEvent(.peripheralLinkEnded(peripheralID: peripheralID, runPeerBookkeeping: false))

        SecureLogger.error("❌ Failed to connect to peripheral: \(peripheral.name ?? "Unknown") [\(peripheralID)] - Error: \(error?.localizedDescription ?? "Unknown")", category: .session)
        radio.recordConnectionFailure(peripheralID: peripheralID)
        // Try next candidate
        bleQueue.async { [weak self] in self?.radio.tryConnectFromQueue() }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !isPanicSuspended else { return }
        if let error = error {
            SecureLogger.error("❌ Error discovering services for \(peripheral.name ?? "Unknown"): \(error.localizedDescription)", category: .session)
            // Retry service discovery after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard peripheral.state == .connected else { return }
                peripheral.discoverServices([BLEService.serviceUUID])
            }
            return
        }
        
        guard let services = peripheral.services else {
            SecureLogger.warning("⚠️ No services discovered for \(peripheral.name ?? "Unknown")", category: .session)
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
        guard !isPanicSuspended else { return }
        if let error = error {
            SecureLogger.error("❌ Error discovering characteristics for \(peripheral.name ?? "Unknown"): \(error.localizedDescription)", category: .session)
            return
        }
        
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == BLEService.characteristicUUID }) else {
            SecureLogger.warning("⚠️ No matching characteristic found for \(peripheral.name ?? "Unknown")", category: .session)
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
            SecureLogger.warning("⚠️ Characteristic doesn't support reliable writes (withResponse)!", category: .session)
        }
        
        // Store characteristic in our consolidated structure
        let peripheralID = peripheral.identifier.uuidString
        linkStateStore.updateCharacteristic(characteristic, forPeripheralID: peripheralID)
        
        // Subscribe for notifications
        if characteristic.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: characteristic)
            SecureLogger.debug("🔔 Subscribed to notifications from \(peripheral.name ?? "Unknown")", category: .session)
            
            // Send announce after subscription is confirmed (force send for new connection)
            engineScheduler.schedule(after: TransportConfig.blePostSubscribeAnnounceDelaySeconds) { [weak self] in
                self?.sendAnnounce(forceSend: true)
                // Try flushing any spooled directed packets now that we have a link
                self?.flushDirectedSpool()
            }
        } else {
            SecureLogger.warning("⚠️ Characteristic does not support notifications", category: .session)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !isPanicSuspended else { return }
        if let error = error {
            SecureLogger.error("❌ Error receiving notification: \(error.localizedDescription)", category: .session)
            return
        }
        
        guard let data = characteristic.value, !data.isEmpty else {
            SecureLogger.warning("⚠️ No data in notification", category: .session)
            return
        }

        bufferNotificationChunk(data, from: peripheral)
    }

    private func bufferNotificationChunk(_ chunk: Data, from peripheral: CBPeripheral) {
        let peripheralUUID = peripheral.identifier.uuidString

        var state = linkStateStore.state(forPeripheralID: peripheralUUID) ?? BLEPeripheralLinkState(
            peripheral: peripheral,
            characteristic: nil,
            isConnecting: false,
            isConnected: peripheral.state == .connected,
            lastConnectionAttempt: nil,
            assembler: NotificationStreamAssembler()
        )

        var assembler = state.assembler
        let result = assembler.append(chunk)
        state.assembler = assembler
        linkStateStore.setPeripheralState(state, for: peripheralUUID)

        for byte in result.droppedPrefixes {
            SecureLogger.warning("⚠️ Dropping byte from BLE stream (unexpected prefix \(String(format: "%02x", byte)))", category: .session)
        }

        if result.reset {
            SecureLogger.error("❌ Invalid BLE frame length; reset notification stream", category: .session)
        }
        
        // Attribution — spoof rejection, announce binding, ingress
        // recording — is engine work now (the engine owns the bindings).
        // Frames hop up in decode order; the engine's serial slot ordering
        // gives the same same-batch spoof protection the old bleQueue-side
        // batch-local binding enforced: an announce that binds this link is
        // attributed before every frame that rode behind it.
        for frame in result.frames {
            guard let packet = BinaryProtocol.decode(frame) else {
                let prefix = frame.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                SecureLogger.error("❌ Failed to decode assembled notification frame (len=\(frame.count), prefix=\(prefix))", category: .session)
                continue
            }
            emitLinkEvent(.frameDecoded(
                packet,
                link: .peripheral(peripheralUUID),
                linkDescription: "Peripheral \(peripheralUUID.prefix(8))…"
            ))
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            SecureLogger.error("❌ Write failed to \(peripheral.name ?? peripheral.identifier.uuidString): \(error.localizedDescription)", category: .session)
            // Don't retry - just log the error
        } else {
            SecureLogger.debug("✅ Write confirmed to \(peripheral.name ?? peripheral.identifier.uuidString)", category: .session)
        }
    }
    
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard !isPanicSuspended else { return }
        // Resume queued writes for this peripheral - called when canSendWriteWithoutResponse becomes true again
        if logRateLimiter.shouldLog(key: "peripheral-ready:\(peripheral.identifier.uuidString)") {
            SecureLogger.debug("📤 Peripheral \(peripheral.name ?? peripheral.identifier.uuidString.prefix(8).description) ready for more writes", category: .session)
        }
        drainPendingWrites(for: peripheral)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard !isPanicSuspended else { return }
        SecureLogger.warning("⚠️ Services modified for \(peripheral.name ?? peripheral.identifier.uuidString)", category: .session)

        let shouldRediscover = BLEService.shouldRediscoverBitChatService(
            invalidatedServiceUUIDs: invalidatedServices.map(\.uuid),
            cachedServiceUUIDs: peripheral.services?.map(\.uuid)
        )

        guard shouldRediscover else { return }

        let peripheralID = peripheral.identifier.uuidString
        linkStateStore.updatePeripheral(peripheralID) {
            $0.characteristic = nil
            $0.assembler = NotificationStreamAssembler()
        }

        SecureLogger.debug("🔄 BitChat service changed for \(peripheral.name ?? peripheral.identifier.uuidString), rediscovering", category: .session)
        peripheral.discoverServices([BLEService.serviceUUID])
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard !isPanicSuspended else { return }
        if let error = error {
            SecureLogger.error("❌ Error updating notification state: \(error.localizedDescription)", category: .session)
        } else {
            SecureLogger.debug("🔔 Notification state updated for \(peripheral.name ?? peripheral.identifier.uuidString): \(characteristic.isNotifying ? "ON" : "OFF")", category: .session)
            
            // If notifications are now on, send an announce to ensure this peer knows about us
            if characteristic.isNotifying {
                // Sending announce after subscription
                self.sendAnnounce(forceSend: true)
            }
        }
    }

}

extension BLEService {
    static func shouldRediscoverBitChatService(
        invalidatedServiceUUIDs: [CBUUID],
        cachedServiceUUIDs: [CBUUID]?
    ) -> Bool {
        invalidatedServiceUUIDs.contains(serviceUUID) || cachedServiceUUIDs?.contains(serviceUUID) != true
    }
}
