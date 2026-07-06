//
// WifiBulkCryptoTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("WifiBulk channel crypto")
struct WifiBulkCryptoTests {
    private static func keyHex(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
    }

    private func makeKey() throws -> SymmetricKey {
        try #require(WifiBulkCrypto.deriveKey(
            senderToken: Data(repeating: 0x11, count: 32),
            receiverToken: Data(repeating: 0x22, count: 32),
            transferID: Data(repeating: 0x33, count: 16)
        ))
    }

    // MARK: HKDF derivation

    @Test("HKDF derivation matches fixed vectors")
    func hkdfVectors() throws {
        // Vectors computed independently with CryptoKit HKDF<SHA256>,
        // ikm = senderToken ‖ receiverToken, salt = transferID,
        // info = "bitchat-bulk-v1", 32 bytes out.
        let key1 = try makeKey()
        #expect(Self.keyHex(key1) == "9ee6f4bf7753a8a9564d6760b7064e31657f1a6bcca2b3ff266bb975cc4f66eb")

        let key2 = try #require(WifiBulkCrypto.deriveKey(
            senderToken: Data((0..<32).map { UInt8($0) }),
            receiverToken: Data((0..<32).map { UInt8(255 - $0) }),
            transferID: Data((0..<16).map { UInt8($0 * 3) })
        ))
        #expect(Self.keyHex(key2) == "432ebb559f2f546d632a91d53b5c25af36f15d1ba53917910a0041329dc0efd4")
    }

    @Test("HKDF derivation is order- and role-sensitive")
    func hkdfRoleSensitivity() throws {
        let a = Data(repeating: 0x11, count: 32)
        let b = Data(repeating: 0x22, count: 32)
        let tid = Data(repeating: 0x33, count: 16)
        let forward = try #require(WifiBulkCrypto.deriveKey(senderToken: a, receiverToken: b, transferID: tid))
        let reversed = try #require(WifiBulkCrypto.deriveKey(senderToken: b, receiverToken: a, transferID: tid))
        #expect(Self.keyHex(forward) != Self.keyHex(reversed))
    }

    @Test("HKDF derivation rejects wrong-length inputs")
    func hkdfRejectsBadLengths() {
        let token = Data(repeating: 1, count: 32)
        let tid = Data(repeating: 2, count: 16)
        #expect(WifiBulkCrypto.deriveKey(senderToken: Data(count: 31), receiverToken: token, transferID: tid) == nil)
        #expect(WifiBulkCrypto.deriveKey(senderToken: token, receiverToken: Data(count: 33), transferID: tid) == nil)
        #expect(WifiBulkCrypto.deriveKey(senderToken: token, receiverToken: token, transferID: Data(count: 15)) == nil)
    }

    // MARK: Frame sealing

    @Test("Frame seal/open round-trips")
    func frameRoundTrip() throws {
        let key = try makeKey()
        let plaintext = Data((0..<1000).map { UInt8($0 % 251) })
        let body = try WifiBulkCrypto.sealFrameBody(plaintext, direction: .senderToReceiver, counter: 7, key: key)
        let opened = try WifiBulkCrypto.openFrameBody(body, direction: .senderToReceiver, counter: 7, key: key)
        #expect(opened == plaintext)
    }

    @Test("Tampered frames are rejected")
    func tamperRejection() throws {
        let key = try makeKey()
        var body = try WifiBulkCrypto.sealFrameBody(Data(repeating: 9, count: 64), direction: .senderToReceiver, counter: 0, key: key)
        body[body.count - 1] ^= 0x01 // flip a tag bit
        #expect(throws: WifiBulkCryptoError.authenticationFailed) {
            try WifiBulkCrypto.openFrameBody(body, direction: .senderToReceiver, counter: 0, key: key)
        }
    }

    @Test("Frames cannot be replayed at another counter or reflected across directions")
    func nonceBinding() throws {
        let key = try makeKey()
        let body = try WifiBulkCrypto.sealFrameBody(Data(repeating: 9, count: 64), direction: .senderToReceiver, counter: 3, key: key)
        #expect(throws: WifiBulkCryptoError.nonceMismatch) {
            try WifiBulkCrypto.openFrameBody(body, direction: .senderToReceiver, counter: 4, key: key)
        }
        #expect(throws: WifiBulkCryptoError.nonceMismatch) {
            try WifiBulkCrypto.openFrameBody(body, direction: .receiverToSender, counter: 3, key: key)
        }
    }

    @Test("Frames sealed under a different key are rejected")
    func wrongKeyRejection() throws {
        let key = try makeKey()
        let otherKey = try #require(WifiBulkCrypto.deriveKey(
            senderToken: Data(repeating: 0x44, count: 32),
            receiverToken: Data(repeating: 0x22, count: 32),
            transferID: Data(repeating: 0x33, count: 16)
        ))
        let body = try WifiBulkCrypto.sealFrameBody(Data(repeating: 9, count: 64), direction: .senderToReceiver, counter: 0, key: otherKey)
        #expect(throws: WifiBulkCryptoError.authenticationFailed) {
            try WifiBulkCrypto.openFrameBody(body, direction: .senderToReceiver, counter: 0, key: key)
        }
    }

    @Test("Auth and receipt control frames validate and reject forgeries")
    func controlFrames() throws {
        let key = try makeKey()
        let transferID = Data(repeating: 0x33, count: 16)
        let hash = Data(repeating: 0x55, count: 32)

        let auth = try WifiBulkCrypto.makeClientAuthFrameBody(transferID: transferID, key: key)
        #expect(WifiBulkCrypto.validateClientAuthFrameBody(auth, transferID: transferID, key: key))
        #expect(!WifiBulkCrypto.validateClientAuthFrameBody(auth, transferID: Data(repeating: 0x34, count: 16), key: key))
        var forgedAuth = auth
        forgedAuth[forgedAuth.count - 1] ^= 0x01
        #expect(!WifiBulkCrypto.validateClientAuthFrameBody(forgedAuth, transferID: transferID, key: key))

        let receipt = try WifiBulkCrypto.makeReceiptFrameBody(payloadHash: hash, key: key)
        #expect(WifiBulkCrypto.validateReceiptFrameBody(receipt, payloadHash: hash, key: key))
        #expect(!WifiBulkCrypto.validateReceiptFrameBody(receipt, payloadHash: Data(repeating: 0x56, count: 32), key: key))
        // An auth frame is not a receipt (distinct counter).
        #expect(!WifiBulkCrypto.validateReceiptFrameBody(auth, payloadHash: hash, key: key))
    }

    // MARK: Frame buffer

    @Test("Frame buffer reassembles frames from arbitrary byte boundaries")
    func frameBufferReassembly() throws {
        let bodyA = Data(repeating: 0xAA, count: 100)
        let bodyB = Data(repeating: 0xBB, count: 5)
        var stream = WifiBulkCrypto.frameData(body: bodyA)
        stream.append(WifiBulkCrypto.frameData(body: bodyB))

        let buffer = WifiBulkFrameBuffer(maxBodyBytes: 1024)
        // Drip-feed 3 bytes at a time.
        var extracted: [Data] = []
        var index = stream.startIndex
        while index < stream.endIndex {
            let next = stream.index(index, offsetBy: 3, limitedBy: stream.endIndex) ?? stream.endIndex
            buffer.append(Data(stream[index..<next]))
            while let body = try buffer.nextFrameBody() {
                extracted.append(body)
            }
            index = next
        }
        #expect(extracted == [bodyA, bodyB])
        #expect(try buffer.nextFrameBody() == nil)
    }

    @Test("Frame buffer rejects oversized frame lengths without buffering them")
    func frameBufferOversizeRejection() {
        let buffer = WifiBulkFrameBuffer(maxBodyBytes: 64)
        buffer.append(WifiBulkCrypto.frameData(body: Data(repeating: 1, count: 65)).prefix(8))
        #expect(throws: WifiBulkCryptoError.frameTooLarge) {
            _ = try buffer.nextFrameBody()
        }
    }

    // MARK: Payload assembler

    private func sealedChunks(_ payload: Data, chunkSize: Int, key: SymmetricKey) throws -> [Data] {
        try stride(from: 0, to: payload.count, by: chunkSize).enumerated().map { index, offset in
            try WifiBulkCrypto.sealFrameBody(
                Data(payload[offset..<min(offset + chunkSize, payload.count)]),
                direction: .senderToReceiver,
                counter: UInt64(index),
                key: key
            )
        }
    }

    @Test("Assembler reassembles and verifies a chunked payload")
    func assemblerHappyPath() throws {
        let key = try makeKey()
        let payload = Data((0..<200_000).map { UInt8($0 % 253) })
        let assembler = try #require(WifiBulkPayloadAssembler(
            key: key,
            expectedSize: UInt64(payload.count),
            expectedHash: Data(SHA256.hash(data: payload)),
            sizeCap: FileTransferLimits.maxWifiBulkPayloadBytes
        ))

        var result: Data?
        for chunk in try sealedChunks(payload, chunkSize: 64 * 1024, key: key) {
            result = try assembler.consume(frameBody: chunk)
        }
        #expect(result == payload)
    }

    @Test("Assembler rejects a payload whose final hash mismatches the offer")
    func assemblerHashMismatch() throws {
        let key = try makeKey()
        let payload = Data(repeating: 0x77, count: 100_000)
        let assembler = try #require(WifiBulkPayloadAssembler(
            key: key,
            expectedSize: UInt64(payload.count),
            expectedHash: Data(repeating: 0, count: 32), // wrong hash
            sizeCap: FileTransferLimits.maxWifiBulkPayloadBytes
        ))

        let chunks = try sealedChunks(payload, chunkSize: 64 * 1024, key: key)
        _ = try assembler.consume(frameBody: chunks[0])
        #expect(throws: WifiBulkCryptoError.hashMismatch) {
            _ = try assembler.consume(frameBody: chunks[1])
        }
    }

    @Test("Assembler rejects overflow beyond the offered size")
    func assemblerOverflow() throws {
        let key = try makeKey()
        let payload = Data(repeating: 0x77, count: 1000)
        let assembler = try #require(WifiBulkPayloadAssembler(
            key: key,
            expectedSize: 500, // offer promised less than the sender streams
            expectedHash: Data(SHA256.hash(data: payload)),
            sizeCap: FileTransferLimits.maxWifiBulkPayloadBytes
        ))
        let chunk = try WifiBulkCrypto.sealFrameBody(payload, direction: .senderToReceiver, counter: 0, key: key)
        #expect(throws: WifiBulkCryptoError.payloadOverflow) {
            _ = try assembler.consume(frameBody: chunk)
        }
    }

    @Test("Assembler enforces the receiver-side size cap at construction")
    func assemblerSizeCap() throws {
        let key = try makeKey()
        #expect(WifiBulkPayloadAssembler(
            key: key,
            expectedSize: UInt64(FileTransferLimits.maxWifiBulkPayloadBytes) + 1,
            expectedHash: Data(repeating: 0, count: 32),
            sizeCap: FileTransferLimits.maxWifiBulkPayloadBytes
        ) == nil)
        #expect(WifiBulkPayloadAssembler(
            key: key,
            expectedSize: 0,
            expectedHash: Data(repeating: 0, count: 32),
            sizeCap: FileTransferLimits.maxWifiBulkPayloadBytes
        ) == nil)
    }

    @Test("Assembler rejects out-of-order chunks")
    func assemblerOutOfOrder() throws {
        let key = try makeKey()
        let payload = Data(repeating: 0x42, count: 100_000)
        let assembler = try #require(WifiBulkPayloadAssembler(
            key: key,
            expectedSize: UInt64(payload.count),
            expectedHash: Data(SHA256.hash(data: payload)),
            sizeCap: FileTransferLimits.maxWifiBulkPayloadBytes
        ))
        let chunks = try sealedChunks(payload, chunkSize: 64 * 1024, key: key)
        #expect(throws: WifiBulkCryptoError.nonceMismatch) {
            _ = try assembler.consume(frameBody: chunks[1]) // skip chunk 0
        }
    }
}
