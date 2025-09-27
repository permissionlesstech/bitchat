import Foundation

struct PeerIDUtils {
    /// Derive the stable 16-hex peer ID from a Noise static public key
    static func derivePeerID(fromPublicKey publicKey: Data) -> String {
        String(publicKey.sha256Fingerprint().prefix(16))
    }
}

