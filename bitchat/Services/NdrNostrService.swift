import BitLogger
import Foundation
import NdrFfi

@MainActor
protocol NostrRelayManaging: AnyObject {
    func subscribe(
        filter: NostrFilter,
        id: String,
        relayUrls: [String]?,
        handler: @escaping (NostrEvent) -> Void,
        onEOSE: (() -> Void)?
    )
    func unsubscribe(id: String)
    func sendEvent(_ event: NostrEvent, to relayUrls: [String]?)
}

extension NostrRelayManager: NostrRelayManaging {}

struct NdrDecryptedMessage {
    let event: NostrEvent
    let senderPubkeyHex: String
    let senderDevicePubkeyHex: String?
    let conversationOwnerPubkeyHex: String?

    /// Iris sets `conversationOwnerPubkeyHex` on a local-sibling copy so the
    /// receiving device can route its own authored event to the remote peer's
    /// thread. Authentication continues to use `senderPubkeyHex`.
    var conversationPubkeyHex: String {
        conversationOwnerPubkeyHex ?? senderPubkeyHex
    }

    var isLocalSiblingCopy: Bool {
        conversationOwnerPubkeyHex != nil
    }
}

/// Bridges the protocol-backed `NdrFfi` `SessionManagerHandle` with `NostrRelayManager`.
///
/// The ndr session manager emits a stream of pub/sub actions we must execute externally:
/// - `subscribe` / `unsubscribe`: Nostr filter subscriptions (for invite responses, sessions, etc)
/// - `publish_signed`: signed Nostr events to publish
/// - `decrypted_message`: decrypted inner event JSON (kind 14) to surface to the app
///
/// BitChat policy: do NOT publish double-ratchet invite/response handshake events to Nostr.
/// Those are exchanged out-of-band over the BLE Noise channel (see `Transport.sendNdrEvent`).
@MainActor
final class NdrNostrService {
    static let shared = NdrNostrService()
    private static let compactInviteURLRoot = "https://b"
    private static let maximumPendingOutOfBandInvites = 64
    private static let maximumBufferedDecryptedMessages = 128

    /// Called when an ndr message is decrypted into an inner Nostr event (kind 14).
    var onDecryptedMessage: ((NdrDecryptedMessage) -> Void)? {
        didSet {
            flushBufferedDecryptedMessages()
        }
    }

    private let relayManager: NostrRelayManaging
    private let storageDirectoryProvider: @MainActor () throws -> URL
    private let rolloutEnabled: Bool

    private var sessionManager: SessionManagerHandle?
    private var activeSubIDs = Set<String>()
    private var appKeysSubscriptionIDByOwner: [String: String] = [:]
    private var appKeysOwnerBySubscriptionID: [String: String] = [:]
    private var cachedInviteEventJson: String?
    private var bufferedDecryptedMessages: [NdrDecryptedMessage] = []

    private struct PendingOutOfBandInvite {
        let key: PendingOutOfBandInviteKey
        let payload: String
        let sequence: UInt64
        let authorization: () -> Bool
        let deferredResponseHandler: (String) -> Void
    }

    private struct PendingOutOfBandInviteKey: Hashable {
        let ownerPubkeyHex: String
        let inviterPubkeyHex: String
    }

    private var pendingOutOfBandInvites:
        [PendingOutOfBandInviteKey: PendingOutOfBandInvite] = [:]
    private var nextPendingOutOfBandInviteSequence: UInt64 = 0

    private var configuredForPubkeyHex: String?
    private var deviceId: String?
    private let deviceIdProvider: @MainActor () -> String
    private let clearPersistedDeviceId: @MainActor () -> Void

    private init() {
        self.relayManager = NostrRelayManager.shared
        self.rolloutEnabled = DoubleRatchetFeature.isEnabled
        self.deviceId = rolloutEnabled ? Self.loadOrCreateDeviceId() : nil
        self.deviceIdProvider = Self.loadOrCreateDeviceId
        self.clearPersistedDeviceId = Self.clearPersistedDeviceId
        self.storageDirectoryProvider = Self.ndrStorageDirectory
    }

    /// Dependency-injected initializer (primarily for tests).
    init(
        relayManager: NostrRelayManaging,
        deviceId: String,
        rolloutEnabled: Bool,
        storageDirectoryProvider: @escaping @MainActor () throws -> URL,
        clearPersistedDeviceId: @escaping @MainActor () -> Void = {}
    ) {
        self.relayManager = relayManager
        self.rolloutEnabled = rolloutEnabled
        self.deviceId = deviceId
        self.deviceIdProvider = { deviceId }
        self.storageDirectoryProvider = storageDirectoryProvider
        self.clearPersistedDeviceId = clearPersistedDeviceId
    }

    var isConfigured: Bool { rolloutEnabled && sessionManager != nil }
    var isRolloutEnabled: Bool { rolloutEnabled }
    var configuredPubkeyHex: String? { configuredForPubkeyHex }

    /// Returns our current device invite event JSON (kind 30078), if available.
    ///
    /// This is exchanged out-of-band with mutual favorites over BLE and is never published to Nostr.
    func currentInviteEventJson() -> String? {
        rolloutEnabled ? cachedInviteEventJson : nil
    }

    func configureIfNeeded(identity: NostrIdentity) {
        guard rolloutEnabled else { return }
        let pubkey = identity.publicKeyHex.lowercased()
        if configuredForPubkeyHex == pubkey, sessionManager != nil { return }

        // Identity changed: tear down subscriptions we created (best-effort).
        for id in activeSubIDs {
            relayManager.unsubscribe(id: id)
        }
        activeSubIDs.removeAll()
        appKeysSubscriptionIDByOwner.removeAll()
        appKeysOwnerBySubscriptionID.removeAll()
        pendingOutOfBandInvites.removeAll()
        bufferedDecryptedMessages.removeAll()
        sessionManager = nil
        cachedInviteEventJson = nil
        configuredForPubkeyHex = pubkey

        do {
            // The FFI's file adapter uses fixed filenames within its base
            // directory. Namespace that directory by owner so switching the
            // account identity can never load another owner's ratchet state.
            let storagePath = try storageDirectoryProvider()
                .appendingPathComponent(pubkey, isDirectory: true)
                .path
            let deviceId = deviceId ?? deviceIdProvider()
            self.deviceId = deviceId
            let mgr = try SessionManagerHandle.newWithStoragePath(
                ourPubkeyHex: pubkey,
                ourIdentityPrivkeyHex: identity.privateKey.hexEncodedString(),
                deviceId: deviceId,
                storagePath: storagePath,
                ownerPubkeyHex: nil
            )
            try mgr.`init`()
            sessionManager = mgr
            _ = drainAndApplyPubSubEvents()
            SecureLogger.info("NdrNostrService configured pub=\(pubkey.prefix(8))… device=\(deviceId)", category: .session)
        } catch {
            SecureLogger.error("NdrNostrService: failed to configure: \(error)", category: .session)
            sessionManager = nil
        }
    }

    func hasActiveSession(with peerPubkeyHex: String) -> Bool {
        guard rolloutEnabled, let mgr = sessionManager else { return false }
        do {
            return try mgr.getActiveSessionState(peerPubkeyHex: peerPubkeyHex.lowercased()) != nil
        } catch {
            return false
        }
    }

    func activeSessionStateJson(with peerPubkeyHex: String) -> String? {
        guard rolloutEnabled, let mgr = sessionManager else { return nil }
        return try? mgr.getActiveSessionState(peerPubkeyHex: peerPubkeyHex.lowercased())
    }

    /// Attempt to send via ndr when a verified, send-ready session exists.
    /// A newly established session can remain unavailable until the peer's
    /// owner-signed AppKeys roster arrives; callers may use their legacy path
    /// until the runtime can prepare an NDR relay event.
    func sendIfPossible(_ text: String, to peerPubkeyHex: String) -> Bool {
        guard rolloutEnabled, let mgr = sessionManager else { return false }
        guard hasActiveSession(with: peerPubkeyHex) else { return false }
        do {
            let outboundEventIDs = try mgr.sendText(
                recipientPubkeyHex: peerPubkeyHex.lowercased(),
                text: text,
                expiresAtSeconds: nil
            )
            _ = drainAndApplyPubSubEvents()
            if outboundEventIDs.isEmpty {
                SecureLogger.debug(
                    "NdrNostrService: send queued no relay publish for \(peerPubkeyHex.prefix(8))…",
                    category: .session
                )
            }
            return true
        } catch {
            SecureLogger.debug("NdrNostrService: send failed (no session yet?): \(error)", category: .session)
            // Still drain in case the error queued any pubsub actions.
            _ = drainAndApplyPubSubEvents()
            return false
        }
    }

    /// Process a received invite/response payload (transferred out-of-band over BLE).
    ///
    /// Returns any outbound handshake payloads (e.g. giftwrap response JSON or compact invite URL)
    /// that should be returned to the sender over BLE.
    func processOutOfBandEventJson(
        _ eventJson: String,
        expectedPeerPubkeyHex: String,
        authorization: (() -> Bool)? = nil,
        deferredResponseHandler: ((String) -> Void)? = nil
    ) -> [String] {
        guard rolloutEnabled,
              let mgr = sessionManager,
              authorization?() != false
        else {
            return []
        }
        let payload = eventJson.trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.utf8.count <= NostrProtocol.maximumPrivateEnvelopeCiphertextBytes,
              let expectedPeer = Self.normalizedPubkeyHex(expectedPeerPubkeyHex)
        else {
            SecureLogger.warning("NdrNostrService: rejected invalid or oversized OOB payload", category: .security)
            return []
        }

        let inboundInvite = parseOutOfBandInvite(payload)
        let responseEvent = inboundInvite == nil
            ? try? JSONDecoder().decode(NostrEvent.self, from: Data(payload.utf8))
            : nil
        if let inboundInvite, inboundInvite.ownerPubkeyHex != expectedPeer {
            SecureLogger.warning(
                "NdrNostrService: rejected OOB invite whose owner does not match the authenticated peer",
                category: .security
            )
            return []
        }

        if inboundInvite == nil {
            guard let responseEvent,
                  responseEvent.kind == 1059,
                  responseEvent.isValidSignature(),
                  NostrEvent.isWithinInboundTagLimits(responseEvent.tags)
            else {
                SecureLogger.warning("NdrNostrService: rejected non-invite OOB payload", category: .security)
                return []
            }
        }

        var blockedOnOwnerRoster = false
        var processingFailed = false
        do {
            switch inboundInvite?.transport {
            case .eventJSON:
                _ = try mgr.acceptInviteFromEventJson(
                    eventJson: payload,
                    ownerPubkeyHintHex: expectedPeer
                )
            case .url:
                _ = try mgr.acceptInviteFromUrl(
                    inviteUrl: payload,
                    ownerPubkeyHintHex: expectedPeer
                )
            case .none:
                try mgr.processOutOfBandResponse(
                    eventJson: payload,
                    expectedOwnerPubkeyHex: expectedPeer
                )
            }
        } catch let error as NdrError {
            if case .SessionNotReady = error {
                blockedOnOwnerRoster = true
            } else {
                processingFailed = true
                SecureLogger.debug(
                    "NdrNostrService: OOB payload ignored/rejected: \(error)",
                    category: .session
                )
            }
        } catch {
            processingFailed = true
            SecureLogger.debug(
                "NdrNostrService: OOB payload ignored/rejected: \(error)",
                category: .session
            )
        }

        let outOfBandPublishes = drainAndApplyPubSubEvents(collectOutOfBandPublishes: true)
        if blockedOnOwnerRoster, let inboundInvite {
            if let deferredResponseHandler {
                retainPendingOutOfBandInvite(
                    payload: payload,
                    ownerPubkeyHex: inboundInvite.ownerPubkeyHex,
                    inviterPubkeyHex: inboundInvite.inviterPubkeyHex,
                    authorization: authorization ?? { true },
                    deferredResponseHandler: deferredResponseHandler
                )
            } else {
                finishPendingOutOfBandInvite(
                    ownerPubkeyHex: inboundInvite.ownerPubkeyHex,
                    inviterPubkeyHex: inboundInvite.inviterPubkeyHex
                )
            }
            return []
        }
        if processingFailed {
            if let inboundInvite {
                finishPendingOutOfBandInvite(
                    ownerPubkeyHex: inboundInvite.ownerPubkeyHex,
                    inviterPubkeyHex: inboundInvite.inviterPubkeyHex
                )
            }
            return []
        }

        if let inboundInvite,
           outOfBandPublishes.isEmpty,
           hasActiveSession(with: inboundInvite.ownerPubkeyHex),
           let currentInvite = preferredInviteOobPayload() {
            finishPendingOutOfBandInvite(
                ownerPubkeyHex: inboundInvite.ownerPubkeyHex,
                inviterPubkeyHex: inboundInvite.inviterPubkeyHex
            )
            return outOfBandPublishes + [currentInvite]
        }
        if let inboundInvite {
            finishPendingOutOfBandInvite(
                ownerPubkeyHex: inboundInvite.ownerPubkeyHex,
                inviterPubkeyHex: inboundInvite.inviterPubkeyHex
            )
        }
        return outOfBandPublishes
    }

    /// Process a Nostr event received from relays (kind 1060 messages, app-keys maintenance, etc).
    func processInboundRelayEvent(_ event: NostrEvent) {
        guard rolloutEnabled else { return }
        processInboundNostrEvent(event)
    }

    /// Invalidates every in-memory callback/session and removes the persisted
    /// ratchet database and device identifier as part of the synchronous panic
    /// transaction. A failed directory deletion is surfaced so startup keeps
    /// the durable recovery marker and retries before transports restart.
    func resetForPanic() throws {
        for id in activeSubIDs {
            relayManager.unsubscribe(id: id)
        }
        activeSubIDs.removeAll()
        appKeysSubscriptionIDByOwner.removeAll()
        appKeysOwnerBySubscriptionID.removeAll()
        pendingOutOfBandInvites.removeAll()
        nextPendingOutOfBandInviteSequence = 0
        bufferedDecryptedMessages.removeAll()
        sessionManager = nil
        cachedInviteEventJson = nil
        configuredForPubkeyHex = nil
        onDecryptedMessage = nil
        deviceId = nil
        clearPersistedDeviceId()

        let storageDirectory = try storageDirectoryProvider()
        if FileManager.default.fileExists(atPath: storageDirectory.path) {
            try FileManager.default.removeItem(at: storageDirectory)
        }
    }

    // MARK: - Internals

    private func processInboundNostrEvent(_ event: NostrEvent) {
        guard let mgr = sessionManager else { return }
        guard event.kind == 1060 || event.kind == 37368,
              event.isValidSignature(),
              NostrEvent.isWithinInboundTagLimits(event.tags),
              let json = try? event.jsonString(),
              json.utf8.count <= NostrProtocol.maximumPrivateEnvelopeCiphertextBytes
        else {
            SecureLogger.warning(
                "NdrNostrService: rejected disallowed or malformed relay-origin event",
                category: .security
            )
            return
        }

        do {
            try mgr.processEvent(eventJson: json)
        } catch {
            // ndr will reject most unrelated events; keep log noise low.
            SecureLogger.debug("NdrNostrService: processEvent ignored/rejected: \(error)", category: .session)
        }

        _ = drainAndApplyPubSubEvents()
        if event.kind == 37368,
           let owner = Self.normalizedPubkeyHex(event.pubkey) {
            retryPendingOutOfBandInvite(ownerPubkeyHex: owner)
        }
    }

    @discardableResult
    private func drainAndApplyPubSubEvents(collectOutOfBandPublishes: Bool = false) -> [String] {
        guard let mgr = sessionManager else { return [] }
        var outOfBandPublishes: [String] = []
        do {
            let events = try mgr.drainEvents()
            for e in events {
                apply(
                    pubsub: e,
                    collectOutOfBandPublish: collectOutOfBandPublishes ? { outOfBandPublishes.append($0) } : nil
                )
            }
        } catch {
            SecureLogger.error("NdrNostrService: drainEvents failed: \(error)", category: .session)
        }
        return outOfBandPublishes
    }

    private func apply(pubsub e: PubSubEvent, collectOutOfBandPublish: ((String) -> Void)?) {
        switch e.kind {
        case "subscribe":
            guard let subid = e.subid, let filterJson = e.filterJson else { return }

            do {
                let filter = try JSONDecoder().decode(NostrFilter.self, from: Data(filterJson.utf8))
                // BitChat policy: don't do Nostr-based DR invite discovery or invite-response listening.
                if shouldIgnoreNdrSubscription(filter) {
                    return
                }
                if let owner = appKeysSubscriptionOwner(filter) {
                    guard appKeysSubscriptionIDByOwner[owner] == nil else {
                        return
                    }
                    appKeysSubscriptionIDByOwner[owner] = subid
                    appKeysOwnerBySubscriptionID[subid] = owner
                }
                guard activeSubIDs.insert(subid).inserted else { return } // already subscribed
                relayManager.subscribe(
                    filter: filter,
                    id: subid,
                    relayUrls: nil,
                    handler: { [weak self] event in
                        self?.processInboundNostrEvent(event)
                    },
                    onEOSE: nil
                )
            } catch {
                SecureLogger.error("NdrNostrService: failed to decode subscribe filter: \(error)", category: .session)
            }

        case "unsubscribe":
            guard let subid = e.subid else { return }
            if let owner = appKeysOwnerBySubscriptionID.removeValue(forKey: subid) {
                appKeysSubscriptionIDByOwner.removeValue(forKey: owner)
            }
            guard activeSubIDs.remove(subid) != nil else { return }
            relayManager.unsubscribe(id: subid)

        case "publish_signed":
            guard let eventJson = e.eventJson else { return }
            do {
                let event = try JSONDecoder().decode(NostrEvent.self, from: Data(eventJson.utf8))

                if isDoubleRatchetInviteEvent(event) {
                    // Cache the current device invite for out-of-band sharing; never publish to Nostr.
                    cachedInviteEventJson = eventJson
                    collectOutOfBandPublish?(eventJson)
                    return
                }
                if event.kind == 1059 {
                    // Giftwrap responses are part of the DR handshake; exchange OOB over BLE.
                    collectOutOfBandPublish?(eventJson)
                    return
                }

                relayManager.sendEvent(event, to: nil)
            } catch {
                SecureLogger.error("NdrNostrService: failed to decode outbound event: \(error)", category: .session)
            }

        case "decrypted_message":
            consumeDecryptedPubSubEvent(e)

        default:
            // Other events currently ignored (e.g. app-keys maintenance).
            break
        }
    }

    private func isDoubleRatchetInviteEvent(_ event: NostrEvent) -> Bool {
        guard event.kind == 30078 else { return false }
        for tag in event.tags where tag.count >= 2 {
            if tag[0] == "l", tag[1] == "double-ratchet/invites" {
                return true
            }
            if tag[0] == "d", tag[1].hasPrefix("double-ratchet/invites/") {
                return true
            }
        }
        return false
    }

    private enum OutOfBandInviteTransport {
        case eventJSON
        case url
    }

    private struct ParsedOutOfBandInvite {
        let ownerPubkeyHex: String
        let inviterPubkeyHex: String
        let transport: OutOfBandInviteTransport
    }

    private func parseOutOfBandInvite(_ payload: String) -> ParsedOutOfBandInvite? {
        guard !payload.isEmpty else { return nil }
        if payload.first == "{" {
            guard let event = try? JSONDecoder().decode(NostrEvent.self, from: Data(payload.utf8)),
                  isDoubleRatchetInviteEvent(event),
                  event.isValidSignature(),
                  NostrEvent.isWithinInboundTagLimits(event.tags),
                  let invite = try? InviteHandle.fromEventJson(eventJson: payload),
                  let ownerPubkeyHex = try? invite.getOwnerPubkeyHex(),
                  let inviterPubkeyHex = Self.normalizedPubkeyHex(
                    invite.getInviterPubkeyHex()
                  ) else {
                return nil
            }
            return ParsedOutOfBandInvite(
                ownerPubkeyHex: ownerPubkeyHex.lowercased(),
                inviterPubkeyHex: inviterPubkeyHex,
                transport: .eventJSON
            )
        }

        guard let invite = try? InviteHandle.fromUrl(url: payload),
              let ownerPubkeyHex = try? invite.getOwnerPubkeyHex(),
              let inviterPubkeyHex = Self.normalizedPubkeyHex(
                invite.getInviterPubkeyHex()
              ) else {
            return nil
        }
        return ParsedOutOfBandInvite(
            ownerPubkeyHex: ownerPubkeyHex.lowercased(),
            inviterPubkeyHex: inviterPubkeyHex,
            transport: .url
        )
    }

    private func preferredInviteOobPayload() -> String? {
        guard let eventJson = cachedInviteEventJson else { return nil }
        return compactInviteURL(from: eventJson) ?? eventJson
    }

    private func compactInviteURL(from eventJson: String) -> String? {
        guard let invite = try? InviteHandle.fromEventJson(eventJson: eventJson) else {
            return nil
        }
        return try? invite.toUrl(root: Self.compactInviteURLRoot)
    }

    private func shouldIgnoreNdrSubscription(_ filter: NostrFilter) -> Bool {
        // Never use Nostr for invite/response exchange in BitChat.
        if filter.kinds?.contains(1059) == true {
            return true
        }
        if filter.kinds?.contains(30078) == true,
           filter.tagFilters?["l"]?.contains("double-ratchet/invites") == true {
            return true
        }
        return false
    }

    private func appKeysSubscriptionOwner(_ filter: NostrFilter) -> String? {
        guard filter.kinds == [37368],
              filter.authors?.count == 1,
              let author = filter.authors?.first
        else {
            return nil
        }
        return Self.normalizedPubkeyHex(author)
    }

    private func retainPendingOutOfBandInvite(
        payload: String,
        ownerPubkeyHex: String,
        inviterPubkeyHex: String,
        authorization: @escaping () -> Bool,
        deferredResponseHandler: @escaping (String) -> Void
    ) {
        let key = PendingOutOfBandInviteKey(
            ownerPubkeyHex: ownerPubkeyHex,
            inviterPubkeyHex: inviterPubkeyHex
        )
        nextPendingOutOfBandInviteSequence &+= 1
        pendingOutOfBandInvites[key] = PendingOutOfBandInvite(
            key: key,
            payload: payload,
            sequence: nextPendingOutOfBandInviteSequence,
            authorization: authorization,
            deferredResponseHandler: deferredResponseHandler
        )
        // Insert first so evicting an older device under this same owner
        // cannot tear down the owner's sole AppKeys subscription.
        if pendingOutOfBandInvites.count > Self.maximumPendingOutOfBandInvites,
           let oldest = pendingOutOfBandInvites.min(by: { $0.value.sequence < $1.value.sequence })?.key {
            finishPendingOutOfBandInvite(key: oldest)
        }
    }

    private func retryPendingOutOfBandInvite(ownerPubkeyHex: String) {
        let pendingForOwner = pendingOutOfBandInvites.values
            .filter { $0.key.ownerPubkeyHex == ownerPubkeyHex }
            .sorted { $0.sequence < $1.sequence }
        for pending in pendingForOwner {
            guard pending.authorization() else {
                finishPendingOutOfBandInvite(key: pending.key)
                continue
            }
            let responses = processOutOfBandEventJson(
                pending.payload,
                expectedPeerPubkeyHex: ownerPubkeyHex,
                authorization: pending.authorization,
                deferredResponseHandler: pending.deferredResponseHandler
            )
            for response in responses {
                pending.deferredResponseHandler(response)
            }
        }
    }

    private func finishPendingOutOfBandInvite(
        ownerPubkeyHex: String,
        inviterPubkeyHex: String
    ) {
        finishPendingOutOfBandInvite(
            key: PendingOutOfBandInviteKey(
                ownerPubkeyHex: ownerPubkeyHex,
                inviterPubkeyHex: inviterPubkeyHex
            )
        )
    }

    private func finishPendingOutOfBandInvite(key: PendingOutOfBandInviteKey) {
        pendingOutOfBandInvites.removeValue(forKey: key)
        let ownerPubkeyHex = key.ownerPubkeyHex
        guard !pendingOutOfBandInvites.keys.contains(where: {
            $0.ownerPubkeyHex == ownerPubkeyHex
        }) else {
            return
        }
        guard let subid = appKeysSubscriptionIDByOwner.removeValue(forKey: ownerPubkeyHex) else {
            return
        }
        appKeysOwnerBySubscriptionID.removeValue(forKey: subid)
        if activeSubIDs.remove(subid) != nil {
            relayManager.unsubscribe(id: subid)
        }
    }

    func consumeDecryptedPubSubEvent(_ event: PubSubEvent) {
        guard rolloutEnabled,
              let inner = Self.validatedDecryptedMessage(from: event)
        else {
            SecureLogger.warning(
                "NdrNostrService: rejected a malformed or misattributed decrypted rumor",
                category: .security
            )
            return
        }
        guard let onDecryptedMessage else {
            if bufferedDecryptedMessages.count >= Self.maximumBufferedDecryptedMessages {
                bufferedDecryptedMessages.removeFirst()
            }
            bufferedDecryptedMessages.append(inner)
            return
        }
        onDecryptedMessage(inner)
    }

    static func validatedDecryptedMessage(from event: PubSubEvent) -> NdrDecryptedMessage? {
        guard event.kind == "decrypted_message",
              let sender = event.senderPubkeyHex.flatMap(normalizedPubkeyHex),
              event.senderDevicePubkeyHex == nil
                || event.senderDevicePubkeyHex.flatMap(normalizedPubkeyHex) != nil,
              event.conversationOwnerPubkeyHex == nil
                || event.conversationOwnerPubkeyHex.flatMap(normalizedPubkeyHex) != nil,
              event.eventId == nil || event.eventId?.count == 64,
              let innerJson = event.content,
              !innerJson.isEmpty,
              innerJson.utf8.count <= NostrProtocol.maximumPrivateEnvelopeCiphertextBytes,
              let inner = try? JSONDecoder().decode(NostrEvent.self, from: Data(innerJson.utf8)),
              inner.kind == NostrProtocol.EventKind.dm.rawValue,
              let innerAuthor = normalizedPubkeyHex(inner.pubkey),
              innerAuthor == sender,
              NostrEvent.isWithinInboundTagLimits(inner.tags),
              inner.hasValidEventID()
        else {
            return nil
        }
        return NdrDecryptedMessage(
            event: inner,
            senderPubkeyHex: sender,
            senderDevicePubkeyHex: event.senderDevicePubkeyHex.flatMap(normalizedPubkeyHex),
            conversationOwnerPubkeyHex:
                event.conversationOwnerPubkeyHex.flatMap(normalizedPubkeyHex)
        )
    }

    private func flushBufferedDecryptedMessages() {
        while let handler = onDecryptedMessage, !bufferedDecryptedMessages.isEmpty {
            handler(bufferedDecryptedMessages.removeFirst())
        }
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

    private static func loadOrCreateDeviceId() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: deviceIdKey)
        return id
    }

    private static let deviceIdKey = "ndr.device_id"

    private static func clearPersistedDeviceId() {
        UserDefaults.standard.removeObject(forKey: deviceIdKey)
    }

    private static func ndrStorageDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("ndr", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var protectedDirectory = dir
        try protectedDirectory.setResourceValues(resourceValues)
#if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dir.path
        )
#endif
        return dir
    }
}
