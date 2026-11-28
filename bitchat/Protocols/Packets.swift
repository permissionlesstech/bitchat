import BitFoundation
import Foundation

// MARK: - Protocol TLV Packets

struct AnnouncementPacket {
    let nickname: String
    let noisePublicKey: Data            // Noise static public key (Curve25519.KeyAgreement)
    let signingPublicKey: Data          // Ed25519 public key for signing
    let directNeighbors: [Data]?        // 8-byte peer IDs
    let capabilities: PeerCapabilities? // advertised feature bits; nil when absent (old clients)
    /// Rendezvous geohash cell this peer bridges, when advertising `.bridge`.
    /// Coarse (cell-level) by design; lets mesh-only peers compose correctly
    /// tagged rendezvous events without their own location fix.
    let bridgeGeohash: String?

    init(
        nickname: String,
        noisePublicKey: Data,
        signingPublicKey: Data,
        directNeighbors: [Data]?,
        capabilities: PeerCapabilities? = nil,
        bridgeGeohash: String? = nil
    ) {
        self.nickname = nickname
        self.noisePublicKey = noisePublicKey
        self.signingPublicKey = signingPublicKey
        self.directNeighbors = directNeighbors
        self.capabilities = capabilities
        self.bridgeGeohash = bridgeGeohash
    }

    private enum TLVType: UInt8 {
        case nickname = 0x01
        case noisePublicKey = 0x02
        case signingPublicKey = 0x03
        case directNeighbors = 0x04
        case capabilities = 0x05
        case bridgeGeohash = 0x06
    }

    func encode() -> Data? {
        guard let nicknameData = nickname.data(using: .utf8), nicknameData.count <= 255,
              noisePublicKey.count <= 255,
              signingPublicKey.count <= 255 else { return nil }

        var writer = TLVWriter(
            lengthWidth: .oneByte,
            capacity: 2 + nicknameData.count + 2 + noisePublicKey.count + 2 + signingPublicKey.count
        )
        writer.append(TLVType.nickname.rawValue, nicknameData)
        writer.append(TLVType.noisePublicKey.rawValue, noisePublicKey)
        writer.append(TLVType.signingPublicKey.rawValue, signingPublicKey)

        // TLV for direct neighbors (optional)
        if let neighbors = directNeighbors, !neighbors.isEmpty {
            let neighborsData = neighbors.prefix(10).reduce(Data()) { $0 + $1 }
            if !neighborsData.isEmpty && neighborsData.count % 8 == 0 {
                writer.append(TLVType.directNeighbors.rawValue, neighborsData)
            }
        }

        // TLV for capabilities (optional)
        if let capabilities {
            let capabilityBytes = capabilities.encoded()
            guard capabilityBytes.count <= 255 else { return nil }
            writer.append(TLVType.capabilities.rawValue, capabilityBytes)
        }

        // TLV for bridge rendezvous cell (optional; old clients skip it)
        if let bridgeGeohash,
           let cellData = bridgeGeohash.data(using: .utf8),
           !cellData.isEmpty, cellData.count <= 12 {
            writer.append(TLVType.bridgeGeohash.rawValue, cellData)
        }

        return writer.data
    }

    static func decode(from data: Data) -> AnnouncementPacket? {
        var reader = TLVReader(data, lengthWidth: .oneByte)
        var nickname: String?
        var noisePublicKey: Data?
        var signingPublicKey: Data?
        var directNeighbors: [Data]?
        var capabilities: PeerCapabilities?
        var bridgeGeohash: String?

        loop: while true {
            switch reader.next(allowTrailingHeaderRemainder: true) {
            case .end:
                break loop
            case .malformed:
                return nil
            case .entry(let typeRaw, let value):
                guard let type = TLVType(rawValue: typeRaw) else { continue }
                switch type {
                case .nickname:
                    nickname = String(data: value, encoding: .utf8)
                case .noisePublicKey:
                    noisePublicKey = Data(value)
                case .signingPublicKey:
                    signingPublicKey = Data(value)
                case .directNeighbors:
                    if !value.isEmpty && value.count % 8 == 0 {
                        var neighbors = [Data]()
                        let count = value.count / 8
                        for i in 0..<count {
                            let start = value.startIndex + i * 8
                            neighbors.append(Data(value[start..<(start + 8)]))
                        }
                        directNeighbors = neighbors
                    }
                case .capabilities:
                    capabilities = PeerCapabilities(encoded: Data(value))
                case .bridgeGeohash:
                    if value.count <= 12 {
                        bridgeGeohash = String(data: value, encoding: .utf8)
                    }
                }
            }
        }

        guard let nickname, let noisePublicKey, let signingPublicKey else { return nil }
        return AnnouncementPacket(
            nickname: nickname,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            directNeighbors: directNeighbors,
            capabilities: capabilities,
            bridgeGeohash: bridgeGeohash
        )
    }
}

/// State that is authoritative only because it is carried inside an
/// established Noise session. The public announce remains useful for
/// discovery, but its self-signature cannot prove possession of the copied
/// Noise public key it contains.
///
/// Wire format (v1):
/// `[version=0x01][type][length][value]...`
/// - TLV `0x01`: canonical minimal little-endian `PeerCapabilities`
/// - TLV `0x02`: 32-byte Ed25519 signing public key
/// - TLV `0x03`: optional 2-byte big-endian reassembly fragment ceiling
///
/// Unknown TLVs are skipped for forward compatibility. Unknown versions,
/// duplicate required fields, non-canonical capabilities, and malformed required
/// lengths are rejected. An unreadable optional ceiling preserves identity and
/// capabilities while selecting the conservative fragment limit.
struct AuthenticatedPeerStatePacket: Equatable {
    static let currentVersion: UInt8 = 1
    static let signingPublicKeyLength = 32
    static let maxReassemblyFragmentsLength = 2
    static let malformedReassemblyFragmentCeiling: UInt16 = 256

    let capabilities: PeerCapabilities
    let signingPublicKey: Data
    /// How many BLE fragments this peer will reassemble for one packet, as it
    /// reported inside the established Noise session.
    ///
    /// The `.privateMedia` capability bit does not describe reassembly capacity.
    /// A missing limit preserves existing sender behavior; this cannot protect
    /// unadvertised encrypted receivers with a smaller fragment limit.
    /// See `BLEFragmentCeilingPolicy` for the conservative malformed-field and
    /// raw migration limits.
    let maxReassemblyFragments: UInt16?

    init(
        capabilities: PeerCapabilities,
        signingPublicKey: Data,
        maxReassemblyFragments: UInt16? = nil
    ) {
        self.capabilities = capabilities
        self.signingPublicKey = signingPublicKey
        self.maxReassemblyFragments = maxReassemblyFragments
    }

    private enum TLVType: UInt8 {
        case capabilities = 0x01
        case signingPublicKey = 0x02
        case maxReassemblyFragments = 0x03
    }

    func encode() -> Data? {
        guard signingPublicKey.count == Self.signingPublicKeyLength else { return nil }
        let capabilityBytes = capabilities.encoded()
        guard !capabilityBytes.isEmpty, capabilityBytes.count <= 8 else { return nil }
        // Zero would advertise a peer that can reassemble nothing, which is
        // indistinguishable in effect from refusing every fragmented packet.
        // Reject zero rather than putting a meaningless number on the wire.
        if let maxReassemblyFragments { guard maxReassemblyFragments > 0 else { return nil } }

        var writer = TLVWriter(lengthWidth: .oneByte, prefix: Data([Self.currentVersion]))
        writer.append(TLVType.capabilities.rawValue, capabilityBytes)
        writer.append(TLVType.signingPublicKey.rawValue, signingPublicKey)
        if let maxReassemblyFragments {
            writer.append(TLVType.maxReassemblyFragments.rawValue, bigEndian: maxReassemblyFragments)
        }
        return writer.data
    }

    static func decode(from data: Data) -> AuthenticatedPeerStatePacket? {
        guard data.first == Self.currentVersion else { return nil }

        // Optional ceiling TLVs are not fatal: a truncated or duplicate 0x03
        // must keep the authenticated identity and fall back to 256. The
        // shared TLVReader reports truncation without the type byte, so this
        // packet still walks the bytes itself.
        var offset = 1
        var capabilities: PeerCapabilities?
        var signingPublicKey: Data?
        var maxReassemblyFragments: UInt16?
        var sawReassemblyCeiling = false

        while offset < data.count {
            guard offset + 2 <= data.count else {
                if data[offset] == TLVType.maxReassemblyFragments.rawValue {
                    maxReassemblyFragments = malformedReassemblyFragmentCeiling
                    break
                }
                return nil
            }
            let typeRaw = data[offset]
            let length = Int(data[offset + 1])
            offset += 2
            guard offset + length <= data.count else {
                if typeRaw == TLVType.maxReassemblyFragments.rawValue {
                    maxReassemblyFragments = malformedReassemblyFragmentCeiling
                    break
                }
                return nil
            }
            let value = Data(data[offset..<(offset + length)])
            offset += length

            guard let type = TLVType(rawValue: typeRaw) else {
                continue
            }
            switch type {
            case .capabilities:
                guard capabilities == nil,
                      !value.isEmpty,
                      value.count <= 8 else { return nil }
                let decoded = PeerCapabilities(encoded: value)
                guard decoded.encoded() == value else { return nil }
                capabilities = decoded

            case .signingPublicKey:
                guard signingPublicKey == nil,
                      value.count == Self.signingPublicKeyLength else { return nil }
                signingPublicKey = value

            case .maxReassemblyFragments:
                // This optional extension must not discard the authenticated
                // capabilities and signing key. Ambiguous or unreadable limits
                // retain those fields and select the conservative 256 fallback.
                guard !sawReassemblyCeiling else {
                    maxReassemblyFragments = malformedReassemblyFragmentCeiling
                    continue
                }
                sawReassemblyCeiling = true
                guard value.count == Self.maxReassemblyFragmentsLength else {
                    maxReassemblyFragments = malformedReassemblyFragmentCeiling
                    continue
                }
                let decoded = value.readBigEndian(UInt16.self) ?? 0
                maxReassemblyFragments = decoded > 0 ? decoded : malformedReassemblyFragmentCeiling
            }
        }

        guard let capabilities, let signingPublicKey else { return nil }
        return AuthenticatedPeerStatePacket(
            capabilities: capabilities,
            signingPublicKey: signingPublicKey,
            maxReassemblyFragments: maxReassemblyFragments
        )
    }
}

struct PrivateMessagePacket {
    /// Content TLV length is one byte. Longer private messages cannot be encoded.
    static let maxContentUTF8Bytes = 255

    static func contentFitsOnWire(_ content: String) -> Bool {
        content.utf8.count <= maxContentUTF8Bytes
    }

    let messageID: String
    let content: String

    private enum TLVType: UInt8 {
        case messageID = 0x00
        case content = 0x01
    }

    func encode() -> Data? {
        guard let messageIDData = messageID.data(using: .utf8), messageIDData.count <= 255,
              let contentData = content.data(using: .utf8), contentData.count <= Self.maxContentUTF8Bytes else { return nil }
        var writer = TLVWriter(
            lengthWidth: .oneByte,
            capacity: 2 + messageIDData.count + 2 + contentData.count
        )
        writer.append(TLVType.messageID.rawValue, messageIDData)
        writer.append(TLVType.content.rawValue, contentData)
        return writer.data
    }

    static func decode(from data: Data) -> PrivateMessagePacket? {
        var reader = TLVReader(data, lengthWidth: .oneByte)
        var messageID: String?
        var content: String?

        loop: while true {
            switch reader.next(allowTrailingHeaderRemainder: true) {
            case .end:
                break loop
            case .malformed:
                return nil
            case .entry(let typeRaw, let value):
                guard let type = TLVType(rawValue: typeRaw) else { return nil }
                switch type {
                case .messageID:
                    messageID = String(data: value, encoding: .utf8)
                case .content:
                    content = String(data: value, encoding: .utf8)
                }
            }
        }

        guard let messageID, let content else { return nil }
        return PrivateMessagePacket(messageID: messageID, content: content)
    }
}
