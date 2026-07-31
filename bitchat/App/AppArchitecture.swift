import BitFoundation
import Combine
import Foundation

enum SharedContentKind: String, Sendable, Equatable {
    case text
    case url
}

enum RuntimeScenePhase: String, Sendable, Equatable {
    case active
    case inactive
    case background
}

enum TorLifecycleEvent: String, Sendable, Equatable {
    case willStart
    case willRestart
    case didBecomeReady
    case preferenceChanged
}

enum AppEvent: Sendable, Equatable {
    case launched
    case startupCompleted
    case scenePhaseChanged(RuntimeScenePhase)
    case openedURL(String)
    case sharedContentAccepted(SharedContentKind)
    case notificationOpened(peerID: PeerID?)
    case deepLinkOpened(String)
    case torLifecycleChanged(TorLifecycleEvent)
    case nostrRelayConnectionChanged(Bool)
    case terminationRequested
}

actor AppEventStream {
    private var continuations: [UUID: AsyncStream<AppEvent>.Continuation] = [:]

    func emit(_ event: AppEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

}

/// Identity key for a direct conversation. Equality and hashing use the
/// canonical `id` only; `routingPeerID` carries the transport-level peer ID
/// the conversation is keyed under (see `ConversationID.directPeer`).
struct PeerHandle: Sendable, Identifiable {
    let id: String
    let routingPeerID: PeerID
}

extension PeerHandle: Equatable {
    static func == (lhs: PeerHandle, rhs: PeerHandle) -> Bool {
        lhs.id == rhs.id
    }
}

extension PeerHandle: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum ConversationID: Hashable, Sendable {
    case mesh
    case geohash(String)
    case direct(PeerHandle)

    init(channelID: ChannelID) {
        switch channelID {
        case .mesh:
            self = .mesh
        case .location(let channel):
            self = .geohash(channel.geohash.lowercased())
        }
    }
}
