//
// PeerID.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

struct PeerID: Equatable, Hashable {
    enum Prefix: String, CaseIterable {
        /// When no prefix is provided
        case empty = ""
        /// `"mesh:"`
        case mesh = "mesh:"
        /// `"name:"`
        case name = "name:"
        /// `"noise:"` (+ 64 characters hex)
        case noise = "noise:"
        /// `"nostr_"` (+ 16 characters hex)
        case geoDM = "nostr_"
        /// `"nostr:"` (+ 8 characters hex)
        case geoChat = "nostr:"
    }
    
    let prefix: Prefix
    
    /// Returns the actual value without any prefix
    let bare: String
    
    /// Returns the full `id` value by combining `(prefix + bare)`
    var id: String { prefix.rawValue + bare }
    
    // Private so the callers have to go through a convenience init
    private init(prefix: Prefix, bare: any StringProtocol) {
        self.prefix = prefix
        self.bare = String(bare).lowercased()
    }
}

// MARK: - Convenience Inits

extension PeerID {
    /// Convenience init to create GeoDM PeerID by appending `"nostr_"` to the first 16 characters of `pubKey`
    init(nostr_ pubKey: String) {
        self.init(prefix: .geoDM, bare: pubKey.prefix(TransportConfig.nostrConvKeyPrefixLength))
    }
    
    /// Convenience init to create GeoChat PeerID by appending `"nostr:"` to the first 8 characters of `pubKey`
    init(nostr pubKey: String) {
        self.init(prefix: .geoChat, bare: pubKey.prefix(TransportConfig.nostrShortKeyDisplayLength))
    }
    
    /// Convenience init to create PeerID from String/Substring by splitting it into prefix and bare parts
    init(str: any StringProtocol) {
        if let prefix = Prefix.allCases.first(where: { $0 != .empty && str.hasPrefix($0.rawValue) }) {
            self.init(prefix: prefix, bare: String(str).dropFirst(prefix.rawValue.count))
        } else {
            self.init(prefix: .empty, bare: str)
        }
    }
    
    /// Convenience init to handle `Optional<String>`
    init?(str: (any StringProtocol)?) {
        guard let str else { return nil }
        self.init(str: str)
    }
    
    /// Convenience init to create PeerID by converting Data to String
    init?(data: Data) {
        self.init(str: String(data: data, encoding: .utf8))
    }
    
    /// Convenience init to "hide" hex-encoding implementation detail
    init(hexData: Data) {
        self.init(str: hexData.hexEncodedString())
    }
    
    /// Convenience init to "hide" hex-encoding implementation detail
    init?(hexData: Data?) {
        guard let hexData else { return nil }
        self.init(hexData: hexData)
    }
}

// MARK: - Noise Public Key Helpers

extension PeerID {
    /// Derive the stable 16-hex peer ID from a Noise static public key
    init(publicKey: Data) {
        self.init(str: publicKey.sha256Fingerprint().prefix(16))
    }
    
    /// Returns a 16-hex short peer ID derived from a 64-hex Noise public key if needed
    func toShort() -> PeerID {
        if let noiseKey {
            return PeerID(publicKey: noiseKey)
        }
        return self
    }
}

// MARK: - Codable

extension PeerID: Codable {
    init(from decoder: any Decoder) throws {
        self.init(str: try decoder.singleValueContainer().decode(String.self))
    }
    
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

// MARK: - Helpers

extension PeerID {
    var isEmpty: Bool {
        id.isEmpty
    }
    
    /// Returns true if `id` starts with "`nostr:`"
    var isGeoChat: Bool {
        prefix == .geoChat
    }
    
    /// Returns true if `id` starts with "`nostr_`"
    var isGeoDM: Bool {
        prefix == .geoDM
    }
    
    func toPercentEncoded() -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    }
}

extension PeerID {
    var routingData: Data? {
        if let direct = Data(hexString: id), direct.count == 8 { return direct }
        if let bareData = Data(hexString: bare), bareData.count == 8 { return bareData }
        let short = toShort()
        return Data(hexString: short.id)
    }

    init?(routingData: Data) {
        guard routingData.count == 8 else { return nil }
        self.init(hexData: routingData)
    }
}

// MARK: - Validation

extension PeerID {
    private enum Constants {
        static let maxIDLength = 64
        static let hexIDLength = 16 // 8 bytes = 16 hex chars
    }
    
    /// Validates a peer ID from any source (short 16-hex, full 64-hex, or internal alnum/-/_ up to 64)
    var isValid: Bool {
        if prefix != .empty {
            return PeerID(str: bare).isValid
        }
        
        // Accept short routing IDs (exact 16-hex) or Full Noise key hex (exact 64-hex)
        if isShort || isNoiseKeyHex {
            return true
        }
        
        // If length equals short or full but isn't valid hex, reject
        if id.count == Constants.hexIDLength || id.count == Constants.maxIDLength {
            return false
        }
        
        // Internal format: alphanumeric + dash/underscore up to 63 (not 16 or 64)
        let validCharset = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !id.isEmpty &&
                id.count < Constants.maxIDLength &&
                id.rangeOfCharacter(from: validCharset.inverted) == nil
    }
    
    /// Returns true if the `bare` id is all hex
    var isHex: Bool {
        bare.allSatisfy { $0.isHexDigit }
    }
    
    /// Short routing IDs (exact 16-hex)
    var isShort: Bool {
        bare.count == Constants.hexIDLength && isHex
    }
    
    /// Full Noise key hex (exact 64-hex)
    var isNoiseKeyHex: Bool {
        noiseKey != nil
    }
    
    /// Full Noise key (exact 64-hex) as Data
    var noiseKey: Data? {
        guard bare.count == Constants.maxIDLength else { return nil }
        return Data(hexString: bare)
    }
}

// MARK: - Comparable

extension PeerID: Comparable {
    static func < (lhs: PeerID, rhs: PeerID) -> Bool {
        lhs.id < rhs.id
    }
}

// MARK: - CustomStringConvertible

extension PeerID: CustomStringConvertible {
    /// So it returns the actual `id` like before even inside another String
    var description: String {
        id
    }
}
