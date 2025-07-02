import Foundation
import CryptoKit

class EncryptionService {
    private var privateKey: Curve25519.KeyAgreement.PrivateKey
    public let publicKey: Curve25519.KeyAgreement.PublicKey
    private var peerPublicKeys: [String: Curve25519.KeyAgreement.PublicKey] = [:]
    private var sharedSecrets: [String: SymmetricKey] = [:]
    
    init() {
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.publicKey = privateKey.publicKey
    }
    
    func addPeerPublicKey(_ peerID: String, publicKeyData: Data) throws {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData)
        peerPublicKeys[peerID] = publicKey
        
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: "bitchat-v1".data(using: .utf8)!,
            sharedInfo: Data(),
            outputByteCount: 32
        )
        sharedSecrets[peerID] = symmetricKey
    }
    
    func encrypt(_ data: Data, for peerID: String) throws -> Data {
        guard let symmetricKey = sharedSecrets[peerID] else {
            throw EncryptionError.noSharedSecret
        }
        
        let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
        return sealedBox.combined ?? Data()
    }
    
    func decrypt(_ data: Data, from peerID: String) throws -> Data {
        guard let symmetricKey = sharedSecrets[peerID] else {
            throw EncryptionError.noSharedSecret
        }
        
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }
    
    func sign(_ data: Data) throws -> Data {
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey.rawRepresentation)
        return try signingKey.signature(for: data)
    }
    
    func verify(_ signature: Data, for data: Data, from peerID: String) throws -> Bool {
        guard let peerPublicKey = peerPublicKeys[peerID] else {
            return false
        }
        
        let verifyingKey = try Curve25519.Signing.PublicKey(rawRepresentation: peerPublicKey.rawRepresentation)
        return verifyingKey.isValidSignature(signature, for: data)
    }
}

enum EncryptionError: Error {
    case noSharedSecret
    case invalidPublicKey
    case encryptionFailed
    case decryptionFailed
}