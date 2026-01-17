//
// MockTransport.swift
// bitchatTests
//
// Mock Transport implementation for unit testing ChatViewModel.
// This is free and unencumbered software released into the public domain.
//

import Foundation
import Combine
import CoreBluetooth
@testable import bitchat

/// Mock Transport implementation for testing ChatViewModel in isolation.
/// Records all method calls and allows test code to verify interactions.
final class MockTransport: Transport {

    // MARK: - Protocol Properties

    weak var delegate: BitchatDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?

    var myPeerID: PeerID = PeerID(str: "TESTPEER")
    var myNickname: String = "TestUser"

    private let peerSnapshotSubject = CurrentValueSubject<[TransportPeerSnapshot], Never>([])
    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
        peerSnapshotSubject.eraseToAnyPublisher()
    }

    // MARK: - Recording Properties (for test assertions)

    private(set) var sentMessages: [(content: String, mentions: [String], messageID: String?, timestamp: Date?)] = []
    private(set) var sentPrivateMessages: [(content: String, peerID: PeerID, recipientNickname: String, messageID: String)] = []
    private(set) var sentReadReceipts: [(receipt: ReadReceipt, peerID: PeerID)] = []
    private(set) var sentDeliveryAcks: [(messageID: String, peerID: PeerID)] = []
    private(set) var sentFavoriteNotifications: [(peerID: PeerID, isFavorite: Bool)] = []
    private(set) var sentVerifyChallenges: [(peerID: PeerID, noiseKeyHex: String, nonceA: Data)] = []
    private(set) var sentVerifyResponses: [(peerID: PeerID, noiseKeyHex: String, nonceA: Data)] = []
    private(set) var startServicesCallCount = 0
    private(set) var stopServicesCallCount = 0
    private(set) var emergencyDisconnectCallCount = 0
    private(set) var broadcastAnnounceCallCount = 0
    private(set) var triggeredHandshakes: [PeerID] = []

    // MARK: - Configurable Mock State

    var connectedPeers: Set<PeerID> = []
    var reachablePeers: Set<PeerID> = []
    var peerNicknames: [PeerID: String] = [:]
    var peerFingerprints: [PeerID: String] = [:]
    var peerNoiseStates: [PeerID: LazyHandshakeState] = [:]
    private let mockKeychain = MockKeychain()

    // MARK: - Transport Protocol Implementation

    func currentPeerSnapshots() -> [TransportPeerSnapshot] {
        peerSnapshotSubject.value
    }

    func setNickname(_ nickname: String) {
        myNickname = nickname
    }

    func startServices() {
        startServicesCallCount += 1
    }

    func stopServices() {
        stopServicesCallCount += 1
    }

    func emergencyDisconnectAll() {
        emergencyDisconnectCallCount += 1
        connectedPeers.removeAll()
        reachablePeers.removeAll()
    }

    func isPeerConnected(_ peerID: PeerID) -> Bool {
        connectedPeers.contains(peerID)
    }

    func isPeerReachable(_ peerID: PeerID) -> Bool {
        reachablePeers.contains(peerID) || connectedPeers.contains(peerID)
    }

    func peerNickname(peerID: PeerID) -> String? {
        peerNicknames[peerID]
    }

    func getPeerNicknames() -> [PeerID: String] {
        peerNicknames
    }

    func getFingerprint(for peerID: PeerID) -> String? {
        peerFingerprints[peerID]
    }

    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState {
        peerNoiseStates[peerID] ?? .none
    }

    func triggerHandshake(with peerID: PeerID) {
        triggeredHandshakes.append(peerID)
    }

    func getNoiseService() -> NoiseEncryptionService {
        NoiseEncryptionService(keychain: mockKeychain)
    }

    // MARK: - Messaging

    func sendMessage(_ content: String, mentions: [String]) {
        sentMessages.append((content, mentions, nil, nil))
    }

    func sendMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date) {
        sentMessages.append((content, mentions, messageID, timestamp))
    }

    func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        sentPrivateMessages.append((content, peerID, recipientNickname, messageID))
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        sentReadReceipts.append((receipt, peerID))
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        sentFavoriteNotifications.append((peerID, isFavorite))
    }

    func sendBroadcastAnnounce() {
        broadcastAnnounceCallCount += 1
    }

    func sendDeliveryAck(for messageID: String, to peerID: PeerID) {
        sentDeliveryAcks.append((messageID, peerID))
    }

    func sendFileBroadcast(_ packet: BitchatFilePacket, transferId: String) {
        // Not tracked for current tests
    }

    func sendFilePrivate(_ packet: BitchatFilePacket, to peerID: PeerID, transferId: String) {
        // Not tracked for current tests
    }

    func cancelTransfer(_ transferId: String) {
        // Not tracked for current tests
    }

    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        sentVerifyChallenges.append((peerID, noiseKeyHex, nonceA))
    }

    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        sentVerifyResponses.append((peerID, noiseKeyHex, nonceA))
    }

    // MARK: - Test Helpers

    /// Clears all recorded method calls for fresh assertions
    func resetRecordings() {
        sentMessages.removeAll()
        sentPrivateMessages.removeAll()
        sentReadReceipts.removeAll()
        sentDeliveryAcks.removeAll()
        sentFavoriteNotifications.removeAll()
        sentVerifyChallenges.removeAll()
        sentVerifyResponses.removeAll()
        startServicesCallCount = 0
        stopServicesCallCount = 0
        emergencyDisconnectCallCount = 0
        broadcastAnnounceCallCount = 0
        triggeredHandshakes.removeAll()
    }

    /// Simulates a peer connecting
    func simulateConnect(_ peerID: PeerID, nickname: String? = nil) {
        connectedPeers.insert(peerID)
        if let nickname = nickname {
            peerNicknames[peerID] = nickname
        }
        delegate?.didConnectToPeer(peerID)
        delegate?.didUpdatePeerList(Array(connectedPeers))
        publishPeerSnapshots()
    }

    /// Simulates a peer disconnecting
    func simulateDisconnect(_ peerID: PeerID) {
        connectedPeers.remove(peerID)
        peerNicknames.removeValue(forKey: peerID)
        delegate?.didDisconnectFromPeer(peerID)
        delegate?.didUpdatePeerList(Array(connectedPeers))
        publishPeerSnapshots()
    }

    /// Simulates receiving a message
    func simulateIncomingMessage(_ message: BitchatMessage) {
        delegate?.didReceiveMessage(message)
    }

    /// Simulates receiving a public message
    func simulateIncomingPublicMessage(
        from peerID: PeerID,
        nickname: String,
        content: String,
        timestamp: Date = Date(),
        messageID: String? = nil
    ) {
        delegate?.didReceivePublicMessage(
            from: peerID,
            nickname: nickname,
            content: content,
            timestamp: timestamp,
            messageID: messageID
        )
    }

    /// Simulates Bluetooth state change
    func simulateBluetoothStateChange(_ state: CBManagerState) {
        delegate?.didUpdateBluetoothState(state)
    }

    /// Updates the peer snapshot publisher
    func updatePeerSnapshots(_ snapshots: [TransportPeerSnapshot]) {
        peerSnapshotSubject.send(snapshots)
        Task { @MainActor [weak self] in
            self?.peerEventsDelegate?.didUpdatePeerSnapshots(snapshots)
        }
    }

    private func publishPeerSnapshots() {
        let now = Date()
        let snapshots = connectedPeers.map { peerID in
            TransportPeerSnapshot(
                peerID: peerID,
                nickname: peerNicknames[peerID] ?? "",
                isConnected: true,
                noisePublicKey: Data(hexString: peerID.bare),
                lastSeen: now
            )
        }
        updatePeerSnapshots(snapshots)
    }
}
