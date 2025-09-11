import Foundation

// REQUEST_SYNC payload TLV (type, length16, value)
//  - 0x01: mBytes (uint16)
//  - 0x02: k (uint8)
//  - 0x03: bloom filter bits (opaque byte array of length mBytes)
struct RequestSyncPacket {
    let mBytes: Int
    let k: Int
    let bits: Data

    func encode() -> Data {
        var out = Data()
        func putTLV(_ t: UInt8, _ v: Data) {
            out.append(t)
            let len = UInt16(v.count)
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
            out.append(v)
        }
        // mBytes
        let mbBE = UInt16(mBytes).bigEndian
        let mbData = withUnsafeBytes(of: mbBE) { Data($0) }
        putTLV(0x01, mbData)
        // k
        putTLV(0x02, Data([UInt8(k & 0xFF)]))
        // bits
        putTLV(0x03, bits)
        return out
    }

    static func decode(from data: Data) -> RequestSyncPacket? {
        var off = 0
        var mBytes: Int? = nil
        var k: Int? = nil
        var bits: Data? = nil

        while off + 3 <= data.count {
            let t = Int(data[off]); off += 1
            guard off + 2 <= data.count else { return nil }
            let len = (Int(data[off]) << 8) | Int(data[off+1]); off += 2
            guard off + len <= data.count else { return nil }
            let v = data.subdata(in: off..<(off+len)); off += len
            switch t {
            case 0x01:
                if v.count == 2 {
                    let mb = (Int(v[0]) << 8) | Int(v[1])
                    mBytes = mb
                }
            case 0x02:
                if v.count == 1 { k = Int(v[0]) }
            case 0x03:
                bits = v
            default:
                break // forward compatible; ignore unknown TLVs
            }
        }

        guard let mb = mBytes, let kk = k, let bb = bits, mb == bb.count else { return nil }
        return RequestSyncPacket(mBytes: mb, k: kk, bits: bb)
    }
}
