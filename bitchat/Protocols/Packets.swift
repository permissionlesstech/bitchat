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

        // TLV for capabilities (optional)
        if let capabilities = capabilities {
            let capabilityBytes = capabilities.encoded()
            guard capabilityBytes.count <= 255 else { return nil }
            data.append(TLVType.capabilities.rawValue)
            data.append(UInt8(capabilityBytes.count))
            data.append(capabilityBytes)
        }

        // TLV for bridge rendezvous cell (optional; old clients skip it)
        if let bridgeGeohash = bridgeGeohash,
           let cellData = bridgeGeohash.data(using: .utf8),
           !cellData.isEmpty, cellData.count <= 12 {
            data.append(TLVType.bridgeGeohash.rawValue)
            data.append(UInt8(cellData.count))
            data.append(cellData)
        }

        return data
    }

    static func decode(from data: Data) -> AnnouncementPacket? {
        var offset = 0
        var nickname: String?
        var noisePublicKey: Data?
        var signingPublicKey: Data?
        var directNeighbors: [Data]?
        var capabilities: PeerCapabilities?
        var bridgeGeohash: String?

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
                case .capabilities:
                    capabilities = PeerCapabilities(encoded: Data(value))
                case .bridgeGeohash:
                    if length <= 12 {
                        bridgeGeohash = String(data: value, encoding: .utf8)
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
/// duplicates, non-canonical capability fields, and malformed lengths are
/// rejected without changing authenticated state.
struct AuthenticatedPeerStatePacket: Equatable {
    static let currentVersion: UInt8 = 1
    static let signingPublicKeyLength = 32
    static let maxReassemblyFragmentsLength = 2

    let capabilities: PeerCapabilities
    let signingPublicKey: Data
    /// How many BLE fragments this peer will reassemble for one packet, as it
    /// reported inside the established Noise session.
    ///
    /// The `.privateMedia` capability bit says a peer understands encrypted
    /// media; it says nothing about how much of it that peer can hold. Before
    /// this TLV existed, senders inferred the ceiling from the packet type —
    /// 256 for the directed migration fallback, the full local ceiling for
    /// anything encrypted — which is only correct while every client that
    /// implements `0x20` also has a large reassembler.
    ///
    /// `nil` means the peer did not advertise one, which is the case for every
    /// client released before this TLV. Senders fall back to the type proxy
    /// there; see `BLEFragmentCeilingPolicy`.
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
        // Omit the TLV instead of putting a meaningless number on the wire.
        if let maxReassemblyFragments { guard maxReassemblyFragments > 0 else { return nil } }

        var data = Data([Self.currentVersion])
        data.append(TLVType.capabilities.rawValue)
        data.append(UInt8(capabilityBytes.count))
        data.append(capabilityBytes)
        data.append(TLVType.signingPublicKey.rawValue)
        data.append(UInt8(signingPublicKey.count))
        data.append(signingPublicKey)
        if let maxReassemblyFragments {
            data.append(TLVType.maxReassemblyFragments.rawValue)
            data.append(UInt8(Self.maxReassemblyFragmentsLength))
            data.append(contentsOf: withUnsafeBytes(of: maxReassemblyFragments.bigEndian) { Data($0) })
        }
        return data
    }

    static func decode(from data: Data) -> AuthenticatedPeerStatePacket? {
        guard data.first == Self.currentVersion else { return nil }

        var offset = 1
        var capabilities: PeerCapabilities?
        var signingPublicKey: Data?
        var maxReassemblyFragments: UInt16?

        while offset < data.count {
            guard offset + 2 <= data.count else { return nil }
            let typeRaw = data[offset]
            let length = Int(data[offset + 1])
            offset += 2
            guard offset + length <= data.count else { return nil }
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
                // Rejected rather than skipped: a peer that meant to constrain
                // us but sent a field we cannot read must not be treated as
                // having said nothing, because "said nothing" falls back to
                // the permissive type proxy.
                guard maxReassemblyFragments == nil,
                      value.count == Self.maxReassemblyFragmentsLength else { return nil }
                let decoded = (UInt16(value[value.startIndex]) << 8)
                    | UInt16(value[value.startIndex + 1])
                guard decoded > 0 else { return nil }
                maxReassemblyFragments = decoded
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
