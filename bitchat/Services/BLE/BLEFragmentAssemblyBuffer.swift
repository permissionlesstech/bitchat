import BitFoundation
import Foundation

struct BLEFragmentKey: Hashable, Equatable {
    let sender: UInt64
    let id: UInt64
}

struct BLEFragmentHeader: Equatable {
    let key: BLEFragmentKey
    let index: Int
    let total: Int
    let originalType: UInt8
    let fragmentData: Data
    let isBroadcastFragment: Bool

    var idLogString: String {
        String(format: "%016llx", key.id)
    }

    init?(packet: BitchatPacket) {
        // Minimum header: 8 bytes ID + 2 index + 2 total + 1 type.
        guard packet.payload.count >= 13 else { return nil }

        var senderU64: UInt64 = 0
        for byte in packet.senderID.prefix(8) {
            senderU64 = (senderU64 << 8) | UInt64(byte)
        }

        var fragmentU64: UInt64 = 0
        for byte in packet.payload.prefix(8) {
            fragmentU64 = (fragmentU64 << 8) | UInt64(byte)
        }

        let index = Int((UInt16(packet.payload[8]) << 8) | UInt16(packet.payload[9]))
        let total = Int((UInt16(packet.payload[10]) << 8) | UInt16(packet.payload[11]))

        guard total > 0 && total <= 10_000 && index >= 0 && index < total else {
            return nil
        }

        let isBroadcastFragment: Bool = {
            guard let recipient = packet.recipientID else { return true }
            return recipient.count == 8 && recipient.allSatisfy { $0 == 0xFF }
        }()

        self.key = BLEFragmentKey(sender: senderU64, id: fragmentU64)
        self.index = index
        self.total = total
        self.originalType = packet.payload[12]
        self.fragmentData = Data(packet.payload.suffix(from: 13))
        self.isBroadcastFragment = isBroadcastFragment
    }
}

/// Reassembles inbound fragment streams keyed by `(sender, fragmentID)`.
///
/// Fragments are unauthenticated and bypass the packet deduplicator, so any
/// peer in range can address a stream it does not own. The buffer treats the
/// first accepted header as authoritative for the stream's shape and refuses
/// to let a later fragment restate it or rewrite an index already held.
///
/// This bounds the damage; it does not eliminate it. An injected fragment
/// that reaches an index before the honest one does *is* the first accepted
/// value for that index, and one such packet is enough to corrupt the
/// reassembled payload. What first-wins buys is cost against premature
/// completion or full replacement: the attacker must supply the stream's
/// pinned total and win the race at every index it needs to control. Closing
/// the gap needs authenticated fragment envelopes or a sender-key-bound
/// stream ID — the receiver has nothing to distinguish the variants by.
struct BLEFragmentAssemblyBuffer {
    enum ConflictReason: Equatable {
        case total(expected: Int, actual: Int)
        case originalType(expected: UInt8, actual: UInt8)
        case broadcastScope(expected: Bool, actual: Bool)
        case fragmentData(index: Int)
    }

    enum AppendResult: Equatable {
        case stored(header: BLEFragmentHeader, started: Bool)
        case complete(header: BLEFragmentHeader, reassembledData: Data, started: Bool)
        case oversized(header: BLEFragmentHeader, projectedSize: Int, limit: Int, started: Bool)
        case conflicting(header: BLEFragmentHeader, reason: ConflictReason)
    }

    private struct Metadata {
        let total: Int
        let originalType: UInt8
        let timestamp: Date
        let isBroadcast: Bool
        var lastFragmentAt: Date
        var lastResyncRequestAt: Date?
        /// Set when a fragment would have pushed the stream past its size
        /// limit. The assembly is kept (see `append`) but cannot complete on
        /// what it holds, so it stops consuming REQUEST_SYNC filter slots
        /// until a fragment actually stores and clears the mark.
        var exceededBudget: Bool = false

        func conflictReason(for header: BLEFragmentHeader) -> ConflictReason? {
            if header.total != total {
                return .total(expected: total, actual: header.total)
            }
            if header.originalType != originalType {
                return .originalType(expected: originalType, actual: header.originalType)
            }
            if header.isBroadcastFragment != isBroadcast {
                return .broadcastScope(expected: isBroadcast, actual: header.isBroadcastFragment)
            }
            return nil
        }
    }

    private var fragmentsByKey: [BLEFragmentKey: [Int: Data]] = [:]
    private var metadataByKey: [BLEFragmentKey: Metadata] = [:]

    mutating func removeAll() {
        fragmentsByKey.removeAll()
        metadataByKey.removeAll()
    }

    @discardableResult
    mutating func removeExpired(before cutoff: Date) -> Int {
        let expiredKeys = metadataByKey
            .filter { $0.value.timestamp < cutoff }
            .map(\.key)

        for key in expiredKeys {
            fragmentsByKey.removeValue(forKey: key)
            metadataByKey.removeValue(forKey: key)
        }

        return expiredKeys.count
    }

    mutating func append(
        _ header: BLEFragmentHeader,
        maxInFlightAssemblies: Int,
        now: Date = Date()
    ) -> AppendResult {
        // Reject a fragment too large to ever be stored before touching the
        // table: starting an assembly evicts the oldest in-flight stream to
        // make room, and a fragment headed for rejection must not cost a
        // legitimate stream its slot. This is reachable with one packet — a
        // compressed fragment may legally inflate to more than the whole
        // budget, since `BinaryProtocol` caps decompression at 50000:1.
        if metadataByKey[header.key] == nil {
            let limit = Self.assemblyLimit(for: header.originalType)
            if header.fragmentData.count > limit {
                return .oversized(
                    header: header,
                    projectedSize: header.fragmentData.count,
                    limit: limit,
                    started: false
                )
            }
        }

        let assembly = prepareAssembly(
            for: header,
            maxInFlightAssemblies: maxInFlightAssemblies,
            now: now
        )
        let metadata = assembly.metadata
        let started = assembly.started

        // A fragment ID identifies one immutable stream from a sender. Keep
        // the first accepted header authoritative so a collision or injected
        // fragment cannot shorten the stream, switch its size policy, or
        // change whether it participates in broadcast gossip recovery.
        if let reason = metadata.conflictReason(for: header) {
            return .conflicting(header: header, reason: reason)
        }

        let existingFragment = fragmentsByKey[header.key]?[header.index]
        if let existingFragment, existingFragment != header.fragmentData {
            // Duplicate delivery is expected in a mesh, but the same stream
            // index must always carry the same bytes. Preserve first-wins
            // state instead of letting a conflicting duplicate poison it.
            // This protects indices already held — an index still empty when
            // the injected fragment arrives is filled by whichever copy wins
            // the race, and nothing here can tell them apart.
            return .conflicting(header: header, reason: .fragmentData(index: header.index))
        }

        let currentSize = fragmentsByKey[header.key]?.values.reduce(0) { $0 + $1.count } ?? 0
        let limit = Self.assemblyLimit(for: metadata.originalType)
        let projectedSize = currentSize + (existingFragment == nil ? header.fragmentData.count : 0)

        guard projectedSize <= limit else {
            // An incoming fragment must never destroy state it did not
            // create: an injected fragment at an unused index would
            // otherwise be enough to wipe a legitimate in-flight stream.
            // Nothing above the limit is ever stored, so keeping the
            // assembly stays inside the same memory bound — a genuinely
            // oversized stream just never completes and `removeExpired`
            // reaps it. Only an assembly this fragment itself started has
            // nothing worth preserving.
            if started {
                fragmentsByKey.removeValue(forKey: header.key)
                metadataByKey.removeValue(forKey: header.key)
            } else {
                // A retained assembly that hit its ceiling cannot complete on
                // what it holds, so stop it drawing REQUEST_SYNC retries it
                // cannot use. This is provisional, not a verdict on the
                // stream: the fragment that tripped the ceiling may be the
                // injected one, so any later fragment that does store clears
                // the mark and restores recovery.
                metadataByKey[header.key]?.exceededBudget = true
            }
            return .oversized(header: header, projectedSize: projectedSize, limit: limit, started: started)
        }

        // Only actual progress resets the stall clock: fragment packets
        // bypass the packet deduplicator, so relayed duplicates of an
        // already-held index must not keep suppressing the targeted
        // REQUEST_SYNC for a stalled stream.
        let isNewIndex = existingFragment == nil
        fragmentsByKey[header.key]?[header.index] = header.fragmentData
        if isNewIndex {
            metadataByKey[header.key]?.lastFragmentAt = now
            // Real progress: whatever tripped the ceiling earlier did not stop
            // this stream, so it is eligible for recovery again.
            metadataByKey[header.key]?.exceededBudget = false
        }

        guard let fragments = fragmentsByKey[header.key],
              fragments.count == metadata.total else {
            return .stored(header: header, started: started)
        }

        let reassembled = (0..<metadata.total).reduce(into: Data()) { data, index in
            if let fragment = fragments[index] {
                data.append(fragment)
            }
        }

        fragmentsByKey.removeValue(forKey: header.key)
        metadataByKey.removeValue(forKey: header.key)

        return .complete(header: header, reassembledData: reassembled, started: started)
    }

    private mutating func prepareAssembly(
        for header: BLEFragmentHeader,
        maxInFlightAssemblies: Int,
        now: Date
    ) -> (metadata: Metadata, started: Bool) {
        if let metadata = metadataByKey[header.key] {
            return (metadata, false)
        }

        if fragmentsByKey.count >= maxInFlightAssemblies,
           let oldest = metadataByKey.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
            fragmentsByKey.removeValue(forKey: oldest)
            metadataByKey.removeValue(forKey: oldest)
        }

        let metadata = Metadata(
            total: header.total,
            originalType: header.originalType,
            timestamp: now,
            isBroadcast: header.isBroadcastFragment,
            lastFragmentAt: now
        )
        fragmentsByKey[header.key] = [:]
        metadataByKey[header.key] = metadata
        return (metadata, true)
    }

    /// Fragment stream IDs (8-byte, big-endian) of incomplete broadcast
    /// reassemblies that have not seen a new fragment for `stalledAfter`
    /// seconds — candidates for a targeted REQUEST_SYNC. Each returned
    /// stream is marked so it is not re-requested within `retryAfter`.
    /// At most `RequestSyncPacket.maxFragmentIdFilterCount` streams are
    /// returned per pass — the wire filter cannot carry more — selected
    /// oldest-stall first; overflow streams stay unmarked and eligible for
    /// the next pass. Directed reassemblies are excluded: peers only archive
    /// broadcast fragments for gossip sync, so a targeted request cannot
    /// recover them. Streams that have tripped their size budget are excluded
    /// too — they are retained rather than discarded, but cannot complete on
    /// what they hold, so requesting more would only burn filter slots. That
    /// exclusion lifts as soon as a fragment stores, since the fragment that
    /// tripped the budget may have been an injected one.
    mutating func stalledBroadcastFragmentIDs(
        stalledAfter: TimeInterval,
        retryAfter: TimeInterval,
        now: Date = Date()
    ) -> [Data] {
        var candidates: [(key: BLEFragmentKey, lastFragmentAt: Date)] = []
        for (key, metadata) in metadataByKey {
            guard metadata.isBroadcast,
                  !metadata.exceededBudget,
                  let fragments = fragmentsByKey[key],
                  fragments.count < metadata.total,
                  now.timeIntervalSince(metadata.lastFragmentAt) >= stalledAfter else { continue }
            if let lastRequest = metadata.lastResyncRequestAt,
               now.timeIntervalSince(lastRequest) < retryAfter { continue }
            candidates.append((key: key, lastFragmentAt: metadata.lastFragmentAt))
        }

        // Mark only the streams that will actually go on the wire, so the
        // overflow is not silently suppressed for `retryAfter`.
        let selected = candidates
            .sorted {
                if $0.lastFragmentAt != $1.lastFragmentAt {
                    return $0.lastFragmentAt < $1.lastFragmentAt
                }
                return ($0.key.sender, $0.key.id) < ($1.key.sender, $1.key.id)
            }
            .prefix(RequestSyncPacket.maxFragmentIdFilterCount)

        return selected.map { candidate in
            metadataByKey[candidate.key]?.lastResyncRequestAt = now
            return withUnsafeBytes(of: candidate.key.id.bigEndian) { Data($0) }
        }
    }

    private static func assemblyLimit(for originalType: UInt8) -> Int {
        if originalType == MessageType.fileTransfer.rawValue
            || originalType == MessageType.noiseEncrypted.rawValue {
            // Allow headroom for TLV metadata and binary framing overhead.
            // A large noiseEncrypted packet can be an E2E-encrypted private
            // file; its authenticated plaintext is validated after decrypt.
            return FileTransferLimits.maxFramedFileBytes
        }

        return FileTransferLimits.maxPayloadBytes
    }
}
