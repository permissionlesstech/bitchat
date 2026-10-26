import Foundation
import CryptoKit

enum CryptoError: Error { case badKey, badData }

/// End-to-end encryption for direct messages (see PROTOCOL.md).
/// X25519 key agreement -> HKDF-SHA256 -> ChaCha20-Poly1305. Wire format of a sealed message: nonce(12) || ciphertext || tag(16).
final class MeshCrypto {
    private let privateKey: Curve25519.KeyAgreement.PrivateKey

    init(privateKeyData: Data) throws {
        privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
    }
    init() { privateKey = Curve25519.KeyAgreement.PrivateKey() }

    var privateKeyData: Data { privateKey.rawRepresentation }
    var publicKey: Data { privateKey.publicKey.rawRepresentation }
    var fingerprint: String { MeshCrypto.fingerprint(publicKey) }

    /// First 128 bits of SHA-256(public key), shown as 8 groups of 4 hex digits on two lines.
    static func fingerprint(_ publicKey: Data) -> String {
        let hex = SHA256.hash(data: publicKey).map { String(format: "%02X", $0) }.joined()
        let groups = stride(from: 0, to: 32, by: 4).map { String(hex.dropFirst($0).prefix(4)) }
        return groups[0..<4].joined(separator: " ") + "\n" + groups[4..<8].joined(separator: " ")
    }

    private func key(with peerPK: Data, myID: String, peerID: String) throws -> SymmetricKey {
        guard peerPK.count == 32, let pk = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPK) else { throw CryptoError.badKey }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: pk)
        let info = [myID, peerID].sorted().joined(separator: "|")
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("nearsend-chat-v2".utf8),
                                              sharedInfo: Data(info.utf8), outputByteCount: 32)
    }

    func seal(_ text: String, peerPK: Data, myID: String, peerID: String, aad: String, nonce: Data? = nil) throws -> Data {
        let k = try key(with: peerPK, myID: myID, peerID: peerID)
        let n = try nonce.map { try ChaChaPoly.Nonce(data: $0) } ?? ChaChaPoly.Nonce()
        return try ChaChaPoly.seal(Data(text.utf8), using: k, nonce: n, authenticating: Data(aad.utf8)).combined
    }

    func open(_ combined: Data, peerPK: Data, myID: String, peerID: String, aad: String) throws -> String {
        let k = try key(with: peerPK, myID: myID, peerID: peerID)
        let box = try ChaChaPoly.SealedBox(combined: combined)
        let plain = try ChaChaPoly.open(box, using: k, authenticating: Data(aad.utf8))
        guard let s = String(data: plain, encoding: .utf8) else { throw CryptoError.badData }
        return s
    }
}
