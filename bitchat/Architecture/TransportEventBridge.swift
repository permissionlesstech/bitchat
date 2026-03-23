import CoreBluetooth
import Foundation

final class TransportEventBridge: BitchatDelegate, TransportPeerEventsDelegate {
    private let transportCore: BLETransportCore

    init(transportCore: BLETransportCore) {
        self.transportCore = transportCore
    }

    func didReceiveMessage(_ message: BitchatMessage) {
        emit(.messageReceived(message))
    }

    func didConnectToPeer(_ peerID: PeerID) {
        emit(.connected(peerID))
    }

    func didDisconnectFromPeer(_ peerID: PeerID) {
        emit(.disconnected(peerID))
    }

    func didUpdatePeerList(_ peers: [PeerID]) {
        emit(.peerListUpdated(peers))
    }

    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        emit(.messageDeliveryStatusUpdated(messageID: messageID, status: status))
    }

    func didReceiveNoisePayload(from peerID: PeerID, type: NoisePayloadType, payload: Data, timestamp: Date) {
        emit(.noisePayloadReceived(peerID: peerID, type: type, payload: payload, timestamp: timestamp))
    }

    func didUpdateBluetoothState(_ state: CBManagerState) {
        emit(.bluetoothStateUpdated(state))
    }

    func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?) {
        emit(
            .publicMessageReceived(
                peerID: peerID,
                nickname: nickname,
                content: content,
                timestamp: timestamp,
                messageID: messageID
            )
        )
    }

    @MainActor
    func didUpdatePeerSnapshots(_ peers: [TransportPeerSnapshot]) {
        emit(.peerSnapshotsUpdated(peers))
    }
}

private extension TransportEventBridge {
    func emit(_ event: TransportEvent) {
        Task {
            await transportCore.emit(event)
        }
    }
}
