import Foundation

struct PeerIDResolver {
    /// Returns a 16-hex short peer ID derived from a 64-hex Noise public key if needed
    static func toShortID(_ id: String) -> String {
        if id.count == 64, let data = Data(hexString: id) {
            return PeerIDUtils.derivePeerID(fromPublicKey: data)
        }
        return id
    }
}

