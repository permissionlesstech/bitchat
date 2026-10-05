import BitFoundation
import CryptoKit
import Foundation
import Testing

@testable import bitchat

struct ForeignPacketReceptionTests {
    func frame(payload: Data, encoded: Data, compressed: Bool, signature: Data? = nil, ttl: UInt8 = 0) -> Data {
        var data = Data([1, 2, ttl])
        let stamp: UInt64 = 1_000_000
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((stamp >> shift) & 255)) }
        data.append(1 | (compressed ? 4 : 0) | (signature == nil ? 0 : 2))
        let count = encoded.count + (compressed ? 2 : 0)
        data.append(UInt8(count >> 8))
        data.append(UInt8(count & 255))
        data.append(contentsOf: [17, 34, 51, 68, 85, 102, 119, 136])
        data.append(Data(repeating: 255, count: 8))
        if compressed {
            data.append(UInt8(payload.count >> 8))
            data.append(UInt8(payload.count & 255))
        }
        data.append(encoded)
        if let signature { data.append(signature) }
        return data
    }

    func delivered(_ packet: BitchatPacket, key: Data) -> Int {
        let remote = PeerID(hexData: packet.senderID)
        let local = PeerID(str: "0102030405060708")
        let verifier = NoiseEncryptionService(keychain: MockKeychain())
        var count = 0
        let info = BLEPeerInfo(
            peerID: remote, nickname: "SyntheticPeer", isConnected: true, noisePublicKey: nil, signingPublicKey: key,
            isVerifiedNickname: true, lastSeen: Date(timeIntervalSince1970: 1000))
        let handler = BLEPublicMessageHandler(
            environment: BLEPublicMessageHandlerEnvironment(
                localPeerID: { local }, localNickname: { "SyntheticLocal" }, now: { Date(timeIntervalSince1970: 1000) },
                peersSnapshot: { [remote: info] },
                verifyPacketSignature: { verifier.verifyPacketSignature($0, publicKey: $1) },
                signedSenderDisplayName: { p, _ in
                    verifier.verifyPacketSignature(p, publicKey: key) ? "SyntheticPeer" : nil
                },
                trackPacketSeen: { _ in }, linkState: { _ in (true, false) }, takeSelfBroadcastMessageID: { _ in nil },
                deliverPublicMessage: { _, _, _, _, _ in count += 1 }))
        handler.handle(packet, from: remote)
        return count
    }
    @Test func deliveryRelayAndTampering() throws {
        let unsigned = try #require(Data(base64Encoded: Self.androidUnsignedFrame))
        let packet = try #require(BitchatPacket.from(unsigned))
        let payload = packet.payload
        let compressed = Data(unsigned.dropFirst(32))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        for isCompressed in [true, false] {
            let encoded = isCompressed ? compressed : payload
            let preimage = isCompressed ? unsigned : frame(payload: payload, encoded: encoded, compressed: false)
            let signature = try key.signature(for: preimage)
            let wire = frame(payload: payload, encoded: encoded, compressed: isCompressed, signature: signature, ttl: 3)
            let decoded = try #require(BitchatPacket.from(wire))
            let received = delivered(decoded, key: key.publicKey.rawRepresentation)
            #expect(received == 1)
            var relay = decoded
            relay.ttl -= 1
            let relayedWire = try #require(relay.toBinaryData(padding: false))
            // Check the relay output against the original signature without recompressing its payload.
            var relayPreimage = relayedWire.dropLast(64)
            relayPreimage[2] = 0
            relayPreimage[11] &= ~UInt8(2)
            let relayValid = key.publicKey.isValidSignature(signature, for: Data(relayPreimage))
            #expect(relayValid)
            var invalidSignature = decoded
            invalidSignature.signature![0] ^= 1
            #expect(delivered(invalidSignature, key: key.publicKey.rawRepresentation) == 0)
            let wrong = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 8, count: 32))
            #expect(delivered(decoded, key: wrong.publicKey.rawRepresentation) == 0)
            // Mutate the signed sender and timestamp, keeping a valid frame.
            for offset in [10, 14] {
                var mutated = wire
                mutated[offset] ^= 1
                let parsed = try #require(BitchatPacket.from(mutated))
                #expect(delivered(parsed, key: key.publicKey.rawRepresentation) == 0)
            }
            // A separately encoded altered payload carries the original signature.
            var alteredPayload = payload
            alteredPayload[0] ^= 1
            let altered = BitchatPacket(
                type: 2, senderID: decoded.senderID, recipientID: decoded.recipientID, timestamp: decoded.timestamp,
                payload: alteredPayload, signature: signature, ttl: 3)
            #expect(delivered(altered, key: key.publicKey.rawRepresentation) == 0)
        }
    }
    @Test func fragmentedAndroidMessage() throws {
        let signing = try #require(Data(base64Encoded: Self.androidUnsignedFrame))
        var wire = signing
        wire[2] = 3
        wire[11] |= 2
        wire.append(Data(repeating: 0, count: 64))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let signature = try key.signature(for: signing)
        wire.replaceSubrange((wire.count - 64)..<wire.count, with: signature)
        let remote = PeerID(str: "1122334455667788")
        let local = PeerID(str: "0102030405060708")
        var assembly = BLEFragmentAssemblyBuffer()
        var reassembled = 0
        var deliveredCount = 0
        let handler = BLEFragmentHandler(
            environment: BLEFragmentHandlerEnvironment(
                localPeerID: { local }, trackPacketSeen: { _ in },
                appendFragment: {
                    assembly.append($0, maxInFlightAssemblies: 128, now: Date(timeIntervalSince1970: 1000))
                },
                isAcceptedIngressPayload: { packet, peer in
                    if case .success = BLEIngressPacketGuard.validatePayload(
                        packet, from: peer, nowMs: 1_000_000, isValidSyncResponse: { _ in false }) {
                        return true
                    }
                    return false
                },
                processReassembledPacket: { packet, _ in
                    reassembled += 1
                    deliveredCount += delivered(packet, key: key.publicKey.rawRepresentation)
                }))
        // Android FragmentManager uses 454-byte chunks for a v1 broadcast with a recipient.
        let chunkSize = 454
        let total = (wire.count + chunkSize - 1) / chunkSize
        for index in (0..<total).reversed() {
            var fragmentPayload = Data([0, 1, 2, 3, 4, 5, 6, 7])
            fragmentPayload.append(UInt8(index >> 8))
            fragmentPayload.append(UInt8(index & 255))
            fragmentPayload.append(UInt8(total >> 8))
            fragmentPayload.append(UInt8(total & 255))
            fragmentPayload.append(2)
            fragmentPayload.append(wire[(index * chunkSize)..<min((index + 1) * chunkSize, wire.count)])
            let fragment = BitchatPacket(
                type: 32, senderID: Data([17, 34, 51, 68, 85, 102, 119, 136]),
                recipientID: Data(repeating: 255, count: 8), timestamp: 1_000_000, payload: fragmentPayload,
                signature: nil, ttl: 3)
            let frame = try #require(fragment.toBinaryData(padding: false))
            let decoded = try #require(BitchatPacket.from(frame))
            handler.handle(decoded, from: remote)
        }
        #expect(reassembled == 1)
        #expect(deliveredCount == 1)
    }

    // Synthetic public-message frame emitted by the Android encoder at
    // 795715a5c8a9d89e18b71150c059ff9d7169c359 using Java 21 raw DEFLATE.
    // TTL is zero and no signature is present; tests sign these exact bytes.
    private static let androidUnsignedFrame =
        "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"
        + "sEsq7Ng165+GVmdFbdVUl9xW1/b3Xw=="
}
