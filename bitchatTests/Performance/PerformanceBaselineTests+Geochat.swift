//
// PerformanceBaselineTests+Geochat.swift
// bitchatTests
//
// Geochat (location channel) benchmarks at a busy-room size. Each guards a
// cost that used to grow with the number of participants N:
//
// - the people sheet resolved every row's color by rebuilding the whole
//   roster, so one render was O(N^2);
// - every roster rebuild hex-encoded our own key once per participant with
//   String(format:) per byte;
// - every inbound event (presence heartbeats arrive ~N/60 times a second)
//   rebuilt and republished the roster.
//
// perf-floors.json keeps each floor far above those regression values.
//

import XCTest
import BitFoundation
@testable import bitchat

extension PerformanceBaselineTests {
    /// The room size at which the regressions above cost seconds.
    private static let geochatParticipants = 500

    // MARK: - Geochat people list colors

    /// One people-sheet render resolves a color for every row.
    func testGeochatPeopleListColors() {
        let fixture = GeochatPerfFixture(participants: Self.geochatParticipants)
        let pubkeys = fixture.pubkeys
        var samples: [TimeInterval] = []

        measure {
            let start = Date()
            for pubkey in pubkeys {
                _ = fixture.viewModel.colorForNostrPubkey(pubkey, isDark: true)
            }
            samples.append(Date().timeIntervalSince(start))
        }

        reportThroughput("geochat.peopleListColors", samples: samples, operations: pubkeys.count, unit: "rows")
    }

    // MARK: - Geochat participant heartbeats

    /// Presence heartbeats and messages from people already in the room.
    func testGeochatParticipantHeartbeats() {
        let fixture = GeochatPerfFixture(participants: Self.geochatParticipants)
        let tracker = fixture.viewModel.participantTracker
        let pubkeys = fixture.pubkeys
        let events = 2_000
        var samples: [TimeInterval] = []

        measure {
            let start = Date()
            for index in 0..<events {
                tracker.recordParticipant(pubkeyHex: pubkeys[index % pubkeys.count], geohash: GeochatPerfFixture.geohash)
            }
            samples.append(Date().timeIntervalSince(start))
        }

        XCTAssertEqual(tracker.visiblePeople.count, pubkeys.count)
        reportThroughput("geochat.participantHeartbeat", samples: samples, operations: events, unit: "events")
    }

    // MARK: - Geochat message formatting

    /// First render of new geochat messages (formatting cache miss), whose
    /// sender color comes from the roster palette.
    func testGeochatFormatNewMessages() {
        let fixture = GeochatPerfFixture(participants: Self.geochatParticipants)
        let batchCount = 16 // > XCTest's default 10 measure iterations
        let batchSize = 200
        let batches: [[BitchatMessage]] = (0..<batchCount).map { batch in
            (0..<batchSize).map { index in
                let pubkey = fixture.pubkeys[(batch * batchSize + index) % fixture.pubkeys.count]
                return BitchatMessage(
                    id: "geo-fmt-\(batch)-\(index)",
                    sender: "peer\(index)#\(pubkey.suffix(4))",
                    content: "anyone near the station tonight? heading over in ten minutes",
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                    isRelay: false,
                    senderPeerID: PeerID(nostr: pubkey)
                )
            }
        }
        var pass = 0
        var samples: [TimeInterval] = []

        measure {
            precondition(pass < batches.count, "add more pre-built batches")
            let batch = batches[pass]
            pass += 1
            let start = Date()
            for message in batch {
                _ = fixture.viewModel.formatMessageAsText(message, colorScheme: .dark)
            }
            samples.append(Date().timeIntervalSince(start))
        }

        reportThroughput("geochat.formatMessage", samples: samples, operations: batchSize, unit: "messages")
    }

    // MARK: - Hex encoding

    /// Nostr public keys are hex-encoded on roster and formatting paths.
    func testHexEncodePublicKeys() {
        let keys: [Data] = (0..<1_000).map { index in
            Data((0..<32).map { UInt8(truncatingIfNeeded: index &* 31 &+ $0) })
        }
        let rounds = 10
        var samples: [TimeInterval] = []

        measure {
            let start = Date()
            var characters = 0
            for _ in 0..<rounds {
                for key in keys {
                    characters += key.hexEncodedString().utf8.count
                }
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertEqual(characters, rounds * keys.count * 64)
        }

        reportThroughput("hex.encodePublicKey", samples: samples, operations: rounds * keys.count, unit: "keys")
    }
}

/// A real `ChatViewModel` in a geohash channel with `participants` people
/// present, each nicknamed the way inbound events nickname them.
@MainActor
private final class GeochatPerfFixture {
    static let geohash = "u4pruyd"

    let viewModel: ChatViewModel
    let pubkeys: [String]

    init(participants: Int) {
        let keychain = MockKeychain()
        let locationSuite = "PerformanceBaselineTests.geochat.\(UUID().uuidString)"
        let locationStorage = UserDefaults(suiteName: locationSuite) ?? .standard
        locationStorage.removePersistentDomain(forName: locationSuite)
        viewModel = ChatViewModel(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain),
            transport: MockTransport(),
            conversations: ConversationStore(),
            locationManager: LocationChannelManager(storage: locationStorage)
        )

        // The view model delivers its initial (mesh) channel asynchronously,
        // which clears the tracker's active geohash. Let startup settle
        // before seeding the room so it can't empty mid-benchmark.
        Self.drainMainQueue()

        // In the channel the way a channel switch leaves the view model, so
        // display names and colors take their real paths (which compare
        // against our own key for this geohash).
        viewModel.activeChannel = .location(GeohashChannel(level: .neighborhood, geohash: Self.geohash))
        viewModel.currentGeohash = Self.geohash
        let tracker = viewModel.participantTracker
        tracker.setActiveGeohash(Self.geohash)
        pubkeys = (0..<participants).map { String(format: "%064x", 0x6E0_0000 + $0) }
        for (index, pubkey) in pubkeys.enumerated() {
            viewModel.setGeoNickname("peer\(index)", forPubkey: pubkey)
            tracker.recordParticipant(pubkeyHex: pubkey, geohash: Self.geohash)
        }
    }

    /// Runs the main run loop until it has been idle for a few polls.
    private static func drainMainQueue() {
        var idlePolls = 0
        let deadline = Date().addingTimeInterval(10)
        while idlePolls < 3, Date() < deadline {
            if CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.001, true) == .handledSource {
                idlePolls = 0
            } else {
                idlePolls += 1
            }
        }
    }
}
