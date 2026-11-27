import Foundation

/// A single raw socket frame awaiting off-main parse + Schnorr verification.
struct InboundFrame: Sendable {
    let message: URLSessionWebSocketTask.Message
}

/// Lock-guarded registry of per-relay inbound streams.
///
/// The raw WebSocket receive callback is not main-actor isolated, so it needs a
/// `Sendable` path to route a frame to the correct relay's stream without a
/// per-frame hop onto the main actor. Pipeline lifecycle (start/finish) is
/// driven from the main actor; frame delivery (`yield`) can come from any
/// thread. All access is serialized by a single lock — contention is negligible
/// because the guarded critical section is only a dictionary lookup + yield.
final class InboundFrameRouter: @unchecked Sendable {
    /// Full cryptographic identity of a Nostr event being verified.
    /// Including every field covered by the NIP-01 event ID + signature ensures
    /// a forged/tampered copy can never coalesce onto — or poison — a genuine copy.
    private struct VerificationFingerprint: Hashable {
        let id: String
        let pubkey: String
        let createdAt: Int
        let kind: Int
        let tags: [[String]]
        let content: String
        let sig: String?

        init(event: NostrEvent) {
            self.id = event.id
            self.pubkey = event.pubkey
            self.createdAt = event.created_at
            self.kind = event.kind
            self.tags = event.tags
            self.content = event.content
            self.sig = event.sig
        }

        static func == (lhs: VerificationFingerprint, rhs: VerificationFingerprint) -> Bool {
            lhs.id == rhs.id &&
            lhs.pubkey == rhs.pubkey &&
            lhs.createdAt == rhs.createdAt &&
            lhs.kind == rhs.kind &&
            lhs.sig == rhs.sig &&
            lhs.content == rhs.content &&
            lhs.tags == rhs.tags
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(pubkey)
            hasher.combine(createdAt)
            hasher.combine(kind)
            hasher.combine(sig)
            hasher.combine(content)
            hasher.combine(tags)
        }
    }

    private let lock = NSLock()
    private var continuations: [String: AsyncStream<InboundFrame>.Continuation] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var activeConnections: [String: ObjectIdentifier] = [:]
    private var inFlightVerifications: [VerificationFingerprint: [CheckedContinuation<Bool, Never>]] = [:]

    /// Start a relay's stream + consumer if one does not already exist.
    /// Returns true when a new pipeline was created. The bounded
    /// `.bufferingNewest` policy makes a single relay shed its OWN oldest
    /// frames under a flood, never other relays' frames. Buffered memory per
    /// relay is bounded (not eliminated) at the frame cap times the per-frame
    /// byte cap (`maximumMessageSize`) — see TransportConfig.
    func startPipeline(
        for relayUrl: String,
        connectionID: ObjectIdentifier,
        makeConsumer: (AsyncStream<InboundFrame>) -> Task<Void, Never>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        activeConnections[relayUrl] = connectionID
        if continuations[relayUrl] != nil { return false }
        let (stream, continuation) = AsyncStream<InboundFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(TransportConfig.nostrInboundPerRelayBufferCap)
        )
        continuations[relayUrl] = continuation
        tasks[relayUrl] = makeConsumer(stream)
        return true
    }

    /// Route a frame to a relay's stream if `connectionID` is still the active
    /// socket for `relayUrl`. Returns whether the caller should re-arm receive.
    @discardableResult
    func yield(_ frame: InboundFrame, to relayUrl: String, from connectionID: ObjectIdentifier) -> Bool {
        lock.lock()
        guard activeConnections[relayUrl] == connectionID,
              let continuation = continuations[relayUrl] else {
            lock.unlock()
            return false
        }
        lock.unlock()
        continuation.yield(frame)
        return true
    }

    /// Verifies `event.isValidSignature()` while coalescing simultaneous fan-in
    /// deliveries of byte-identical events across multiple relay pipelines.
    func verifySignatureCoalesced(_ event: NostrEvent) async -> Bool {
        let fingerprint = VerificationFingerprint(event: event)
        let isOwner: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if inFlightVerifications[fingerprint] != nil {
                return false
            }
            inFlightVerifications[fingerprint] = []
            return true
        }()

        if isOwner {
            let valid = event.isValidSignature()
            let waiters: [CheckedContinuation<Bool, Never>] = {
                lock.lock()
                defer { lock.unlock() }
                return inFlightVerifications.removeValue(forKey: fingerprint) ?? []
            }()
            for waiter in waiters {
                waiter.resume(returning: valid)
            }
            return valid
        }

        return await withCheckedContinuation { continuation in
            lock.lock()
            if var waiters = inFlightVerifications[fingerprint] {
                waiters.append(continuation)
                inFlightVerifications[fingerprint] = waiters
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume(returning: event.isValidSignature())
            }
        }
    }

    /// Finish a relay's stream. The consumer drains any already-buffered frames
    /// before exiting, so in-flight verified events are still delivered.
    func finishPipeline(for relayUrl: String) {
        lock.lock()
        activeConnections.removeValue(forKey: relayUrl)
        let continuation = continuations.removeValue(forKey: relayUrl)
        tasks.removeValue(forKey: relayUrl)
        lock.unlock()
        continuation?.finish()
    }

    func finishAll() {
        lock.lock()
        let allContinuations = continuations
        activeConnections.removeAll()
        continuations.removeAll()
        tasks.removeAll()
        lock.unlock()
        for continuation in allContinuations.values {
            continuation.finish()
        }
    }
}

enum ParsedInbound {
    case event(subId: String, event: NostrEvent)
    case ok(eventId: String, success: Bool, reason: String)
    case eose(subscriptionId: String)

    init?(_ message: URLSessionWebSocketTask.Message) {
        guard let data = message.dataWithinInboundLimit,
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.count >= 2,
              let type = array[0] as? String else {
            return nil
        }

        switch type {
        case "EVENT":
            if array.count >= 3,
               let subId = array[1] as? String,
               let eventDict = array[2] as? [String: Any],
               let event = try? NostrEvent(from: eventDict) {
                self = .event(subId: subId, event: event)
                return
            }
            return nil
        case "EOSE":
            if let subId = array[1] as? String {
                self = .eose(subscriptionId: subId)
                return
            }
            return nil
        case "OK":
            if array.count >= 3,
               let eventId = array[1] as? String,
               let success = array[2] as? Bool {
                let reason = array.count >= 4 ? (array[3] as? String ?? "no reason given") : "no reason given"
                self = .ok(eventId: eventId, success: success, reason: reason)
                return
            }
            return nil
        default:
            return nil
        }
    }
}

private extension URLSessionWebSocketTask.Message {
    /// Prefer rejecting oversized frames before UTF-8/Data materialization
    /// where we can (string length), and always before JSON parse.
    var dataWithinInboundLimit: Data? {
        let maxBytes = TransportConfig.nostrMaxInboundMessageBytes
        switch self {
        case .string(let text):
            guard text.utf8.count <= maxBytes else { return nil }
            return text.data(using: .utf8)
        case .data(let data):
            guard data.count <= maxBytes else { return nil }
            return data
        @unknown default:
            return nil
        }
    }
}
