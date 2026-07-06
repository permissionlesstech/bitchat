//
// WifiBulkCrypto.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import Foundation

/// Channel security for the Wi-Fi bulk data plane.
///
/// The TCP stream is encrypted and authenticated independently of TLS: both
/// endpoints exchanged random 32-byte tokens inside the established Noise
/// session, so only they can derive the ChaChaPoly channel key via
/// HKDF-SHA256 (domain "bitchat-bulk-v1", transferID as salt). A Bonjour-level
/// gatecrasher that connects to the listener cannot produce a single valid
/// frame and is disconnected.
///
/// Stream format: length-prefixed frames, each a ChaChaPoly sealed box in
/// combined form (12-byte nonce ‖ ciphertext ‖ 16-byte tag). Nonces are
/// structured, never random: [direction byte][3 zero bytes][8-byte BE counter],
/// and the reader requires the exact expected nonce for each frame, so frames
/// cannot be replayed, reordered, or reflected across directions.
enum WifiBulkCryptoError: Error, Equatable {
    case invalidParameters
    case frameTooLarge
    case truncatedFrame
    case nonceMismatch
    case authenticationFailed
    case emptyChunk
    case payloadOverflow
    case hashMismatch
}

enum WifiBulkFrameDirection: UInt8 {
    /// Data chunks: counters 0, 1, 2, …
    case senderToReceiver = 0x00
    /// Counter 0 = client auth frame, counter 1 = final receipt.
    case receiverToSender = 0x01
}

enum WifiBulkCrypto {
    static let keyDomain = "bitchat-bulk-v1"
    static let nonceLength = 12
    static let tagLength = 16
    /// AEAD overhead per frame body (nonce + tag).
    static let frameOverhead = nonceLength + tagLength
    /// 4-byte big-endian length prefix per frame.
    static let framePrefixLength = 4

    // MARK: Key derivation

    /// Derives the ChaChaPoly channel key from the two Noise-exchanged tokens.
    /// Deterministic: same tokens + transferID always yield the same key.
    static func deriveKey(senderToken: Data, receiverToken: Data, transferID: Data) -> SymmetricKey? {
        guard senderToken.count == WifiBulkWire.tokenLength,
              receiverToken.count == WifiBulkWire.tokenLength,
              transferID.count == WifiBulkWire.transferIDLength else {
            return nil
        }
        var inputKeyMaterial = Data()
        inputKeyMaterial.append(senderToken)
        inputKeyMaterial.append(receiverToken)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
            salt: transferID,
            info: Data(keyDomain.utf8),
            outputByteCount: 32
        )
    }

    // MARK: Frame sealing

    static func nonceData(direction: WifiBulkFrameDirection, counter: UInt64) -> Data {
        var nonce = Data(count: nonceLength)
        nonce[0] = direction.rawValue
        var counterBE = counter.bigEndian
        withUnsafeBytes(of: &counterBE) { nonce.replaceSubrange(4..<nonceLength, with: $0) }
        return nonce
    }

    /// Seals one frame body (nonce ‖ ciphertext ‖ tag), without length prefix.
    static func sealFrameBody(
        _ plaintext: Data,
        direction: WifiBulkFrameDirection,
        counter: UInt64,
        key: SymmetricKey
    ) throws -> Data {
        let nonce = try ChaChaPoly.Nonce(data: nonceData(direction: direction, counter: counter))
        return try ChaChaPoly.seal(plaintext, using: key, nonce: nonce).combined
    }

    /// Opens one frame body, enforcing the exact expected nonce.
    static func openFrameBody(
        _ body: Data,
        direction: WifiBulkFrameDirection,
        counter: UInt64,
        key: SymmetricKey
    ) throws -> Data {
        guard body.count >= frameOverhead else { throw WifiBulkCryptoError.truncatedFrame }
        guard body.prefix(nonceLength) == nonceData(direction: direction, counter: counter) else {
            throw WifiBulkCryptoError.nonceMismatch
        }
        do {
            let box = try ChaChaPoly.SealedBox(combined: body)
            return try ChaChaPoly.open(box, using: key)
        } catch {
            throw WifiBulkCryptoError.authenticationFailed
        }
    }

    /// Prefixes a frame body with its 4-byte big-endian length for the wire.
    static func frameData(body: Data) -> Data {
        var framed = Data(capacity: framePrefixLength + body.count)
        var lengthBE = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &lengthBE) { framed.append(contentsOf: $0) }
        framed.append(body)
        return framed
    }

    // MARK: Control frames

    /// First frame on the wire, receiver → sender: proves the connecting
    /// client holds the Noise-exchanged secret before any data flows.
    static func makeClientAuthFrameBody(transferID: Data, key: SymmetricKey) throws -> Data {
        try sealFrameBody(transferID, direction: .receiverToSender, counter: 0, key: key)
    }

    static func validateClientAuthFrameBody(_ body: Data, transferID: Data, key: SymmetricKey) -> Bool {
        (try? openFrameBody(body, direction: .receiverToSender, counter: 0, key: key)) == transferID
    }

    /// Final frame, receiver → sender: acknowledges the fully verified payload.
    static func makeReceiptFrameBody(payloadHash: Data, key: SymmetricKey) throws -> Data {
        try sealFrameBody(payloadHash, direction: .receiverToSender, counter: 1, key: key)
    }

    static func validateReceiptFrameBody(_ body: Data, payloadHash: Data, key: SymmetricKey) -> Bool {
        (try? openFrameBody(body, direction: .receiverToSender, counter: 1, key: key)) == payloadHash
    }
}

/// Incremental length-prefix parser for the frame stream. Bounded: bodies
/// larger than `maxBodyBytes` throw instead of buffering unboundedly.
final class WifiBulkFrameBuffer {
    private var buffer = Data()
    private let maxBodyBytes: Int

    init(maxBodyBytes: Int) {
        self.maxBodyBytes = maxBodyBytes
    }

    func append(_ data: Data) {
        buffer.append(data)
    }

    /// Extracts the next complete frame body, or nil when more bytes are needed.
    func nextFrameBody() throws -> Data? {
        guard buffer.count >= WifiBulkCrypto.framePrefixLength else { return nil }
        let length = buffer.prefix(WifiBulkCrypto.framePrefixLength).reduce(Int(0)) { ($0 << 8) | Int($1) }
        guard length <= maxBodyBytes else { throw WifiBulkCryptoError.frameTooLarge }
        guard buffer.count >= WifiBulkCrypto.framePrefixLength + length else { return nil }
        let body = Data(buffer.dropFirst(WifiBulkCrypto.framePrefixLength).prefix(length))
        buffer.removeFirst(WifiBulkCrypto.framePrefixLength + length)
        return body
    }
}

/// Receiver-side reassembly: opens sequential data frames, enforces the size
/// negotiated in the accepted offer, and verifies the final SHA-256.
final class WifiBulkPayloadAssembler {
    private let key: SymmetricKey
    private let expectedSize: Int
    private let expectedHash: Data
    private var received = Data()
    private var counter: UInt64 = 0

    /// Fails when the offer exceeds the receiver-enforced cap.
    init?(key: SymmetricKey, expectedSize: UInt64, expectedHash: Data, sizeCap: Int) {
        guard expectedSize > 0,
              expectedSize <= UInt64(sizeCap),
              expectedHash.count == WifiBulkWire.hashLength else {
            return nil
        }
        self.key = key
        self.expectedSize = Int(expectedSize)
        self.expectedHash = expectedHash
    }

    var isComplete: Bool { received.count == expectedSize }

    /// Consumes one sealed data frame body. Returns the verified payload when
    /// the final byte arrives; throws on tampering, overflow, or hash mismatch.
    func consume(frameBody: Data) throws -> Data? {
        let chunk = try WifiBulkCrypto.openFrameBody(
            frameBody,
            direction: .senderToReceiver,
            counter: counter,
            key: key
        )
        guard !chunk.isEmpty else { throw WifiBulkCryptoError.emptyChunk }
        counter += 1
        guard received.count + chunk.count <= expectedSize else {
            throw WifiBulkCryptoError.payloadOverflow
        }
        received.append(chunk)
        guard isComplete else { return nil }
        guard Data(SHA256.hash(data: received)) == expectedHash else {
            throw WifiBulkCryptoError.hashMismatch
        }
        return received
    }
}
