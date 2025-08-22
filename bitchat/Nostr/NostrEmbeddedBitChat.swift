import Foundation

// MARK: - BitChat-over-Nostr Adapter

struct NostrEmbeddedBitChat {
    /// Build a `bitchat1:` base64url-encoded BitChat packet carrying a private message for Nostr DMs.
    static func encodePMForNostr(content: String, messageID: String, recipientPeerID: String, senderPeerID: String) -> String? {
        // TLV-encode the private message
        let pm = PrivateMessagePacket(messageID: messageID, content: content)
        guard let tlv = pm.encode() else { return nil }

        // Prefix with NoisePayloadType
        var payload = Data([NoisePayloadType.privateMessage.rawValue])
        payload.append(tlv)

        // Determine 8-byte recipient ID to embed
        let recipientIDHex: String = normalizeRecipientPeerID(recipientPeerID)

        let packet = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: Data(hexString: senderPeerID) ?? Data(),
            recipientID: Data(hexString: recipientIDHex),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )

        guard let data = packet.toBinaryData() else { return nil }
        return "bitchat1:" + base64URLEncode(data)
    }

    /// Build a `bitchat1:` base64url-encoded BitChat packet carrying a delivery/read ack for Nostr DMs.
    static func encodeAckForNostr(type: NoisePayloadType, messageID: String, recipientPeerID: String, senderPeerID: String) -> String? {
        guard type == .delivered || type == .readReceipt else { return nil }

        var payload = Data([type.rawValue])
        payload.append(Data(messageID.utf8))

        let recipientIDHex: String = normalizeRecipientPeerID(recipientPeerID)

        let packet = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: Data(hexString: senderPeerID) ?? Data(),
            recipientID: Data(hexString: recipientIDHex),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )

        guard let data = packet.toBinaryData() else { return nil }
        return "bitchat1:" + base64URLEncode(data)
    }

    /// Build a `bitchat1:` ACK (delivered/read) without an embedded recipient peer ID (geohash DMs).
    static func encodeAckForNostrNoRecipient(type: NoisePayloadType, messageID: String, senderPeerID: String) -> String? {
        guard type == .delivered || type == .readReceipt else { return nil }

        var payload = Data([type.rawValue])
        payload.append(Data(messageID.utf8))

        let packet = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: Data(hexString: senderPeerID) ?? Data(),
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
    static func encodePMForNostrNoRecipient(content: String, messageID: String, senderPeerID: String) -> String? {
        let pm = PrivateMessagePacket(messageID: messageID, content: content)
        guard let tlv = pm.encode() else { return nil }

        var payload = Data([NoisePayloadType.privateMessage.rawValue])
        payload.append(tlv)

        let packet = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: Data(hexString: senderPeerID) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )

        guard let data = packet.toBinaryData() else { return nil }
        return "bitchat1:" + base64URLEncode(data)
    }

    private static func normalizeRecipientPeerID(_ recipientPeerID: String) -> String {
        if let maybeData = Data(hexString: recipientPeerID) {
            if maybeData.count == 32 {
                // Treat as Noise static public key; derive peerID from fingerprint
                return PeerIDUtils.derivePeerID(fromPublicKey: maybeData)
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
