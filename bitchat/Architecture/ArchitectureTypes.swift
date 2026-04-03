import Combine
import CoreBluetooth
import Foundation
import SwiftUI

struct PrivateConversation: Equatable {
    let peerID: PeerID
    let messages: [BitchatMessage]
    let isUnread: Bool
}

struct PeerHeaderContext: Equatable {
    let headerPeerID: PeerID
    let peer: BitchatPeer?
    let displayName: String
    let isNostrAvailable: Bool
}

struct FingerprintDetails: Equatable {
    let statusPeerID: PeerID
    let displayName: String
    let encryptionStatus: EncryptionStatus
    let theirFingerprint: String?
    let myFingerprint: String
}

enum TransportEvent: Equatable {
    case messageReceived(BitchatMessage)
    case peerListUpdated([PeerID])
    case peerSnapshotsUpdated([TransportPeerSnapshot])
    case publicMessageReceived(peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?)
    case noisePayloadReceived(peerID: PeerID, type: NoisePayloadType, payload: Data, timestamp: Date)
    case messageDeliveryStatusUpdated(messageID: String, status: DeliveryStatus)
    case bluetoothStateUpdated(CBManagerState)
    case connected(PeerID)
    case disconnected(PeerID)
}

@MainActor
protocol PublicTimelineStoreProtocol: AnyObject {
    var visibleMessages: [BitchatMessage] { get }
    var activeChannel: ChannelID { get }

    func activate(channel: ChannelID)
    func append(_ message: BitchatMessage, to channel: ChannelID)
    func appendIfAbsent(_ message: BitchatMessage, toGeohash geohash: String) -> Bool
    func messages(for channel: ChannelID) -> [BitchatMessage]
    func refreshVisibleMessages(from channel: ChannelID?)
    func setVisibleMessages(_ messages: [BitchatMessage])
    func trimVisibleMessages(to limit: Int)
    func clear(channel: ChannelID)
    func clearAll()
    @discardableResult
    func updateMessage(id: String, transform: (BitchatMessage) -> BitchatMessage) -> Bool
}

protocol PrivateConversationsStoreProtocol: AnyObject {
    var privateChats: [PeerID: [BitchatMessage]] { get }
    var unreadMessages: Set<PeerID> { get }
    var selectedPeer: PeerID? { get }
    var hasSelectedPeerFingerprint: Bool { get }

    func messages(for peerID: PeerID) -> [BitchatMessage]
    func containsMessage(_ messageID: String, targetPeerID: PeerID?) -> Bool
    func upsertMessage(_ message: BitchatMessage, for peerID: PeerID)
    @MainActor func combinedMessages(for peerID: PeerID) -> [BitchatMessage]
    @MainActor func hasUnreadMessages(for peerID: PeerID) -> Bool
    @MainActor func mostRelevantPeerID() -> PeerID?
    @discardableResult
    func removeMessage(withID id: String) -> BitchatMessage?
    func clearAll()
    @discardableResult
    func updateMessage(id: String, in peerID: PeerID, transform: (BitchatMessage) -> BitchatMessage) -> Bool
    @discardableResult
    func updateDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String, in peerID: PeerID) -> Bool
    @discardableResult
    func reconcileSelectedPeerForCurrentFingerprint() -> PeerID?
    func selectPeerForContinuity(_ peerID: PeerID)
}

@MainActor
protocol PeerStoreProtocol: AnyObject {
    var peers: [BitchatPeer] { get }
    var connectedPeerIDs: Set<PeerID> { get }

    func getPeer(by peerID: PeerID) -> BitchatPeer?
    func getPeerID(for nickname: String) -> PeerID?
    func isBlocked(_ peerID: PeerID) -> Bool
}

@MainActor
protocol PeerPresentationStoreProtocol: AnyObject {
    var verifiedFingerprints: Set<String> { get }
    var showingFingerprintFor: PeerID? { get set }
    var selectedPeer: PeerID? { get }
    var myPeerID: PeerID { get }

    func shortID(for fullNoiseKeyHex: PeerID) -> PeerID
    func fingerprint(for peerID: PeerID) -> String?
    func isVerified(peerID: PeerID) -> Bool
    func encryptionStatus(for peerID: PeerID) -> EncryptionStatus
    func color(forMeshPeer peerID: PeerID, isDark: Bool) -> Color
    func displayName(for peerID: PeerID) -> String
    func headerContext(for privatePeerID: PeerID, selectedChannel: ChannelID) -> PeerHeaderContext
    func fingerprintDetails(for peerID: PeerID) -> FingerprintDetails
    func isBlocked(_ peerID: PeerID) -> Bool
    func isFavorite(peerID: PeerID) -> Bool
    func isPeerConnected(_ peerID: PeerID) -> Bool
    func isPeerReachable(_ peerID: PeerID) -> Bool
    func toggleFavorite(peerID: PeerID)
    func showFingerprint(for peerID: PeerID)
    func myFingerprint() -> String
    func verifyFingerprint(for peerID: PeerID)
    func unverifyFingerprint(for peerID: PeerID)
}

@MainActor
protocol ComposerStoreProtocol: AnyObject {
    var draft: String { get set }
    var autocompleteSuggestions: [String] { get }
    var showAutocomplete: Bool { get }

    func updateAutocomplete(for text: String, cursorPosition: Int)
    func completeNickname(_ nickname: String, in text: inout String) -> Int
    func clearAutocomplete()
}

@MainActor
protocol VerificationStoreProtocol: AnyObject {
    func myQRString() -> String
    func warmQRCodeCache()
    func beginQRVerification(with qr: VerificationService.VerificationQR) -> Bool
    func handlePeerAuthenticated(_ peerID: PeerID)
    func handleVerificationPayload(_ type: NoisePayloadType, payload: Data, from peerID: PeerID)
}

@MainActor
protocol GeohashPeopleStoreProtocol: AnyObject, GeohashParticipantContext {
    func currentIdentityHex() -> String?
    func commandParticipants() -> [CommandGeoParticipant]
    func peerID(for nickname: String) -> PeerID?
    func autocompleteTokens(excludingSelfNickname nickname: String) -> [String]
    func clearNicknames()
    func registerNickname(_ nickname: String, for pubkeyHex: String)
    func registerPubkey(_ pubkeyHex: String, for peerID: PeerID)
    func color(for pubkeyHexLowercased: String, isDark: Bool) -> Color
    func startDirectMessage(withPubkeyHex hex: String)
    func block(pubkeyHexLowercased: String, displayName: String)
    func unblock(pubkeyHexLowercased: String, displayName: String)
}

extension UnifiedPeerService: PeerStoreProtocol {}

@MainActor
final class ComposerStore: ObservableObject, ComposerStoreProtocol {
    @Published var draft: String = ""
    @Published private(set) var autocompleteSuggestions: [String] = []
    @Published private(set) var showAutocomplete: Bool = false
    @Published private(set) var autocompleteRange: NSRange? = nil
    @Published private(set) var selectedAutocompleteIndex: Int = 0

    private let autocompleteService: AutocompleteService
    private let sessionStore: SessionStore
    private let geohashPeopleStore: GeohashPeopleStoreProtocol
    private let channelProvider: () -> ChannelID
    private let meshPeerCandidatesProvider: () -> [String]

    init(
        autocompleteService: AutocompleteService = AutocompleteService(),
        sessionStore: SessionStore,
        geohashPeopleStore: GeohashPeopleStoreProtocol,
        channelProvider: @escaping () -> ChannelID,
        meshPeerCandidatesProvider: @escaping () -> [String]
    ) {
        self.autocompleteService = autocompleteService
        self.sessionStore = sessionStore
        self.geohashPeopleStore = geohashPeopleStore
        self.channelProvider = channelProvider
        self.meshPeerCandidatesProvider = meshPeerCandidatesProvider
    }

    func updateAutocomplete(for text: String, cursorPosition: Int) {
        let peerCandidates: [String] = {
            switch channelProvider() {
            case .mesh:
                return Array(
                    Set(
                        meshPeerCandidatesProvider()
                            .filter { !$0.isEmpty && $0 != sessionStore.nickname }
                    )
                )
            case .location:
                return geohashPeopleStore.autocompleteTokens(excludingSelfNickname: sessionStore.nickname)
            }
        }()

        let (suggestions, range) = autocompleteService.getSuggestions(
            for: text,
            peers: peerCandidates,
            cursorPosition: cursorPosition
        )

        guard !suggestions.isEmpty else {
            clearAutocomplete()
            return
        }

        autocompleteSuggestions = suggestions
        autocompleteRange = range
        showAutocomplete = true
        selectedAutocompleteIndex = 0
    }

    func completeNickname(_ nickname: String, in text: inout String) -> Int {
        guard let range = autocompleteRange else { return text.count }

        text = autocompleteService.applySuggestion(nickname, to: text, range: range)
        clearAutocomplete()

        return range.location + nickname.count + (nickname.hasPrefix("@") ? 1 : 2)
    }

    func clearAutocomplete() {
        autocompleteSuggestions = []
        autocompleteRange = nil
        showAutocomplete = false
        selectedAutocompleteIndex = 0
    }
}
