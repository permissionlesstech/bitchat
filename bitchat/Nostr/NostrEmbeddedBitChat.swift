import Foundation
import BitFoundation

// MARK: - BitChat-over-Nostr Adapter

struct NostrEmbeddedBitChat {
    /// Build a `bitchat1:` base64url-encoded BitChat packet carrying a private message for Nostr DMs.
    static func encodePMForNostr(content: String, messageID: String, recipientPeerID: PeerID, senderPeerID: PeerID) -> String? {
        // TLV-encode the private message
        let pm = PrivateMessagePacket(messageID: messageID, content: content)
        guard let tlv = pm.encode() else { return nil }

        // Prefix with NoisePayloadType
        var payload = Data([NoisePayloadType.privateMessage.rawValue])
        payload.append(tlv)

        // Determine 8-byte recipient ID to embed
        let recipientID = normalizeRecipientPeerID(recipientPeerID)

        let packet = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: Data(hexString: senderPeerID.id) ?? Data(),
            recipientID: Data(hexString: recipientID.id),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )

        guard let data = packet.toBinaryData() else { return nil }
        return "bitchat1:" + base64URLEncode(data)
    }

    /// Build a `bitchat1:` base64url-encoded BitChat packet carrying a delivery/read ack for Nostr DMs.
    static func encodeAckForNostr(type: NoisePayloadType, messageID: String, recipientPeerID: PeerID, senderPeerID: PeerID) -> String? {
        guard type == .delivered || type == .readReceipt else { return nil }

        var payload = Data([type.rawValue])
        payload.append(Data(messageID.utf8))

        let recipientID = normalizeRecipientPeerID(recipientPeerID)

        let packet = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: Data(hexString: senderPeerID.id) ?? Data(),
            recipientID: Data(hexString: recipientID.id),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )

        guard let data = packet.toBinaryData() else { return nil }
        return "bitchat1:" + base64URLEncode(data)
    }

    /// Build a `bitchat1:` ACK (delivered/read) without an embedded recipient peer ID (geohash DMs).
    /// The sender ID is random per envelope; see `unlinkableSenderID()`.
    static func encodeAckForNostrNoRecipient(type: NoisePayloadType, messageID: String) -> String? {
        guard type == .delivered || type == .readReceipt else { return nil }

        var payload = Data([type.rawValue])
        payload.append(Data(messageID.utf8))

        let packet = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: unlinkableSenderID(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )

        guard let data = packet.toBinaryData() else { return nil }
        return "bitchat1:" + base64URLEncode(data)
    }

    /// Build a `bitchat1:` payload without an embedded recipient peer ID (used for geohash DMs).
    /// The sender ID is random per envelope; see `unlinkableSenderID()`.
    static func encodePMForNostrNoRecipient(content: String, messageID: String) -> String? {
        let pm = PrivateMessagePacket(messageID: messageID, content: content)
        guard let tlv = pm.encode() else { return nil }

        var payload = Data([NoisePayloadType.privateMessage.rawValue])
        payload.append(tlv)

        let packet = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: unlinkableSenderID(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )

        guard let data = packet.toBinaryData() else { return nil }
        return "bitchat1:" + base64URLEncode(data)
    }

    /// Sender ID for the recipient-less envelopes above. They go out under a
    /// per-geohash identity (and as the acks for inbound account DMs), where
    /// no receiver reads this field: iOS and Android both key these
    /// conversations on the Nostr sender pubkey. The mesh peer ID must never
    /// go here: it is the stable Noise fingerprint prefix, so anyone who DMs
    /// a geohash identity (and gets the automatic DELIVERED ack back) could
    /// link that persona to the device and to its other geohash personas.
    /// Fresh random bytes per envelope keep even our own envelopes unlinkable.
    private static func unlinkableSenderID() -> Data {
        Data((0..<BinaryProtocol.senderIDSize).map { _ in UInt8.random(in: .min ... .max) })
    }

    private static func normalizeRecipientPeerID(_ recipientPeerID: PeerID) -> PeerID {
        if let maybeData = Data(hexString: recipientPeerID.id) {
            if maybeData.count == 32 {
                // Treat as Noise static public key; derive peerID from fingerprint
                return PeerID(publicKey: maybeData)
            } else if maybeData.count == 8 {
                // Already an 8-byte peer ID
                return recipientPeerID
            }
        }
        // Fallback: return as-is (expecting 16 hex chars) – caller should pass a valid peer ID
        return recipientPeerID
    }

    /// Base64url encode without padding
    private static func base64URLEncode(_ data: Data) -> String {
        let b64 = data.base64EncodedString()
        return b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
