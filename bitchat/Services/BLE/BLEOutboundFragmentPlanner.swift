import BitFoundation
import Foundation

struct BLEOutboundFragmentPlan {
    let fragmentPackets: [BitchatPacket]
    let fragmentVersion: UInt8
    let chunkSize: Int
    let spacingMs: Int

    var totalFragments: Int {
        fragmentPackets.count
    }

    var shouldPauseScanning: Bool {
        totalFragments > 4
    }
}

enum BLEOutboundFragmentPlanner {
    private static let minimumChunkSize = 64
    private static let fragmentIDLength = 8

    static func makePlan(
        for request: BLEOutboundFragmentTransferRequest,
        defaultChunkSize: Int,
        bleMaxMTU: Int,
        fragmentID: Data = randomFragmentID()
    ) -> BLEOutboundFragmentPlan? {
        guard fragmentID.count == fragmentIDLength,
              let fullData = request.packet.toBinaryData(padding: request.pad) else {
            return nil
        }

        let sizing = sizingPolicy(
            for: request.packet,
            requestedMaxChunk: request.maxChunk,
            defaultChunkSize: defaultChunkSize,
            bleMaxMTU: bleMaxMTU
        )

        let chunks = stride(from: 0, to: fullData.count, by: sizing.chunkSize).map { offset in
            Data(fullData[offset..<min(offset + sizing.chunkSize, fullData.count)])
        }

        guard !chunks.isEmpty else { return nil }

        let fragmentRecipient: Data? = {
            if let directedPeer = request.directedPeer {
                return Data(hexString: directedPeer.id)
            }
            return request.packet.recipientID
        }()

        let fragmentPackets = chunks.enumerated().map { index, chunk in
            makeFragmentPacket(
                original: request.packet,
                fragmentID: fragmentID,
                index: index,
                total: chunks.count,
                fragmentData: chunk,
                fragmentRecipient: fragmentRecipient,
                fragmentVersion: sizing.fragmentVersion
            )
        }

        return BLEOutboundFragmentPlan(
            fragmentPackets: fragmentPackets,
            fragmentVersion: sizing.fragmentVersion,
            chunkSize: sizing.chunkSize,
            spacingMs: spacingMs(for: request)
        )
    }

    private static func sizingPolicy(
        for packet: BitchatPacket,
        requestedMaxChunk: Int?,
        defaultChunkSize: Int,
        bleMaxMTU: Int
    ) -> (fragmentVersion: UInt8, chunkSize: Int) {
        var fragmentVersion: UInt8 = 1
        var calculatedChunk = defaultChunkSize

        if let route = packet.route, !route.isEmpty {
            fragmentVersion = 2
            let routeSize = 1 + (route.count * 8)
            let overhead = 16 + 8 + 8 + routeSize + 13 + 16
            calculatedChunk = max(minimumChunkSize, bleMaxMTU - overhead)
        }

        return (
            fragmentVersion: fragmentVersion,
            chunkSize: max(minimumChunkSize, requestedMaxChunk ?? calculatedChunk)
        )
    }

    private static func makeFragmentPacket(
        original packet: BitchatPacket,
        fragmentID: Data,
        index: Int,
        total: Int,
        fragmentData: Data,
        fragmentRecipient: Data?,
        fragmentVersion: UInt8
    ) -> BitchatPacket {
        var payload = Data()
        payload.append(fragmentID)
        payload.append(contentsOf: withUnsafeBytes(of: UInt16(index).bigEndian) { Data($0) })
        payload.append(contentsOf: withUnsafeBytes(of: UInt16(total).bigEndian) { Data($0) })
        payload.append(packet.type)
        payload.append(fragmentData)

        return BitchatPacket(
            type: MessageType.fragment.rawValue,
            senderID: packet.senderID,
            recipientID: fragmentRecipient,
            timestamp: packet.timestamp,
            payload: payload,
            signature: nil,
            ttl: packet.ttl,
            version: fragmentVersion,
            route: packet.route,
            isRSR: packet.isRSR
        )
    }

    private static func spacingMs(for request: BLEOutboundFragmentTransferRequest) -> Int {
        if request.directedPeer != nil || request.packet.recipientID != nil {
            return TransportConfig.bleFragmentSpacingDirectedMs
        }

        return TransportConfig.bleFragmentSpacingMs
    }

    private static func randomFragmentID() -> Data {
        Data((0..<fragmentIDLength).map { _ in UInt8.random(in: 0...255) })
    }
}
