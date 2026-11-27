import BitFoundation
import Foundation

// REQUEST_SYNC payload TLV (type, length16, value)
//  - 0x01: P (uint8) — Golomb-Rice parameter
//  - 0x02: M (uint32, big-endian) — hash range (N * 2^P)
//  - 0x03: data (opaque) — GR bitstream bytes (MSB-first)
//  - 0x04: types (SyncTypeFlags) — packet types the filter covers
//  - 0x05: sinceTimestamp (uint64, big-endian) — filter coverage cursor
//  - 0x06: fragmentIdFilter (UTF-8) — comma-separated 16-hex-char (8-byte)
//          fragment stream IDs; restricts the fragment diff to exactly those
//          streams (targeted resync for stalled reassemblies)
struct RequestSyncPacket {
    /// Maximum fragment IDs one 0x06 filter may carry. Each ID encodes as
    /// 16 hex chars plus a comma separator, so the largest encoded value is
    /// 60 * 17 - 1 = 1019 bytes, which fits the 1024-byte decoder cap.
    static let maxFragmentIdFilterCount = 60

    let p: Int
    let m: UInt32
    let data: Data
    let types: SyncTypeFlags?
    let sinceTimestamp: UInt64?
    let fragmentIdFilter: String?

    /// Encodes 8-byte fragment stream IDs as the 0x06 filter string,
    /// dropping malformed IDs and capping at `maxFragmentIdFilterCount`.
    static func encodeFragmentIdFilter(_ fragmentIDs: [Data]) -> String? {
        let tokens = fragmentIDs
            .filter { $0.count == 8 }
            .prefix(maxFragmentIdFilterCount)
            .map { $0.hexEncodedString() }
        guard !tokens.isEmpty else { return nil }
        return tokens.joined(separator: ",")
    }

    /// Decodes a 0x06 filter string back into 8-byte fragment stream IDs,
    /// ignoring malformed tokens and capping at `maxFragmentIdFilterCount`.
    static func decodeFragmentIdFilter(_ filter: String?) -> Set<Data>? {
        guard let filter else { return nil }
        var ids: Set<Data> = []
        for token in filter.split(separator: ",").prefix(maxFragmentIdFilterCount) {
            guard token.count == 16, let id = Data(hexString: String(token)) else { continue }
            ids.insert(id)
        }
        return ids.isEmpty ? nil : ids
    }

    init(p: Int, m: UInt32, data: Data, types: SyncTypeFlags? = nil, sinceTimestamp: UInt64? = nil, fragmentIdFilter: String? = nil) {
        self.p = p
        self.m = m
        self.data = data
        self.types = types
        self.sinceTimestamp = sinceTimestamp
        self.fragmentIdFilter = fragmentIdFilter
    }

    func encode() -> Data {
        var writer = TLVWriter(lengthWidth: .twoBytes)
        writer.append(0x01, byte: UInt8(p & 0xFF))
        writer.append(0x02, bigEndian: m)
        writer.append(0x03, data)
        if let typesData = types?.toData() {
            writer.append(0x04, typesData)
        }
        if let ts = sinceTimestamp {
            writer.append(0x05, bigEndian: ts)
        }
        if let fid = fragmentIdFilter, let fidData = fid.data(using: .utf8) {
            writer.append(0x06, fidData)
        }
        return writer.data
    }
    
    static func decode(from data: Data, maxAcceptBytes: Int = 1024) -> RequestSyncPacket? {
        var reader = TLVReader(data, lengthWidth: .twoBytes)
        var p: Int? = nil
        var m: UInt32? = nil
        var payload: Data? = nil
        var types: SyncTypeFlags? = nil
        var sinceTimestamp: UInt64? = nil
        var fragmentIdFilter: String? = nil

        loop: while true {
            switch reader.next(allowTrailingHeaderRemainder: true) {
            case .end:
                break loop
            case .malformed:
                return nil
            case .entry(let t, let v):
                switch t {
                case 0x01:
                    if v.count == 1 { p = Int(v[v.startIndex]) }
                case 0x02:
                    if let parsed: UInt32 = v.readBigEndian() { m = parsed }
                case 0x03:
                    if v.count > maxAcceptBytes { return nil }
                    payload = Data(v)
                case 0x04:
                    if let decoded = SyncTypeFlags.decode(Data(v)) {
                        types = decoded
                    }
                case 0x05:
                    if let parsed: UInt64 = v.readBigEndian() { sinceTimestamp = parsed }
                case 0x06:
                    // Same acceptance cap as the GCS payload; an oversized filter
                    // is ignored rather than failing the whole request.
                    if v.count <= maxAcceptBytes, let fid = String(data: v, encoding: .utf8) {
                        fragmentIdFilter = fid
                    }
                default:
                    break // forward compatible; ignore unknown TLVs
                }
            }
        }

        guard let pp = p, let mm = m, let dd = payload, pp >= 1, pp <= GCSFilter.maxP, mm > 0 else { return nil }
        return RequestSyncPacket(p: pp, m: mm, data: dd, types: types, sinceTimestamp: sinceTimestamp, fragmentIdFilter: fragmentIdFilter)
    }
}
