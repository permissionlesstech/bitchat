import Foundation
import CryptoKit

/// P256K compatibility layer for Nostr functionality using CryptoKit
public struct BitchatP256KUtils {
    
    public struct Schnorr {
        
        public struct PrivateKey {
            private let key: P256.Signing.PrivateKey
            
            public init() throws {
                self.key = P256.Signing.PrivateKey()
            }
            
            public init(dataRepresentation: Data) throws {
                self.key = try P256.Signing.PrivateKey(rawRepresentation: dataRepresentation)
            }
            
            public var dataRepresentation: Data {
                return key.rawRepresentation
            }
            
            public var xonly: XOnlyPublicKey {
                return XOnlyPublicKey(publicKey: key.publicKey)
            }
            
            public func signature(message: inout [UInt8], auxiliaryRand: inout [UInt8]) throws -> SchnorrSignature {
                let signature = try key.signature(for: Data(message))
                return SchnorrSignature(data: signature.rawRepresentation)
            }
        }
        
        public struct XOnlyPublicKey {
            private let publicKey: P256.Signing.PublicKey
            
            init(publicKey: P256.Signing.PublicKey) {
                self.publicKey = publicKey
            }
            
            public var bytes: [UInt8] {
                return Array(publicKey.rawRepresentation.suffix(32)) // Take last 32 bytes for x-only
            }
        }
        
        public struct SchnorrSignature {
            public let dataRepresentation: Data
            
            init(data: Data) {
                self.dataRepresentation = data
            }
        }
    }
    
    public struct Signing {
        
        public struct PrivateKey {
            private let key: P256.Signing.PrivateKey
            
            public init(dataRepresentation: Data) throws {
                self.key = try P256.Signing.PrivateKey(rawRepresentation: dataRepresentation)
            }
            
            public var dataRepresentation: Data {
                return key.rawRepresentation
            }
        }
    }
    
    public struct KeyAgreement {
        
        public struct PrivateKey {
            private let key: P256.KeyAgreement.PrivateKey
            
            public init(dataRepresentation: Data) throws {
                self.key = try P256.KeyAgreement.PrivateKey(rawRepresentation: dataRepresentation)
            }
            
            public var dataRepresentation: Data {
                return key.rawRepresentation
            }
            
            public func sharedSecretFromKeyAgreement(with publicKeyShare: PublicKey) throws -> SharedSecret {
                let sharedSecret = try key.sharedSecretFromKeyAgreement(with: publicKeyShare.key)
                return SharedSecret(secret: sharedSecret)
            }
        }
        
        public struct PublicKey {
            fileprivate let key: P256.KeyAgreement.PublicKey
            
            public init(dataRepresentation: Data) throws {
                self.key = try P256.KeyAgreement.PublicKey(rawRepresentation: dataRepresentation)
            }
        }
        
        public struct SharedSecret {
            private let secret: SharedSecret_P256
            
            fileprivate init(secret: SharedSecret_P256) {
                self.secret = secret
            }
            
            public func hkdfDerivedSymmetricKey<H, K>(using hashFunction: H.Type, salt: Data, sharedInfo: Data, outputByteCount: Int) throws -> K where H: HashFunction, K: ContiguousBytes {
                let derivedKey = secret.hkdfDerivedSymmetricKey(using: hashFunction, salt: salt, sharedInfo: sharedInfo, outputByteCount: outputByteCount)
                return derivedKey.withUnsafeBytes { bytes in
                    return Data(bytes) as! K
                }
            }
        }
    }
}

// Type alias to avoid confusion
private typealias SharedSecret_P256 = SharedSecret