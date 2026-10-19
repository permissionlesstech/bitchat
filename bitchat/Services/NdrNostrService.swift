import BitFoundation
import BitLogger
import Foundation
import NdrFfi

@MainActor
protocol NostrRelayManaging: AnyObject {
    @discardableResult
    func subscribe(
        filter: NostrFilter,
        id: String,
        relayUrls: [String]?,
        handler: @escaping (NostrEvent) -> Void,
        onEOSE: (() -> Void)?
    ) -> Bool
    func unsubscribe(id: String)
    func sendEventImmediately(
        _ event: NostrEvent,
        to relayUrls: [String]?,
        completion: @escaping (Bool) -> Void
    )
}

extension NostrRelayManager: NostrRelayManaging {}

enum NdrDeliveryDisposition: Equatable {
    case consumed
    case retry
}

enum NdrSendDisposition: Equatable {
    case sent(innerEventID: String, outerEventID: String)
    case noSession
    case failed
}

enum NdrStorageDirectoryError: Error, Equatable {
    case applicationSupportUnavailable
}

enum NdrSessionStateError: Error, Equatable {
    case missingEstablishedState
    case invalidEstablishedSessionMarker
    case establishedSessionMarkerWriteFailed
    case establishedSessionMarkerClearFailed
}

@MainActor
protocol NdrSessionMarkerStoring: AnyObject {
    func contains(identityPubkeyHex: String) throws -> Bool
    func mark(identityPubkeyHex: String) throws
    func clear() throws
}

@MainActor
final class InMemoryNdrSessionMarkerStore: NdrSessionMarkerStoring {
    private var identities = Set<String>()

    func contains(identityPubkeyHex: String) throws -> Bool {
        identities.contains(identityPubkeyHex)
    }

    func mark(identityPubkeyHex: String) throws {
        identities.insert(identityPubkeyHex)
    }

    func clear() throws {
        identities.removeAll()
    }
}

@MainActor
private final class KeychainNdrSessionMarkerStore:
    NdrSessionMarkerStoring
{
    private static let service = "chat.bitchat.ndr.session-markers"
    private static let key = "established-identities"
    private let keychain: KeychainManagerProtocol

    init(keychain: KeychainManagerProtocol = KeychainManager.makeDefault()) {
        self.keychain = keychain
    }

    func contains(identityPubkeyHex: String) throws -> Bool {
        try identities().contains(identityPubkeyHex)
    }

    func mark(identityPubkeyHex: String) throws {
        var updated = try identities()
        updated.insert(identityPubkeyHex)
        let data = try JSONEncoder().encode(updated.sorted())
        keychain.save(
            key: Self.key,
            data: data,
            service: Self.service,
            accessible: nil
        )
        guard try identities().contains(identityPubkeyHex) else {
            throw NdrSessionStateError
                .establishedSessionMarkerWriteFailed
        }
    }

    func clear() throws {
        keychain.delete(key: Self.key, service: Self.service)
        guard keychain.load(key: Self.key, service: Self.service) == nil else {
            throw NdrSessionStateError
                .establishedSessionMarkerClearFailed
        }
    }

    private func identities() throws -> Set<String> {
        guard let data = keychain.load(
            key: Self.key,
            service: Self.service
        ) else {
            return []
        }
        guard let values = try? JSONDecoder().decode(
            [String].self,
            from: data
        ),
            values.allSatisfy({
                $0.count == 64
                    && $0.allSatisfy { character in
                        character.isHexDigit
                    }
            })
        else {
            throw NdrSessionStateError.invalidEstablishedSessionMarker
        }
        return Set(values.map { $0.lowercased() })
    }
}

struct NdrDecryptedMessage {
    let event: NostrEvent
    let senderPubkeyHex: String
    let outerEventID: String
    let expiresAtSeconds: UInt64?
}

struct NdrOutOfBandAction {
    let eventJson: String
    let peerPubkeyHex: String

    let actionID: String
    fileprivate let manager: PairwiseManager
    fileprivate let managerEpoch: UInt64
}

struct NdrInviteAction {
    let eventJson: String
    let eventID: String

    fileprivate let manager: PairwiseManager
    fileprivate let managerEpoch: UInt64
}

typealias NdrDeliveryCompletion = @MainActor (NdrDeliveryDisposition) -> Void
typealias NdrDecryptedMessageHandler =
    @MainActor (NdrDecryptedMessage, @escaping NdrDeliveryCompletion) -> Void

/// Bridges BitChat's authenticated BLE bootstrap and relay transport to the
/// durable single-device pairwise NDR runtime.
///
/// Only kind 1060 reaches relays. Invite/response payloads remain bound to the
/// authenticated BLE Noise generation, and every durable runtime action is
/// acknowledged only after its host-side effect succeeds.
@MainActor
final class NdrNostrService {
    static let shared = NdrNostrService()

    private static let storageVersionDirectory = "pairwise-v1"
    private static let maximumActionsPerRetry = 128
    private static let transientRetryDelays: [TimeInterval] = [
        0.25, 0.5, 1, 2
    ]

    var onDecryptedMessage: NdrDecryptedMessageHandler? {
        didSet {
            // A retired lifecycle owner can leave a delivery deferred after
            // returning `.retry`. Replacing that non-nil handler is the host's
            // recovery boundary just as much as installing the first handler.
            if onDecryptedMessage != nil {
                retryPendingDeliveries()
            }
        }
    }

    private let relayManager: NostrRelayManaging
    private let storageDirectoryProvider: @MainActor () throws -> URL
    private let sessionMarkerStore: NdrSessionMarkerStoring
    private let retryScheduler:
        @MainActor (
            TimeInterval,
            @escaping @MainActor () -> Void
        ) -> Void
    private let nativeOutOfBandMutationObserver:
        (@MainActor () -> Void)?
    private let rolloutEnabled: Bool

    private var manager: PairwiseManager?
    private var managerEpoch: UInt64 = 0
    private var configuredForPubkeyHex: String?
    private var failedConfigurationPubkeyHex: String?
    private var activeSubIDs = Set<String>()
    private var inFlightActionIDs = Set<String>()
    private var deferredActionIDs = Set<String>()
    private var transientRetryAttempts: [String: Int] = [:]
    private var scheduledTransientRetryTokens: [String: UUID] = [:]
    private var continuationScheduled = false

    private init() {
        relayManager = NostrRelayManager.shared
        rolloutEnabled = DoubleRatchetFeature.isEnabled
        sessionMarkerStore = KeychainNdrSessionMarkerStore()
        storageDirectoryProvider = {
            try Self.ndrStorageDirectory()
        }
        retryScheduler = Self.scheduleLiveRetry
        nativeOutOfBandMutationObserver = nil
    }

    /// Dependency-injected initializer used by the app-target integration tests.
    init(
        relayManager: NostrRelayManaging,
        rolloutEnabled: Bool,
        storageDirectoryProvider: @escaping @MainActor () throws -> URL,
        sessionMarkerStore: NdrSessionMarkerStoring? = nil,
        retryScheduler: @escaping @MainActor (
            TimeInterval,
            @escaping @MainActor () -> Void
        ) -> Void = NdrNostrService.scheduleLiveRetry,
        nativeOutOfBandMutationObserver:
            (@MainActor () -> Void)? = nil
    ) {
        self.relayManager = relayManager
        self.rolloutEnabled = rolloutEnabled
        self.storageDirectoryProvider = storageDirectoryProvider
        self.sessionMarkerStore =
            sessionMarkerStore ?? InMemoryNdrSessionMarkerStore()
        self.retryScheduler = retryScheduler
        self.nativeOutOfBandMutationObserver =
            nativeOutOfBandMutationObserver
    }

    var isConfigured: Bool { rolloutEnabled && manager != nil }
    var isRolloutEnabled: Bool { rolloutEnabled }
    var configuredPubkeyHex: String? { configuredForPubkeyHex }

    func currentInviteEventJson() -> String? {
        currentInviteAction()?.eventJson
    }

    func currentInviteAction() -> NdrInviteAction? {
        guard rolloutEnabled, let manager else { return nil }
        guard let eventJson = try? manager.currentInviteEventJson(),
              let event = try? JSONDecoder().decode(
                NostrEvent.self,
                from: Data(eventJson.utf8)
              )
        else {
            return nil
        }
        return NdrInviteAction(
            eventJson: eventJson,
            eventID: event.id,
            manager: manager,
            managerEpoch: managerEpoch
        )
    }

    func isCurrentInviteAction(_ action: NdrInviteAction) -> Bool {
        guard isCurrent(action.manager, epoch: action.managerEpoch) else {
            return false
        }
        guard let eventJson = try? action.manager.currentInviteEventJson(),
              let event = try? JSONDecoder().decode(
                NostrEvent.self,
                from: Data(eventJson.utf8)
              )
        else {
            return false
        }
        return event.id == action.eventID
    }

    @discardableResult
    func configureIfNeeded(
        identity: NostrIdentity,
        processPendingActions shouldProcessPendingActions: Bool = true,
        allowDisabledMaintenance: Bool = false
    ) -> Bool {
        guard rolloutEnabled || allowDisabledMaintenance else {
            return false
        }
        let pubkey = identity.publicKeyHex.lowercased()
        if failedConfigurationPubkeyHex == pubkey {
            // A corrupt/unopenable runtime must not be reclassified as
            // "no session" by a later send. Recovery requires an identity
            // change or the explicit panic/storage wipe transaction.
            return false
        }
        if configuredForPubkeyHex == pubkey, manager != nil {
            if shouldProcessPendingActions && rolloutEnabled {
                processAvailableActions()
            }
            return true
        }

        replaceManager(with: nil, configuredPubkeyHex: nil)
        failedConfigurationPubkeyHex = nil
        configuredForPubkeyHex = pubkey

        do {
            let storageURL = try storageDirectoryProvider()
                .appendingPathComponent(
                    Self.storageVersionDirectory,
                    isDirectory: true
                )
                .appendingPathComponent(pubkey, isDirectory: true)
            if try sessionMarkerStore.contains(
                identityPubkeyHex: pubkey
            ),
                !Self.hasDurablePairwiseState(at: storageURL)
            {
                throw NdrSessionStateError.missingEstablishedState
            }
            let newManager = try PairwiseManager.newWithStoragePath(
                ourPubkeyHex: pubkey,
                ourIdentityPrivateKeyHex:
                    identity.privateKey.hexEncodedString(),
                storagePath: storageURL.path
            )
            manager = newManager
            try markEstablishedSessionIfNeeded(
                manager: newManager,
                identityPubkeyHex: pubkey
            )
            failedConfigurationPubkeyHex = nil
            if shouldProcessPendingActions && rolloutEnabled {
                processAvailableActions()
            }
            SecureLogger.info(
                "NdrNostrService configured pairwise pub=\(pubkey.prefix(8))…",
                category: .session
            )
            return true
        } catch {
            SecureLogger.error(
                "NdrNostrService: failed to configure: \(error)",
                category: .session
            )
            replaceManager(with: nil, configuredPubkeyHex: pubkey)
            failedConfigurationPubkeyHex = pubkey
            return false
        }
    }

    func hasActiveSession(with peerPubkeyHex: String) -> Bool {
        guard rolloutEnabled,
              let manager,
              let peer = Self.normalizedPubkeyHex(peerPubkeyHex),
              let info = try? manager.sessionInfo(peerPubkeyHex: peer)
        else {
            return false
        }
        return info.sendReady && info.receiveReady
    }

    /// Any native session record suppresses another invite. A valid response
    /// can create a half-ready session while its relay bootstrap is still in
    /// flight; sending a second invite in that window creates avoidable glare.
    func hasPairwiseSession(with peerPubkeyHex: String) -> Bool {
        guard rolloutEnabled,
              let manager,
              let peer = Self.normalizedPubkeyHex(peerPubkeyHex)
        else {
            return false
        }
        return (try? manager.sessionInfo(peerPubkeyHex: peer)) != nil
    }

    /// Removes only the selected pairwise peer. Other peer sessions and the
    /// local invite remain intact.
    @discardableResult
    func retirePeer(
        _ peerPubkeyHex: String,
        processPendingActions shouldProcessPendingActions: Bool = true,
        allowDisabledMaintenance: Bool = false
    ) -> Bool {
        guard rolloutEnabled || allowDisabledMaintenance,
              let manager,
              let peer = Self.normalizedPubkeyHex(peerPubkeyHex)
        else {
            return false
        }

        let retiredActionIDs = Set(
            (try? manager.pendingActions())?
                .filter { $0.peerPubkeyHex == peer }
                .map(\.actionId)
                ?? []
        )
        do {
            guard try manager.retirePeer(peerPubkeyHex: peer) else {
                return true
            }
            for actionID in retiredActionIDs {
                inFlightActionIDs.remove(actionID)
                deferredActionIDs.remove(actionID)
                transientRetryAttempts.removeValue(forKey: actionID)
                scheduledTransientRetryTokens.removeValue(forKey: actionID)
            }
            if shouldProcessPendingActions && rolloutEnabled {
                processAvailableActions()
            }
            return true
        } catch {
            SecureLogger.error(
                "NdrNostrService: failed to retire pairwise peer: \(error)",
                category: .session
            )
            return false
        }
    }

    /// A legacy envelope is permitted only when no pairwise session exists.
    /// Once any session exists, inability to ratchet is a fail-closed error.
    func send(
        _ text: String,
        to peerPubkeyHex: String,
        expiresAtSeconds: UInt64? = nil
    ) -> NdrSendDisposition {
        guard rolloutEnabled else {
            return .noSession
        }
        guard let manager else {
            return failedConfigurationPubkeyHex == nil
                ? .noSession
                : .failed
        }
        guard
              let peer = Self.normalizedPubkeyHex(peerPubkeyHex)
        else {
            return .noSession
        }

        do {
            guard let info = try manager.sessionInfo(peerPubkeyHex: peer) else {
                return .noSession
            }
            guard info.sendReady else {
                SecureLogger.warning(
                    "NdrNostrService: pairwise session exists but is not send-ready",
                    category: .security
                )
                return .failed
            }

            let result = try manager.sendText(
                peerPubkeyHex: peer,
                text: text,
                expiresAtSeconds: expiresAtSeconds
            )
            processAvailableActions()
            return .sent(
                innerEventID: result.innerEventId,
                outerEventID: result.outerEventId
            )
        } catch {
            SecureLogger.error(
                "NdrNostrService: active pairwise send failed: \(error)",
                category: .session
            )
            processAvailableActions()
            return .failed
        }
    }

    /// Processes an invite or response delivered over an authenticated BLE
    /// Noise session and returns only OOB actions for that exact peer.
    func processOutOfBandEventJson(
        _ eventJson: String,
        expectedPeerPubkeyHex: String,
        authorization: (() -> Bool)? = nil,
        persistEstablishedBinding: () -> Bool
    ) -> [NdrOutOfBandAction] {
        guard rolloutEnabled,
              let manager,
              authorization?() != false,
              let expectedPeer =
                Self.normalizedPubkeyHex(expectedPeerPubkeyHex)
        else {
            return []
        }
        let epoch = managerEpoch
        let payload =
            eventJson.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty,
              payload.utf8.count
                <= NostrProtocol.maximumPrivateEnvelopeCiphertextBytes
        else {
            SecureLogger.warning(
                "NdrNostrService: rejected invalid or oversized OOB payload",
                category: .security
            )
            return []
        }

        let mutation: ValidatedOutOfBandMutation
        if let invite = parseOutOfBandInvite(payload) {
            guard invite.peerPubkeyHex == expectedPeer else {
                SecureLogger.warning(
                    "NdrNostrService: rejected OOB invite for another authenticated peer",
                    category: .security
                )
                return []
            }
            mutation = .invite(invite.transport)
        } else {
            guard let response = try? JSONDecoder().decode(
                NostrEvent.self,
                from: Data(payload.utf8)
            ),
                response.kind == 1059,
                response.isValidSignature(),
                NostrEvent.isWithinInboundTagLimits(response.tags)
            else {
                SecureLogger.warning(
                    "NdrNostrService: rejected non-invite OOB payload",
                    category: .security
                )
                return []
            }
            mutation = .response
        }

        // A valid authenticated OOB payload can durably create native
        // pairwise state. Persist both host-side downgrade barriers first so
        // a crash at any later instruction cannot reopen kind-1059 fallback.
        guard persistEstablishedBinding() else {
            SecureLogger.error(
                "NdrNostrService: OOB binding pin was not durable",
                category: .security
            )
            return []
        }
        do {
            guard let identityPubkeyHex = configuredForPubkeyHex else {
                throw NdrSessionStateError
                    .establishedSessionMarkerWriteFailed
            }
            try sessionMarkerStore.mark(
                identityPubkeyHex: identityPubkeyHex.lowercased()
            )
        } catch {
            SecureLogger.error(
                "NdrNostrService: failed to precommit established-session marker: \(error)",
                category: .security
            )
            return []
        }

        do {
            nativeOutOfBandMutationObserver?()
            switch mutation {
            case .invite(.eventJSON):
                _ = try manager.acceptInviteFromEventJson(
                    eventJson: payload,
                    authenticatedPeerPubkeyHex: expectedPeer
                )
            case .invite(.url):
                _ = try manager.acceptInviteFromUrl(
                    inviteUrl: payload,
                    authenticatedPeerPubkeyHex: expectedPeer
                )
            case .response:
                try manager.processOutOfBandResponse(
                    eventJson: payload,
                    authenticatedPeerPubkeyHex: expectedPeer
                )
            }
        } catch {
            SecureLogger.debug(
                "NdrNostrService: OOB payload ignored/rejected: \(error)",
                category: .session
            )
            processAvailableActions()
            return []
        }

        guard isCurrent(manager, epoch: epoch) else { return [] }
        return processPendingActions(collectOutOfBandFor: expectedPeer)
    }

    /// Completes the durable OOB action only after BLE accepted the encrypted
    /// packet for the exact authenticated Noise generation.
    func completeOutOfBandAction(
        _ action: NdrOutOfBandAction,
        succeeded: Bool
    ) {
        guard isCurrent(action.manager, epoch: action.managerEpoch) else {
            return
        }
        inFlightActionIDs.remove(action.actionID)
        guard succeeded else {
            deferredActionIDs.insert(action.actionID)
            return
        }
        deferredActionIDs.remove(action.actionID)
        if !acknowledge(
            [action.actionID],
            manager: action.manager,
            epoch: action.managerEpoch
        ) {
            deferredActionIDs.insert(action.actionID)
        } else {
            // A bootstrap publish for this session is deliberately held until
            // BLE has accepted the authenticated OOB response.
            processAvailableActions()
        }
    }

    /// Reclaims one failed BLE action for a bounded host retry without
    /// releasing unrelated peer-routed actions from the durable queue.
    func prepareOutOfBandActionForRetry(
        _ action: NdrOutOfBandAction
    ) -> Bool {
        guard isCurrent(action.manager, epoch: action.managerEpoch),
              !inFlightActionIDs.contains(action.actionID),
              let pending = try? action.manager.pendingActions(),
              pending.contains(where: {
                  $0.actionId == action.actionID
                    && $0.kind == "out_of_band"
              })
        else {
            return false
        }
        deferredActionIDs.remove(action.actionID)
        inFlightActionIDs.insert(action.actionID)
        return true
    }

    @discardableResult
    func scheduleHostTransientRetry(
        after retryAttempt: Int,
        operation: @escaping @MainActor () -> Void
    ) -> Bool {
        guard retryAttempt < Self.transientRetryDelays.count else {
            return false
        }
        retryScheduler(
            Self.transientRetryDelays[retryAttempt],
            operation
        )
        return true
    }

    func processInboundRelayEvent(_ event: NostrEvent) {
        guard rolloutEnabled, let manager else { return }
        processInboundNostrEvent(
            event,
            manager: manager,
            epoch: managerEpoch
        )
    }

    func pendingOutOfBandActions(
        forAuthenticatedPeerPubkeyHex peerPubkeyHex: String,
        releaseDeferred: Bool = false
    ) -> [NdrOutOfBandAction] {
        guard rolloutEnabled,
              let peer = Self.normalizedPubkeyHex(peerPubkeyHex)
        else {
            return []
        }
        if releaseDeferred {
            releaseDeferredOutOfBandActions(for: peer)
        }
        return processPendingActions(collectOutOfBandFor: peer)
    }

    /// A real disconnected→connected edge starts a fresh bounded relay retry
    /// epoch without releasing consumer or BLE work.
    func retryRelayActions() {
        releaseDeferredActions(
            where: { action in
                action.kind == "publish"
                    || action.kind == "subscribe"
                    || action.kind == "unsubscribe"
            }
        )
        processAvailableActions()
    }

    /// Consumer installation or an explicit delivery retry releases only
    /// application delivery work.
    func retryPendingDeliveries() {
        releaseDeferredActions(where: { $0.kind == "delivery" })
        processAvailableActions()
    }

    /// Invalidates callbacks first, then deletes every pairwise database as
    /// part of the synchronous panic transaction.
    func resetForPanic() throws {
        replaceManager(with: nil, configuredPubkeyHex: nil)
        failedConfigurationPubkeyHex = nil
        onDecryptedMessage = nil

        let storageDirectory = try storageDirectoryProvider()
        if FileManager.default.fileExists(atPath: storageDirectory.path) {
            try FileManager.default.removeItem(at: storageDirectory)
        }
        try sessionMarkerStore.clear()
    }

    // MARK: - Durable action processing

    @discardableResult
    private func processPendingActions(
        collectOutOfBandFor expectedPeer: String?
    ) -> [NdrOutOfBandAction] {
        guard let manager else { return [] }
        let epoch = managerEpoch
        let actions: [PairwiseAction]
        do {
            // Inspect the bounded native queue in full so already in-flight,
            // deferred, or peer-routed OOB actions at its head cannot starve
            // actionable work behind them. Host-side effects remain capped
            // below by `maximumActionsPerRetry`.
            actions = try manager.pendingActions()
        } catch {
            SecureLogger.error(
                "NdrNostrService: pendingActions failed: \(error)",
                category: .session
            )
            return []
        }

        let pendingOutOfBandSessionIDs = Set(
            actions.compactMap { action in
                action.kind == "out_of_band" ? action.sessionId : nil
            }
        )
        let hasUnscopedOutOfBandAction = actions.contains { action in
            action.kind == "out_of_band" && action.sessionId == nil
        }

        var synchronousAcks: [String] = []
        var outOfBand: [NdrOutOfBandAction] = []
        var processedActionCount = 0
        var hitBatchLimit = false

        for action in actions {
            guard isCurrent(manager, epoch: epoch),
                  !inFlightActionIDs.contains(action.actionId),
                  !deferredActionIDs.contains(action.actionId)
            else {
                continue
            }

            switch action.kind {
            case "publish":
                let sharesPendingOutOfBandSession =
                    action.sessionId.map(
                        pendingOutOfBandSessionIDs.contains
                    )
                    ?? !pendingOutOfBandSessionIDs.isEmpty
                guard !hasUnscopedOutOfBandAction,
                      !sharesPendingOutOfBandSession
                else {
                    // The OOB response and relay bootstrap are one ordered
                    // handshake. Unrelated established sessions continue.
                    continue
                }
                guard processedActionCount
                        < Self.maximumActionsPerRetry
                else {
                    hitBatchLimit = true
                    continue
                }
                processedActionCount += 1
                guard let event = Self.validatedPublishAction(action) else {
                    synchronousAcks.append(action.actionId)
                    continue
                }
                inFlightActionIDs.insert(action.actionId)
                relayManager.sendEventImmediately(
                    event,
                    to: nil,
                    completion: { [weak self, manager] accepted in
                        guard let self,
                              self.isCurrent(manager, epoch: epoch)
                        else {
                            return
                        }
                        self.inFlightActionIDs.remove(action.actionId)
                        if accepted {
                            self.deferredActionIDs.remove(action.actionId)
                            if !self.acknowledge(
                                [action.actionId],
                                manager: manager,
                                epoch: epoch
                            ) {
                                self.deferForTransientRetry(
                                    action.actionId,
                                    manager: manager,
                                    epoch: epoch
                                )
                            }
                        } else {
                            self.deferForTransientRetry(
                                action.actionId,
                                manager: manager,
                                epoch: epoch
                            )
                        }
                    }
                )

            case "out_of_band":
                guard let eventJson = action.eventJson,
                      let peer =
                        action.peerPubkeyHex.flatMap(
                            Self.normalizedPubkeyHex
                        ),
                      Self.isValidOutOfBandResponse(eventJson)
                else {
                    guard processedActionCount
                            < Self.maximumActionsPerRetry
                    else {
                        hitBatchLimit = true
                        continue
                    }
                    processedActionCount += 1
                    synchronousAcks.append(action.actionId)
                    continue
                }
                guard let expectedPeer, peer == expectedPeer else {
                    // An OOB action for another peer needs that peer's current
                    // authenticated BLE route, so it remains durable.
                    continue
                }
                guard processedActionCount
                        < Self.maximumActionsPerRetry
                else {
                    hitBatchLimit = true
                    continue
                }
                processedActionCount += 1
                inFlightActionIDs.insert(action.actionId)
                outOfBand.append(
                    NdrOutOfBandAction(
                        eventJson: eventJson,
                        peerPubkeyHex: peer,
                        actionID: action.actionId,
                        manager: manager,
                        managerEpoch: epoch
                    )
                )

            case "subscribe":
                guard processedActionCount
                        < Self.maximumActionsPerRetry
                else {
                    hitBatchLimit = true
                    continue
                }
                processedActionCount += 1
                guard let subscriptionID = action.subscriptionId,
                      let filterJson = action.filterJson,
                      let filter = try? JSONDecoder().decode(
                        NostrFilter.self,
                        from: Data(filterJson.utf8)
                      ),
                      Self.isAllowedNdrSubscription(filter)
                else {
                    synchronousAcks.append(action.actionId)
                    continue
                }
                // The native runtime deliberately reuses its account-scoped
                // subscription ID while rotating ephemeral sender authors.
                // Register every durable replacement before acknowledging it;
                // NIP-01 replaces the relay's live REQ atomically by ID.
                let registered = relayManager.subscribe(
                    filter: filter,
                    id: subscriptionID,
                    relayUrls: nil,
                    handler: { [weak self, manager] event in
                        self?.processInboundNostrEvent(
                            event,
                            manager: manager,
                            epoch: epoch
                        )
                    },
                    onEOSE: nil
                )
                guard registered else {
                    deferForTransientRetry(
                        action.actionId,
                        manager: manager,
                        epoch: epoch
                    )
                    continue
                }
                activeSubIDs.insert(subscriptionID)
                synchronousAcks.append(action.actionId)

            case "unsubscribe":
                guard processedActionCount
                        < Self.maximumActionsPerRetry
                else {
                    hitBatchLimit = true
                    continue
                }
                processedActionCount += 1
                guard let subscriptionID = action.subscriptionId else {
                    synchronousAcks.append(action.actionId)
                    continue
                }
                if activeSubIDs.remove(subscriptionID) != nil {
                    relayManager.unsubscribe(id: subscriptionID)
                }
                synchronousAcks.append(action.actionId)

            case "delivery":
                guard processedActionCount
                        < Self.maximumActionsPerRetry
                else {
                    hitBatchLimit = true
                    continue
                }
                guard let message =
                    Self.validatedDecryptedMessage(from: action)
                else {
                    processedActionCount += 1
                    // Malformed or policy-disallowed plaintext is a definitive
                    // rejection, not a transient retry.
                    synchronousAcks.append(action.actionId)
                    continue
                }
                if Self.isExpiredDelivery(action) {
                    processedActionCount += 1
                    // Expiration is a definitive policy drop. Recheck here,
                    // after decrypt/validation and immediately before handing
                    // plaintext to the app.
                    synchronousAcks.append(action.actionId)
                    continue
                }
                guard let handler = onDecryptedMessage else {
                    // The FFI remains the durable buffer.
                    continue
                }
                guard !Self.isExpiredDelivery(action) else {
                    processedActionCount += 1
                    synchronousAcks.append(action.actionId)
                    continue
                }
                processedActionCount += 1
                inFlightActionIDs.insert(action.actionId)
                handler(message) { [weak self, manager] disposition in
                    guard let self,
                          self.isCurrent(manager, epoch: epoch)
                    else {
                        return
                    }
                    self.inFlightActionIDs.remove(action.actionId)
                    if disposition == .consumed {
                        self.deferredActionIDs.remove(action.actionId)
                        if !self.acknowledge(
                            [action.actionId],
                            manager: manager,
                            epoch: epoch
                        ) {
                            self.deferredActionIDs.insert(action.actionId)
                        }
                    } else {
                        self.deferredActionIDs.insert(action.actionId)
                    }
                }

            default:
                guard processedActionCount
                        < Self.maximumActionsPerRetry
                else {
                    hitBatchLimit = true
                    continue
                }
                processedActionCount += 1
                // Unknown actions cannot become valid after a retry.
                synchronousAcks.append(action.actionId)
            }
        }

        let synchronousAckSucceeded = acknowledge(
            synchronousAcks,
            manager: manager,
            epoch: epoch
        )
        if !synchronousAcks.isEmpty, !synchronousAckSucceeded {
            for actionID in synchronousAcks {
                deferForTransientRetry(
                    actionID,
                    manager: manager,
                    epoch: epoch
                )
            }
        }
        if hitBatchLimit,
           synchronousAckSucceeded
            || processedActionCount > synchronousAcks.count
        {
            schedulePendingActionContinuation(
                manager: manager,
                epoch: epoch
            )
        }
        return outOfBand
    }

    @discardableResult
    private func acknowledge(
        _ actionIDs: [String],
        manager: PairwiseManager,
        epoch: UInt64
    ) -> Bool {
        guard !actionIDs.isEmpty, isCurrent(manager, epoch: epoch) else {
            return false
        }
        do {
            try manager.ackActions(actionIds: actionIDs)
            for actionID in actionIDs {
                transientRetryAttempts.removeValue(forKey: actionID)
                scheduledTransientRetryTokens.removeValue(forKey: actionID)
            }
            schedulePendingActionContinuation(
                manager: manager,
                epoch: epoch
            )
            return true
        } catch {
            SecureLogger.error(
                "NdrNostrService: durable action ack failed: \(error)",
                category: .session
            )
            return false
        }
    }

    private func deferForTransientRetry(
        _ actionID: String,
        manager: PairwiseManager,
        epoch: UInt64
    ) {
        guard isCurrent(manager, epoch: epoch) else { return }
        deferredActionIDs.insert(actionID)
        guard scheduledTransientRetryTokens[actionID] == nil else {
            return
        }
        let attempt = transientRetryAttempts[actionID, default: 0]
        guard attempt < Self.transientRetryDelays.count else { return }

        transientRetryAttempts[actionID] = attempt + 1
        let retryToken = UUID()
        scheduledTransientRetryTokens[actionID] = retryToken
        retryScheduler(Self.transientRetryDelays[attempt]) {
            [weak self, manager] in
            guard let self,
                  self.isCurrent(manager, epoch: epoch),
                  self.scheduledTransientRetryTokens[actionID] == retryToken,
                  self.deferredActionIDs.remove(actionID) != nil
            else {
                return
            }
            self.scheduledTransientRetryTokens.removeValue(
                forKey: actionID
            )
            _ = self.processPendingActions(collectOutOfBandFor: nil)
        }
    }

    private func schedulePendingActionContinuation(
        manager: PairwiseManager,
        epoch: UInt64
    ) {
        guard isCurrent(manager, epoch: epoch),
              !continuationScheduled
        else {
            return
        }
        continuationScheduled = true
        Task { @MainActor [weak self, manager] in
            guard let self,
                  self.isCurrent(manager, epoch: epoch)
            else {
                return
            }
            self.continuationScheduled = false
            _ = self.processPendingActions(collectOutOfBandFor: nil)
        }
    }

    private func processInboundNostrEvent(
        _ event: NostrEvent,
        manager: PairwiseManager,
        epoch: UInt64
    ) {
        guard isCurrent(manager, epoch: epoch),
              event.kind == 1060,
              event.isValidSignature(),
              NostrEvent.isWithinInboundTagLimits(event.tags),
              Self.isRecipientFreeNdrEnvelope(event),
              let json = try? event.jsonString(),
              json.utf8.count
                <= NostrProtocol.maximumPrivateEnvelopeCiphertextBytes
        else {
            SecureLogger.warning(
                "NdrNostrService: rejected disallowed or malformed relay-origin event",
                category: .security
            )
            return
        }

        do {
            try manager.processEvent(eventJson: json)
        } catch {
            SecureLogger.debug(
                "NdrNostrService: relay event ignored/rejected: \(error)",
                category: .session
            )
        }
        guard isCurrent(manager, epoch: epoch) else { return }
        processAvailableActions()
    }

    private func processAvailableActions() {
        _ = processPendingActions(collectOutOfBandFor: nil)
    }

    private func releaseDeferredOutOfBandActions(for peerPubkeyHex: String) {
        releaseDeferredActions { action in
            action.kind == "out_of_band"
                && action.peerPubkeyHex.flatMap(Self.normalizedPubkeyHex)
                    == peerPubkeyHex
        }
    }

    private func releaseDeferredActions(
        where shouldRelease: (PairwiseAction) -> Bool
    ) {
        guard let manager,
              let actions = try? manager.pendingActions()
        else {
            return
        }
        for action in actions where shouldRelease(action) {
            deferredActionIDs.remove(action.actionId)
            transientRetryAttempts.removeValue(forKey: action.actionId)
            scheduledTransientRetryTokens.removeValue(
                forKey: action.actionId
            )
        }
    }

    // MARK: - Validation

    static func validatedPublishAction(
        _ action: PairwiseAction
    ) -> NostrEvent? {
        guard action.kind == "publish",
              let eventJson = action.eventJson,
              eventJson.utf8.count
                <= NostrProtocol.maximumPrivateEnvelopeCiphertextBytes,
              let event = try? JSONDecoder().decode(
                NostrEvent.self,
                from: Data(eventJson.utf8)
              ),
              event.kind == 1060,
              event.isValidSignature(),
              NostrEvent.isWithinInboundTagLimits(event.tags),
              isRecipientFreeNdrEnvelope(event),
              action.outerEventId == event.id
        else {
            SecureLogger.warning(
                "NdrNostrService: rejected malformed pairwise publish action",
                category: .security
            )
            return nil
        }
        return event
    }

    static func isRecipientFreeNdrEnvelope(_ event: NostrEvent) -> Bool {
        !event.tags.contains { $0.first == "p" }
    }

    static func validatedDecryptedMessage(
        from action: PairwiseAction
    ) -> NdrDecryptedMessage? {
        guard action.kind == "delivery",
              let sender =
                action.peerPubkeyHex.flatMap(normalizedPubkeyHex),
              let innerJson = action.innerEventJson,
              !innerJson.isEmpty,
              innerJson.utf8.count
                <= NostrProtocol.maximumPrivateEnvelopeCiphertextBytes,
              let innerID = action.innerEventId,
              innerID.count == 64,
              let outerID = action.outerEventId,
              outerID.count == 64,
              let inner = try? JSONDecoder().decode(
                NostrEvent.self,
                from: Data(innerJson.utf8)
              ),
              inner.kind == NostrProtocol.EventKind.dm.rawValue,
              normalizedPubkeyHex(inner.pubkey) == sender,
              inner.id == innerID,
              inner.hasValidEventID(),
              NostrEvent.isWithinInboundTagLimits(inner.tags)
        else {
            return nil
        }
        return NdrDecryptedMessage(
            event: inner,
            senderPubkeyHex: sender,
            outerEventID: outerID,
            expiresAtSeconds: action.expiresAtSeconds
        )
    }

    static func isExpiredDelivery(
        _ action: PairwiseAction,
        now: Date = Date()
    ) -> Bool {
        guard action.kind == "delivery",
              let expiresAtSeconds = action.expiresAtSeconds
        else {
            return false
        }
        return now.timeIntervalSince1970 >= TimeInterval(expiresAtSeconds)
    }

    private enum OutOfBandInviteTransport {
        case eventJSON
        case url
    }

    private enum ValidatedOutOfBandMutation {
        case invite(OutOfBandInviteTransport)
        case response
    }

    private struct ParsedOutOfBandInvite {
        let peerPubkeyHex: String
        let transport: OutOfBandInviteTransport
    }

    private func parseOutOfBandInvite(
        _ payload: String
    ) -> ParsedOutOfBandInvite? {
        if payload.first == "{" {
            guard let event = try? JSONDecoder().decode(
                NostrEvent.self,
                from: Data(payload.utf8)
            ),
                event.kind == 30078,
                event.isValidSignature(),
                NostrEvent.isWithinInboundTagLimits(event.tags),
                let invite = try? PairwiseInvite.fromEventJson(
                    eventJson: payload
                ),
                let peer =
                    Self.normalizedPubkeyHex(invite.getPeerPubkeyHex())
            else {
                return nil
            }
            return ParsedOutOfBandInvite(
                peerPubkeyHex: peer,
                transport: .eventJSON
            )
        }

        guard let invite = try? PairwiseInvite.fromUrl(url: payload),
              let peer =
                Self.normalizedPubkeyHex(invite.getPeerPubkeyHex())
        else {
            return nil
        }
        return ParsedOutOfBandInvite(
            peerPubkeyHex: peer,
            transport: .url
        )
    }

    private static func isAllowedNdrSubscription(
        _ filter: NostrFilter
    ) -> Bool {
        guard filter.kinds == [1060],
              let authors = filter.authors,
              !authors.isEmpty
        else {
            return false
        }
        return authors.allSatisfy { normalizedPubkeyHex($0) != nil }
    }

    private static func isValidOutOfBandResponse(
        _ eventJson: String
    ) -> Bool {
        guard eventJson.utf8.count
                <= NostrProtocol.maximumPrivateEnvelopeCiphertextBytes,
              let event = try? JSONDecoder().decode(
                NostrEvent.self,
                from: Data(eventJson.utf8)
              )
        else {
            return false
        }
        return event.kind == 1059
            && event.isValidSignature()
            && NostrEvent.isWithinInboundTagLimits(event.tags)
    }

    private static func normalizedPubkeyHex(_ value: String) -> String? {
        let lowered = value.lowercased()
        guard lowered.count == 64,
              lowered.allSatisfy(\.isHexDigit),
              Data(hexString: lowered)?.count == 32
        else {
            return nil
        }
        return lowered
    }

    // MARK: - Manager lifecycle

    private func isCurrent(
        _ candidate: PairwiseManager,
        epoch: UInt64
    ) -> Bool {
        managerEpoch == epoch && manager === candidate
    }

    private func replaceManager(
        with replacement: PairwiseManager?,
        configuredPubkeyHex: String?
    ) {
        managerEpoch &+= 1
        for id in activeSubIDs {
            relayManager.unsubscribe(id: id)
        }
        activeSubIDs.removeAll()
        inFlightActionIDs.removeAll()
        deferredActionIDs.removeAll()
        transientRetryAttempts.removeAll()
        scheduledTransientRetryTokens.removeAll()
        continuationScheduled = false
        manager = replacement
        configuredForPubkeyHex = configuredPubkeyHex
    }

    private func markEstablishedSessionIfNeeded(
        manager: PairwiseManager,
        identityPubkeyHex: String
    ) throws {
        guard !(try manager.knownPeerPubkeys()).isEmpty else { return }
        try sessionMarkerStore.mark(
            identityPubkeyHex: identityPubkeyHex.lowercased()
        )
    }

    static func hasDurablePairwiseState(at directory: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ) else {
            return false
        }
        return names.contains { name in
            name.hasPrefix("ndr-pairwise-state-v1-")
                && name.hasSuffix(".json")
        }
    }

    static func ndrStorageDirectory(
        applicationSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let root = applicationSupportDirectory else {
            throw NdrStorageDirectoryError
                .applicationSupportUnavailable
        }
        let directory = root.appendingPathComponent(
            "ndr",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(resourceValues)
#if os(iOS)
        try fileManager.setAttributes(
            [
                .protectionKey:
                    FileProtectionType
                    .completeUntilFirstUserAuthentication
            ],
            ofItemAtPath: directory.path
        )
#endif
        return directory
    }

    static func scheduleLiveRetry(
        after delay: TimeInterval,
        operation: @escaping @MainActor () -> Void
    ) {
        Task { @MainActor in
            let nanoseconds = UInt64(
                max(0, delay) * 1_000_000_000
            )
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            operation()
        }
    }
}
