import Foundation

// RelayDecision encapsulates a single relay scheduling choice.
struct RelayDecision {
    let shouldRelay: Bool
    let newTTL: UInt8
    let delayMs: Int
}

// RelayController centralizes flood control policy for relays.
struct RelayController {
    static func decide(ttl: UInt8,
                       senderIsSelf: Bool,
                       recipientIsSelf: Bool = false,
                       isEncrypted _: Bool,
                       isDirectedEncrypted: Bool,
                       isFragment: Bool,
                       isDirectedFragment: Bool,
                       isHandshake: Bool,
                       isAnnounce: Bool,
                       isRequestSync: Bool = false,
                       isUrgentBoardPost: Bool = false,
                       isVoiceFrame: Bool = false,
                       degree: Int,
                       highDegreeThreshold: Int) -> RelayDecision {
        let ttlCap = min(ttl, TransportConfig.messageTTLDefault)

        // REQUEST_SYNC is link-local: never relay it, even when a peer crafts
        // one with TTL headroom to turn every reachable node into a responder.
        if isRequestSync {
            return RelayDecision(shouldRelay: false, newTTL: ttlCap, delayMs: 0)
        }

        // Suppress obvious non-relays
        if ttlCap <= 1 || senderIsSelf || recipientIsSelf {
            return RelayDecision(shouldRelay: false, newTTL: ttlCap, delayMs: 0)
        }

        // For session-critical or directed traffic, be deterministic and reliable
        if isHandshake || isDirectedFragment || isDirectedEncrypted {
            // Always relay with no TTL cap for these types
            let newTTL = ttlCap &- 1
            // Slight jitter to desynchronize without adding too much latency
            // Tighter for faster multi-hop handshakes and directed DMs
            let delayRange: ClosedRange<Int> = isHandshake ? 10...35 : 20...60
            let delayMs = Int.random(in: delayRange)
            return RelayDecision(shouldRelay: true, newTTL: newTTL, delayMs: delayMs)
        }

        // Live voice floods with the fragment policy: the dense clamp
        // contains the sustained ~15 pkt/s per-talker stream, and the tight
        // jitter window keeps per-hop latency inside the receiver's ~350 ms
        // jitter buffer across multi-hop paths.
        if isFragment || isVoiceFrame {
            // Dense graphs clamp harder to contain full-fanout fragment floods;
            // sparse graphs get full depth so media reaches as far as text.
            let fragmentCap = degree >= highDegreeThreshold
                ? TransportConfig.bleFragmentRelayTtlCapDense
                : TransportConfig.bleFragmentRelayTtlCap
            let ttlLimit = min(ttlCap, fragmentCap)
            guard ttlLimit > 1 else {
                return RelayDecision(shouldRelay: false, newTTL: ttlLimit, delayMs: 0)
            }
            let newTTL = ttlLimit &- 1
            let delayMs = Int.random(in: TransportConfig.bleFragmentRelayMinDelayMs...TransportConfig.bleFragmentRelayMaxDelayMs)
            return RelayDecision(shouldRelay: true, newTTL: newTTL, delayMs: delayMs)
        }

        // TTL clamping for broadcast
        // - Dense graphs: keep lower but still allow multi-hop bridging
        // - Thin chains (degree <= 2): every hop counts and flood cost is
        //   minimal, so relay at full incoming depth
        // - Announces (and urgent board posts) get a bit more headroom
        let ttlLimit: UInt8 = {
            if degree >= highDegreeThreshold {
                return max(UInt8(2), min(ttlCap, UInt8(5)))
            }
            if degree <= 2 {
                return ttlCap
            }
            let preferred = UInt8((isAnnounce || isUrgentBoardPost) ? 7 : 6)
            return max(UInt8(2), min(ttlCap, preferred))
        }()
        let newTTL = ttlLimit &- 1

        // Wider jitter window to allow duplicate suppression to win more often
        // For sparse graphs (<=2), relay quickly to avoid cancellation races
        let delayMs: Int
        switch degree {
        case 0...2: delayMs = Int.random(in: 10...40)
        case 3...5: delayMs = Int.random(in: 60...150)
        case 6...9: delayMs = Int.random(in: 80...180)
        default:    delayMs = Int.random(in: 100...220)
        }
        return RelayDecision(shouldRelay: true, newTTL: newTTL, delayMs: delayMs)
    }
}
