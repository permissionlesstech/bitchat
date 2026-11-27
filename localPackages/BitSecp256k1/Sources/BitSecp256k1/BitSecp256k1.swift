import CLibSecp256k1
import Foundation
import Security

/// Minimal Swift wrapper over upstream libsecp256k1 providing only the
/// BIP-340 Schnorr and compressed-point ECDH operations BitChat uses for Nostr.
public enum BitSecp256k1 {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidPrivateKey
        case invalidPublicKey
        case invalidAuxiliaryRandomness
        case randomGenerationFailed
        case cryptographicFailure
    }

    /// Process-wide randomized secp256k1 context.
    /// Read-only operations on a constructed context are thread-safe per libsecp256k1.
    private nonisolated(unsafe) static let sharedContext: OpaquePointer = {
        guard let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else {
            preconditionFailure("Failed to create secp256k1 context")
        }
        var seed = [UInt8](repeating: 0, count: 32)
        defer { wipe(&seed) }
        let status = SecRandomCopyBytes(kSecRandomDefault, seed.count, &seed)
        precondition(status == errSecSuccess, "Failed to generate secp256k1 context seed")
        precondition(
            secp256k1_context_randomize(ctx, &seed) == 1,
            "Failed to randomize secp256k1 context"
        )
        return ctx
    }()

    /// BIP-340 Schnorr signing key backed by a validated 32-byte secp256k1 scalar.
    public struct SchnorrPrivateKey: Equatable, Sendable {
        public let dataRepresentation: Data
        public let xonlyPublicKey: Data

        /// Generates a fresh random secp256k1 private key using the OS CSPRNG.
        public init() throws {
            var bytes = [UInt8](repeating: 0, count: 32)
            defer { BitSecp256k1.wipe(&bytes) }
            for _ in 0..<16 {
                let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                guard status == errSecSuccess else {
                    throw BitSecp256k1.Error.randomGenerationFailed
                }
                if secp256k1_ec_seckey_verify(BitSecp256k1.sharedContext, bytes) == 1 {
                    try self.init(validatedSecretBytes: bytes)
                    return
                }
            }
            throw BitSecp256k1.Error.cryptographicFailure
        }

        /// Initializes from an existing 32-byte raw secp256k1 private scalar.
        public init(dataRepresentation: Data) throws {
            guard dataRepresentation.count == 32 else {
                throw BitSecp256k1.Error.invalidPrivateKey
            }
            var bytes = [UInt8](dataRepresentation)
            defer { BitSecp256k1.wipe(&bytes) }
            guard secp256k1_ec_seckey_verify(BitSecp256k1.sharedContext, bytes) == 1 else {
                throw BitSecp256k1.Error.invalidPrivateKey
            }
            try self.init(validatedSecretBytes: bytes)
        }

        private init(validatedSecretBytes bytes: [UInt8]) throws {
            let ctx = BitSecp256k1.sharedContext
            var keypair = secp256k1_keypair()
            defer { BitSecp256k1.wipeValue(&keypair) }
            guard secp256k1_keypair_create(ctx, &keypair, bytes) == 1 else {
                throw BitSecp256k1.Error.invalidPrivateKey
            }
            var xonly = secp256k1_xonly_pubkey()
            guard secp256k1_keypair_xonly_pub(ctx, &xonly, nil, &keypair) == 1 else {
                throw BitSecp256k1.Error.cryptographicFailure
            }
            var out = [UInt8](repeating: 0, count: 32)
            guard secp256k1_xonly_pubkey_serialize(ctx, &out, &xonly) == 1 else {
                throw BitSecp256k1.Error.cryptographicFailure
            }
            self.dataRepresentation = Data(bytes)
            self.xonlyPublicKey = Data(out)
        }

        /// Produces a 64-byte BIP-340 Schnorr signature using caller-supplied
        /// 32-byte auxiliary randomness.
        public func sign(message: [UInt8], auxiliaryRand: [UInt8]) throws -> Data {
            guard auxiliaryRand.count == 32 else {
                throw BitSecp256k1.Error.invalidAuxiliaryRandomness
            }
            let ctx = BitSecp256k1.sharedContext
            var secret = [UInt8](dataRepresentation)
            var aux = auxiliaryRand
            var keypair = secp256k1_keypair()
            defer {
                BitSecp256k1.wipe(&secret)
                BitSecp256k1.wipe(&aux)
                BitSecp256k1.wipeValue(&keypair)
            }
            guard secp256k1_keypair_create(ctx, &keypair, secret) == 1 else {
                throw BitSecp256k1.Error.invalidPrivateKey
            }
            var signature = [UInt8](repeating: 0, count: 64)
            let ok: Int32 = aux.withUnsafeMutableBytes { auxPtr in
                var extra = secp256k1_schnorrsig_extraparams(
                    magic: (0xDA, 0x6F, 0xB3, 0x8C),
                    noncefp: nil,
                    ndata: auxPtr.baseAddress
                )
                return message.withUnsafeBytes { msgPtr in
                    secp256k1_schnorrsig_sign_custom(
                        ctx,
                        &signature,
                        msgPtr.bindMemory(to: UInt8.self).baseAddress,
                        message.count,
                        &keypair,
                        &extra
                    )
                }
            }
            guard ok == 1 else {
                throw BitSecp256k1.Error.cryptographicFailure
            }
            return Data(signature)
        }
    }

    /// Verifies a 64-byte BIP-340 Schnorr signature against a 32-byte x-only public key.
    public static func verifySchnorr(
        signature: Data,
        message: [UInt8],
        xonlyPublicKey: Data
    ) -> Bool {
        guard signature.count == 64, xonlyPublicKey.count == 32 else {
            return false
        }
        let ctx = sharedContext
        var pubkey = secp256k1_xonly_pubkey()
        let parsed = xonlyPublicKey.withUnsafeBytes { pubPtr -> Int32 in
            guard let base = pubPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return secp256k1_xonly_pubkey_parse(ctx, &pubkey, base)
        }
        guard parsed == 1 else { return false }
        return signature.withUnsafeBytes { sigPtr in
            guard let sigBase = sigPtr.bindMemory(to: UInt8.self).baseAddress else { return false }
            return message.withUnsafeBytes { msgPtr in
                secp256k1_schnorrsig_verify(
                    ctx,
                    sigBase,
                    msgPtr.bindMemory(to: UInt8.self).baseAddress,
                    message.count,
                    &pubkey
                ) == 1
            }
        }
    }

    /// Computes a secp256k1 ECDH shared secret serialized as the raw 33-byte SEC1
    /// compressed EC point (`0x02`/`0x03` || X), matching `P256K.KeyAgreement` `.compressed`.
    public static func ecdhCompressed(
        privateKey: Data,
        compressedPublicKey: Data
    ) throws -> Data {
        guard privateKey.count == 32 else {
            throw Error.invalidPrivateKey
        }
        guard compressedPublicKey.count == 33 else {
            throw Error.invalidPublicKey
        }
        let ctx = sharedContext
        var pubkey = secp256k1_pubkey()
        let parsed = compressedPublicKey.withUnsafeBytes { pubPtr -> Int32 in
            guard let base = pubPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return secp256k1_ec_pubkey_parse(ctx, &pubkey, base, compressedPublicKey.count)
        }
        guard parsed == 1 else {
            throw Error.invalidPublicKey
        }

        var secret = [UInt8](privateKey)
        defer { wipe(&secret) }
        guard secp256k1_ec_seckey_verify(ctx, secret) == 1 else {
            throw Error.invalidPrivateKey
        }

        var shared = [UInt8](repeating: 0, count: 33)
        let ok = secp256k1_ecdh(ctx, &shared, &pubkey, secret, ecdhCompressedPointHash, nil)
        guard ok == 1 else {
            wipe(&shared)
            throw Error.cryptographicFailure
        }
        let result = Data(shared)
        wipe(&shared)
        return result
    }

    private static let ecdhCompressedPointHash: @convention(c) (
        UnsafeMutablePointer<UInt8>?,
        UnsafePointer<UInt8>?,
        UnsafePointer<UInt8>?,
        UnsafeMutableRawPointer?
    ) -> Int32 = { output, x32, y32, _ in
        guard let output, let x32, let y32 else { return 0 }
        output[0] = (y32[31] & 0x01) | 0x02
        output.advanced(by: 1).update(from: x32, count: 32)
        return 1
    }

    private static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress, !ptr.isEmpty else { return }
            _ = memset_s(base, ptr.count, 0, ptr.count)
        }
    }

    private static func wipeValue<T>(_ value: inout T) {
        withUnsafeMutableBytes(of: &value) { ptr in
            guard let base = ptr.baseAddress, !ptr.isEmpty else { return }
            _ = memset_s(base, ptr.count, 0, ptr.count)
        }
    }
}
