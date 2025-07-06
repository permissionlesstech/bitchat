//
// WiFiDirectTransport.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import MultipeerConnectivity

// Note: hexEncodedString extension is already defined in BluetoothMeshService

// MARK: - WiFi Direct Transport

class WiFiDirectTransport: NSObject, TransportProtocol {
    
    // MARK: - Properties
    
    let transportType: TransportType = .wifiDirect
    
    var isAvailable: Bool {
        return true  // MultipeerConnectivity is always available on iOS/macOS
    }
    
    var currentPeers: [PeerInfo] {
        return connectedPeers.map { (peerID, session) in
            PeerInfo(
                peerID: peerID.displayName,
                nickname: peerNicknames[peerID.displayName],
                publicKey: peerPublicKeys[peerID.displayName],
                transportTypes: [.wifiDirect],
                rssi: nil,  // WiFi Direct doesn't provide RSSI
                lastSeen: Date()
            )
        }
    }
    
    let capabilities = TransportCapabilities(
        maxMessageSize: 100 * 1024 * 1024,  // 100MB
        averageBandwidth: 25_000_000,        // ~200 Mbps = 25MB/s
        typicalRange: 100,                   // 100 meters typical
        powerConsumption: .high
    )
    
    weak var delegate: TransportDelegate?
    
    // Private properties
    private let serviceType = "bitchat-wifi"
    private var myPeerID: MCPeerID!
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!
    
    private var connectedPeers: [MCPeerID: MCSession] = [:]
    private var peerNicknames: [String: String] = [:]
    private var peerPublicKeys: [String: Data] = [:]
    private let sessionQueue = DispatchQueue(label: "bitchat.wifidirect", attributes: .concurrent)
    
    // Message handling
    private var messageHandlers: [String: (Data) -> Void] = [:]
    private var pendingMessages: [String: Data] = [:]
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        setupMultipeerConnectivity()
    }
    
    private func setupMultipeerConnectivity() {
        // Create peer ID with device name or stored ID
        let displayName = UserDefaults.standard.string(forKey: "bitchat.deviceName") ?? getDeviceName()
        myPeerID = MCPeerID(displayName: displayName)
        
        // Create session
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        
        // Create advertiser
        let discoveryInfo = ["bitchat": "1.0"]
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: discoveryInfo, serviceType: serviceType)
        advertiser.delegate = self
        
        // Create browser
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser.delegate = self
    }
    
    // MARK: - TransportProtocol Implementation
    
    func startDiscovery() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }
    
    func stopDiscovery() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
    }
    
    func send(_ packet: BitchatPacket, to peerID: String?) throws {
        // Encode packet
        let encoder = JSONEncoder()
        let data = try encoder.encode(packet)
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            if let peerID = peerID {
                // Unicast
                if let mcPeerID = self.findMCPeerID(for: peerID) {
                    do {
                        try self.session.send(data, toPeers: [mcPeerID], with: .reliable)
                    } catch {
                        // Generate a message ID from packet data
                        let messageID = "\(packet.timestamp)-\(packet.senderID.prefix(8).hexEncodedString())"
                        self.delegate?.transport(self, didFailToSend: messageID, to: peerID, error: error)
                    }
                } else {
                    // Generate a message ID from packet data
                    let messageID = "\(packet.timestamp)-\(packet.senderID.prefix(8).hexEncodedString())"
                    self.delegate?.transport(self, didFailToSend: messageID, to: peerID, error: TransportError.peerNotFound(peerID))
                }
            } else {
                // Broadcast
                let peers = self.session.connectedPeers
                if !peers.isEmpty {
                    do {
                        try self.session.send(data, toPeers: peers, with: .reliable)
                    } catch {
                        // Handle broadcast failure
                    }
                }
            }
        }
    }
    
    func connect(to peerID: String) throws {
        // MultipeerConnectivity handles connection automatically during discovery
        // This is mainly for explicit connection requests
    }
    
    func disconnect(from peerID: String) {
        sessionQueue.async { [weak self] in
            if let mcPeerID = self?.findMCPeerID(for: peerID) {
                self?.session.cancelConnectPeer(mcPeerID)
            }
        }
    }
    
    func start() {
        // MultipeerConnectivity is initialized in init
        startDiscovery()
    }
    
    func stop() {
        stopDiscovery()
        session.disconnect()
    }
    
    func requestHighBandwidth(for peerID: String) -> Bool {
        // WiFi Direct is already high bandwidth
        return true
    }
    
    func getConnectionQuality(for peerID: String) -> ConnectionQuality? {
        guard findMCPeerID(for: peerID) != nil else { return nil }
        
        return ConnectionQuality(
            rssi: nil,  // Not available for WiFi Direct
            packetLoss: 0.01,  // ~1% typical for WiFi
            averageLatency: 0.002,  // ~2ms typical for WiFi
            bandwidth: 25_000_000  // 200 Mbps
        )
    }
    
    // MARK: - Helper Methods
    
    private func findMCPeerID(for displayName: String) -> MCPeerID? {
        return session.connectedPeers.first { $0.displayName == displayName }
    }
    
    private func handleReceivedData(_ data: Data, from peerID: MCPeerID) {
        do {
            let decoder = JSONDecoder()
            let packet = try decoder.decode(BitchatPacket.self, from: data)
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.transport(self, didReceivePacket: packet, from: peerID.displayName)
            }
        } catch {
            // Handle decode error
        }
    }
}

// MARK: - MCSessionDelegate

extension WiFiDirectTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            switch state {
            case .connected:
                let peer = PeerInfo(
                    peerID: peerID.displayName,
                    nickname: nil,
                    publicKey: nil,
                    transportTypes: [.wifiDirect],
                    rssi: nil,
                    lastSeen: Date()
                )
                self.delegate?.transport(self, didDiscoverPeer: peer)
                
            case .notConnected:
                self.delegate?.transport(self, didLosePeer: peerID.displayName)
                
            case .connecting:
                break
                
            @unknown default:
                break
            }
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        handleReceivedData(data, from: peerID)
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Handle stream if needed for large file transfers
    }
    
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        // Handle resource transfer if needed
    }
    
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // Handle completed resource transfer
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension WiFiDirectTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Auto-accept invitations
        invitationHandler(true, session)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension WiFiDirectTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        // Invite peer to session
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // Peer is no longer available
    }
}

// MARK: - Platform Compatibility

extension WiFiDirectTransport {
    private func getDeviceName() -> String {
        #if os(iOS)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #endif
    }
}

#if os(macOS)
import AppKit
#endif