//
// BitchatAppVectorReplayTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

///
/// Replays the app-target kinds of the cross-platform wire-format vectors in
/// `bitchat-ios.json` against the real app codecs:
///
/// - `announce_tlv`, `announce_decode`   -> `AnnouncementPacket`         (bitchat/Protocols/Packets.swift)
/// - `peer_state_tlv`                     -> `AuthenticatedPeerStatePacket`
/// - `private_message_tlv`                -> `PrivateMessagePacket`
/// - `noise_payload`                      -> `NoisePayload` / `NoisePayloadType`
/// - `file_packet_tlv`                    -> `BitchatFilePacket`         (bitchat/Protocols/BitchatFilePacket.swift)
/// - `fragment_payload`                   -> `BLEOutboundFragmentPlanner` (bitchat/Services/BLE/)
///
/// The BitFoundation kinds (packet framing, padding, compression, peer id,
/// capabilities) are replayed by `BitchatVectorReplayTests` in
/// `localPackages/BitFoundation/Tests/BitFoundationTests/`.
///
/// Intended home: `bitchatTests/Protocols/BitchatAppVectorReplayTests.swift`
/// (XCTest, `@testable import bitchat`). The `#if canImport(bitchat)` guard
/// exists only so this file also compiles inside the BitFoundation package
/// test target when the app codec files are copied next to it (that is how it
/// was compile-checked and run while the vectors were produced; the app itself
/// was not built). In the app target the guard is simply true.
///
/// Vector file resolution, in order:
/// 1. `SONAR_VECTOR_FILE` environment variable (absolute path).
/// 2. A `bitchat-ios.json` file next to this source file.
/// 3. A `bitchat-ios.json` resource in the test bundle.
/// Otherwise every test is skipped via `XCTSkip`.
///
/// Hex encoding: lowercase hex strings; a run of one byte repeated >= 1024
/// times is written `repeat:xx*N` (byte in hex, count in decimal).
///

import Foundation
import XCTest
import BitFoundation
#if canImport(bitchat)
@testable import bitchat
#endif

// MARK: - Vector file model

private indirect enum JV: Decodable {
    case null
    case bool(Bool)
    case uint(UInt64)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JV])
    case object([String: JV])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(UInt64.self) { self = .uint(v); return }
        if let v = try? c.decode(Int64.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JV].self) { self = .array(v); return }
        self = .object(try c.decode([String: JV].self))
    }

    subscript(_ key: String) -> JV {
        if case .object(let o) = self, let v = o[key] { return v }
        return .null
    }
    func has(_ key: String) -> Bool { if case .object(let o) = self { return o[key] != nil }; return false }
    var isNull: Bool { if case .null = self { return true }; return false }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var u64: UInt64? {
        switch self {
        case .uint(let v): return v
        case .int(let v): return v >= 0 ? UInt64(v) : nil
        case .double(let v): return v >= 0 ? UInt64(v) : nil
        default: return nil
        }
    }
    var int: Int? { u64.flatMap { Int(exactly: $0) } }
    var array: [JV]? { if case .array(let a) = self { return a }; return nil }
    var hex: Data? {
        guard let s = string else { return nil }
        if s.hasPrefix("repeat:") {
            let parts = s.dropFirst("repeat:".count).split(separator: "*", maxSplits: 1)
            guard parts.count == 2, let byte = UInt8(parts[0], radix: 16), let count = Int(parts[1]) else { return nil }
            return Data(repeating: byte, count: count)
        }
        if s.isEmpty { return Data() }
        return Data(hexString: s)
    }
    var hexList: [Data]? { array?.compactMap { $0.hex } }
}

private struct VectorCase {
    let name: String
    let kind: String
    let input: JV
    let expected: JV
}

private enum VectorFile {
    static let resolvedPath: String? = {
        let env = ProcessInfo.processInfo.environment["SONAR_VECTOR_FILE"]
        if let env, !env.isEmpty, FileManager.default.fileExists(atPath: env) { return env }
        let sibling = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("bitchat-ios.json").path
        if FileManager.default.fileExists(atPath: sibling) { return sibling }
        if let bundled = Bundle(for: BitchatAppVectorReplayTests.self).url(forResource: "bitchat-ios", withExtension: "json") {
            return bundled.path
        }
        return nil
    }()

    static let cases: [VectorCase]? = {
        guard let path = resolvedPath, let data = FileManager.default.contents(atPath: path),
              let root = try? JSONDecoder().decode(JV.self, from: data), let list = root["cases"].array else { return nil }
        return list.map {
            VectorCase(name: $0["name"].string ?? "?", kind: $0["kind"].string ?? "?", input: $0["input"], expected: $0["expected"])
        }
    }()

    static func cases(_ kind: String) throws -> [VectorCase] {
        guard let path = resolvedPath else {
            throw XCTSkip("No vector file: set SONAR_VECTOR_FILE=/path/to/bitchat-ios.json or place bitchat-ios.json next to BitchatAppVectorReplayTests.swift")
        }
        let all = try XCTUnwrap(cases, "vector file at \(path) could not be parsed")
        let list = all.filter { $0.kind == kind }
        print("REPLAY kind=\(kind) cases=\(list.count) file=\(path)")
        return list
    }
}

private func capsValue(_ v: JV) -> PeerCapabilities? {
    v.u64.map { PeerCapabilities(rawValue: $0) }
}

// MARK: - Tests

final class BitchatAppVectorReplayTests: XCTestCase {

    // MARK: announce

    func testAnnounceTLVEncode() throws {
        for c in try VectorFile.cases("announce_tlv") {
            let i = c.input
            let packet = AnnouncementPacket(
                nickname: try XCTUnwrap(i["nickname"].string, c.name),
                noisePublicKey: try XCTUnwrap(i["noise_public_key"].hex, c.name),
                signingPublicKey: try XCTUnwrap(i["signing_public_key"].hex, c.name),
                directNeighbors: i["direct_neighbors"].hexList,
                capabilities: capsValue(i["capabilities"]),
                bridgeGeohash: i["bridge_geohash"].string
            )
            let encoded = packet.encode()
            XCTAssertEqual(encoded, c.expected["encoded"].hex, "\(c.name): encoded bytes")
            guard let encoded, c.expected.has("roundtrip") else { continue }
            let rt = c.expected["roundtrip"]
            let decoded = try XCTUnwrap(AnnouncementPacket.decode(from: encoded), "\(c.name): must decode its own encoding")
            assertAnnounce(decoded, matches: rt, c.name)
        }
    }

    func testAnnounceTLVDecode() throws {
        for c in try VectorFile.cases("announce_decode") {
            let bytes = try XCTUnwrap(c.input["bytes"].hex, c.name)
            let decoded = AnnouncementPacket.decode(from: bytes)
            let expectDecodes = c.expected["decodes"].bool ?? true
            XCTAssertEqual(decoded != nil, expectDecodes, "\(c.name): decodes")
            if let decoded, expectDecodes { assertAnnounce(decoded, matches: c.expected, c.name) }
        }
    }

    private func assertAnnounce(_ a: AnnouncementPacket, matches e: JV, _ name: String) {
        XCTAssertEqual(a.nickname, e["nickname"].string, "\(name): nickname")
        XCTAssertEqual(a.noisePublicKey, e["noise_public_key"].hex, "\(name): noise key")
        XCTAssertEqual(a.signingPublicKey, e["signing_public_key"].hex, "\(name): signing key")
        XCTAssertEqual(a.directNeighbors, e["direct_neighbors"].hexList, "\(name): neighbors")
        XCTAssertEqual(a.capabilities?.rawValue, e["capabilities"].u64, "\(name): capabilities")
        XCTAssertEqual(a.bridgeGeohash, e["bridge_geohash"].string, "\(name): bridge geohash")
    }

    // MARK: authenticated peer state

    func testAuthenticatedPeerStateTLV() throws {
        for c in try VectorFile.cases("peer_state_tlv") {
            if let bytes = c.input["bytes"].hex {
                let decoded = AuthenticatedPeerStatePacket.decode(from: bytes)
                let expectDecodes = c.expected["decodes"].bool ?? true
                XCTAssertEqual(decoded != nil, expectDecodes, "\(c.name): decodes")
                if let decoded, expectDecodes {
                    XCTAssertEqual(decoded.capabilities.rawValue, c.expected["capabilities"].u64, "\(c.name): capabilities")
                    XCTAssertEqual(decoded.signingPublicKey, c.expected["signing_public_key"].hex, "\(c.name): signing key")
                }
            } else {
                let packet = AuthenticatedPeerStatePacket(
                    capabilities: PeerCapabilities(rawValue: try XCTUnwrap(c.input["capabilities"].u64, c.name)),
                    signingPublicKey: try XCTUnwrap(c.input["signing_public_key"].hex, c.name)
                )
                XCTAssertEqual(packet.encode(), c.expected["encoded"].hex, "\(c.name): encoded bytes")
            }
        }
    }

    // MARK: private message

    func testPrivateMessageTLV() throws {
        for c in try VectorFile.cases("private_message_tlv") {
            if let bytes = c.input["bytes"].hex {
                let decoded = PrivateMessagePacket.decode(from: bytes)
                let expectDecodes = c.expected["decodes"].bool ?? true
                XCTAssertEqual(decoded != nil, expectDecodes, "\(c.name): decodes")
                if let decoded, expectDecodes {
                    XCTAssertEqual(decoded.messageID, c.expected["message_id"].string, "\(c.name): message id")
                    XCTAssertEqual(decoded.content, c.expected["content"].string, "\(c.name): content")
                }
            } else {
                let packet = PrivateMessagePacket(
                    messageID: try XCTUnwrap(c.input["message_id"].string, c.name),
                    content: try XCTUnwrap(c.input["content"].string, c.name)
                )
                let encoded = packet.encode()
                XCTAssertEqual(encoded, c.expected["encoded"].hex, "\(c.name): encoded bytes")
                if let encoded, c.expected.has("roundtrip") {
                    let rt = c.expected["roundtrip"]
                    let decoded = try XCTUnwrap(PrivateMessagePacket.decode(from: encoded), "\(c.name): must decode its own encoding")
                    XCTAssertEqual(decoded.messageID, rt["message_id"].string, "\(c.name): rt message id")
                    XCTAssertEqual(decoded.content, rt["content"].string, "\(c.name): rt content")
                }
            }
        }
    }

    // MARK: noise payload

    func testNoisePayload() throws {
        for c in try VectorFile.cases("noise_payload") {
            if let bytes = c.input["bytes"].hex {
                let decoded = NoisePayload.decode(bytes)
                let expectDecodes = c.expected["decodes"].bool ?? true
                XCTAssertEqual(decoded != nil, expectDecodes, "\(c.name): decodes")
                if let decoded, expectDecodes {
                    XCTAssertEqual(Int(decoded.type.rawValue), c.expected["type"].int, "\(c.name): canonical type")
                    XCTAssertEqual(decoded.data, c.expected["data"].hex, "\(c.name): data")
                }
            } else {
                let raw = UInt8(try XCTUnwrap(c.input["type"].int, c.name))
                let type = try XCTUnwrap(NoisePayloadType(rawValue: raw), "\(c.name): unknown NoisePayloadType \(raw)")
                let data = try XCTUnwrap(c.input["data"].hex, c.name)
                XCTAssertEqual(NoisePayload(type: type, data: data).encode(), c.expected["encoded"].hex, "\(c.name): encoded bytes")
            }
        }
    }

    // MARK: file packet

    func testFilePacketTLV() throws {
        for c in try VectorFile.cases("file_packet_tlv") {
            if let bytes = c.input["bytes"].hex {
                let decoded = BitchatFilePacket.decode(bytes)
                let expectDecodes = c.expected["decodes"].bool ?? true
                XCTAssertEqual(decoded != nil, expectDecodes, "\(c.name): decodes")
                if let decoded, expectDecodes { assertFile(decoded, matches: c.expected, c.name) }
            } else {
                let packet = BitchatFilePacket(
                    fileName: c.input["file_name"].string,
                    fileSize: c.input["file_size"].u64,
                    mimeType: c.input["mime_type"].string,
                    content: try XCTUnwrap(c.input["content"].hex, c.name)
                )
                let encoded = packet.encode()
                XCTAssertEqual(encoded, c.expected["encoded"].hex, "\(c.name): encoded bytes")
                guard let encoded, c.expected.has("roundtrip") else { continue }
                let rt = c.expected["roundtrip"]
                let decoded = BitchatFilePacket.decode(encoded)
                if rt.isNull {
                    XCTAssertNil(decoded, "\(c.name): upstream rejects its own encoding here (empty content)")
                } else {
                    let d = try XCTUnwrap(decoded, "\(c.name): must decode its own encoding")
                    assertFile(d, matches: rt, c.name)
                }
            }
        }
    }

    private func assertFile(_ f: BitchatFilePacket, matches e: JV, _ name: String) {
        XCTAssertEqual(f.fileName, e["file_name"].string, "\(name): file name")
        XCTAssertEqual(f.fileSize, e["file_size"].u64, "\(name): file size")
        XCTAssertEqual(f.mimeType, e["mime_type"].string, "\(name): mime type")
        XCTAssertEqual(f.content, e["content"].hex, "\(name): content")
    }

    // MARK: fragments

    func testFragmentPayload() throws {
        for c in try VectorFile.cases("fragment_payload") {
            let i = c.input
            let p = i["packet"]
            let packet = BitchatPacket(
                type: UInt8(try XCTUnwrap(p["type"].int, c.name)),
                senderID: try XCTUnwrap(p["sender_id"].hex, c.name),
                recipientID: p["recipient_id"].hex,
                timestamp: try XCTUnwrap(p["timestamp"].u64, c.name),
                payload: try XCTUnwrap(p["payload"].hex, c.name),
                signature: p["signature"].hex,
                ttl: UInt8(try XCTUnwrap(p["ttl"].int, c.name)),
                version: UInt8(try XCTUnwrap(p["version"].int, c.name)),
                route: p["route"].hexList,
                isRSR: p["is_rsr"].bool ?? false
            )
            let pad = try XCTUnwrap(i["pad"].bool, c.name)
            let request = BLEOutboundFragmentTransferRequest(
                packet: packet,
                pad: pad,
                maxChunk: i["max_chunk"].int,
                directedPeer: i["directed_peer"].string.map { PeerID(str: $0) },
                transferId: nil
            )
            let plan = try XCTUnwrap(BLEOutboundFragmentPlanner.makePlan(
                for: request,
                defaultChunkSize: try XCTUnwrap(i["default_chunk_size"].int, c.name),
                bleMaxMTU: try XCTUnwrap(i["ble_max_mtu"].int, c.name),
                fragmentID: try XCTUnwrap(i["fragment_id"].hex, c.name)
            ), "\(c.name): plan")

            XCTAssertEqual(packet.toBinaryData(padding: pad), c.expected["full_data"].hex, "\(c.name): full frame")
            XCTAssertEqual(plan.chunkSize, c.expected["chunk_size"].int, "\(c.name): chunk size")
            XCTAssertEqual(Int(plan.fragmentVersion), c.expected["fragment_version"].int, "\(c.name): fragment version")
            XCTAssertEqual(plan.totalFragments, c.expected["total_fragments"].int, "\(c.name): total")
            let expectedFragments = try XCTUnwrap(c.expected["fragments"].array, c.name)
            XCTAssertEqual(plan.fragmentPackets.count, expectedFragments.count, "\(c.name): fragment count")
            for (idx, (f, e)) in zip(plan.fragmentPackets, expectedFragments).enumerated() {
                let n = "\(c.name)[\(idx)]"
                XCTAssertEqual(f.payload, e["payload"].hex, "\(n): payload")
                XCTAssertEqual(Int(f.version), e["version"].int, "\(n): version")
                XCTAssertEqual(Int(f.type), e["type"].int, "\(n): type")
                XCTAssertEqual(Int(f.ttl), e["ttl"].int, "\(n): ttl")
                XCTAssertEqual(f.timestamp, e["timestamp"].u64, "\(n): timestamp")
                XCTAssertEqual(f.recipientID, e["recipient_id"].hex, "\(n): recipient")
                XCTAssertEqual(f.route, e["route"].hexList, "\(n): route")
                XCTAssertEqual(f.toBinaryData(padding: false), e["encoded_unpadded"].hex, "\(n): encoded unpadded")
                XCTAssertEqual(f.toBinaryData(padding: true), e["encoded_padded"].hex, "\(n): encoded padded")
            }
        }
    }
}
