import Foundation
import P256K

/// Manages Nostr identity (secp256k1 keypair) for NIP-17 private messaging
struct NostrIdentity: Codable {
    let privateKey: Data
    let publicKey: Data
    let npub: String // Bech32-encoded public key
    let createdAt: Date
    
    /// Memberwise initializer
    init(privateKey: Data, publicKey: Data, npub: String, createdAt: Date) {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.npub = npub
        self.createdAt = createdAt
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
        self.createdAt = Date()
    }
    
    /// Get signing key for event signatures
    func signingKey() throws -> P256K.Signing.PrivateKey {
        try P256K.Signing.PrivateKey(dataRepresentation: privateKey)
    }
    
    /// Get Schnorr signing key for Nostr event signatures
    func schnorrSigningKey() throws -> P256K.Schnorr.PrivateKey {
        try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
    }
    
    /// Get hex-encoded public key (for Nostr events)
    var publicKeyHex: String {
        // Public key is already stored as x-only (32 bytes)
        return publicKey.hexEncodedString()
    }
}
