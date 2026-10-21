//
// LANTransportConfig.swift
// bitchat
//
// Feature flag, configuration keys and permission state for the Wi-Fi LAN
// transport.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

/// Local-network permission state as observed by the LAN transport.
///
/// The transport never triggers the system permission prompt on its own:
/// the user opts in from Settings, and only then does the transport ask the
/// system for local-network access. When the state is `denied` or
/// `unavailable` the transport stays completely inert (no listener, no
/// browser) and every transport-selection decision falls back to BLE/Nostr.
enum LANPermissionState: String, Equatable, Codable, Sendable {
    /// The transport has not asked for local-network access yet.
    case unknown
    /// Local-network access is granted.
    case granted
    /// The user (or the OS) denied local-network access.
    case denied
    /// The platform cannot provide local-network access (for example a
    /// platform without Bonjour, or Wi-Fi turned off).
    case unavailable

    /// Whether the transport may open a listener or a browser.
    var allowsLocalNetworkAccess: Bool {
        self == .granted
    }

    /// Whether the transport may attempt to start.
    ///
    /// `unknown` is allowed on purpose: the first Bonjour browse/advertise is
    /// what triggers the system permission prompt. Only a known refusal keeps
    /// the transport inert.
    var canAttemptStart: Bool {
        self == .unknown || self == .granted
    }
}

/// Why a local-network operation failed.
enum LANFailureKind: Equatable, Sendable {
    /// The user (or the OS) denied local-network access.
    case permissionDenied
    /// Local-network access is not available on this platform.
    case unavailable
    /// A transient failure; the operation may be retried.
    case transient
}

/// Maps a local-network failure to a permission state.
///
/// The mapping is a pure function so the permission state machine can be
/// unit-tested without a real browser or listener.
enum LANPermissionStateResolver {
    static func resolve(failure: LANFailureKind) -> LANPermissionState {
        switch failure {
        case .permissionDenied:
            return .denied
        case .unavailable:
            return .unavailable
        case .transient:
            return .unknown
        }
    }
}

/// Static configuration for the Wi-Fi LAN transport.
enum LANTransportConfig {
    /// `UserDefaults` key holding the feature flag.
    ///
    /// The LAN transport is **off by default**: with the flag unset the
    /// transport creates no listener, starts no browser and triggers no
    /// local-network permission prompt.
    static let enabledDefaultsKey = "bitchat.lan.enabled"

    /// Bonjour service type used for LAN discovery.
    ///
    /// Must match the `NSBonjourServices` entry in `Info.plist`, otherwise
    /// the OS refuses to browse or advertise the service.
    static let serviceType = "_bitchat._tcp"

    /// Prefix of the advertised Bonjour service name.
    ///
    /// The advertised name is `<prefix><peer id>`, e.g. `bitchat-1a2b3c4d5e6f7890`.
    /// The peer ID is derived from the Noise static key, exactly like the BLE
    /// mesh peer ID, so a peer keeps one identity across transports.
    static let serviceNamePrefix = "bitchat-"

    /// Maximum number of simultaneously open LAN connections.
    ///
    /// This bounds unauthenticated connections that have not completed a
    /// hello yet; the peer registry separately caps authenticated peers.
    static let maxConcurrentConnections = 64

    /// Maximum number of concurrent LAN peers tracked in the peer registry.
    /// The peer table is small by construction (a phone sees a handful of
    /// peers on one Wi-Fi network), the cap only bounds memory.
    static let maxConcurrentPeers = 32

    /// Maximum accepted frame payload. A single BitChat packet is far
    /// smaller; the cap stops a hostile peer from forcing an unbounded
    /// allocation on the reader.
    static let maximumFramePayloadBytes = 1 << 20 // 1 MiB

    /// How long a discovered peer may stay in the `discovered` state before
    /// it is expired. A peer that never completes the handshake is dropped.
    static let discoveryTimeout: TimeInterval = 30

    /// How long the Noise handshake may take before the attempt is aborted
    /// and the peer is expired.
    static let handshakeTimeout: TimeInterval = 10

    /// How long an authenticated peer may stay silent before it is treated
    /// as gone. The transport refreshes the timer on every received frame.
    static let idleTimeout: TimeInterval = 120

    /// Interval between periodic keepalive frames on an idle LAN link.
    /// Keeps NAT/router idle timers and the peer's idle timeout in sync.
    static let keepaliveInterval: TimeInterval = 30

    /// Build the advertised Bonjour service name for a peer ID.
    static func serviceName(for peerID: PeerID) -> String {
        serviceNamePrefix + peerID.id
    }

    /// Parse a peer ID out of an advertised Bonjour service name.
    ///
    /// Returns `nil` for names that do not carry a peer ID (a foreign
    /// service on the same network, or a stale advertisement).
    static func peerID(fromServiceName name: String) -> PeerID? {
        guard name.hasPrefix(serviceNamePrefix) else { return nil }
        let bare = String(name.dropFirst(serviceNamePrefix.count))
        guard bare.count == 16, bare.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return PeerID(str: bare.lowercased())
    }
}

extension Notification.Name {
    /// Posted when the observed local-network permission state changes.
    /// `userInfo["state"]` carries the `LANPermissionState.rawValue`.
    static let lanPermissionStateDidChange = Notification.Name("bitchat.lan.permissionStateDidChange")
}

/// Persisted feature-flag state for the Wi-Fi LAN transport.
///
/// Kept as a small object (instead of a static global) so the flag can be
/// exercised in unit tests against an isolated `UserDefaults` suite.
final class LANTransportSettings {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = LANTransportConfig.enabledDefaultsKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    /// Whether the Wi-Fi LAN transport is enabled. Defaults to `false`.
    var isEnabled: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}
