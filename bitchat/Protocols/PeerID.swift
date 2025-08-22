import Foundation
import CryptoKit

// MARK: - Peer ID Utilities

struct PeerIDUtils {
    /// Derive the stable 16-hex peer ID from a Noise static public key
    static func derivePeerID(fromPublicKey publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}

