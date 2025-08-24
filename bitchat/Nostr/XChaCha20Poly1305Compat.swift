import Foundation
import CryptoKit

/// Minimal XChaCha20-Poly1305 compatibility wrapper using CryptoKit's ChaChaPoly.
/// Implements HChaCha20 to derive a subkey and reduces the 24-byte nonce to a 12-byte nonce
/// as per XChaCha20 construction.
enum XChaCha20Poly1305Compat {
    struct SealBox {
        let ciphertext: Data
        let tag: Data
    }

    static func seal(plaintext: Data, key: Data, nonce24: Data, aad: Data? = nil) throws -> SealBox {
        precondition(key.count == 32, "XChaCha20 key must be 32 bytes")
        precondition(nonce24.count == 24, "XChaCha20 nonce must be 24 bytes")

        let subkey = hchacha20(key: key, nonce16: nonce24.prefix(16))
        let nonce12 = derive12ByteNonce(from24: nonce24)
        let chachaKey = SymmetricKey(data: subkey)
        let nonce = try ChaChaPoly.Nonce(data: nonce12)
        let sealed = try ChaChaPoly.seal(plaintext, using: chachaKey, nonce: nonce, authenticating: aad ?? Data())
        return SealBox(ciphertext: sealed.ciphertext, tag: sealed.tag)
    }

    static func open(ciphertext: Data, tag: Data, key: Data, nonce24: Data, aad: Data? = nil) throws -> Data {
        precondition(key.count == 32, "XChaCha20 key must be 32 bytes")
        precondition(nonce24.count == 24, "XChaCha20 nonce must be 24 bytes")

        let subkey = hchacha20(key: key, nonce16: nonce24.prefix(16))
        let nonce12 = derive12ByteNonce(from24: nonce24)
        let chachaKey = SymmetricKey(data: subkey)
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce12), ciphertext: ciphertext, tag: tag)
        return try ChaChaPoly.open(box, using: chachaKey, authenticating: aad ?? Data())
    }

    // MARK: - Internals

    private static func derive12ByteNonce(from24 nonce24: Data) -> Data {
        // XChaCha20-Poly1305: 12-byte nonce = 4 zero bytes || last 8 bytes of the 24-byte nonce
        var out = Data(count: 12)
        out.replaceSubrange(0..<4, with: [0, 0, 0, 0])
        out.replaceSubrange(4..<12, with: nonce24.suffix(8))
        return out
    }

    private static func hchacha20(key: Data, nonce16: Data) -> Data {
        // HChaCha20 based on the original ChaCha20 core with a 16-byte nonce.
        precondition(key.count == 32)
        precondition(nonce16.count == 16)

        // Constants "expand 32-byte k"
        var state: [UInt32] = [
            0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
            // key (8 words)
            key.loadLEWord(0), key.loadLEWord(4), key.loadLEWord(8), key.loadLEWord(12),
            key.loadLEWord(16), key.loadLEWord(20), key.loadLEWord(24), key.loadLEWord(28),
            // nonce (4 words)
            nonce16.loadLEWord(0), nonce16.loadLEWord(4), nonce16.loadLEWord(8), nonce16.loadLEWord(12)
        ]

        // 20 rounds (10 double rounds)
        for _ in 0..<10 {
            // Column rounds
            quarterRound(&state, 0, 4, 8, 12)
            quarterRound(&state, 1, 5, 9, 13)
            quarterRound(&state, 2, 6, 10, 14)
            quarterRound(&state, 3, 7, 11, 15)
            // Diagonal rounds
            quarterRound(&state, 0, 5, 10, 15)
            quarterRound(&state, 1, 6, 11, 12)
            quarterRound(&state, 2, 7, 8, 13)
            quarterRound(&state, 3, 4, 9, 14)
        }

        // Output subkey: state[0..3] and state[12..15]
        var out = Data(count: 32)
        out.storeLEWord(state[0], at: 0)
        out.storeLEWord(state[1], at: 4)
        out.storeLEWord(state[2], at: 8)
        out.storeLEWord(state[3], at: 12)
        out.storeLEWord(state[12], at: 16)
        out.storeLEWord(state[13], at: 20)
        out.storeLEWord(state[14], at: 24)
        out.storeLEWord(state[15], at: 28)
        return out
    }

    private static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = (s[d] << 16) | (s[d] >> 16)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = (s[b] << 12) | (s[b] >> 20)
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = (s[d] << 8)  | (s[d] >> 24)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = (s[b] << 7)  | (s[b] >> 25)
    }
}

private extension Data {
    func loadLEWord(_ offset: Int) -> UInt32 {
        let range = offset..<(offset+4)
        let bytes = self[range]
        return bytes.withUnsafeBytes { ptr -> UInt32 in
            let b = ptr.bindMemory(to: UInt8.self)
            return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
        }
    }

    mutating func storeLEWord(_ value: UInt32, at offset: Int) {
        let bytes: [UInt8] = [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ]
        replaceSubrange(offset..<(offset+4), with: bytes)
    }
}

