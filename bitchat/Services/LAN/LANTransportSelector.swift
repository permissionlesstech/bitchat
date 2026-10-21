//
// LANTransportSelector.swift
// bitchat
//
// Transport selection policy for the Wi-Fi LAN transport.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// The transport that should carry a message to a peer.
enum LANTransportChoice: String, Equatable, Sendable {
    /// The peer is directly reachable over the local network.
    case lan
    /// The peer is reachable over the Bluetooth mesh.
    case ble
    /// The peer is reachable over Nostr (needs the internet).
    case nostr
    /// No transport can reach the peer right now.
    case none
}

/// Why the LAN transport was not selected.
enum LANFallbackReason: String, Equatable, Sendable {
    /// The LAN transport was selected.
    case none
    /// The feature flag is off.
    case featureDisabled
    /// The user (or the OS) denied local-network access.
    case permissionDenied
    /// Local-network access is not available on this platform.
    case permissionUnavailable
    /// The permission has not been granted yet.
    case permissionNotGranted
    /// The peer is not authenticated over the LAN link yet.
    case peerNotAuthenticated
    /// The peer is simply not on the local network.
    case peerNotOnLAN
}

/// Chooses which transport carries a message to a peer.
///
/// Policy (v1):
/// 1. The LAN transport wins **only** for a peer that is directly reachable
///    over the local network: the transport is enabled, the local-network
///    permission is granted and the peer's Noise session over the LAN link
///    is established.
/// 2. Otherwise the existing behaviour is untouched: BLE first (connected,
///    then reachable), Nostr last.
/// 3. A denied, unavailable or not-yet-granted permission never blocks
///    BLE/Nostr: the LAN transport simply becomes ineligible.
///
/// The selector is a pure value type so the policy can be unit-tested
/// without any networking.
struct LANTransportSelector: Equatable {
    /// Whether the LAN transport is enabled by the feature flag.
    var isEnabled: Bool
    /// The current local-network permission state.
    var permission: LANPermissionState

    init(isEnabled: Bool = false, permission: LANPermissionState = .unknown) {
        self.isEnabled = isEnabled
        self.permission = permission
    }

    /// Whether a LAN link may be used at all.
    var isLANEligible: Bool {
        isEnabled && permission.allowsLocalNetworkAccess
    }

    /// Select the transport for a peer.
    ///
    /// - Parameters:
    ///   - peerState: state of the peer in the LAN peer registry, `nil` when
    ///     the peer is unknown on the local network.
    ///   - bleConnected: the peer has a live BLE link.
    ///   - bleReachable: the peer was seen recently on the BLE mesh.
    ///   - nostrReachable: the peer is known to Nostr.
    func select(
        peerState: LANPeerState?,
        bleConnected: Bool,
        bleReachable: Bool,
        nostrReachable: Bool
    ) -> LANTransportChoice {
        selectWithReason(
            peerState: peerState,
            bleConnected: bleConnected,
            bleReachable: bleReachable,
            nostrReachable: nostrReachable
        ).choice
    }

    /// Select the transport for a peer and explain a LAN fallback.
    func selectWithReason(
        peerState: LANPeerState?,
        bleConnected: Bool,
        bleReachable: Bool,
        nostrReachable: Bool
    ) -> (choice: LANTransportChoice, reason: LANFallbackReason) {
        guard isEnabled else {
            return (bleConnected || bleReachable ? .ble : (nostrReachable ? .nostr : .none), .featureDisabled)
        }

        switch permission {
        case .denied:
            return (bleConnected || bleReachable ? .ble : (nostrReachable ? .nostr : .none), .permissionDenied)
        case .unavailable:
            return (bleConnected || bleReachable ? .ble : (nostrReachable ? .nostr : .none), .permissionUnavailable)
        case .unknown:
            return (bleConnected || bleReachable ? .ble : (nostrReachable ? .nostr : .none), .permissionNotGranted)
        case .granted:
            break
        }

        if let peerState, peerState.isAuthenticated {
            return (.lan, .none)
        }

        let fallback: LANTransportChoice = bleConnected || bleReachable
            ? .ble
            : (nostrReachable ? .nostr : .none)
        let reason: LANFallbackReason = peerState == nil ? .peerNotOnLAN : .peerNotAuthenticated
        return (fallback, reason)
    }
}
