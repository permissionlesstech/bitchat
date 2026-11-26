import struct BitFoundation.BitchatPacket
import Foundation
import CryptoKit

// Deterministic packet ID used for gossip sync membership
// ID = first 16 bytes of SHA-256 over: [type | senderID | timestamp | payload]
enum PacketIdUtil {
    static func computeId(_ packet: BitchatPacket) -> Data {
        var hasher = SHA256()
        var typeByte = packet.type
        withUnsafeBytes(of: &typeByte) { hasher.update(bufferPointer: $0) }
        hasher.update(data: packet.senderID)
        var tsBE = packet.timestamp.bigEndian
        withUnsafeBytes(of: &tsBE) { hasher.update(bufferPointer: $0) }
        hasher.update(data: packet.payload)
        let digest = hasher.finalize()
        return digest.withUnsafeBytes { raw in
            Data(bytes: raw.baseAddress!, count: 16)
        }
    }
}
