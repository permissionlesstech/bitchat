import BitFoundation
import BitLogger
import CryptoKit
import Foundation

struct BLENoiseHandshakeHandlingResult {
    let processed: Bool
    let didEstablishAuthenticatedSession: Bool
}

struct BLENoiseDecryptionResult {
    let plaintext: Data
    let sessionGeneration: UUID
}

/// Narrow environment for `BLENoisePacketHandler`.
///
/// All queue hops (collections barrier writes, main-actor UI notification)
/// and every `noiseService.*` crypto call live inside the closures supplied by
/// `BLEService`, keeping the handler queue-agnostic and synchronously testable.
struct BLENoisePacketHandlerEnvironment {
    /// Local peer identity at the time the packet is handled.
    let localPeerID: () -> PeerID
    /// Local peer ID bytes used as the sender of handshake responses.
    let localPeerIDData: () -> Data
    /// TTL value used for direct (non-relayed) packets.
    let messageTTL: UInt8
    /// Current time source.
    let now: () -> Date
    /// Processes an inbound handshake message, returning its optional response
    /// and whether that exact candidate authenticated (crypto).
    let processHandshakeMessage:
        (_ peerID: PeerID, _ message: Data) throws
            -> NoiseHandshakeProcessingResult
    /// Whether any Noise session (established or pending) exists for the peer (crypto).
    let hasNoiseSession: (PeerID) -> Bool
    /// Whether an inbound ordinary XX responder is waiting for message 3.
    let isAwaitingResponderHandshakeCompletion: (PeerID) -> Bool
    /// Initiates a fresh Noise handshake with the peer (crypto + send).
    let initiateHandshake: (PeerID) -> Void
    /// Broadcasts a packet on the mesh (caller is already on the message queue).
    let broadcastPacket: (BitchatPacket) -> Void
    /// Updates the registry last-seen timestamp for the peer (async barrier write).
    let updatePeerLastSeen: (PeerID) -> Void
    /// Decrypts an encrypted payload from the peer (crypto).
    let decrypt: (_ payload: Data, _ peerID: PeerID) throws -> BLENoiseDecryptionResult
    /// Clears the peer's Noise session after an unrecoverable decrypt failure (crypto).
    let clearSession: (PeerID) -> Void
    /// Consumes session-authenticated protocol state inside the transport. It
    /// must never escape to UI or Nostr payload dispatch.
    let handleAuthenticatedPeerState: (
        _ peerID: PeerID,
        _ payload: Data,
        _ sessionGeneration: UUID
    ) -> Void
    /// Delivers `.noisePayloadReceived` to the UI as one main-actor hop.
    let deliverNoisePayload: (
        _ peerID: PeerID,
        _ type: NoisePayloadType,
        _ payload: Data,
        _ timestamp: Date
    ) -> Void
}

/// Orchestrates the Noise session domain for inbound packets: handshake
/// processing (with response), encrypted payload decryption and dispatch,
/// and session recovery on decrypt failure.
final class BLENoisePacketHandler {
    private struct DeferredCiphertext {
        let packet: BitchatPacket
        let receivedAt: Date
    }

    /// Early post-handshake packets are normally tiny control messages or
    /// queued DMs. Keep the recovery surface deliberately small so an
    /// unauthenticated half-handshake cannot create an unbounded memory queue.
    private static let maxDeferredPacketsPerPeer = 4
    private static let maxDeferredPacketsGlobal = 32
    /// One legacy sender can immediately follow message 3 with the largest
    /// valid private-file ciphertext and has no application-level retry. Keep
    /// room for that packet plus a small control-message budget.
    private static let maxDeferredBytes =
        NoiseSecurityConstants.maxPrivateFileCiphertextSize + 256 * 1024
    private static let deferredLifetime =
        NoiseSecurityConstants.ordinaryResponderHandshakeTimeout

    private let environment: BLENoisePacketHandlerEnvironment
    private let deferredLock = NSLock()
    private var deferredCiphertexts: [PeerID: [DeferredCiphertext]] = [:]
    private var deferredCiphertextBytes = 0

    init(environment: BLENoisePacketHandlerEnvironment) {
        self.environment = environment
    }

    /// Returns true when the handshake message was processed successfully.
    /// Callers use this to distinguish an authenticated reconnect completion
    /// from a rejected ordinary responder while rollback state is restored.
    @discardableResult
    func handleHandshake(_ packet: BitchatPacket, from peerID: PeerID) -> Bool {
        handleHandshakeWithResult(packet, from: peerID).processed
    }

    func handleHandshakeWithResult(
        _ packet: BitchatPacket,
        from peerID: PeerID
    ) -> BLENoiseHandshakeHandlingResult {
        let env = environment
        // Use NoiseEncryptionService for handshake processing
        if PeerID(hexData: packet.recipientID) == env.localPeerID() {
            // Handshake is for us
            do {
                let result = try env.processHandshakeMessage(
                    peerID,
                    packet.payload
                )
                if let response = result.response {
                    // Send response
                    let responsePacket = BitchatPacket(
                        type: MessageType.noiseHandshake.rawValue,
                        senderID: env.localPeerIDData(),
                        recipientID: Data(hexString: peerID.id),
                        timestamp: UInt64(env.now().timeIntervalSince1970 * 1000),
                        payload: response,
                        signature: nil,
                        ttl: env.messageTTL
                    )
                    // We're on messageQueue from delegate callback
                    env.broadcastPacket(responsePacket)
                }

                // The serialized authentication callback installs transport
                // state before it drains any bounded early ciphertext.
                return BLENoiseHandshakeHandlingResult(
                    processed: true,
                    didEstablishAuthenticatedSession:
                        result.didEstablishAuthenticatedSession
                )
            } catch let managedFailure as NoiseManagedHandshakeFailure {
                SecureLogger.error(
                    "Failed to process handshake; manager owns recovery: \(managedFailure.underlying)"
                )
                return BLENoiseHandshakeHandlingResult(
                    processed: false,
                    didEstablishAuthenticatedSession: false
                )
            } catch NoiseSessionError.peerIdentityMismatch {
                // The responder was already discarded by the session manager.
                // Do not let a spoofed claimed ID trigger a fresh outbound
                // handshake or recreate state for the attacker-selected ID.
                SecureLogger.warning(
                    "Rejected Noise handshake whose static key does not match \(peerID.id.prefix(8))…",
                    category: .security
                )
                return BLENoiseHandshakeHandlingResult(
                    processed: false,
                    didEstablishAuthenticatedSession: false
                )
            } catch {
                SecureLogger.error("Failed to process handshake: \(error)")
                // Try initiating a new handshake
                if !env.hasNoiseSession(peerID) {
                    env.initiateHandshake(peerID)
                }
                return BLENoiseHandshakeHandlingResult(
                    processed: false,
                    didEstablishAuthenticatedSession: false
                )
            }
        }
        return BLENoiseHandshakeHandlingResult(
            processed: false,
            didEstablishAuthenticatedSession: false
        )
    }

    func handleEncrypted(_ packet: BitchatPacket, from peerID: PeerID) {
        handleEncrypted(packet, from: peerID, isDeferredRetry: false)
    }

    /// Called by the transport's serialized authentication callback after it
    /// has installed state for the promoted or restored session generation.
    func handleSessionAuthenticated(_ peerID: PeerID) {
        drainDeferredCiphertextsIfReady(for: peerID)
    }

    /// Synchronously discards ciphertext retained for a pre-panic Noise
    /// generation. The handler survives the service's identity replacement,
    /// so keeping this queue would replay old bytes after post-panic auth.
    func resetForPanic() {
        deferredLock.lock()
        deferredCiphertexts.removeAll(keepingCapacity: false)
        deferredCiphertextBytes = 0
        deferredLock.unlock()
    }

    private func handleEncrypted(
        _ packet: BitchatPacket,
        from peerID: PeerID,
        isDeferredRetry: Bool
    ) {
        let env = environment
        guard let recipientID = PeerID(hexData: packet.recipientID) else {
            SecureLogger.warning("⚠️ Encrypted message has no recipient ID", category: .session)
            return
        }

        if recipientID != env.localPeerID() {
            SecureLogger.debug("🔐 Encrypted message not for me (for \(recipientID.id.prefix(8))…, I am \(env.localPeerID().id.prefix(8))…)", category: .session)
            return
        }

        // Update lastSeen for the peer we received from (important for private messages)
        env.updatePeerLastSeen(peerID)

        do {
            let decryption = try env.decrypt(packet.payload, peerID)
            let decrypted = decryption.plaintext
            guard decrypted.count > 0 else { return }

            // First byte indicates the payload type
            let payloadType = decrypted[0]
            let payloadData = decrypted.dropFirst()

            guard let noisePayloadType = NoisePayloadType.decoded(rawValue: payloadType) else {
                SecureLogger.warning("⚠️ Unknown noise payload type: \(payloadType)")
                return
            }

            SecureLogger.debug("🔐 Decrypted noise payload type \(noisePayloadType.description) from \(peerID.id.prefix(8))…", category: .session)

            if noisePayloadType == .authenticatedPeerState {
                env.handleAuthenticatedPeerState(
                    peerID,
                    Data(payloadData),
                    decryption.sessionGeneration
                )
                return
            }

            let ts = Date(timeIntervalSince1970: Double(packet.timestamp) / 1000)
            env.deliverNoisePayload(peerID, noisePayloadType, Data(payloadData), ts)
        } catch NoiseEncryptionError.transportGenerationNotReady {
            if isDeferredRetry {
                SecureLogger.warning(
                    "Dropping deferred Noise ciphertext from \(peerID.id.prefix(8))… because its authenticated transport generation changed again",
                    category: .session
                )
                return
            }
            // The manager promoted or restored keys before BLE's serialized
            // callback installed generation-bound transport state. The
            // manager rejected this before decrypting, so replay is safe.
            deferCiphertext(packet, from: peerID)
        } catch NoiseEncryptionError.sessionNotEstablished {
            if isDeferredRetry {
                SecureLogger.warning(
                    "Dropping deferred Noise ciphertext from \(peerID.id.prefix(8))… because the authenticated session is unavailable",
                    category: .session
                )
                return
            }
            // We received an encrypted message before establishing a session with this peer.
            // An initiator may already have sent message 3 followed by this
            // ciphertext, with BLE delivering the ciphertext first.
            if env.isAwaitingResponderHandshakeCompletion(peerID) {
                deferCiphertext(packet, from: peerID)
                return
            }
            // Otherwise trigger a handshake so future messages can decrypt.
            SecureLogger.debug("🔑 Encrypted message from \(peerID.id.prefix(8))… without session; initiating handshake")
            if !env.hasNoiseSession(peerID) {
                env.initiateHandshake(peerID)
            }
        } catch {
            if isDeferredRetry {
                // An early packet cannot tear down the authenticated session
                // merely because its single bounded retry still fails.
                SecureLogger.warning(
                    "Dropping deferred Noise ciphertext from \(peerID.id.prefix(8))… after retry failed: \(error)",
                    category: .session
                )
                return
            }
            // A responder may retain an older transport as receive-only
            // rollback state while ordinary XX waits for message 3. New-key
            // ciphertext can fail against those retained receive keys first.
            if env.isAwaitingResponderHandshakeCompletion(peerID) {
                if isDeferrableEarlyHandshakeFailure(error) {
                    deferCiphertext(packet, from: peerID)
                } else {
                    SecureLogger.warning(
                        "Dropping invalid Noise ciphertext from \(peerID.id.prefix(8))… while responder handshake is completing: \(error)",
                        category: .session
                    )
                }
                return
            }
            if isDropOnlyCiphertextFailure(error) {
                // The packet is attacker-controlled and did not prove a
                // transport-state failure. Never let malformed, replayed,
                // forged, oversized, or rate-limited bytes evict working keys.
                SecureLogger.warning(
                    "Dropping rejected Noise ciphertext from \(peerID.id.prefix(8))… without clearing its session: \(error)",
                    category: .security
                )
                return
            }
            // Decryption failed - clear the corrupted session and re-initiate handshake
            // Only local/session lifecycle failures reach this path.
            SecureLogger.error("❌ Failed to decrypt message from \(peerID.id.prefix(8))…: \(error) - clearing session and re-initiating handshake")
            env.clearSession(peerID)
            env.initiateHandshake(peerID)
        }
    }

    private func isDeferrableEarlyHandshakeFailure(_ error: Error) -> Bool {
        if let noiseError = error as? NoiseError {
            switch noiseError {
            case .authenticationFailure, .replayDetected:
                return true
            default:
                return false
            }
        }
        if let cryptoError = error as? CryptoKitError,
           case .authenticationFailure = cryptoError {
            return true
        }
        return false
    }

    private func isDropOnlyCiphertextFailure(_ error: Error) -> Bool {
        if let securityError = error as? NoiseSecurityError {
            switch securityError {
            case .messageTooLarge, .rateLimitExceeded, .invalidPeerID:
                return true
            case .sessionExpired, .sessionExhausted:
                return false
            }
        }
        if let noiseError = error as? NoiseError {
            switch noiseError {
            case .invalidCiphertext, .authenticationFailure, .replayDetected:
                return true
            case .uninitializedCipher, .handshakeComplete,
                    .handshakeNotComplete, .missingLocalStaticKey,
                    .missingKeys, .invalidMessage, .invalidPublicKey,
                    .nonceExceeded:
                return false
            }
        }
        return error is CryptoKitError
    }

    private func deferCiphertext(_ packet: BitchatPacket, from peerID: PeerID) {
        guard NoiseSecurityValidator.validatePrivateFileCiphertextSize(
            packet.payload
        ) else {
            SecureLogger.warning(
                "Dropping oversized early Noise ciphertext from \(peerID.id.prefix(8))…",
                category: .security
            )
            return
        }

        let now = environment.now()
        deferredLock.lock()
        defer { deferredLock.unlock() }
        purgeExpiredCiphertextsLocked(now: now)

        let peerCount = deferredCiphertexts[peerID]?.count ?? 0
        let globalCount = deferredCiphertexts.values.reduce(0) {
            $0 + $1.count
        }
        guard peerCount < Self.maxDeferredPacketsPerPeer,
              globalCount < Self.maxDeferredPacketsGlobal,
              deferredCiphertextBytes + packet.payload.count
                <= Self.maxDeferredBytes else {
            SecureLogger.warning(
                "Dropping early Noise ciphertext from \(peerID.id.prefix(8))… because the handshake buffer is full",
                category: .security
            )
            return
        }

        deferredCiphertexts[peerID, default: []].append(
            DeferredCiphertext(packet: packet, receivedAt: now)
        )
        deferredCiphertextBytes += packet.payload.count
        SecureLogger.debug(
            "Deferring early Noise ciphertext from \(peerID.id.prefix(8))… until responder handshake completion",
            category: .session
        )
    }

    private func drainDeferredCiphertextsIfReady(for peerID: PeerID) {
        let env = environment
        guard !env.isAwaitingResponderHandshakeCompletion(peerID),
              env.hasNoiseSession(peerID) else {
            return
        }

        let now = env.now()
        deferredLock.lock()
        purgeExpiredCiphertextsLocked(now: now)
        let deferred = deferredCiphertexts.removeValue(forKey: peerID) ?? []
        deferredCiphertextBytes -= deferred.reduce(0) {
            $0 + $1.packet.payload.count
        }
        deferredLock.unlock()

        guard !deferred.isEmpty else { return }
        SecureLogger.debug(
            "Retrying \(deferred.count) early Noise ciphertext packet(s) from \(peerID.id.prefix(8))… after handshake completion",
            category: .session
        )
        for item in deferred {
            handleEncrypted(item.packet, from: peerID, isDeferredRetry: true)
        }
    }

    private func purgeExpiredCiphertextsLocked(now: Date) {
        for peerID in Array(deferredCiphertexts.keys) {
            guard let items = deferredCiphertexts[peerID] else { continue }
            let retained = items.filter {
                now.timeIntervalSince($0.receivedAt) <= Self.deferredLifetime
            }
            guard retained.count != items.count else { continue }

            deferredCiphertextBytes -= items.reduce(0) {
                $0 + $1.packet.payload.count
            }
            deferredCiphertextBytes += retained.reduce(0) {
                $0 + $1.packet.payload.count
            }
            if retained.isEmpty {
                deferredCiphertexts.removeValue(forKey: peerID)
            } else {
                deferredCiphertexts[peerID] = retained
            }
        }
    }
}
