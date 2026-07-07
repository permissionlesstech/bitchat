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
        var out = Data()
        func putTLV(_ t: UInt8, _ v: Data) {
            out.append(t)
            let len = UInt16(v.count)
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
            out.append(v)
        }
        // P
        putTLV(0x01, Data([UInt8(p & 0xFF)]))
        // M (uint32)
        var mBE = m.bigEndian
        putTLV(0x02, withUnsafeBytes(of: &mBE) { Data($0) })
        // data
        putTLV(0x03, data)
        if let typesData = types?.toData() {
            putTLV(0x04, typesData)
        }
        if let ts = sinceTimestamp {
            var tsBE = ts.bigEndian
            putTLV(0x05, withUnsafeBytes(of: &tsBE) { Data($0) })
        }
        if let fid = fragmentIdFilter, let fidData = fid.data(using: .utf8) {
            putTLV(0x06, fidData)
        }
        return out
    }
    
    static func decode(from data: Data, maxAcceptBytes: Int = 1024) -> RequestSyncPacket? {
        var off = 0
        var p: Int? = nil
        var m: UInt32? = nil
        var payload: Data? = nil
        var types: SyncTypeFlags? = nil
        var sinceTimestamp: UInt64? = nil
        var fragmentIdFilter: String? = nil

        while off + 3 <= data.count {
            let t = Int(data[off]); off += 1
            guard off + 2 <= data.count else { return nil }
            let len = (Int(data[off]) << 8) | Int(data[off+1]); off += 2
            guard off + len <= data.count else { return nil }
            let v = data.subdata(in: off..<(off+len)); off += len
            switch t {
            case 0x01:
                if v.count == 1 { p = Int(v[0]) }
            case 0x02:
                if v.count == 4 {
                    var mm: UInt32 = 0
                    for b in v { mm = (mm << 8) | UInt32(b) }
                    m = mm
                }
            case 0x03:
                if v.count > maxAcceptBytes { return nil }
                payload = v
            case 0x04:
                if let decoded = SyncTypeFlags.decode(v) {
                    types = decoded
                }
            case 0x05:
                if v.count == 8 {
                    var ts: UInt64 = 0
                    for b in v { ts = (ts << 8) | UInt64(b) }
                    sinceTimestamp = ts
                }
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

        guard let pp = p, let mm = m, let dd = payload, pp >= 1, pp <= GCSFilter.maxP, mm > 0 else { return nil }
        return RequestSyncPacket(p: pp, m: mm, data: dd, types: types, sinceTimestamp: sinceTimestamp, fragmentIdFilter: fragmentIdFilter)
    }
}
