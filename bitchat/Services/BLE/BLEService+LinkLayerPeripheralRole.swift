//
// BLEService+LinkLayerPeripheralRole.swift
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

// MARK: - CBPeripheralManagerDelegate

extension BLEService: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        SecureLogger.debug("📡 Peripheral manager state: \(peripheral.state.rawValue)", category: .session)

        switch peripheral.state {
        case .poweredOn:
            guard !isPanicSuspended else {
                peripheral.stopAdvertising()
                peripheral.removeAllServices()
                characteristic = nil
                return
            }
            // Remove all services first to ensure clean state
            peripheral.removeAllServices()

            // Create characteristic
            characteristic = CBMutableCharacteristic(
                type: BLEService.characteristicUUID,
                properties: [.notify, .write, .writeWithoutResponse, .read],
                value: nil,
                permissions: [.readable, .writeable]
            )

            // Create service
            let service = CBMutableService(type: BLEService.serviceUUID, primary: true)
            service.characteristics = [characteristic!]

            // Add service (advertising will start in didAdd delegate)
            SecureLogger.debug("🔧 Adding BLE service...", category: .session)
            peripheral.add(service)

        case .poweredOff:
            // Bluetooth was turned off - clean up peripheral state
            SecureLogger.info("📴 Bluetooth powered off - cleaning up peripheral state", category: .session)
            // Clear subscribed centrals (they are now invalid)
            let centralIDs = linkStateStore.subscribedCentrals.map { $0.identifier.uuidString }
            pendingNotifications.removeAll()
            pendingWriteBuffers.removeAll()
            linkStateStore.clearCentrals()
            subscriptionAnnounceLimiter.removeAll()
            characteristic = nil
            emitLinkEvent(.allCentralLinksEnded(centralUUIDs: centralIDs, retireProofsAndNotify: true))

        case .unauthorized:
            // User denied Bluetooth permission
            SecureLogger.warning("🚫 Bluetooth unauthorized for peripheral role", category: .session)
            linkStateStore.clearCentrals()
            subscriptionAnnounceLimiter.removeAll()
            characteristic = nil
            emitLinkEvent(.allCentralLinksEnded(centralUUIDs: [], retireProofsAndNotify: false))

        case .unsupported:
            // Device doesn't support BLE peripheral role
            SecureLogger.error("❌ Bluetooth LE peripheral role not supported", category: .session)

        case .resetting:
            // Bluetooth stack is resetting
            SecureLogger.info("🔄 Bluetooth peripheral stack resetting...", category: .session)

        case .unknown:
            SecureLogger.debug("❓ Peripheral Bluetooth state unknown (initializing)", category: .session)

        @unknown default:
            SecureLogger.warning("⚠️ Unknown peripheral Bluetooth state: \(peripheral.state.rawValue)", category: .session)
        }
    }
    
    #if os(iOS)
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        guard !isPanicSuspended else {
            peripheral.stopAdvertising()
            peripheral.removeAllServices()
            characteristic = nil
            return
        }
        let restoredServices = (dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService]) ?? []
        let restoredAdvertisement = (dict[CBPeripheralManagerRestoredStateAdvertisementDataKey] as? [String: Any]) ?? [:]

        SecureLogger.info(
            "♻️ Peripheral restore: services=\(restoredServices.count) advertisingDataKeys=\(Array(restoredAdvertisement.keys))",
            category: .session
        )

        // Attempt to recover characteristic from restored services
        if characteristic == nil {
            if let service = restoredServices.first(where: { $0.uuid == BLEService.serviceUUID }),
               let restoredCharacteristic = service.characteristics?.first(where: { $0.uuid == BLEService.characteristicUUID }) as? CBMutableCharacteristic {
                characteristic = restoredCharacteristic
            }
        }

        // Via the sampler for a fresh background budget (see central-restore).
        logBluetoothStatus("peripheral-restore")

        if peripheral.state == .poweredOn && !peripheral.isAdvertising {
            peripheral.startAdvertising(BLERadioController.advertisementData())
        }
    }
    #endif
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard !isPanicSuspended else {
            peripheral.stopAdvertising()
            return
        }
        if let error = error {
            SecureLogger.error("❌ Failed to add service: \(error.localizedDescription)", category: .session)
            return
        }
        
        SecureLogger.debug("✅ Service added successfully, starting advertising", category: .session)
        
        // Start advertising after service is confirmed added
        let adData = BLERadioController.advertisementData()
        peripheral.startAdvertising(adData)
        
        SecureLogger.debug("📡 Started advertising (LocalName: \((adData[CBAdvertisementDataLocalNameKey] as? String) != nil ? "on" : "off"), ID: \(myPeerID.id.prefix(8))…)", category: .session)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard !isPanicSuspended else { return }
        let centralUUID = central.identifier.uuidString
        SecureLogger.debug("📥 Central subscribed: \(centralUUID.prefix(8))…", category: .session)
        linkStateStore.addSubscribedCentral(central)

        // BCH-01-004: Rate-limit subscription-triggered announces to prevent enumeration attacks
        let now = Date()
        switch subscriptionAnnounceLimiter.decision(for: centralUUID, now: now) {
        case .allowed:
            break
        case let .rateLimited(backoffSeconds, attemptCount, suppressAnnounce):
            SecureLogger.warning("🛡️ BCH-01-004: Rate-limited announce for central \(centralUUID.prefix(8))... (backoff: \(Int(backoffSeconds))s, attempts: \(attemptCount))", category: .security)
            if suppressAnnounce {
                SecureLogger.warning("🚨 BCH-01-004: Possible enumeration attack from central \(centralUUID.prefix(8))... - suppressing announce", category: .security)
                return
            }

            // Still flush directed packets for legitimate mesh operation
            engineScheduler.schedule(after: TransportConfig.blePostAnnounceDelaySeconds) { [weak self] in
                self?.flushDirectedSpool()
            }
            return
        }

        // Send announce to the newly subscribed central after a small delay
        engineScheduler.schedule(after: TransportConfig.blePostAnnounceDelaySeconds) { [weak self] in
            self?.sendAnnounce(forceSend: true)
            // Flush any spooled directed packets now that we have a central subscribed
            self?.flushDirectedSpool()
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        let centralID = central.identifier.uuidString
        SecureLogger.debug("📤 Central unsubscribed: \(centralID.prefix(8))…", category: .session)
        // bleQueue: physical retirement now.
        pendingNotifications.removeTarget { $0.identifier.uuidString == centralID }
        linkStateStore.removeSubscribedCentral(central)

        // Ensure we're still advertising for other devices to find us
        if !isPanicSuspended, peripheral.isAdvertising == false {
            SecureLogger.debug("📡 Restarting advertising after central unsubscribed", category: .session)
            peripheral.startAdvertising(BLERadioController.advertisementData())
        }

        // Identity retirement and peer-disconnect bookkeeping ride the
        // link-event port.
        emitLinkEvent(.centralLinkEnded(centralUUID: centralID))
    }
    
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard !isPanicSuspended else { return }
        drainPendingNotifications(logPrefix: "✅ Sent")
    }

    func logBackpressureSampled(_ message: @autoclosure () -> String) {
        notificationBackpressureLogCount += 1
        if notificationBackpressureLogCount == 1 ||
            notificationBackpressureLogCount.isMultiple(of: TransportConfig.bleBackpressureLogInterval) {
            SecureLogger.debug("\(message()) [backpressure event #\(notificationBackpressureLogCount)]", category: .session)
        }
    }

    func drainPendingNotifications(logPrefix: String) {
        bleQueue.async { [weak self] in
            guard let self = self,
                  let characteristic = self.characteristic,
                  !self.pendingNotifications.isEmpty else { return }

            let pending = self.pendingNotifications.takeAll()
            let sentCount = self.sendPendingNotifications(pending, characteristic: characteristic)

            if sentCount > 0 {
                self.logBackpressureSampled("\(logPrefix) \(sentCount) pending notifications from retry queue (\(self.pendingNotifications.count) still pending)")
            }
        }
    }

    private func sendPendingNotifications(_ pending: [BLEPendingNotification<CBCentral>], characteristic: CBMutableCharacteristic) -> Int {
        var sentCount = 0

        for (index, notification) in pending.enumerated() {
            let success = peripheralManager?.updateValue(
                notification.data,
                for: characteristic,
                onSubscribedCentrals: notification.targets
            ) ?? false

            guard success else {
                let remaining = Array(pending.dropFirst(index))
                pendingNotifications.prepend(remaining)
                logBackpressureSampled("⚠️ Notification queue still full after \(sentCount) sent, re-queuing \(remaining.count) items")
                break
            }

            sentCount += 1
        }

        return sentCount
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Suppress logs for single write requests to reduce noise
        if requests.count > 1 {
            SecureLogger.debug("📥 Received \(requests.count) write requests from central", category: .session)
        }
        
        // IMPORTANT: Respond immediately to prevent timeouts!
        // We must respond within a few milliseconds or the central will timeout
        for request in requests {
            peripheral.respond(to: request, withResult: .success)
        }
        guard !isPanicSuspended else { return }
        
        // Process writes. For long writes, CoreBluetooth may deliver multiple CBATTRequest values with offsets.
        // Combine per-central request values by offset before decoding.
        // Process directly on our message queue to match transport context
        let grouped = Dictionary(grouping: requests, by: { $0.central.identifier.uuidString })
        for (centralUUID, group) in grouped {
            // Sort by offset ascending
            let sorted = group.sorted { $0.offset < $1.offset }
            let hasMultiple = sorted.count > 1 || (sorted.first?.offset ?? 0) > 0
            let chunks = sorted.compactMap { request -> BLEInboundWriteChunk? in
                guard let data = request.value, !data.isEmpty else { return nil }
                return BLEInboundWriteChunk(offset: request.offset, data: data)
            }

            let result = pendingWriteBuffers.append(
                chunks: chunks,
                for: centralUUID,
                capBytes: TransportConfig.blePendingWriteBufferCapBytes
            )

            switch result {
            case let .decoded(packet, metadata):
                logAccumulatedCentralWrite(metadata, centralUUID: centralUUID)
                processDecodedCentralWrite(packet, centralUUID: centralUUID, central: sorted[0].central)

            case let .waiting(metadata):
                logAccumulatedCentralWrite(metadata, centralUUID: centralUUID)
                logFailedSingleWriteIfNeeded(hasMultiple: hasMultiple, sortedRequests: sorted)

            case let .oversized(metadata):
                logAccumulatedCentralWrite(metadata, centralUUID: centralUUID)
                SecureLogger.warning("⚠️ Dropping oversized pending write buffer (\(metadata.accumulatedBytes) bytes) for central \(centralUUID.prefix(8))…", category: .session)
                logFailedSingleWriteIfNeeded(hasMultiple: hasMultiple, sortedRequests: sorted)
            }
        }
    }

    private func logAccumulatedCentralWrite(_ metadata: BLEInboundWriteAppendMetadata, centralUUID: String) {
        guard let packetType = metadata.packetType,
              packetType != MessageType.announce.rawValue else { return }

        SecureLogger.debug(
            "📥 Accumulated write from central \(centralUUID.prefix(8))…: size=\(metadata.accumulatedBytes) (+\(metadata.appendedBytes)) bytes (type=\(packetType)), offsets=\(metadata.offsets)",
            category: .session
        )
    }

    private func logFailedSingleWriteIfNeeded(hasMultiple: Bool, sortedRequests: [CBATTRequest]) {
        guard !hasMultiple, let raw = sortedRequests.first?.value else { return }

        let prefix = raw.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
        SecureLogger.error("❌ Failed to decode packet from central (len=\(raw.count), prefix=\(prefix))", category: .session)
    }

    private func processDecodedCentralWrite(_ packet: BitchatPacket, centralUUID: String, central: CBCentral) {
        // bleQueue: physical bookkeeping only. A writer is a live central
        // whether or not it subscribed; track it so directed replies and
        // the fanout planner can reach it.
        linkStateStore.addSubscribedCentral(central)
        // Attribution is engine work (the engine owns the bindings).
        emitLinkEvent(.frameDecoded(
            packet,
            link: .central(centralUUID),
            linkDescription: "Central \(centralUUID.prefix(8))…"
        ))
    }
}
