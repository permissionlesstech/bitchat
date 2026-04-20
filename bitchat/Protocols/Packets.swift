import Foundation

// MARK: - Protocol TLV Packets

// MARK: - LightningPaymentRequestPacket

/// A structured BOLT11 Lightning invoice sent peer-to-peer over the Bluetooth mesh.
///
/// Sending a bolt11 as plain text works, but a structured packet enables:
/// - Amount and description displayed before the user opens a wallet app
/// - Expiry awareness so the UI can mark stale invoices as expired
/// - A stable `requestID` for delivery receipts and UI deduplication
///
/// ## Wire format
/// Carried inside a `NoisePayloadType.lightningPaymentRequest` Noise payload.
/// All length fields are big-endian UInt16 to accommodate invoices up to 65 KB.
///
/// ```
/// [type: UInt8][length: UInt16 BE][value: …]  …repeating…
/// ```
///
/// ## Offline use
/// A recipient without internet can store the invoice and pay it later once
/// connectivity is restored — the mesh relay handles delivery.
struct LightningPaymentRequestPacket {
    /// Stable UUID for this payment request (for deduplication and receipts).
    let requestID: String
    /// BOLT11 invoice string (lnbc…, lntb…, etc.).
    let invoice: String
    /// Human-readable description of what the payment is for (optional).
    let memo: String?
    /// Amount in satoshis, decoded from the invoice for display (optional).
    /// Senders SHOULD populate this so recipients see the amount without decoding.
    let amountSat: UInt64?
    /// Unix timestamp after which the invoice expires (optional).
    let expiresAt: UInt64?

    private enum TLVType: UInt8 {
        case requestID  = 0x00
        case invoice    = 0x01
        case memo       = 0x02
        case amountSat  = 0x03
        case expiresAt  = 0x04
    }

    func encode() -> Data? {
        var out = Data()

        func appendUInt16BE(_ v: UInt16, into d: inout Data) {
            d.append(UInt8(v >> 8))
            d.append(UInt8(v & 0xFF))
        }

        func appendTLV(_ type: TLVType, utf8 string: String, into d: inout Data) -> Bool {
            guard let bytes = string.data(using: .utf8), bytes.count <= Int(UInt16.max) else { return false }
            d.append(type.rawValue)
            appendUInt16BE(UInt16(bytes.count), into: &d)
            d.append(bytes)
            return true
        }

        func appendTLV(_ type: TLVType, uint64 value: UInt64, into d: inout Data) {
            d.append(type.rawValue)
            appendUInt16BE(8, into: &d)
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { d.append(contentsOf: $0) }
        }

        guard appendTLV(.requestID, utf8: requestID, into: &out) else { return nil }
        guard appendTLV(.invoice,   utf8: invoice,   into: &out) else { return nil }
        if let memo = memo, !memo.isEmpty {
            guard appendTLV(.memo, utf8: memo, into: &out) else { return nil }
        }
        if let sats = amountSat  { appendTLV(.amountSat,  uint64: sats,      into: &out) }
        if let exp  = expiresAt  { appendTLV(.expiresAt,  uint64: exp,       into: &out) }

        return out
    }

    static func decode(from data: Data) -> LightningPaymentRequestPacket? {
        var cursor = data.startIndex
        let end    = data.endIndex

        var requestID: String?
        var invoice:   String?
        var memo:      String?
        var amountSat: UInt64?
        var expiresAt: UInt64?

        while cursor < end {
            guard data.distance(from: cursor, to: end) >= 3 else { return nil }
            let typeRaw = data[cursor]; cursor = data.index(after: cursor)
            let lenHi   = data[cursor]; cursor = data.index(after: cursor)
            let lenLo   = data[cursor]; cursor = data.index(after: cursor)
            let length  = Int(lenHi) << 8 | Int(lenLo)

            guard data.distance(from: cursor, to: end) >= length else { return nil }
            let valueEnd = data.index(cursor, offsetBy: length)
            let value    = data[cursor..<valueEnd]
            cursor = valueEnd

            guard let type = TLVType(rawValue: typeRaw) else { continue }
            switch type {
            case .requestID: requestID = String(data: Data(value), encoding: .utf8)
            case .invoice:   invoice   = String(data: Data(value), encoding: .utf8)
            case .memo:      memo      = String(data: Data(value), encoding: .utf8)
            case .amountSat:
                if length == 8 {
                    var v: UInt64 = 0
                    for byte in value { v = (v << 8) | UInt64(byte) }
                    amountSat = v
                }
            case .expiresAt:
                if length == 8 {
                    var v: UInt64 = 0
                    for byte in value { v = (v << 8) | UInt64(byte) }
                    expiresAt = v
                }
            }
        }

        guard let rid = requestID, let inv = invoice else { return nil }
        return LightningPaymentRequestPacket(
            requestID: rid,
            invoice:   inv,
            memo:      memo,
            amountSat: amountSat,
            expiresAt: expiresAt
        )
    }
}

// MARK: - CashuTokenPacket

/// A Cashu eCash bearer token sent peer-to-peer over the Bluetooth mesh.
///
/// Cashu tokens are self-contained bearer instruments — the token string
/// IS the money. No internet is required by the sender or the relay nodes.
/// The recipient can redeem the token at the mint whenever connectivity allows.
///
/// This enables genuinely offline Bitcoin transfers over Bluetooth mesh:
/// value moves even when neither peer has internet access.
///
/// ## Wire format
/// Carried inside a `NoisePayloadType.cashuToken` Noise payload.
/// Length fields are big-endian UInt16.
///
/// ## Security
/// Once received, the token should be immediately redeemed or re-issued
/// to prevent double-spend by the sender. Warn users to redeem promptly.
struct CashuTokenPacket {
    /// Stable UUID for this transfer (for deduplication and UI tracking).
    let transferID: String
    /// Serialised Cashu token (cashuA… or cashuB… base64url string).
    let token: String
    /// Mint URL the token is valid against (from the token's embedded proof).
    let mintURL: String
    /// Face value in satoshis (from the proofs; provided for display).
    let amountSat: UInt64
    /// Optional note from the sender.
    let memo: String?

    private enum TLVType: UInt8 {
        case transferID = 0x00
        case token      = 0x01
        case mintURL    = 0x02
        case amountSat  = 0x03
        case memo       = 0x04
    }

    func encode() -> Data? {
        var out = Data()

        func appendUInt16BE(_ v: UInt16, into d: inout Data) {
            d.append(UInt8(v >> 8))
            d.append(UInt8(v & 0xFF))
        }

        func appendTLV(_ type: TLVType, utf8 string: String, into d: inout Data) -> Bool {
            guard let bytes = string.data(using: .utf8), bytes.count <= Int(UInt16.max) else { return false }
            d.append(type.rawValue)
            appendUInt16BE(UInt16(bytes.count), into: &d)
            d.append(bytes)
            return true
        }

        func appendTLV(_ type: TLVType, uint64 value: UInt64, into d: inout Data) {
            d.append(type.rawValue)
            appendUInt16BE(8, into: &d)
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { d.append(contentsOf: $0) }
        }

        guard appendTLV(.transferID, utf8: transferID, into: &out) else { return nil }
        guard appendTLV(.token,      utf8: token,      into: &out) else { return nil }
        guard appendTLV(.mintURL,    utf8: mintURL,    into: &out) else { return nil }
        appendTLV(.amountSat, uint64: amountSat, into: &out)
        if let memo = memo, !memo.isEmpty {
            guard appendTLV(.memo, utf8: memo, into: &out) else { return nil }
        }

        return out
    }

    static func decode(from data: Data) -> CashuTokenPacket? {
        var cursor = data.startIndex
        let end    = data.endIndex

        var transferID: String?
        var token:      String?
        var mintURL:    String?
        var amountSat:  UInt64?
        var memo:       String?

        while cursor < end {
            guard data.distance(from: cursor, to: end) >= 3 else { return nil }
            let typeRaw = data[cursor]; cursor = data.index(after: cursor)
            let lenHi   = data[cursor]; cursor = data.index(after: cursor)
            let lenLo   = data[cursor]; cursor = data.index(after: cursor)
            let length  = Int(lenHi) << 8 | Int(lenLo)

            guard data.distance(from: cursor, to: end) >= length else { return nil }
            let valueEnd = data.index(cursor, offsetBy: length)
            let value    = data[cursor..<valueEnd]
            cursor = valueEnd

            guard let type = TLVType(rawValue: typeRaw) else { continue }
            switch type {
            case .transferID: transferID = String(data: Data(value), encoding: .utf8)
            case .token:      token      = String(data: Data(value), encoding: .utf8)
            case .mintURL:    mintURL    = String(data: Data(value), encoding: .utf8)
            case .amountSat:
                if length == 8 {
                    var v: UInt64 = 0
                    for byte in value { v = (v << 8) | UInt64(byte) }
                    amountSat = v
                }
            case .memo: memo = String(data: Data(value), encoding: .utf8)
            }
        }

        guard let tid = transferID, let tok = token,
              let mint = mintURL, let sats = amountSat else { return nil }
        return CashuTokenPacket(
            transferID: tid,
            token:      tok,
            mintURL:    mint,
            amountSat:  sats,
            memo:       memo
        )
    }
}

// MARK: - DVMQueryPacket

/// A NIP-90 Data Vending Machine job request routed over the Bluetooth mesh.
///
/// ## The mesh AI bridge concept
/// Gateway nodes — devices with both Bluetooth mesh connectivity and internet access —
/// receive these packets and forward them to Nostr DVMs (AI service providers).
/// Results return through the mesh as `DVMResultPacket`. This enables nodes without
/// internet (deep rural, disaster zones, offline islands) to query AI services via
/// neighbours who happen to have connectivity.
///
/// ## Use cases
/// - Crop disease diagnosis for farmers in areas without reliable internet
/// - Medical triage information for rural health workers
/// - Bitcoin/Lightning education in local languages
/// - Legal rights information for migrants and displaced persons
///
/// ## Wire format
/// Carried inside a `NoisePayloadType.dvmQuery` Noise payload.
/// Length fields are big-endian UInt16 (same pattern as LightningPaymentRequestPacket).
///
/// ```
/// [type: UInt8][length: UInt16 BE][value: …]  …repeating…
/// ```
struct DVMQueryPacket {
    /// Stable UUID for this query (for deduplication, routing, and result matching).
    let requestID: String
    /// NIP-90 job kind (5000-5999). Examples: 5100 = summarize, 5202 = classify.
    let kind: UInt16
    /// The query input text (the question / content to process).
    let input: String
    /// Maximum satoshis the requester is willing to pay for this job.
    let maxSatoshi: UInt64
    /// Optional BCP-47 language tag for the preferred response language (e.g. "sw", "pt-BR").
    let preferredLanguage: String?

    private enum TLVType: UInt8 {
        case requestID        = 0x00
        case kind             = 0x01
        case input            = 0x02
        case maxSatoshi       = 0x03
        case preferredLanguage = 0x04
    }

    func encode() -> Data? {
        var out = Data()

        func appendUInt16BE(_ v: UInt16, into d: inout Data) {
            d.append(UInt8(v >> 8))
            d.append(UInt8(v & 0xFF))
        }

        func appendTLV(_ type: TLVType, utf8 string: String, into d: inout Data) -> Bool {
            guard let bytes = string.data(using: .utf8), bytes.count <= Int(UInt16.max) else { return false }
            d.append(type.rawValue)
            appendUInt16BE(UInt16(bytes.count), into: &d)
            d.append(bytes)
            return true
        }

        func appendTLV(_ type: TLVType, uint16 value: UInt16, into d: inout Data) {
            d.append(type.rawValue)
            appendUInt16BE(2, into: &d)
            appendUInt16BE(value, into: &d)
        }

        func appendTLV(_ type: TLVType, uint64 value: UInt64, into d: inout Data) {
            d.append(type.rawValue)
            appendUInt16BE(8, into: &d)
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { out.append(contentsOf: $0) }
        }

        guard appendTLV(.requestID, utf8: requestID, into: &out) else { return nil }
        appendTLV(.kind, uint16: kind, into: &out)
        guard appendTLV(.input, utf8: input, into: &out) else { return nil }
        appendTLV(.maxSatoshi, uint64: maxSatoshi, into: &out)
        if let lang = preferredLanguage, !lang.isEmpty {
            guard appendTLV(.preferredLanguage, utf8: lang, into: &out) else { return nil }
        }

        return out
    }

    static func decode(from data: Data) -> DVMQueryPacket? {
        var cursor = data.startIndex
        let end    = data.endIndex

        var requestID: String?
        var kind: UInt16?
        var input: String?
        var maxSatoshi: UInt64 = 0
        var preferredLanguage: String?

        while cursor < end {
            guard data.distance(from: cursor, to: end) >= 3 else { return nil }
            let typeRaw = data[cursor]; cursor = data.index(after: cursor)
            let lenHi   = data[cursor]; cursor = data.index(after: cursor)
            let lenLo   = data[cursor]; cursor = data.index(after: cursor)
            let length  = Int(lenHi) << 8 | Int(lenLo)

            guard data.distance(from: cursor, to: end) >= length else { return nil }
            let valueEnd = data.index(cursor, offsetBy: length)
            let value    = data[cursor..<valueEnd]
            cursor = valueEnd

            guard let type = TLVType(rawValue: typeRaw) else { continue }
            switch type {
            case .requestID:        requestID = String(data: Data(value), encoding: .utf8)
            case .input:            input = String(data: Data(value), encoding: .utf8)
            case .preferredLanguage: preferredLanguage = String(data: Data(value), encoding: .utf8)
            case .kind:
                if length == 2 {
                    kind = UInt16(value[value.startIndex]) << 8 | UInt16(value[value.index(after: value.startIndex)])
                }
            case .maxSatoshi:
                if length == 8 {
                    var v: UInt64 = 0
                    for byte in value { v = (v << 8) | UInt64(byte) }
                    maxSatoshi = v
                }
            }
        }

        guard let rid = requestID, let k = kind, let inp = input else { return nil }
        return DVMQueryPacket(
            requestID: rid,
            kind: k,
            input: inp,
            maxSatoshi: maxSatoshi,
            preferredLanguage: preferredLanguage
        )
    }
}

// MARK: - DVMResultPacket

/// A NIP-90 DVM job result returned through the Bluetooth mesh.
/// Sent by gateway nodes in response to a `DVMQueryPacket`.
struct DVMResultPacket {
    /// Matches the `requestID` of the originating `DVMQueryPacket`.
    let requestID: String
    /// The job result content (AI response text).
    let result: String
    /// Satoshis paid to the Nostr DVM for this result.
    let satsPaid: UInt64
    /// Optional: the DVM's Nostr pubkey (hex), for reputation purposes.
    let dvmPubkey: String?

    private enum TLVType: UInt8 {
        case requestID  = 0x00
        case result     = 0x01
        case satsPaid   = 0x02
        case dvmPubkey  = 0x03
    }

    func encode() -> Data? {
        var out = Data()

        func appendUInt16BE(_ v: UInt16, into d: inout Data) {
            d.append(UInt8(v >> 8))
            d.append(UInt8(v & 0xFF))
        }

        func appendTLV(_ type: TLVType, utf8 string: String, into d: inout Data) -> Bool {
            guard let bytes = string.data(using: .utf8), bytes.count <= Int(UInt16.max) else { return false }
            d.append(type.rawValue)
            appendUInt16BE(UInt16(bytes.count), into: &d)
            d.append(bytes)
            return true
        }

        func appendTLV(_ type: TLVType, uint64 value: UInt64, into d: inout Data) {
            d.append(type.rawValue)
            appendUInt16BE(8, into: &d)
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { out.append(contentsOf: $0) }
        }

        guard appendTLV(.requestID, utf8: requestID, into: &out) else { return nil }
        guard appendTLV(.result,    utf8: result,    into: &out) else { return nil }
        appendTLV(.satsPaid, uint64: satsPaid, into: &out)
        if let pub = dvmPubkey, !pub.isEmpty {
            guard appendTLV(.dvmPubkey, utf8: pub, into: &out) else { return nil }
        }

        return out
    }

    static func decode(from data: Data) -> DVMResultPacket? {
        var cursor = data.startIndex
        let end    = data.endIndex

        var requestID: String?
        var result:    String?
        var satsPaid:  UInt64 = 0
        var dvmPubkey: String?

        while cursor < end {
            guard data.distance(from: cursor, to: end) >= 3 else { return nil }
            let typeRaw = data[cursor]; cursor = data.index(after: cursor)
            let lenHi   = data[cursor]; cursor = data.index(after: cursor)
            let lenLo   = data[cursor]; cursor = data.index(after: cursor)
            let length  = Int(lenHi) << 8 | Int(lenLo)

            guard data.distance(from: cursor, to: end) >= length else { return nil }
            let valueEnd = data.index(cursor, offsetBy: length)
            let value    = data[cursor..<valueEnd]
            cursor = valueEnd

            guard let type = TLVType(rawValue: typeRaw) else { continue }
            switch type {
            case .requestID: requestID = String(data: Data(value), encoding: .utf8)
            case .result:    result    = String(data: Data(value), encoding: .utf8)
            case .dvmPubkey: dvmPubkey = String(data: Data(value), encoding: .utf8)
            case .satsPaid:
                if length == 8 {
                    var v: UInt64 = 0
                    for byte in value { v = (v << 8) | UInt64(byte) }
                    satsPaid = v
                }
            }
        }

        guard let rid = requestID, let res = result else { return nil }
        return DVMResultPacket(
            requestID: rid,
            result:    res,
            satsPaid:  satsPaid,
            dvmPubkey: dvmPubkey
        )
    }
}

struct AnnouncementPacket {
    let nickname: String
    let noisePublicKey: Data            // Noise static public key (Curve25519.KeyAgreement)
    let signingPublicKey: Data          // Ed25519 public key for signing
    let directNeighbors: [Data]?        // 8-byte peer IDs

    private enum TLVType: UInt8 {
        case nickname = 0x01
        case noisePublicKey = 0x02
        case signingPublicKey = 0x03
        case directNeighbors = 0x04
    }

    func encode() -> Data? {
        var data = Data()
        // Reserve: TLVs for nickname (2 + n), noise key (2 + 32), signing key (2 + 32)
        data.reserveCapacity(2 + min(nickname.count, 255) + 2 + noisePublicKey.count + 2 + signingPublicKey.count)

        // TLV for nickname
        guard let nicknameData = nickname.data(using: .utf8), nicknameData.count <= 255 else { return nil }
        data.append(TLVType.nickname.rawValue)
        data.append(UInt8(nicknameData.count))
        data.append(nicknameData)

        // TLV for noise public key
        guard noisePublicKey.count <= 255 else { return nil }
        data.append(TLVType.noisePublicKey.rawValue)
        data.append(UInt8(noisePublicKey.count))
        data.append(noisePublicKey)

        // TLV for signing public key
        guard signingPublicKey.count <= 255 else { return nil }
        data.append(TLVType.signingPublicKey.rawValue)
        data.append(UInt8(signingPublicKey.count))
        data.append(signingPublicKey)
        
        // TLV for direct neighbors (optional)
        if let neighbors = directNeighbors, !neighbors.isEmpty {
            let neighborsData = neighbors.prefix(10).reduce(Data()) { $0 + $1 }
            if !neighborsData.isEmpty && neighborsData.count % 8 == 0 {
                data.append(TLVType.directNeighbors.rawValue)
                data.append(UInt8(neighborsData.count))
                data.append(neighborsData)
            }
        }

        return data
    }

    static func decode(from data: Data) -> AnnouncementPacket? {
        var offset = 0
        var nickname: String?
        var noisePublicKey: Data?
        var signingPublicKey: Data?
        var directNeighbors: [Data]?

        while offset + 2 <= data.count {
            let typeRaw = data[offset]
            offset += 1
            let length = Int(data[offset])
            offset += 1

            guard offset + length <= data.count else { return nil }
            let value = data[offset..<offset + length]
            offset += length

            if let type = TLVType(rawValue: typeRaw) {
                switch type {
                case .nickname:
                    nickname = String(data: value, encoding: .utf8)
                case .noisePublicKey:
                    noisePublicKey = Data(value)
                case .signingPublicKey:
                    signingPublicKey = Data(value)
                case .directNeighbors:
                    if length > 0 && length % 8 == 0 {
                        var neighbors = [Data]()
                        let count = length / 8
                        for i in 0..<count {
                            let start = value.startIndex + i * 8
                            let end = start + 8
                            neighbors.append(Data(value[start..<end]))
                        }
                        directNeighbors = neighbors
                    }
                }
            } else {
                // Unknown TLV; skip (tolerant decoder for forward compatibility)
                continue
            }
        }

        guard let nickname = nickname, let noisePublicKey = noisePublicKey, let signingPublicKey = signingPublicKey else { return nil }
        return AnnouncementPacket(
            nickname: nickname,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            directNeighbors: directNeighbors
        )
    }
}

struct PrivateMessagePacket {
    let messageID: String
    let content: String

    private enum TLVType: UInt8 {
        case messageID = 0x00
        case content = 0x01
    }

    func encode() -> Data? {
        var data = Data()
        data.reserveCapacity(2 + min(messageID.count, 255) + 2 + min(content.count, 255))

        // TLV for messageID
        guard let messageIDData = messageID.data(using: .utf8), messageIDData.count <= 255 else { return nil }
        data.append(TLVType.messageID.rawValue)
        data.append(UInt8(messageIDData.count))
        data.append(messageIDData)

        // TLV for content
        guard let contentData = content.data(using: .utf8), contentData.count <= 255 else { return nil }
        data.append(TLVType.content.rawValue)
        data.append(UInt8(contentData.count))
        data.append(contentData)

        return data
    }

    static func decode(from data: Data) -> PrivateMessagePacket? {
        var offset = 0
        var messageID: String?
        var content: String?

        while offset + 2 <= data.count {
            guard let type = TLVType(rawValue: data[offset]) else { return nil }
            offset += 1

            let length = Int(data[offset])
            offset += 1

            guard offset + length <= data.count else { return nil }
            let value = data[offset..<offset + length]
            offset += length

            switch type {
            case .messageID:
                messageID = String(data: value, encoding: .utf8)
            case .content:
                content = String(data: value, encoding: .utf8)
            }
        }

        guard let messageID = messageID, let content = content else { return nil }
        return PrivateMessagePacket(messageID: messageID, content: content)
    }
}
