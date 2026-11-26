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
    /// Current Android receivers reject fragment sets above 256. Private
    /// media v1 treats that deployed ceiling as a cross-platform contract.
    static let privateMediaV1MaxFragments = 256
    /// Matches `BLEFragmentHeader.maxSupportedFragments` (`10_000`) and stays
    /// well below the 16-bit wire fragment-count limit so tiny routed chunks
    /// can never allocate unbounded trains or trap on `UInt16(total)`.
    static let maxSupportedFragments = BLEFragmentHeader.maxSupportedFragments
    private static let minimumChunkSize = 64
    private static let fragmentIDLength = 8

    static func fragmentCount(forDataCount dataCount: Int, chunkSize: Int) -> Int {
        guard dataCount > 0, chunkSize > 0 else { return 0 }
        return (dataCount + chunkSize - 1) / chunkSize
    }

    static func makePlan(
        for request: BLEOutboundFragmentTransferRequest,
        defaultChunkSize: Int,
        bleMaxMTU: Int,
        fragmentID: Data = randomFragmentID()
    ) -> BLEOutboundFragmentPlan? {
        guard fragmentID.count == fragmentIDLength,
              let fullData = request.packet.toBinaryData(padding: request.pad),
              !fullData.isEmpty else {
            return nil
        }

        guard let sizing = sizingPolicy(
            for: request.packet,
            requestedMaxChunk: request.maxChunk,
            defaultChunkSize: defaultChunkSize,
            bleMaxMTU: bleMaxMTU
        ) else {
            return nil
        }

        let totalFragments = fragmentCount(forDataCount: fullData.count, chunkSize: sizing.chunkSize)
        guard totalFragments > 0, totalFragments <= maxSupportedFragments else {
            return nil
        }

        let chunks = stride(from: 0, to: fullData.count, by: sizing.chunkSize).map { offset in
            Data(fullData[offset..<min(offset + sizing.chunkSize, fullData.count)])
        }

        guard !chunks.isEmpty else { return nil }

        let fragmentRecipient: Data? = {
            // Source-routed packets must preserve their final destination
            // recipientID on every fragment so intermediate hops forward
            // along `route` instead of terminating reassembly locally.
            if let route = request.packet.route, !route.isEmpty,
               let originalRecipient = request.packet.recipientID {
                return originalRecipient
            }
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

    static func isPrivateMediaV1Compatible(_ plan: BLEOutboundFragmentPlan) -> Bool {
        plan.totalFragments <= privateMediaV1MaxFragments
    }

    private static func sizingPolicy(
        for packet: BitchatPacket,
        requestedMaxChunk: Int?,
        defaultChunkSize: Int,
        bleMaxMTU: Int
    ) -> (fragmentVersion: UInt8, chunkSize: Int)? {
        var fragmentVersion: UInt8 = 1
        var calculatedChunk = defaultChunkSize

        if let route = packet.route, !route.isEmpty {
            fragmentVersion = 2
            let overhead = BLEOutboundPacketPolicy.routedFragmentFrameOverhead(routeHopCount: route.count) + 16
            calculatedChunk = max(minimumChunkSize, bleMaxMTU - overhead)
            if let requestedMaxChunk {
                guard requestedMaxChunk > 0 else { return nil }
                // Honor the caller's link-MTU-derived routed chunk size without
                // clamping upward past the physical link's payload budget.
                return (fragmentVersion: fragmentVersion, chunkSize: requestedMaxChunk)
            }
        }

        if let requestedMaxChunk {
            guard requestedMaxChunk > 0 else { return nil }
            // Honor explicit link-MTU-derived budgets for directed packets too
            // so tight links never clamp upward past the physical MTU.
            let chunk = packet.recipientID != nil
                ? requestedMaxChunk
                : max(minimumChunkSize, requestedMaxChunk)
            return (
                fragmentVersion: fragmentVersion,
                chunkSize: chunk
            )
        }

        return (
            fragmentVersion: fragmentVersion,
            chunkSize: max(minimumChunkSize, calculatedChunk)
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
