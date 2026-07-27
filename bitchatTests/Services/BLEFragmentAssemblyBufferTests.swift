import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEFragmentAssemblyBufferTests {
    @Test
    func appendCompletesOutOfOrderFragments() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let original = makePacket(payload: makePayload(count: 512))
        let fragmentPackets = try makeFragments(for: original, chunkSize: 128, fragmentID: Data(repeating: 0x01, count: 8))
        let headers = try fragmentPackets.reversed().map { try #require(BLEFragmentHeader(packet: $0)) }
        var result: BLEFragmentAssemblyBuffer.AppendResult?

        for header in headers {
            result = buffer.append(header, maxInFlightAssemblies: 8)
        }

        if case let .complete(header, reassembledData, started) = result {
            #expect(header.total == fragmentPackets.count)
            #expect(!started)
            #expect(BinaryProtocol.decode(reassembledData)?.payload == original.payload)
        } else {
            Issue.record("Expected final fragment to complete reassembly")
        }
    }

    @Test
    func appendDuplicateFragmentDoesNotCompleteEarly() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let original = makePacket(payload: makePayload(count: 384))
        let fragmentPackets = try makeFragments(for: original, chunkSize: 128, fragmentID: Data(repeating: 0x02, count: 8))
        let first = try #require(BLEFragmentHeader(packet: fragmentPackets[0]))
        let second = try #require(BLEFragmentHeader(packet: fragmentPackets[1]))

        if case let .stored(_, started) = buffer.append(first, maxInFlightAssemblies: 8) {
            #expect(started)
        } else {
            Issue.record("Expected first fragment to be stored")
        }

        if case .stored = buffer.append(first, maxInFlightAssemblies: 8) {
            // Duplicate should replace the same index, not increase completion count.
        } else {
            Issue.record("Expected duplicate fragment to remain incomplete")
        }

        if case .stored = buffer.append(second, maxInFlightAssemblies: 8) {
            // Still missing at least one fragment.
        } else {
            Issue.record("Expected assembly to remain incomplete")
        }
    }

    @Test
    func conflictingTotalIsRejectedWithoutDiscardingAssembly() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let fragmentID = Data(repeating: 0x21, count: 8)
        let first = try makeHeader(
            fragmentID: fragmentID,
            index: 0,
            total: 3,
            fragmentData: Data([0x01])
        )
        let conflicting = try makeHeader(
            fragmentID: fragmentID,
            index: 1,
            total: 2,
            fragmentData: Data([0xEE])
        )
        let second = try makeHeader(
            fragmentID: fragmentID,
            index: 1,
            total: 3,
            fragmentData: Data([0x02])
        )
        let third = try makeHeader(
            fragmentID: fragmentID,
            index: 2,
            total: 3,
            fragmentData: Data([0x03])
        )

        _ = buffer.append(first, maxInFlightAssemblies: 8)
        let conflict = buffer.append(conflicting, maxInFlightAssemblies: 8)

        #expect(
            conflict == .conflicting(
                header: conflicting,
                reason: .total(expected: 3, actual: 2)
            )
        )
        _ = buffer.append(second, maxInFlightAssemblies: 8)

        if case let .complete(_, data, _) = buffer.append(third, maxInFlightAssemblies: 8) {
            #expect(data == Data([0x01, 0x02, 0x03]))
        } else {
            Issue.record("Expected the original assembly to survive a conflicting total")
        }
    }

    @Test
    func conflictingOriginalTypeIsRejected() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let fragmentID = Data(repeating: 0x22, count: 8)
        let first = try makeHeader(
            fragmentID: fragmentID,
            index: 0,
            total: 2,
            fragmentData: Data([0x01])
        )
        let conflicting = try makeHeader(
            fragmentID: fragmentID,
            index: 1,
            total: 2,
            originalType: MessageType.noiseEncrypted.rawValue,
            fragmentData: Data([0xEE])
        )

        _ = buffer.append(first, maxInFlightAssemblies: 8)

        #expect(
            buffer.append(conflicting, maxInFlightAssemblies: 8) == .conflicting(
                header: conflicting,
                reason: .originalType(
                    expected: MessageType.message.rawValue,
                    actual: MessageType.noiseEncrypted.rawValue
                )
            )
        )
    }

    @Test
    func conflictingRecipientScopeIsRejected() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let fragmentID = Data(repeating: 0x23, count: 8)
        let broadcast = try makeHeader(
            fragmentID: fragmentID,
            index: 0,
            total: 2,
            fragmentData: Data([0x01])
        )
        let directed = try makeHeader(
            fragmentID: fragmentID,
            index: 1,
            total: 2,
            fragmentData: Data([0x02]),
            recipientID: Data(hexString: "0102030405060708")
        )

        _ = buffer.append(broadcast, maxInFlightAssemblies: 8)

        #expect(
            buffer.append(directed, maxInFlightAssemblies: 8) == .conflicting(
                header: directed,
                reason: .broadcastScope(expected: true, actual: false)
            )
        )
    }

    @Test
    func conflictingDuplicateDataCannotOverwriteFirstFragment() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let fragmentID = Data(repeating: 0x24, count: 8)
        let first = try makeHeader(
            fragmentID: fragmentID,
            index: 0,
            total: 2,
            fragmentData: Data([0x01])
        )
        let conflicting = try makeHeader(
            fragmentID: fragmentID,
            index: 0,
            total: 2,
            fragmentData: Data([0xEE])
        )
        let second = try makeHeader(
            fragmentID: fragmentID,
            index: 1,
            total: 2,
            fragmentData: Data([0x02])
        )

        _ = buffer.append(first, maxInFlightAssemblies: 8)

        #expect(
            buffer.append(conflicting, maxInFlightAssemblies: 8) == .conflicting(
                header: conflicting,
                reason: .fragmentData(index: 0)
            )
        )

        if case let .complete(_, data, _) = buffer.append(second, maxInFlightAssemblies: 8) {
            #expect(data == Data([0x01, 0x02]))
        } else {
            Issue.record("Expected first-wins fragment data to complete normally")
        }
    }

    @Test
    func exactDuplicateDoesNotCountTwiceTowardSizeLimit() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let fragmentID = Data(repeating: 0x25, count: 8)
        let fragment = try makeHeader(
            fragmentID: fragmentID,
            index: 0,
            total: 2,
            fragmentData: Data(
                repeating: 0x01,
                count: FileTransferLimits.maxPayloadBytes / 2 + 1
            )
        )

        _ = buffer.append(fragment, maxInFlightAssemblies: 8)

        if case let .stored(_, started) = buffer.append(fragment, maxInFlightAssemblies: 8) {
            #expect(!started)
        } else {
            Issue.record("Expected an exact duplicate to keep the assembly unchanged")
        }
    }

    @Test
    func appendEvictsOldestAssemblyWhenCapIsReached() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let oldPacket = makePacket(payload: makePayload(count: 256, seed: 1), timestamp: 1)
        let newPacket = makePacket(payload: makePayload(count: 256, seed: 2), timestamp: 2)
        let oldFragments = try makeFragments(for: oldPacket, chunkSize: 128, fragmentID: Data(repeating: 0x03, count: 8))
        let newFragments = try makeFragments(for: newPacket, chunkSize: 128, fragmentID: Data(repeating: 0x04, count: 8))
        let oldFirst = try #require(BLEFragmentHeader(packet: oldFragments[0]))
        let oldSecond = try #require(BLEFragmentHeader(packet: oldFragments[1]))
        let newFirst = try #require(BLEFragmentHeader(packet: newFragments[0]))
        let newSecond = try #require(BLEFragmentHeader(packet: newFragments[1]))

        _ = buffer.append(oldFirst, maxInFlightAssemblies: 1, now: Date(timeIntervalSince1970: 1))
        _ = buffer.append(newFirst, maxInFlightAssemblies: 1, now: Date(timeIntervalSince1970: 2))

        if case let .stored(_, started) = buffer.append(oldSecond, maxInFlightAssemblies: 1) {
            #expect(started)
        } else {
            Issue.record("Expected evicted assembly to restart when old fragment arrives")
        }

        if case let .stored(_, started) = buffer.append(newSecond, maxInFlightAssemblies: 1) {
            #expect(started)
        } else {
            Issue.record("Expected new assembly to restart after old one consumed the only slot")
        }
    }

    @Test
    func oversizedFragmentIsRejectedWithoutDiscardingAssembly() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let fragmentID = Data(repeating: 0x05, count: 8)
        let headroom = 10
        let first = try makeHeader(
            fragmentID: fragmentID,
            index: 0,
            total: 2,
            fragmentData: Data(
                repeating: 0x01,
                count: FileTransferLimits.maxPayloadBytes - headroom
            )
        )
        // An injected fragment at an unused index, sized to blow the budget.
        let oversized = try makeHeader(
            fragmentID: fragmentID,
            index: 1,
            total: 2,
            fragmentData: Data(repeating: 0xEE, count: headroom + 1)
        )
        let legitimate = try makeHeader(
            fragmentID: fragmentID,
            index: 1,
            total: 2,
            fragmentData: Data(repeating: 0x02, count: headroom)
        )

        _ = buffer.append(first, maxInFlightAssemblies: 8)
        let result = buffer.append(oversized, maxInFlightAssemblies: 8)

        if case let .oversized(_, projectedSize, limit, started) = result {
            #expect(projectedSize == FileTransferLimits.maxPayloadBytes + 1)
            #expect(limit == FileTransferLimits.maxPayloadBytes)
            #expect(!started)
        } else {
            Issue.record("Expected the oversized fragment to be rejected")
        }

        // The stream a spoofed fragment tried to blow up still completes.
        if case let .complete(_, data, _) = buffer.append(legitimate, maxInFlightAssemblies: 8) {
            #expect(data.count == FileTransferLimits.maxPayloadBytes)
            #expect(data.suffix(headroom) == Data(repeating: 0x02, count: headroom))
        } else {
            Issue.record("Expected the original assembly to survive an oversized fragment")
        }
    }

    @Test
    func oversizedFirstFragmentIsRejectedWithoutClaimingASlot() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        // A single fragment over the budget can never be stored, so it must be
        // turned away before an assembly is started for it — starting one
        // evicts the oldest in-flight stream to make room. A compressed
        // fragment can reach this size in one packet.
        let victimID = Data(repeating: 0x07, count: 8)
        let victimFirst = try makeHeader(
            fragmentID: victimID,
            index: 0,
            total: 2,
            fragmentData: Data([0x01])
        )
        let victimSecond = try makeHeader(
            fragmentID: victimID,
            index: 1,
            total: 2,
            fragmentData: Data([0x02])
        )
        let oversized = try makeHeader(
            fragmentID: Data(repeating: 0x06, count: 8),
            index: 0,
            total: 2,
            fragmentData: Data(
                repeating: 0xEE,
                count: FileTransferLimits.maxPayloadBytes + 1
            )
        )

        _ = buffer.append(victimFirst, maxInFlightAssemblies: 1)

        if case let .oversized(_, projectedSize, limit, started) = buffer.append(oversized, maxInFlightAssemblies: 1) {
            #expect(projectedSize == FileTransferLimits.maxPayloadBytes + 1)
            #expect(limit == FileTransferLimits.maxPayloadBytes)
            #expect(!started)
        } else {
            Issue.record("Expected a single over-budget fragment to be rejected")
        }

        // The assembly holding the only in-flight slot was never evicted.
        if case let .complete(_, data, _) = buffer.append(victimSecond, maxInFlightAssemblies: 1) {
            #expect(data == Data([0x01, 0x02]))
        } else {
            Issue.record("Expected a rejected fragment to leave the in-flight slot alone")
        }
    }

    @Test
    func overBudgetStreamStopsDrawingResyncRequests() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let t0 = Date(timeIntervalSince1970: 100)
        let headroom = 10
        let starvedID = Data(repeating: 0x08, count: 8)
        let healthyID = Data(repeating: 0x09, count: 8)

        let starvedFirst = try makeHeader(
            fragmentID: starvedID,
            index: 0,
            total: 3,
            fragmentData: Data(
                repeating: 0x01,
                count: FileTransferLimits.maxPayloadBytes - headroom
            )
        )
        let starvedOversized = try makeHeader(
            fragmentID: starvedID,
            index: 1,
            total: 3,
            fragmentData: Data(repeating: 0xEE, count: headroom + 1)
        )
        let healthyFirst = try makeHeader(
            fragmentID: healthyID,
            index: 0,
            total: 2,
            fragmentData: Data([0x01])
        )

        _ = buffer.append(starvedFirst, maxInFlightAssemblies: 8, now: t0)
        _ = buffer.append(healthyFirst, maxInFlightAssemblies: 8, now: t0)
        _ = buffer.append(starvedOversized, maxInFlightAssemblies: 8, now: t0)

        // The starved stream is retained so a spoofed fragment cannot destroy
        // it, but it cannot complete on what it holds — only the healthy
        // stream is worth a REQUEST_SYNC slot.
        let stalled = buffer.stalledBroadcastFragmentIDs(
            stalledAfter: 5,
            retryAfter: 10,
            now: t0.addingTimeInterval(6)
        )
        #expect(stalled == [healthyID])

        // The fragment that tripped the ceiling may have been the injected
        // one. A fragment that does store proves the stream is still moving,
        // so recovery must come back rather than stay suppressed for the
        // assembly's whole lifetime.
        let starvedProgress = try makeHeader(
            fragmentID: starvedID,
            index: 1,
            total: 3,
            fragmentData: Data(repeating: 0x02, count: headroom)
        )
        _ = buffer.append(starvedProgress, maxInFlightAssemblies: 8, now: t0.addingTimeInterval(7))

        let recovered = buffer.stalledBroadcastFragmentIDs(
            stalledAfter: 5,
            retryAfter: 10,
            now: t0.addingTimeInterval(20)
        )
        #expect(recovered.contains(starvedID))
    }

    @Test
    func streamsFromDifferentSendersSharingAFragmentIDStayIsolated() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        // Fragment IDs are only unique per sender, and a colliding ID must not
        // make two honest senders reject each other — `BLEFragmentKey` carries
        // the sender for exactly this reason. Dropping it would turn the
        // first-wins checks below into a mutual-rejection DoS.
        let sharedID = Data(repeating: 0x0A, count: 8)
        let alice = Data([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7])
        let bob = Data([0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7])

        // Same ID, different senders, and every header field disagrees.
        let aliceFirst = try makeHeader(
            fragmentID: sharedID,
            index: 0,
            total: 2,
            fragmentData: Data([0x01]),
            senderID: alice
        )
        let bobFirst = try makeHeader(
            fragmentID: sharedID,
            index: 0,
            total: 3,
            originalType: MessageType.noiseEncrypted.rawValue,
            fragmentData: Data([0xB1]),
            senderID: bob
        )
        let aliceSecond = try makeHeader(
            fragmentID: sharedID,
            index: 1,
            total: 2,
            fragmentData: Data([0x02]),
            senderID: alice
        )
        let bobRest = try (1...2).map { index in
            try makeHeader(
                fragmentID: sharedID,
                index: index,
                total: 3,
                originalType: MessageType.noiseEncrypted.rawValue,
                fragmentData: Data([UInt8(0xB1 + index)]),
                senderID: bob
            )
        }

        _ = buffer.append(aliceFirst, maxInFlightAssemblies: 8)
        #expect(!isConflicting(buffer.append(bobFirst, maxInFlightAssemblies: 8)))
        #expect(!isConflicting(buffer.append(bobRest[0], maxInFlightAssemblies: 8)))

        if case let .complete(_, data, _) = buffer.append(aliceSecond, maxInFlightAssemblies: 8) {
            #expect(data == Data([0x01, 0x02]))
        } else {
            Issue.record("Expected Alice's stream to complete independently")
        }

        if case let .complete(_, data, _) = buffer.append(bobRest[1], maxInFlightAssemblies: 8) {
            #expect(data == Data([0xB1, 0xB2, 0xB3]))
        } else {
            Issue.record("Expected Bob's stream to complete independently")
        }
    }

    @Test
    func encryptedPrivateFileAssemblyGetsFramedFileHeadroom() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let fragmentID = Data(repeating: 0x15, count: 8)
        let first = try #require(BLEFragmentHeader(packet: makeFragmentPacket(
            fragmentID: fragmentID,
            index: 0,
            total: 2,
            originalType: MessageType.noiseEncrypted.rawValue,
            fragmentData: Data(repeating: 0x01, count: FileTransferLimits.maxPayloadBytes)
        )))
        let second = try #require(BLEFragmentHeader(packet: makeFragmentPacket(
            fragmentID: fragmentID,
            index: 1,
            total: 2,
            originalType: MessageType.noiseEncrypted.rawValue,
            fragmentData: Data([0x02])
        )))

        _ = buffer.append(first, maxInFlightAssemblies: 8)
        let result = buffer.append(second, maxInFlightAssemblies: 8)

        if case let .complete(_, data, _) = result {
            #expect(data.count == FileTransferLimits.maxPayloadBytes + 1)
        } else {
            Issue.record("Expected encrypted private-file assembly to use framed-file limit")
        }
    }

    @Test
    func removeExpiredDropsOldAssemblies() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let packet = makePacket(payload: makePayload(count: 256))
        let fragments = try makeFragments(for: packet, chunkSize: 128, fragmentID: Data(repeating: 0x06, count: 8))
        let first = try #require(BLEFragmentHeader(packet: fragments[0]))
        let second = try #require(BLEFragmentHeader(packet: fragments[1]))

        _ = buffer.append(first, maxInFlightAssemblies: 8, now: Date(timeIntervalSince1970: 1))
        #expect(buffer.removeExpired(before: Date(timeIntervalSince1970: 2)) == 1)

        if case let .stored(_, started) = buffer.append(second, maxInFlightAssemblies: 8) {
            #expect(started)
        } else {
            Issue.record("Expected expired assembly to be gone")
        }
    }

    @Test
    func stalledBroadcastAssemblyReportsFragmentIDOnceUntilRetryLapses() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let fragmentID = Data((1...8).map { UInt8($0) })
        let packet = makePacket(payload: makePayload(count: 256))
        let fragments = try makeFragments(for: packet, chunkSize: 128, fragmentID: fragmentID)
        let first = try #require(BLEFragmentHeader(packet: fragments[0]))

        let t0 = Date(timeIntervalSince1970: 100)
        _ = buffer.append(first, maxInFlightAssemblies: 8, now: t0)

        // Not yet stalled.
        let early = buffer.stalledBroadcastFragmentIDs(stalledAfter: 5, retryAfter: 10, now: t0.addingTimeInterval(4))
        #expect(early.isEmpty)

        // Stalled: reported once, big-endian stream ID.
        let stalled = buffer.stalledBroadcastFragmentIDs(stalledAfter: 5, retryAfter: 10, now: t0.addingTimeInterval(6))
        #expect(stalled == [fragmentID])

        // Within the retry window: not re-reported.
        let repeated = buffer.stalledBroadcastFragmentIDs(stalledAfter: 5, retryAfter: 10, now: t0.addingTimeInterval(8))
        #expect(repeated.isEmpty)

        // After the retry window it is requested again.
        let retried = buffer.stalledBroadcastFragmentIDs(stalledAfter: 5, retryAfter: 10, now: t0.addingTimeInterval(17))
        #expect(retried == [fragmentID])
    }

    @Test
    func newFragmentResetsStallClockAndCompletionStopsRequests() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let fragmentID = Data((10...17).map { UInt8($0) })
        let packet = makePacket(payload: makePayload(count: 384))
        let fragments = try makeFragments(for: packet, chunkSize: 128, fragmentID: fragmentID)
        let headers = try fragments.map { try #require(BLEFragmentHeader(packet: $0)) }
        #expect(headers.count >= 3)

        let t0 = Date(timeIntervalSince1970: 100)
        _ = buffer.append(headers[0], maxInFlightAssemblies: 8, now: t0)
        // A fragment arriving at t0+4 resets the stall clock.
        _ = buffer.append(headers[1], maxInFlightAssemblies: 8, now: t0.addingTimeInterval(4))
        let afterProgress = buffer.stalledBroadcastFragmentIDs(stalledAfter: 5, retryAfter: 10, now: t0.addingTimeInterval(6))
        #expect(afterProgress.isEmpty)

        // Completion removes the assembly entirely.
        var result: BLEFragmentAssemblyBuffer.AppendResult?
        for header in headers.dropFirst(2) {
            result = buffer.append(header, maxInFlightAssemblies: 8, now: t0.addingTimeInterval(5))
        }
        guard case .complete = result else {
            Issue.record("Expected assembly to complete")
            return
        }
        let afterCompletion = buffer.stalledBroadcastFragmentIDs(stalledAfter: 5, retryAfter: 10, now: t0.addingTimeInterval(60))
        #expect(afterCompletion.isEmpty)
    }

    @Test
    func duplicateFragmentsDoNotResetStallClock() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let fragmentID = Data((20...27).map { UInt8($0) })
        let packet = makePacket(payload: makePayload(count: 256))
        let fragments = try makeFragments(for: packet, chunkSize: 128, fragmentID: fragmentID)
        let first = try #require(BLEFragmentHeader(packet: fragments[0]))

        let t0 = Date(timeIntervalSince1970: 100)
        _ = buffer.append(first, maxInFlightAssemblies: 8, now: t0)

        // Relay duplicates of the same index arrive every few seconds; they
        // bring no new data, so they must not keep the stream "fresh".
        _ = buffer.append(first, maxInFlightAssemblies: 8, now: t0.addingTimeInterval(3))
        _ = buffer.append(first, maxInFlightAssemblies: 8, now: t0.addingTimeInterval(5))

        let stalled = buffer.stalledBroadcastFragmentIDs(stalledAfter: 5, retryAfter: 10, now: t0.addingTimeInterval(6))
        #expect(stalled == [fragmentID])
    }

    @Test
    func conflictingFragmentsDoNotResetStallClock() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let fragmentID = Data(repeating: 0x26, count: 8)
        let first = try makeHeader(
            fragmentID: fragmentID,
            index: 0,
            total: 2,
            fragmentData: Data([0x01])
        )
        let conflicting = try makeHeader(
            fragmentID: fragmentID,
            index: 0,
            total: 2,
            fragmentData: Data([0xEE])
        )

        let t0 = Date(timeIntervalSince1970: 100)
        _ = buffer.append(first, maxInFlightAssemblies: 8, now: t0)

        // A rejected fragment brings no progress, so a flood of them must not
        // keep a stalled stream looking "fresh" and suppress its REQUEST_SYNC.
        for offset in [3.0, 5.0] {
            let result = buffer.append(
                conflicting,
                maxInFlightAssemblies: 8,
                now: t0.addingTimeInterval(offset)
            )
            #expect(result == .conflicting(header: conflicting, reason: .fragmentData(index: 0)))
        }

        let stalled = buffer.stalledBroadcastFragmentIDs(
            stalledAfter: 5,
            retryAfter: 10,
            now: t0.addingTimeInterval(6)
        )
        #expect(stalled == [fragmentID])
    }

    @Test
    func overflowStalledStreamsRotateAcrossPasses() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let cap = RequestSyncPacket.maxFragmentIdFilterCount
        let streamCount = cap + 10
        let t0 = Date(timeIntervalSince1970: 100)

        // Incomplete broadcast assemblies with staggered last-fragment times
        // (stream 0 is the oldest stall).
        var ids: [Data] = []
        for i in 0..<streamCount {
            let fragmentID = Data([0xAB, 0, 0, 0, 0, 0, UInt8(i >> 8), UInt8(i & 0xFF)])
            ids.append(fragmentID)
            let header = try #require(BLEFragmentHeader(packet: makeFragmentPacket(
                fragmentID: fragmentID,
                index: 0,
                total: 2,
                originalType: MessageType.message.rawValue,
                fragmentData: Data([0x01])
            )))
            _ = buffer.append(header, maxInFlightAssemblies: streamCount, now: t0.addingTimeInterval(Double(i)))
        }

        // All streams are stalled; only the cap's worth (oldest first) is
        // requested and rate-limited, the overflow stays eligible.
        let firstPassAt = t0.addingTimeInterval(Double(streamCount) + 5)
        let firstPass = buffer.stalledBroadcastFragmentIDs(stalledAfter: 5, retryAfter: 60, now: firstPassAt)
        #expect(firstPass == Array(ids.prefix(cap)))

        // Next pass picks up exactly the overflow streams.
        let secondPass = buffer.stalledBroadcastFragmentIDs(stalledAfter: 5, retryAfter: 60, now: firstPassAt.addingTimeInterval(1))
        #expect(secondPass == Array(ids.suffix(streamCount - cap)))

        // Nothing left until a retry window lapses.
        let thirdPass = buffer.stalledBroadcastFragmentIDs(stalledAfter: 5, retryAfter: 60, now: firstPassAt.addingTimeInterval(2))
        #expect(thirdPass.isEmpty)
    }

    @Test
    func directedAssembliesAreNeverReportedAsStalled() throws {
        var buffer = BLEFragmentAssemblyBuffer()
        let fragment = makeFragmentPacket(
            fragmentID: Data(repeating: 0x0A, count: 8),
            index: 0,
            total: 2,
            originalType: MessageType.message.rawValue,
            fragmentData: Data([0x01]),
            recipientID: Data(hexString: "0102030405060708")
        )
        let header = try #require(BLEFragmentHeader(packet: fragment))

        let t0 = Date(timeIntervalSince1970: 100)
        _ = buffer.append(header, maxInFlightAssemblies: 8, now: t0)
        let stalled = buffer.stalledBroadcastFragmentIDs(stalledAfter: 5, retryAfter: 10, now: t0.addingTimeInterval(60))
        #expect(stalled.isEmpty)
    }

    private func makePacket(payload: Data, timestamp: UInt64 = 0x0102030405) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]),
            recipientID: nil,
            timestamp: timestamp,
            payload: payload,
            signature: nil,
            ttl: 3
        )
    }

    private func makePayload(count: Int, seed: UInt64 = 0x1234ABCD) -> Data {
        var state = seed
        return Data((0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 32)
        })
    }

    private func makeFragments(for packet: BitchatPacket, chunkSize: Int, fragmentID: Data) throws -> [BitchatPacket] {
        let fullData = try #require(packet.toBinaryData(padding: false))
        let chunks = stride(from: 0, to: fullData.count, by: chunkSize).map { offset in
            Data(fullData[offset..<min(offset + chunkSize, fullData.count)])
        }

        return chunks.enumerated().map { index, chunk in
            makeFragmentPacket(
                fragmentID: fragmentID,
                index: index,
                total: chunks.count,
                originalType: packet.type,
                fragmentData: chunk,
                senderID: packet.senderID,
                recipientID: packet.recipientID,
                timestamp: packet.timestamp
            )
        }
    }

    private func isConflicting(_ result: BLEFragmentAssemblyBuffer.AppendResult) -> Bool {
        if case .conflicting = result { return true }
        return false
    }

    private func makeHeader(
        fragmentID: Data,
        index: Int,
        total: Int,
        originalType: UInt8 = MessageType.message.rawValue,
        fragmentData: Data,
        senderID: Data = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]),
        recipientID: Data? = nil
    ) throws -> BLEFragmentHeader {
        try #require(BLEFragmentHeader(packet: makeFragmentPacket(
            fragmentID: fragmentID,
            index: index,
            total: total,
            originalType: originalType,
            fragmentData: fragmentData,
            senderID: senderID,
            recipientID: recipientID
        )))
    }

    private func makeFragmentPacket(
        fragmentID: Data,
        index: Int,
        total: Int,
        originalType: UInt8,
        fragmentData: Data,
        senderID: Data = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]),
        recipientID: Data? = nil,
        timestamp: UInt64 = 0x0102030405
    ) -> BitchatPacket {
        var payload = Data()
        payload.append(fragmentID)
        payload.append(contentsOf: withUnsafeBytes(of: UInt16(index).bigEndian) { Data($0) })
        payload.append(contentsOf: withUnsafeBytes(of: UInt16(total).bigEndian) { Data($0) })
        payload.append(originalType)
        payload.append(fragmentData)

        return BitchatPacket(
            type: MessageType.fragment.rawValue,
            senderID: senderID,
            recipientID: recipientID,
            timestamp: timestamp,
            payload: payload,
            signature: nil,
            ttl: 3
        )
    }
}
