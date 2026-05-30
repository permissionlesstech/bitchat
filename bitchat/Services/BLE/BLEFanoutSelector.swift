import BitFoundation
import CryptoKit
import Foundation

struct BLEFanoutSelection: Equatable {
    let peripheralIDs: Set<String>
    let centralIDs: Set<String>
}

enum BLEFanoutSelector {
    static func selectLinks(
        peripheralIDs: [String],
        centralIDs: [String],
        ingressLink: BLEIngressLinkID?,
        excludedLinks: Set<BLEIngressLinkID> = [],
        directedPeerHint: PeerID?,
        packetType: UInt8,
        messageID: String
    ) -> BLEFanoutSelection {
        let allowed = allowedLinks(
            peripheralIDs: peripheralIDs,
            centralIDs: centralIDs,
            ingressLink: ingressLink,
            excludedLinks: excludedLinks
        )

        guard shouldSubset(packetType: packetType, directedPeerHint: directedPeerHint) else {
            return BLEFanoutSelection(
                peripheralIDs: Set(allowed.peripheralIDs),
                centralIDs: Set(allowed.centralIDs)
            )
        }

        return BLEFanoutSelection(
            peripheralIDs: deterministicSubset(
                ids: allowed.peripheralIDs,
                k: subsetSize(for: allowed.peripheralIDs.count),
                seed: messageID
            ),
            centralIDs: deterministicSubset(
                ids: allowed.centralIDs,
                k: subsetSize(for: allowed.centralIDs.count),
                seed: messageID
            )
        )
    }

    private static func allowedLinks(
        peripheralIDs: [String],
        centralIDs: [String],
        ingressLink: BLEIngressLinkID?,
        excludedLinks: Set<BLEIngressLinkID>
    ) -> (peripheralIDs: [String], centralIDs: [String]) {
        var allowedPeripheralIDs = peripheralIDs
        var allowedCentralIDs = centralIDs
        var blockedLinks = excludedLinks

        if let ingressLink {
            blockedLinks.insert(ingressLink)
        }

        allowedPeripheralIDs.removeAll { blockedLinks.contains(.peripheral($0)) }
        allowedCentralIDs.removeAll { blockedLinks.contains(.central($0)) }

        return (allowedPeripheralIDs, allowedCentralIDs)
    }

    private static func shouldSubset(packetType: UInt8, directedPeerHint: PeerID?) -> Bool {
        directedPeerHint == nil
            && packetType != MessageType.fragment.rawValue
            && packetType != MessageType.announce.rawValue
            && packetType != MessageType.requestSync.rawValue
    }

    private static func subsetSize(for count: Int) -> Int {
        guard count > 0 else { return 0 }
        if count <= 2 { return count }

        var value = count - 1
        var bits = 0
        while value > 0 {
            value >>= 1
            bits += 1
        }
        return min(count, max(1, bits + 1))
    }

    private static func deterministicSubset(ids: [String], k: Int, seed: String) -> Set<String> {
        guard k > 0 && ids.count > k else { return Set(ids) }

        var scored: [(score: [UInt8], id: String)] = []
        for id in ids {
            let data = (seed + "::" + id).data(using: .utf8) ?? Data()
            let digest = Array(SHA256.hash(data: data))
            scored.append((digest, id))
        }

        scored.sort { lhs, rhs in
            for index in 0..<min(lhs.score.count, rhs.score.count) {
                if lhs.score[index] != rhs.score[index] {
                    return lhs.score[index] < rhs.score[index]
                }
            }
            return lhs.id < rhs.id
        }

        return Set(scored.prefix(k).map(\.id))
    }
}
