import Foundation
import P256K

/// Manages Nostr identity (secp256k1 keypair) for NIP-17 private messaging
public struct NostrIdentity: Codable, Sendable {
    public let privateKey: Data
    public let publicKey: Data
    public let npub: String // Bech32-encoded public key
    public let createdAt: Date

    public init(privateKey: Data, publicKey: Data, npub: String, createdAt: Date) {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.npub = npub
        self.createdAt = createdAt
    }

    /// Generate a new Nostr identity
    public static func generate() throws -> NostrIdentity {
        let schnorrKey = try P256K.Schnorr.PrivateKey()
        let xOnlyPubkey = Data(schnorrKey.xonly.bytes)
        let npub = try Bech32.encode(hrp: "npub", data: xOnlyPubkey)

        return NostrIdentity(
            privateKey: schnorrKey.dataRepresentation,
            publicKey: xOnlyPubkey,
            npub: npub,
            createdAt: Date()
        )
    }

    /// Initialize from existing private key data
    public init(privateKeyData: Data) throws {
        let schnorrKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKeyData)
        let xOnlyPubkey = Data(schnorrKey.xonly.bytes)

        self.privateKey = privateKeyData
        self.publicKey = xOnlyPubkey
        self.npub = try Bech32.encode(hrp: "npub", data: xOnlyPubkey)
        self.createdAt = Date()
    }

    /// Get signing key for event signatures
    public func signingKey() throws -> P256K.Signing.PrivateKey {
        try P256K.Signing.PrivateKey(dataRepresentation: privateKey)
    }

    /// Get Schnorr signing key for Nostr event signatures
    public func schnorrSigningKey() throws -> P256K.Schnorr.PrivateKey {
        try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
    }

    /// Get hex-encoded public key (for Nostr events)
    public var publicKeyHex: String {
        publicKey.hexEncodedString()
    }
}
