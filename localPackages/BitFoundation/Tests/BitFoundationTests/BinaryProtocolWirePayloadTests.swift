//
// BinaryProtocolWirePayloadTests.swift
// BitFoundationTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import Foundation
import Testing
@testable import BitFoundation

/// Signature preimages must be rebuilt from the bytes the ORIGINATOR put on
/// the wire, never from a re-compression of the decoded payload. DEFLATE
/// output is encoder-specific (Apple `Compression` vs `java.util.zip` on
/// bitchat-android vs Rust miniz), and a sender may have left a compressible
/// payload plain; either way a re-encode changes the preimage and every such
/// signed packet fails verification. `WirePayload` on `BitchatPacket` keeps
/// the received bytes so `BinaryProtocol.encode` and `toBinaryDataForSigning`
/// reproduce the frame that was signed.
struct BinaryProtocolWirePayloadTests {

    private let sender = Data([0, 1, 2, 3, 4, 5, 6, 7])
    private let timestamp: UInt64 = 0x0102_0304_0506_0708
    /// 360 bytes: far over the compression threshold (100) and well under 90%
    /// unique bytes, so `shouldCompress` says yes.
    private var compressiblePayload: Data {
        Data(String(repeating: "compress-me ", count: 30).utf8)
    }

    /// Hand-assembled v1 frame: header(14) + sender(8) + body. No recipient,
    /// no signature, no padding.
    private func v1Frame(type: UInt8, ttl: UInt8, flags: UInt8, body: Data) -> Data {
        var frame = Data([1, type, ttl])
        for shift in stride(from: 56, through: 0, by: -8) {
            frame.append(UInt8((timestamp >> UInt64(shift)) & 0xFF))
        }
        frame.append(flags)
        let length = UInt16(body.count)
        frame.append(UInt8(length >> 8))
        frame.append(UInt8(length & 0xFF))
        frame.append(sender)
        frame.append(body)
        return frame
    }

    /// A valid raw DEFLATE stream Apple's encoder never emits for this input:
    /// a single stored (uncompressed) block, RFC 1951 section 3.2.4.
    private func storedDeflate(_ payload: Data) -> Data {
        var out = Data([0x01]) // BFINAL=1, BTYPE=00, byte-aligned
        let len = UInt16(payload.count)
        out.append(UInt8(len & 0xFF))
        out.append(UInt8(len >> 8))
        let nlen = ~len
        out.append(UInt8(nlen & 0xFF))
        out.append(UInt8(nlen >> 8))
        out.append(payload)
        return out
    }

    private func fresh(type: UInt8, ttl: UInt8, payload: Data) -> BitchatPacket {
        BitchatPacket(
            type: type,
            senderID: sender,
            recipientID: nil,
            timestamp: timestamp,
            payload: payload,
            signature: nil,
            ttl: ttl
        )
    }

    private func padded(_ frame: Data) -> Data {
        MessagePadding.pad(frame, toSize: MessagePadding.optimalBlockSize(for: frame.count))
    }

    /// The canonical signing form of a raw frame: ttl 0, signature bit and RSR
    /// bit cleared, then padded exactly like `BinaryProtocol.encode`.
    private func signingForm(of frame: Data) -> Data {
        var canonical = frame
        canonical[2] = 0
        canonical[BinaryProtocol.Offsets.flags] &= ~(BinaryProtocol.Flags.hasSignature | BinaryProtocol.Flags.isRSR)
        return padded(canonical)
    }

    // MARK: - 1. A foreign compressed stream is reproduced byte for byte

    @Test func reencodeReproducesAForeignDeflateStream() throws {
        let payload = compressiblePayload
        let stream = storedDeflate(payload)
        var body = Data()
        body.append(UInt8(payload.count >> 8))
        body.append(UInt8(payload.count & 0xFF))
        body.append(stream)
        let frame = v1Frame(type: 0x02, ttl: 7, flags: BinaryProtocol.Flags.isCompressed | BinaryProtocol.Flags.isRSR, body: body)

        let decoded = try #require(BinaryProtocol.decode(frame), "stored-block deflate must decode")
        #expect(decoded.payload == payload)
        #expect(decoded.wirePayload?.compressed == true)
        #expect(decoded.wirePayload?.bytes == stream)
        #expect(decoded.wirePayload?.matches(payload) == true)

        // Our encoder would have produced a different (smaller) stream...
        let ours = try #require(fresh(type: 0x02, ttl: 7, payload: payload).toBinaryData(padding: false))
        #expect(ours != frame, "precondition: Apple's DEFLATE differs from the hand-built stream")
        #expect(ours.count < frame.count)

        // ...but a decoded packet re-encodes to exactly what arrived.
        #expect(decoded.toBinaryData(padding: false) == frame)
        let paddedFrame = try #require(decoded.toBinaryData(padding: true))
        #expect(paddedFrame == padded(frame))
        #expect(BinaryProtocol.decode(paddedFrame)?.payload == payload)

        // The signing preimage is the padded ORIGINAL frame with ttl 0 and the
        // RSR bit cleared: the originator's stream, not a re-compression.
        let preimage = try #require(decoded.toBinaryDataForSigning())
        #expect(preimage == signingForm(of: frame))
        #expect(preimage != fresh(type: 0x02, ttl: 7, payload: payload).toBinaryDataForSigning())
    }

    /// The retained stream can be larger than the payload it inflates to: a
    /// store that charged `payload.count` would hold frame-sized streams for
    /// a few-byte budget each. `retainedPayloadBytes` is what to charge.
    @Test func retainedBytesCountTheWireStreamWhenItIsLarger() throws {
        let payload = compressiblePayload
        let stream = storedDeflate(payload)
        var body = Data()
        body.append(UInt8(payload.count >> 8))
        body.append(UInt8(payload.count & 0xFF))
        body.append(stream)
        let frame = v1Frame(type: 0x02, ttl: 7, flags: BinaryProtocol.Flags.isCompressed, body: body)

        let decoded = try #require(BinaryProtocol.decode(frame))
        #expect(decoded.wirePayload?.bytes.count == stream.count)
        #expect(stream.count > payload.count)
        #expect(decoded.retainedPayloadBytes == stream.count)

        // A frame compressed by a reference encoder is smaller than its payload,
        // so there the charge is the payload size, as before.
        let ownFrame = try #require(fresh(type: 0x02, ttl: 7, payload: payload).toBinaryData(padding: false))
        let own = try #require(BinaryProtocol.decode(ownFrame))
        #expect(own.wirePayload?.compressed == true)
        #expect(own.retainedPayloadBytes == payload.count)
        // And a locally built packet, with no wire bytes, charges its payload.
        #expect(fresh(type: 0x02, ttl: 7, payload: payload).retainedPayloadBytes == payload.count)
    }

    @Test func reencodeReproducesOurOwnCompressedFrame() throws {
        let frame = try #require(fresh(type: 0x02, ttl: 7, payload: compressiblePayload).toBinaryData(padding: false))
        #expect(frame[BinaryProtocol.Offsets.flags] & BinaryProtocol.Flags.isCompressed != 0)
        let decoded = try #require(BinaryProtocol.decode(frame))
        #expect(decoded.toBinaryData(padding: false) == frame)
        // For our own frames the fix is invisible: preimage unchanged.
        #expect(decoded.toBinaryDataForSigning() == fresh(type: 0x02, ttl: 7, payload: compressiblePayload).toBinaryDataForSigning())
    }

    @Test func v2ForeignStreamKeepsFourByteOriginalSize() throws {
        let payload = compressiblePayload
        let stream = storedDeflate(payload)
        var body = Data()
        for shift in stride(from: 24, through: 0, by: -8) {
            body.append(UInt8((UInt32(payload.count) >> UInt32(shift)) & 0xFF))
        }
        body.append(stream)
        var frame = Data([2, 0x02, 7])
        for shift in stride(from: 56, through: 0, by: -8) {
            frame.append(UInt8((timestamp >> UInt64(shift)) & 0xFF))
        }
        frame.append(BinaryProtocol.Flags.isCompressed)
        for shift in stride(from: 24, through: 0, by: -8) {
            frame.append(UInt8((UInt32(body.count) >> UInt32(shift)) & 0xFF))
        }
        frame.append(sender)
        frame.append(body)

        let decoded = try #require(BinaryProtocol.decode(frame))
        #expect(decoded.version == 2)
        #expect(decoded.payload == payload)
        #expect(decoded.toBinaryData(padding: false) == frame)
    }

    // MARK: - 2. Signed over an UNCOMPRESSED but compressible payload

    @Test func signatureOverUncompressedCompressiblePayloadVerifies() throws {
        // 120 identical bytes: over the threshold, trivially compressible,
        // sent plain (flags without 0x04), which is what a sender that does
        // not compress produces.
        let payload = Data(repeating: 0x41, count: 120)
        #expect(CompressionUtil.shouldCompress(payload), "precondition: we WOULD compress this")
        let frame = v1Frame(type: 0x02, ttl: 7, flags: 0, body: payload)

        let decoded = try #require(BinaryProtocol.decode(frame))
        #expect(decoded.payload == payload)
        #expect(decoded.wirePayload?.compressed == false)

        // The preimage is the canonical (ttl 0, unsigned, padded) form of the
        // frame AS SENT: still uncompressed.
        let preimage = try #require(decoded.toBinaryDataForSigning())
        #expect(preimage[BinaryProtocol.Offsets.flags] & BinaryProtocol.Flags.isCompressed == 0)
        #expect(preimage == signingForm(of: frame))

        // The originator signs that preimage; a CryptoKit verifier accepts it.
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: preimage)
        #expect(key.publicKey.isValidSignature(signature, for: preimage))

        // A packet built fresh from the same fields re-compresses and yields a
        // DIFFERENT preimage: the pre-fix behaviour, and why every such packet
        // from a non-compressing sender failed verification.
        let freshPreimage = try #require(fresh(type: 0x02, ttl: 7, payload: payload).toBinaryDataForSigning())
        #expect(freshPreimage[BinaryProtocol.Offsets.flags] & BinaryProtocol.Flags.isCompressed != 0)
        #expect(freshPreimage != preimage)
        #expect(!key.publicKey.isValidSignature(signature, for: freshPreimage))

        // Relay round trip: attach the signature, change the mutable fields,
        // encode, decode again. The receiver's preimage still verifies.
        var signed = decoded
        signed.signature = signature
        signed.ttl = 3
        signed.isRSR = true
        let wire = try #require(signed.toBinaryData(padding: false))
        #expect(wire[BinaryProtocol.Offsets.flags] & BinaryProtocol.Flags.isCompressed == 0, "relay must not compress the payload either")
        let relayed = try #require(BinaryProtocol.decode(wire))
        #expect(relayed.ttl == 3)
        #expect(relayed.isRSR)
        #expect(relayed.signature == signature)
        let relayedPreimage = try #require(relayed.toBinaryDataForSigning())
        #expect(relayedPreimage == preimage)
        #expect(key.publicKey.isValidSignature(signature, for: relayedPreimage))
    }

    // MARK: - 2b. A frame stock bitchat-android actually sends

    /// `10_v1_300_a_b33_sig22` from the bitchat-android vector file: a signed
    /// v1 message whose 300-byte payload ("A" + 33 x "B", repeated) Android's
    /// `java.util.zip.Deflater` (zlib level 6) compresses to a 10-byte stream.
    /// Apple's encoder (zlib level 5) emits a different stream for the same
    /// input, so rebuilding the preimage by re-compressing yields bytes the
    /// Android sender never signed.
    @Test func stockAndroidFrameKeepsTheAndroidSigningPreimage() throws {
        let frame = try #require(Data(hexString:
            "0102070000018e0c19c80006000c1122334455667788012c737422041c4755400100"
            + String(repeating: "22", count: 64)))
        let androidStream = try #require(Data(hexString: "737422041c4755400100"))
        let payload = Data((0..<300).map { $0 % 34 == 0 ? 0x41 : 0x42 })
        // Android's preimage: the frame with ttl 0, no signature, padded to 256.
        let androidPreimage = padded(try #require(Data(hexString:
            "0102000000018e0c19c80004000c1122334455667788012c737422041c4755400100")))

        let decoded = try #require(BinaryProtocol.decode(frame))
        #expect(decoded.payload == payload)
        #expect(decoded.wirePayload?.bytes == androidStream)
        let preimage = try #require(decoded.toBinaryDataForSigning())
        #expect(preimage == androidPreimage)

        // Re-compressing with Apple's encoder gives another stream and so
        // another preimage: a signature over Android's bytes fails on it.
        let freshPreimage = try #require(
            fresh(type: 0x02, ttl: 7, payload: payload).toBinaryDataForSigning())
        #expect(freshPreimage != androidPreimage, "precondition: Apple's DEFLATE differs from Android's here")
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: androidPreimage)
        #expect(key.publicKey.isValidSignature(signature, for: preimage))
        #expect(!key.publicKey.isValidSignature(signature, for: freshPreimage))
    }

    // MARK: - 3. Changing the payload drops the remembered wire bytes

    @Test func changedPayloadIsCompressedAfreshNotReplayed() throws {
        let frame = try #require(fresh(type: 0x02, ttl: 7, payload: compressiblePayload).toBinaryData(padding: false))
        let decoded = try #require(BinaryProtocol.decode(frame))
        #expect(decoded.wirePayload?.compressed == true)

        let other = Data(String(repeating: "something else entirely, also long and repetitive ", count: 6).utf8)
        #expect(other != decoded.payload)
        // `payload` is immutable, so the stale wire bytes travel with a new
        // packet value. The SHA-256 guard must notice the mismatch.
        var changed = fresh(type: decoded.type, ttl: decoded.ttl, payload: other)
        changed.wirePayload = decoded.wirePayload
        #expect(changed.wirePayload?.matches(other) == false)

        let bytes = try #require(changed.toBinaryData(padding: false))
        #expect(bytes != frame)
        let redecoded = try #require(BinaryProtocol.decode(bytes))
        #expect(redecoded.payload == other)
        #expect(bytes[BinaryProtocol.Offsets.flags] & BinaryProtocol.Flags.isCompressed != 0, "a compressible payload is still compressed when encoded fresh")
        // And it is identical to encoding the new payload with no wire bytes at all.
        #expect(bytes == fresh(type: decoded.type, ttl: decoded.ttl, payload: other).toBinaryData(padding: false))
    }

    @Test func wirePayloadIsNotPartOfTheCodedForm() throws {
        let frame = try #require(fresh(type: 0x02, ttl: 7, payload: compressiblePayload).toBinaryData(padding: false))
        let decoded = try #require(BinaryProtocol.decode(frame))
        let json = try JSONEncoder().encode(decoded)
        let text = try #require(String(bytes: json, encoding: .utf8))
        #expect(!text.contains("wirePayload"))
        let restored = try JSONDecoder().decode(BitchatPacket.self, from: json)
        #expect(restored.wirePayload == nil)
        #expect(restored.payload == decoded.payload)
        // Without wire bytes the restored packet encodes like a fresh one.
        #expect(restored.toBinaryData(padding: false) == frame)
    }
}
