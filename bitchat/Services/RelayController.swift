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
                       isDirectedFragment: Bool,
                       isHandshake: Bool,
                       degree: Int,
                       highDegreeThreshold: Int) -> RelayDecision {
        // Suppress obvious non-relays
        if ttl <= 1 || senderIsSelf { return RelayDecision(shouldRelay: false, newTTL: ttl, delayMs: 0) }

        // Degree-aware probability to reduce floods in dense graphs
        let baseProb: Double
        switch degree {
        case 0...2: baseProb = 1.0
        case 3...4: baseProb = 0.9
        case 5...6: baseProb = 0.7
        case 7...9: baseProb = 0.55
        default:    baseProb = 0.45
        }
        var prob = baseProb
        if isHandshake { prob = max(0.3, baseProb - 0.2) }

        // Sample a forwarding decision
        let shouldRelay = Double.random(in: 0...1) <= prob

        // TTL clamping in dense graphs
        let ttlCap: UInt8 = degree >= highDegreeThreshold ? 3 : 5
        let clamped = max(1, min(ttl, ttlCap))
        let newTTL = clamped &- 1

        // Short jitter to desynchronize rebroadcasts
        let delayMs = Int.random(in: 20...80)
        return RelayDecision(shouldRelay: shouldRelay, newTTL: newTTL, delayMs: delayMs)
    }
}

