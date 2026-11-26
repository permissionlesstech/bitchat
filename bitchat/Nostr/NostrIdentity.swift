import Foundation
import P256K

/// Manages the secp256k1 identity used by BitChat's Nostr relay features,
/// including the proprietary private-envelope transport.
struct NostrIdentity: Codable {
    let privateKey: Data
    let publicKey: Data
    let npub: String // Bech32-encoded public key
    /// Precomputed lowercase hex representation of `publicKey` (32-byte x-only),
    /// stored once at construction instead of re-encoding on every render/lookup.
    let publicKeyHex: String

    private enum CodingKeys: String, CodingKey {
        case privateKey
        case publicKey
        case npub
    }

    /// Memberwise initializer
    init(privateKey: Data, publicKey: Data, npub: String, createdAt _: Date) {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.npub = npub
        self.publicKeyHex = publicKey.hexEncodedString()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let privateKey = try container.decode(Data.self, forKey: .privateKey)
        let publicKey = try container.decode(Data.self, forKey: .publicKey)
        let npub = try container.decode(String.self, forKey: .npub)
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.npub = npub
        self.publicKeyHex = publicKey.hexEncodedString()
    }
    
    /// Generate a new Nostr identity
    static func generate() throws -> NostrIdentity {
        // Generate Schnorr key for Nostr
        let schnorrKey = try P256K.Schnorr.PrivateKey()
        let xOnlyPubkey = Data(schnorrKey.xonly.bytes)
        let npub = try Bech32.encode(hrp: "npub", data: xOnlyPubkey)
        
        return NostrIdentity(
            privateKey: schnorrKey.dataRepresentation,
            publicKey: xOnlyPubkey, // Store x-only public key
            npub: npub,
            createdAt: Date()
        )
    }
    
    /// Initialize from existing private key data
    init(privateKeyData: Data) throws {
        let schnorrKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKeyData)
        let xOnlyPubkey = Data(schnorrKey.xonly.bytes)
        
        self.privateKey = privateKeyData
        self.publicKey = xOnlyPubkey
        self.npub = try Bech32.encode(hrp: "npub", data: xOnlyPubkey)
        self.publicKeyHex = xOnlyPubkey.hexEncodedString()
    }
    
    /// Get Schnorr signing key for Nostr event signatures
    func schnorrSigningKey() throws -> P256K.Schnorr.PrivateKey {
        try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
    }
}
