import BitFoundation
import Foundation
import CryptoKit
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import bitchat

@Suite(.serialized)
@MainActor
struct PanicMetadataStoreTests {
    enum Store: CaseIterable { case groups, board, courier, gossip, bridge, events }

    @Test(arguments: Store.allCases)
    func deletionFailureIsReportedAndRetryPreservesSibling(_ store: Store) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { _ = chmod(root.path, 0o700); try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("metadata.json")
        let sibling = root.appendingPathComponent("keep.txt")
        let wipe: () -> Bool
        switch store {
        case .groups:
            let owner = GroupStore(keychain: MockKeychain(), fileURL: file)
            wipe = { owner.wipe() }
        case .board:
            let owner = BoardStore(fileURL: file)
            wipe = { owner.wipe() }
        case .courier:
            let owner = CourierStore(fileURL: file)
            wipe = { owner.wipe() }
        case .gossip:
            let owner = GossipMessageArchive(fileURL: file)
            wipe = { owner.wipe() }
        case .bridge:
            let owner = BridgeDropDedupStore(fileURL: file)
            wipe = { owner.wipe() }
        case .events:
            let owner = NostrProcessedEventStore(fileURL: file)
            wipe = { owner.wipe() }
        }
        // Deletion is independent of record decoding; producer/reload coverage is separate.
        let bytes = Data("SYNTHETIC_METADATA_DELETE_UNIT_FIXTURE".utf8)
        try bytes.write(to: file)
        try Data("KEEP".utf8).write(to: sibling)
        #expect(chmod(root.path, 0o500) == 0)
        #expect(!wipe(), "A denied metadata deletion must be reported")
        #expect(try Data(contentsOf: file) == bytes)
        #expect(chmod(root.path, 0o700) == 0)
        #expect(wipe(), "Metadata deletion must succeed after access is restored")
        #expect(!fm.fileExists(atPath: file.path))
        #expect(fm.fileExists(atPath: sibling.path), "Unrelated metadata sibling must survive")
        if fm.fileExists(atPath: sibling.path) {
            #expect(try Data(contentsOf: sibling) == Data("KEEP".utf8))
        }
        #expect(wipe(), "An absent metadata file must be harmless")
    }

    private func makeWipe(
        _ store: Store,
        fileURL: URL? = nil,
        persistsToDisk: Bool = true,
        resolve: @escaping () -> URL?
    ) -> () -> Bool {
        switch store {
        case .groups:
            let owner = GroupStore(keychain: MockKeychain(), persistsToDisk: persistsToDisk,
                                   fileURL: fileURL, resolveDefaultFileURL: resolve)
            return { owner.wipe() }
        case .board:
            let owner = BoardStore(persistsToDisk: persistsToDisk, fileURL: fileURL,
                                   resolveDefaultFileURL: resolve)
            return { owner.wipe() }
        case .courier:
            let owner = CourierStore(persistsToDisk: persistsToDisk, fileURL: fileURL,
                                     resolveDefaultFileURL: resolve)
            return { owner.wipe() }
        case .gossip:
            let owner = GossipMessageArchive(fileURL: fileURL, resolveDefaultFileURL: resolve)
            return { owner.wipe() }
        case .bridge:
            let owner = BridgeDropDedupStore(persistsToDisk: persistsToDisk, fileURL: fileURL,
                                            resolveDefaultFileURL: resolve)
            return { owner.wipe() }
        case .events:
            let owner = NostrProcessedEventStore(fileURL: fileURL, resolveDefaultFileURL: resolve)
            return { owner.wipe() }
        }
    }

    @Test(arguments: Store.allCases)
    func unresolvedLocationFailsAndSameOwnerRetries(_ store: Store) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("metadata.json")
        let sibling = root.appendingPathComponent("keep.txt")
        let bytes = Data("SYNTHETIC_UNRESOLVED_METADATA".utf8)
        try bytes.write(to: file)
        try Data("KEEP".utf8).write(to: sibling)
        var resolvedURL: URL?
        var lookups = 0
        let wipe = makeWipe(store) { lookups += 1; return resolvedURL }
        #expect(!wipe(), "An unresolved persistent location must not count as deleted")
        #expect(try Data(contentsOf: file) == bytes)
        let failedLookups = lookups
        resolvedURL = file
        #expect(wipe(), "The same store must retry a failed location lookup")
        #expect(lookups > failedLookups)
        #expect(!fm.fileExists(atPath: file.path), "Recovered lookup must delete the retained metadata")
        #expect(try Data(contentsOf: sibling) == Data("KEEP".utf8))
        let recoveredLookups = lookups
        resolvedURL = nil
        #expect(wipe(), "A recovered, now absent location must remain harmless")
        #expect(lookups == recoveredLookups, "A recovered location must be retained")
    }

    @Test(arguments: Store.allCases)
    func explicitLocationBypassesDefaultLookup(_ store: Store) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("metadata.json")
        var lookups = 0
        let wipe = makeWipe(store, fileURL: file) { lookups += 1; return nil }
        try Data("SYNTHETIC_EXPLICIT_METADATA".utf8).write(to: file)
        #expect(wipe())
        #expect(!fm.fileExists(atPath: file.path))
        #expect(wipe(), "An explicitly located missing file must be harmless")
        #expect(lookups == 0, "Explicit locations must bypass default lookup")
    }

    @Test(arguments: [Store.groups, .board, .courier, .bridge])
    func memoryOnlyStoreNeitherResolvesNorDeletes(_ store: Store) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("keep.json")
        let bytes = Data("SYNTHETIC_UNOWNED_FILE".utf8)
        try bytes.write(to: file)
        var lookups = 0
        let wipe = makeWipe(store, fileURL: file, persistsToDisk: false) { lookups += 1; return file }
        #expect(wipe(), "An intentionally memory-only store has no persistent cleanup")
        #expect(fm.fileExists(atPath: file.path), "Memory-only cleanup must preserve supplied files")
        if fm.fileExists(atPath: file.path) { #expect(try Data(contentsOf: file) == bytes) }
        let wipeWithoutOverride = makeWipe(store, persistsToDisk: false) { lookups += 1; return file }
        #expect(wipeWithoutOverride())
        #expect(lookups == 0, "Memory-only stores must not resolve a persistent location")
        #expect(fm.fileExists(atPath: file.path))
        if fm.fileExists(atPath: file.path) { #expect(try Data(contentsOf: file) == bytes) }
    }

    @Test
    func defaultGossipWipeReportsUnresolvedLocationAndRetries() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("archive.json")
        let sibling = root.appendingPathComponent("keep.txt")
        let bytes = Data("SYNTHETIC_DEFAULT_ARCHIVE".utf8)
        try bytes.write(to: file)
        try Data("KEEP".utf8).write(to: sibling)
        #expect(!GossipMessageArchive.wipeDefault(resolveDefaultFileURL: { nil }),
                "Default archive cleanup must report failed lookup")
        #expect(try Data(contentsOf: file) == bytes)
        #expect(GossipMessageArchive.wipeDefault(resolveDefaultFileURL: { file }))
        #expect(!fm.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: sibling) == Data("KEEP".utf8))
        #expect(GossipMessageArchive.wipeDefault(resolveDefaultFileURL: { file }))
    }

    @Test(arguments: Store.allCases)
    func recoveredLocationSupportsSameOwnerPersistence(_ store: Store) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("metadata.json")
        var resolvedURL: URL?
        let resolve = { resolvedURL }
        let wipe: () -> Bool
        let saveAndReload: () throws -> Void
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        switch store {
        case .groups:
            let keychain = MockKeychain()
            let owner = GroupStore(keychain: keychain, resolveDefaultFileURL: resolve)
            wipe = { owner.wipe() }
            saveAndReload = {
                let member = GroupMember(fingerprint: Data(repeating: 1, count: 32).hexEncodedString(),
                                         signingKey: Data(repeating: 2, count: 32), nickname: "synthetic")
                let group = try #require(owner.createGroup(named: "synthetic", creator: member))
                let reloaded = GroupStore(keychain: keychain, fileURL: file)
                #expect(reloaded.group(withID: group.groupID) == group)
            }
        case .board:
            let owner = BoardStore(now: { now }, resolveDefaultFileURL: resolve)
            wipe = { owner.wipe() }
            saveAndReload = {
                let author = Curve25519.Signing.PrivateKey()
                let postID = Data(repeating: 3, count: 16)
                let created = UInt64(now.timeIntervalSince1970 * 1000)
                let expires = created + 3_600_000
                let key = author.publicKey.rawRepresentation
                let signingBytes = BoardPostPacket.signingBytes(
                    postID: postID, geohash: "9q8yy", content: "synthetic", authorSigningKey: key,
                    authorNickname: "synthetic", createdAt: created, expiresAt: expires, flags: 0)
                let post = BoardPostPacket(
                    postID: postID, geohash: "9q8yy", content: "synthetic", authorSigningKey: key,
                    authorNickname: "synthetic", createdAt: created, expiresAt: expires, flags: 0,
                    signature: try author.signature(for: signingBytes))
                let wire = BoardWire.post(post)
                let packet = BitchatPacket(type: MessageType.boardPost.rawValue,
                                          senderID: Data(repeating: 4, count: 8), recipientID: nil,
                                          timestamp: created, payload: wire.encode(), signature: nil, ttl: 1)
                #expect(owner.ingest(wire, packet: packet) == .accepted)
                let reloaded = BoardStore(fileURL: file, now: { now })
                #expect(reloaded.posts(forGeohash: "9q8yy").map(\.postID) == [postID])
            }
        case .courier:
            let owner = CourierStore(now: { now }, resolveDefaultFileURL: resolve)
            wipe = { owner.wipe() }
            saveAndReload = {
                let recipient = Data(repeating: 5, count: 32)
                let envelope = CourierEnvelope(
                    recipientTag: CourierEnvelope.recipientTag(
                        noiseStaticKey: recipient, epochDay: CourierEnvelope.epochDay(for: now)),
                    expiry: UInt64((now.timeIntervalSince1970 + 3600) * 1000),
                    ciphertext: Data(repeating: 6, count: 96))
                #expect(owner.deposit(envelope, from: Data(repeating: 7, count: 32)))
                let reloaded = CourierStore(fileURL: file, now: { now })
                #expect(reloaded.takeEnvelopes(for: recipient) == [envelope])
            }
        case .gossip:
            let owner = GossipMessageArchive(resolveDefaultFileURL: resolve)
            wipe = { owner.wipe() }
            saveAndReload = {
                let packet = BitchatPacket(type: MessageType.message.rawValue,
                                          senderID: Data(repeating: 8, count: 8), recipientID: nil,
                                          timestamp: UInt64(now.timeIntervalSince1970 * 1000),
                                          payload: Data("SYNTHETIC_PUBLIC_PACKET".utf8), signature: nil, ttl: 1)
                let encoded = try #require(packet.toBinaryData(padding: false))
                owner.save([encoded])
                #expect(GossipMessageArchive(fileURL: file).load() == [encoded])
            }
        case .bridge:
            let owner = BridgeDropDedupStore(resolveDefaultFileURL: resolve)
            wipe = { owner.wipe() }
            saveAndReload = {
                owner.save(BridgeDropDedupStore.Snapshot(
                    publishedDropKeys: ["synthetic-drop": now], seenDropEventIDs: ["synthetic-event": now]))
                let reloaded = BridgeDropDedupStore(fileURL: file).load()
                #expect(reloaded.publishedDropKeys == ["synthetic-drop": now])
                #expect(reloaded.seenDropEventIDs == ["synthetic-event": now])
            }
        case .events:
            let owner = NostrProcessedEventStore(resolveDefaultFileURL: resolve)
            wipe = { owner.wipe() }
            saveAndReload = {
                let eventID = String(repeating: "a", count: 64)
                owner.append([eventID], cap: 10)
                // load fences the serial append before a fresh owner reads the file.
                #expect(owner.load() == [eventID])
                #expect(NostrProcessedEventStore(fileURL: file).load() == [eventID])
            }
        }
        #expect(!wipe())
        resolvedURL = file
        #expect(wipe())
        resolvedURL = nil
        try saveAndReload()
    }

    @Test(arguments: [false, true])
    func panicRetirementPreventsPersistenceAndOrdinaryStopPreservesIt(_ retire: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("archive.json")
        let archive = GossipMessageArchive(fileURL: file)
        let sender = PeerID(str: "1122334455667788")
        let packet = BitchatPacket(type: MessageType.message.rawValue,
                                   senderID: Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]),
                                   recipientID: nil,
                                   timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                                   payload: Data("SYNTHETIC_PUBLIC_PACKET".utf8), signature: nil, ttl: 1)
        let encoded = try #require(packet.toBinaryData(padding: false))
        archive.save([encoded])
        let manager = GossipSyncManager(myPeerID: sender, requestSyncManager: RequestSyncManager(), archive: archive)
        #expect(manager._messageCount(for: sender) == 1)
        if retire { manager.stopForPanic() } else { manager.stop(); manager.start() }
        defer { manager.stop() }
        #expect(archive.wipe())
        manager.persistNow()
        _ = manager._messageCount(for: sender)
        #expect(fm.fileExists(atPath: file.path) == !retire,
                "A retired owner must not save; ordinary stop/start must retain persistence")
    }
}
