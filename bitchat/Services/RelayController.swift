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
                       isEncrypted: Bool,
                       isDirectedEncrypted: Bool,
                       isDirectedFragment: Bool,
                       isHandshake: Bool,
                       isAnnounce: Bool,
                       degree: Int,
                       highDegreeThreshold: Int) -> RelayDecision {
        // Suppress obvious non-relays
        if ttl <= 1 || senderIsSelf { return RelayDecision(shouldRelay: false, newTTL: ttl, delayMs: 0) }

        // For session-critical or directed traffic, be deterministic and reliable
        if isHandshake || isDirectedFragment || isDirectedEncrypted {
            // Always relay with no TTL cap for these types
            let newTTL = (ttl &- 1)
            // Slight jitter to desynchronize without adding too much latency
            // Tighter for faster multi-hop handshakes and directed DMs
            let delayRange: ClosedRange<Int> = isHandshake ? 10...35 : 20...60
            let delayMs = Int.random(in: delayRange)
            return RelayDecision(shouldRelay: true, newTTL: newTTL, delayMs: delayMs)
        }

        // Degree-aware probability to reduce floods in dense graphs (broadcast/public)
        let baseProb: Double
        switch degree {
        case 0...2: baseProb = 1.0
        case 3...4: baseProb = 0.9
        case 5...6: baseProb = 0.7
        case 7...9: baseProb = 0.55
        default:    baseProb = 0.45
        }
        let prob = baseProb
        let shouldRelay = Double.random(in: 0...1) <= prob

        // TTL clamping for broadcast
        // - Dense graphs: keep very low to avoid floods
        // - Sparse graphs: allow slightly longer reach for multi-hop discovery
        // - Announces in sparse graphs get a bit more headroom
        let ttlCap: UInt8 = {
            if degree >= highDegreeThreshold { return 3 }
            return isAnnounce ? 7 : 6
        }()
        let clamped = max(1, min(ttl, ttlCap))
        let newTTL = clamped &- 1

        // Wider jitter window to allow duplicate suppression to win more often
        // For sparse graphs (<=2), relay quickly to avoid cancellation races
        let delayMs: Int
        switch degree {
        case 0...2: delayMs = Int.random(in: 10...40)
        case 3...5: delayMs = Int.random(in: 60...150)
        case 6...9: delayMs = Int.random(in: 80...180)
        default:    delayMs = Int.random(in: 100...220)
        }
        return RelayDecision(shouldRelay: shouldRelay, newTTL: newTTL, delayMs: delayMs)
    }
}
