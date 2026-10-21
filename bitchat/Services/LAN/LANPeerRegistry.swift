//
// LANPeerRegistry.swift
// bitchat
//
// Peer state machine for the Wi-Fi LAN transport.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

/// Lifecycle state of a peer seen on the local network.
enum LANPeerState: String, Equatable, Sendable {
    /// The peer was found (Bonjour advertisement or inbound connection) but
    /// no identity exchange happened yet.
    case discovered
    /// The Noise handshake is running over the LAN link.
    case handshaking
    /// The Noise session is established; payloads can be exchanged.
    case authenticated
    /// The link was closed (locally, remotely, or by the peer leaving).
    case disconnected
    /// The peer stopped answering before it could be authenticated.
    case timedOut

    /// Whether the peer can currently carry encrypted payloads.
    var isAuthenticated: Bool { self == .authenticated }

    /// Whether the peer is still expected to become usable.
    var isPending: Bool { self == .discovered || self == .handshaking }
}

/// A peer known to the LAN transport.
struct LANPeer: Equatable, Identifiable, Sendable {
    let peerID: PeerID
    var nickname: String
    var state: LANPeerState
    /// Noise static public key of the peer, once the identity exchange
    /// completed. This is the same key the BLE mesh uses, so the peer keeps
    /// one identity (and one fingerprint) across transports.
    var noisePublicKey: Data?
    /// Ed25519 key that signs this peer's packets, learned from its hello.
    /// Used to authenticate public LAN messages independently of the TCP
    /// link they arrived on.
    var signingPublicKey: Data?
    /// Human readable description of the remote endpoint (for logs).
    var endpointDescription: String?
    /// Last time we heard anything from this peer.
    var lastSeen: Date
    /// Last time the state changed.
    var stateChangedAt: Date
    /// Whether the identity exchange was signature-verified.
    var isVerified: Bool

    var id: PeerID { peerID }
}

/// Tracks the LAN peers and their lifecycle.
///
/// The registry is a pure state machine: it has no networking dependency and
/// no clock of its own — every mutation takes an explicit `now`, which keeps
/// it deterministic and unit-testable.
final class LANPeerRegistry {
    /// Timeout table for the state machine.
    struct Timeouts: Equatable {
        /// How long a peer may stay `discovered` before it is expired.
        var discovery: TimeInterval = LANTransportConfig.discoveryTimeout
        /// How long the Noise handshake may take.
        var handshake: TimeInterval = LANTransportConfig.handshakeTimeout
        /// How long an authenticated peer may stay silent.
        var idle: TimeInterval = LANTransportConfig.idleTimeout
        /// Maximum number of tracked peers.
        var capacity: Int = LANTransportConfig.maxConcurrentPeers

        static let standard = Timeouts()
    }

    private(set) var peers: [PeerID: LANPeer] = [:]
    private let timeouts: Timeouts

    init(timeouts: Timeouts = .standard) {
        self.timeouts = timeouts
    }

    /// Current state of a peer, if it is known.
    func state(of peerID: PeerID) -> LANPeerState? {
        peers[peerID]?.state
    }

    /// All peers that completed the Noise handshake.
    func authenticatedPeers() -> [LANPeer] {
        peers.values.filter { $0.state.isAuthenticated }
    }

    /// Record (or refresh) a discovered peer.
    ///
    /// A peer that is already authenticated is never downgraded: a repeated
    /// advertisement only refreshes its metadata.
    @discardableResult
    func discover(
        peerID: PeerID,
        nickname: String? = nil,
        noisePublicKey: Data? = nil,
        signingPublicKey: Data? = nil,
        endpointDescription: String? = nil,
        now: Date
    ) -> LANPeer? {
        if var existing = peers[peerID] {
            if let nickname, !nickname.isEmpty { existing.nickname = nickname }
            if let noisePublicKey { existing.noisePublicKey = noisePublicKey }
            if let signingPublicKey { existing.signingPublicKey = signingPublicKey }
            if let endpointDescription { existing.endpointDescription = endpointDescription }
            existing.lastSeen = now
            if existing.state == .disconnected || existing.state == .timedOut {
                existing.state = .discovered
                existing.stateChangedAt = now
            }
            peers[peerID] = existing
            return existing
        }

        guard peers.count < timeouts.capacity else { return nil }

        let peer = LANPeer(
            peerID: peerID,
            nickname: nickname ?? "",
            state: .discovered,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            endpointDescription: endpointDescription,
            lastSeen: now,
            stateChangedAt: now,
            isVerified: false
        )
        peers[peerID] = peer
        return peer
    }

    /// Move a peer into the handshake state.
    @discardableResult
    func beginHandshake(peerID: PeerID, now: Date) -> LANPeer? {
        guard var peer = peers[peerID] else { return nil }
        switch peer.state {
        case .discovered:
            peer.state = .handshaking
            peer.stateChangedAt = now
        case .handshaking:
            // Restart of a stalled attempt: keep the state, refresh the timer.
            peer.stateChangedAt = now
        case .authenticated, .disconnected, .timedOut:
            return peer
        }
        peer.lastSeen = now
        peers[peerID] = peer
        return peer
    }

    /// Mark a peer as authenticated and record its identity.
    @discardableResult
    func authenticate(
        peerID: PeerID,
        nickname: String? = nil,
        noisePublicKey: Data? = nil,
        signingPublicKey: Data? = nil,
        isVerified: Bool = false,
        now: Date
    ) -> LANPeer? {
        guard var peer = peers[peerID] else {
            // A peer that was never discovered (for example an inbound
            // connection that skipped the discovery step) is registered on
            // the fly so the state machine stays complete.
            guard peers.count < timeouts.capacity else { return nil }
            let created = LANPeer(
                peerID: peerID,
                nickname: nickname ?? "",
                state: .authenticated,
                noisePublicKey: noisePublicKey,
                signingPublicKey: signingPublicKey,
                endpointDescription: nil,
                lastSeen: now,
                stateChangedAt: now,
                isVerified: isVerified
            )
            peers[peerID] = created
            return created
        }
        if let nickname, !nickname.isEmpty { peer.nickname = nickname }
        if let noisePublicKey { peer.noisePublicKey = noisePublicKey }
        if let signingPublicKey { peer.signingPublicKey = signingPublicKey }
        peer.isVerified = peer.isVerified || isVerified
        peer.state = .authenticated
        peer.stateChangedAt = now
        peer.lastSeen = now
        peers[peerID] = peer
        return peer
    }

    /// Mark a peer as disconnected.
    @discardableResult
    func disconnect(peerID: PeerID, now: Date) -> LANPeer? {
        guard var peer = peers[peerID] else { return nil }
        peer.state = .disconnected
        peer.stateChangedAt = now
        peers[peerID] = peer
        return peer
    }

    /// Record inbound traffic (refreshes the idle timer).
    func markTraffic(peerID: PeerID, now: Date) {
        guard var peer = peers[peerID] else { return }
        peer.lastSeen = now
        peers[peerID] = peer
    }

    /// Expire peers that stopped making progress.
    ///
    /// - Peers stuck in `discovered` or `handshaking` become `timedOut`.
    /// - Authenticated peers that went silent become `disconnected`.
    ///
    /// - Returns: the peer IDs whose state changed.
    @discardableResult
    func expireStalePeers(now: Date) -> [PeerID] {
        var expired: [PeerID] = []
        for (peerID, var peer) in peers {
            switch peer.state {
            case .discovered:
                if now.timeIntervalSince(peer.lastSeen) > timeouts.discovery {
                    peer.state = .timedOut
                    peer.stateChangedAt = now
                    expired.append(peerID)
                }
            case .handshaking:
                if now.timeIntervalSince(peer.stateChangedAt) > timeouts.handshake {
                    peer.state = .timedOut
                    peer.stateChangedAt = now
                    expired.append(peerID)
                }
            case .authenticated:
                if now.timeIntervalSince(peer.lastSeen) > timeouts.idle {
                    peer.state = .disconnected
                    peer.stateChangedAt = now
                    expired.append(peerID)
                }
            case .disconnected, .timedOut:
                continue
            }
            peers[peerID] = peer
        }
        return expired
    }

    /// Drop a peer entirely (used when a link is closed and the peer is not
    /// expected to come back).
    func remove(peerID: PeerID) {
        peers.removeValue(forKey: peerID)
    }

    /// Forget every peer when the transport stops or is disabled.
    func removeAll() {
        peers.removeAll()
    }

    /// Peer snapshots for the unified peer list.
    ///
    /// LAN peers are published with the same shape as BLE peers, so the
    /// unified peer service merges them by peer ID and keeps a single row
    /// per peer.
    func snapshots(now: Date) -> [TransportPeerSnapshot] {
        peers.values
            .filter { $0.state != .timedOut }
            .map { peer in
                TransportPeerSnapshot(
                    peerID: peer.peerID,
                    nickname: peer.nickname,
                    isConnected: peer.state.isAuthenticated,
                    noisePublicKey: peer.noisePublicKey,
                    lastSeen: peer.lastSeen,
                    isVerified: peer.isVerified
                )
            }
            .sorted { lhs, rhs in
                if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
                return lhs.peerID.id < rhs.peerID.id
            }
    }
}
