import Foundation

// REQUEST_SYNC payload TLV (type, length16, value)
//  - 0x01: P (uint8) — Golomb-Rice parameter
//  - 0x02: M (uint32, big-endian) — hash range (N * 2^P)
//  - 0x03: data (opaque) — GR bitstream bytes (MSB-first)
struct RequestSyncPacket {
    let p: Int
    let m: UInt32
    let data: Data
    let types: SyncTypeFlags?

    init(p: Int, m: UInt32, data: Data, types: SyncTypeFlags? = nil) {
        self.p = p
        self.m = m
        self.data = data
        self.types = types
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
        return out
    }

    static func decode(from data: Data, maxAcceptBytes: Int = 1024) -> RequestSyncPacket? {
        var off = 0
        var p: Int? = nil
        var m: UInt32? = nil
        var payload: Data? = nil
        var types: SyncTypeFlags? = nil

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
            default:
                break // forward compatible; ignore unknown TLVs
            }
        }

        guard let pp = p, let mm = m, let dd = payload, pp >= 1, mm > 0 else { return nil }
        return RequestSyncPacket(p: pp, m: mm, data: dd, types: types)
    }
}
