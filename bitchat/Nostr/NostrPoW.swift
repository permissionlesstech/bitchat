import Foundation
import CryptoKit
import Security
import Darwin

/// NIP-13 Proof-of-Work utilities for Nostr events.
/// - Counts leading zero bits and mines a nonce tag to meet a target.
enum NostrPoW {
    /// Table of leading zero bit counts for all 256 byte values.
    private static let lzTable: [UInt8] = {
        (0...255).map { v -> UInt8 in
            var x = UInt8(v)
            if x == 0 { return 8 }
            var n: UInt8 = 0
            while (x & 0x80) == 0 {
                n &+= 1
                x <<= 1
            }
            return n
        }
    }()

    /// Count leading zero bits in a 32-byte hash.
    static func leadingZeroBits(_ data: Data) -> Int {
        var total = 0
        for b in data {
            let lz = Int(lzTable[Int(b)])
            total += lz
            if lz != 8 { break }
        }
        return total
    }

    /// Compute Nostr event id hash (SHA-256 over canonical serialization) for given fields.
    private static func eventIDHash(pubkey: String, createdAt: Int, kind: Int, tags: [[String]], content: String) -> (hex: String, data: Data) {
        let serialized: [Any] = [0, pubkey, createdAt, kind, tags, content]
        let json = try! JSONSerialization.data(withJSONObject: serialized, options: [.withoutEscapingSlashes])
        let digest = SHA256.hash(data: json)
        let data = Data(digest)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return (hex, data)
    }

    /// Mine a NIP-13 nonce tag that satisfies the target leading-zero bits.
    /// - Parameters:
    ///   - pubkey: x-only hex pubkey (64-hex chars)
    ///   - createdAt: seconds since epoch
    ///   - kind: event kind
    ///   - baseTags: existing tags (e.g., [ ["g", geohash], ["n", nickname], ... ])
    ///   - content: event content
    ///   - targetBits: required leading zero bits
    ///   - startNonce: optional starting nonce (random if nil)
    /// - Returns: (nonce, idHex)
    static func mine(pubkey: String,
                     createdAt: Int,
                     kind: Int,
                     baseTags: [[String]],
                     content: String,
                     targetBits: Int,
                     startNonce: UInt64? = nil) -> (nonce: UInt64, idHex: String) {
        var nonce: UInt64 = startNonce ?? randomNonce()
        // Build a local tags buffer once to avoid reallocating unrelated tags
        var tags = baseTags
        tags.append(["nonce", "0", String(targetBits)])

        var iter: UInt64 = 0
        while true {
            var solved = false
            var idHexOut = ""
            // Use an autorelease pool periodically to keep memory stable on iOS
            autoreleasepool {
                // Update nonce tag value (second element)
                tags[tags.count - 1][1] = String(nonce)
                let (idHex, idData) = eventIDHash(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
                if leadingZeroBits(idData) >= targetBits {
                    solved = true
                    idHexOut = idHex
                }
            }
            if solved {
                return (nonce, idHexOut)
            }
            nonce &+= 1
            iter &+= 1
            if iter & 0x3FFF == 0 { /* yield every ~16k iterations */ _ = sched_yield() }
        }
    }

    private static func randomNonce() -> UInt64 {
        var n: UInt64 = 0
        withUnsafeMutableBytes(of: &n) { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, ptr.count, ptr.baseAddress!)
        }
        return n
    }
}
