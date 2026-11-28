//
// Phase3FeedTests.swift
// bitchatTests
//
// Coverage for Phase 3:
// - BLE Gateway uplink/downlink for kind-1 Place Feed posts & kind-7 reactions
// - LocalWebOfTrustService bridging verified + VouchAttestation -> .vouched filter
// - NIP-92 imeta tag encoding/parsing & BUD-02 Blossom upload auth + Tor fail-closed upload/download + SHA-256 verification
// - 3D Globe live spatial activity beacon builder
//

import BitFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import bitchat

@MainActor
struct Phase3FeedTests {

    @Test
    func gatewayBridgesKind1PostAndKind7ReactionAndRejectsMetadata() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let suite = "Phase3Gateway-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        var published: [(NostrEvent, String)] = []
        var injectedFeed: [(NostrEvent, String)] = []
        var broadcasted: [Data] = []

        let gateway = GatewayService(defaults: defaults, now: { now })
        gateway.setEnabled(true)
        gateway.relaysConnected = { true }
        gateway.publishToRelays = { event, gh in published.append((event, gh)) }
        gateway.injectFeedInbound = { event, gh in injectedFeed.append((event, gh)) }
        gateway.broadcastToMesh = { broadcasted.append($0) }

        let sender = try NostrIdentity.generate()
        let depositor = PeerID(str: "0123456789abcdef")

        // 1. Uplink deposit of kind-1 Place Feed note succeeds and injects into feed
        let post = try NostrProtocol.createGeohashTextNote(
            content: "offline mesh dispatch",
            geohash: "9q8yy",
            senderIdentity: sender,
            nickname: "scout",
            createdAt: now
        )
        let postCarrier = try #require(NostrCarrierPacket(direction: .toGateway, geohash: "9q8yy", event: post)?.encode())
        gateway.handleMeshCarrier(postCarrier, from: depositor, directedToUs: true)

        #expect(published.count == 1)
        #expect(published[0].0.id == post.id)
        #expect(injectedFeed.count == 1)
        #expect(injectedFeed[0].0.id == post.id)

        // 2. Uplink deposit of kind-7 NIP-25 reaction also bridges cleanly
        let reaction = try NostrProtocol.createGeohashReactionEvent(
            emoji: "🔥",
            targetEventID: post.id,
            targetAuthorPubkey: sender.publicKeyHex,
            geohash: "9q8yy",
            senderIdentity: sender,
            createdAt: now
        )
        let reactCarrier = try #require(NostrCarrierPacket(direction: .toGateway, geohash: "9q8yy", event: reaction)?.encode())
        gateway.handleMeshCarrier(reactCarrier, from: depositor, directedToUs: true)
        #expect(published.count == 2)
        #expect(injectedFeed.count == 2)

        // 3. Downlink rebroadcast of a remote relay kind-1 post broadcasts on BLE
        let remoteAuthor = try NostrIdentity.generate()
        let remotePost = try NostrProtocol.createGeohashTextNote(
            content: "from internet relay",
            geohash: "9q8yy",
            senderIdentity: remoteAuthor,
            createdAt: now
        )
        gateway.rebroadcastRelayEvent(remotePost, geohash: "9q8yy")
        #expect(broadcasted.count == 1)

        // 4. Receiver injects downlinked kind-1 carrier into LocationNotesPool manager
        let rxDeps = LocationNotesDependencies(
            relayLookup: { _, _ in [] },
            subscribe: { _, _, _, _, _ in },
            unsubscribe: { _ in },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in try NostrIdentity.generate() },
            now: { now }
        )
        let manager = LocationNotesManager(geohash: "9q8yy", dependencies: rxDeps)
        let rxGateway = GatewayService(defaults: defaults, now: { now })
        rxGateway.injectFeedInbound = { event, _ in manager.ingestCarriedEvent(event) }
        rxGateway.handleMeshCarrier(broadcasted[0], from: depositor, directedToUs: false)
        #expect(manager.notes.map(\.id) == [remotePost.id])
    }

    @Test
    func offlineLocationNotesManagerUplinksKind1ViaMeshGateway() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var uplinked: [(NostrEvent, String)] = []

        var deps = LocationNotesDependencies(
            relayLookup: { _, _ in [] },
            subscribe: { _, _, _, _, _ in },
            unsubscribe: { _ in },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in try NostrIdentity.generate() },
            now: { now }
        )
        deps.anyRelayConnected = { _ in false }
        deps.uplinkViaMesh = { event, gh in
            uplinked.append((event, gh))
            return true
        }

        let manager = LocationNotesManager(geohash: "9q8yy", dependencies: deps)
        #expect(manager.sendFeedPost(content: "sent over BLE gateway", nickname: "meshuser"))

        #expect(uplinked.count == 1)
        #expect(uplinked[0].1 == "9q8yy")
        #expect(manager.notes.first?.content == "sent over BLE gateway")
    }

    @Test
    func localWebOfTrustResolvesVerifiedVouchedAndFiltersFeed() {
        let verifiedNoise = Data(repeating: 0xAA, count: 32)
        let vouchedNoise = Data(repeating: 0xBB, count: 32)
        let strangerPubkey = String(repeating: "3", count: 64)
        let verifiedPubkey = String(repeating: "1", count: 64)
        let vouchedPubkey = String(repeating: "2", count: 64)

        let wot = LocalWebOfTrustService(
            noiseKeyLookup: { pubkey in
                if pubkey == verifiedPubkey { return verifiedNoise }
                if pubkey == vouchedPubkey { return vouchedNoise }
                return nil
            },
            isVerifiedFingerprint: { $0 == verifiedNoise.sha256Fingerprint() },
            validVoucherCount: { $0 == vouchedNoise.sha256Fingerprint() ? 2 : 0 }
        )

        #expect(wot.trust(forNostrPubkey: verifiedPubkey) == .verified)
        #expect(wot.trust(forNostrPubkey: vouchedPubkey) == .vouched(voucherCount: 2))
        #expect(wot.trust(forNostrPubkey: strangerPubkey) == .none)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [
            NoticeItem(note: .init(id: "1", pubkey: verifiedPubkey, content: "verified post", createdAt: now, nickname: "v", geohash: "9q8yy")),
            NoticeItem(note: .init(id: "2", pubkey: vouchedPubkey, content: "vouched post", createdAt: now.addingTimeInterval(-10), nickname: "w", geohash: "9q8yy")),
            NoticeItem(note: .init(id: "3", pubkey: strangerPubkey, content: "stranger post", createdAt: now.addingTimeInterval(-20), nickname: "s", geohash: "9q8yy"))
        ]

        let vouchedOnly = PlaceFeedOrganizer.organize(
            items: items,
            sort: .latest,
            filter: .vouched,
            isVouched: { item in
                guard let note = item.nostrNote else { return false }
                return wot.isTrustedAuthor(note.pubkey)
            }
        )
        #expect(vouchedOnly.map(\.id) == ["1", "2"])
    }

    @Test
    func blossomImetaAuthUploadDownloadVerifiesSha256AndFailsClosedOnTor() async throws {
        // Build a tiny valid 4x4 PNG in memory
        let sampleImageData = try makeTinyPNGData()
        let identity = try NostrIdentity.generate()

        // 1. NIP-92 imeta tag round-trip & security rejections (http/localhost/missing hash)
        let validHash = String(repeating: "a", count: 64)
        let validURL = try #require(URL(string: "https://blossom.example.com/\(validHash).jpg"))
        let attachment = NostrProtocol.MediaAttachment(
            url: validURL,
            mimeType: "image/jpeg",
            sha256Hex: validHash,
            sizeBytes: 1234,
            dimensions: "4x4"
        )
        let parsed = NostrProtocol.parseMediaAttachments(from: [
            NostrProtocol.imetaTag(for: attachment),
            ["imeta", "url http://insecure.example.com/x.jpg", "m image/jpeg", "x \(validHash)"],
            ["imeta", "url https://localhost/x.jpg", "m image/jpeg", "x \(String(repeating: "b", count: 64))"]
        ])
        #expect(parsed == [attachment])

        // 2. Fail-closed when Tor is not ready
        let torBlockedService = BlossomMediaService(
            defaults: UserDefaults(suiteName: "BlossomTor-\(UUID().uuidString)")!,
            dependencies: .init(
                awaitTorReady: { false },
                isNetworkActivationAllowed: { true },
                performRequest: { _, _ in (Data(), 200) },
                now: Date.init
            )
        )
        await #expect(throws: BlossomMediaError.torNotReady) {
            _ = try await torBlockedService.uploadImage(rawData: sampleImageData, senderIdentity: identity)
        }

        // 3. Full upload -> download round-trip with BUD-02 auth header & SHA-256 verification
        final class MockBlossomStore: @unchecked Sendable {
            private let lock = NSLock()
            private var blob = Data()
            private var authHeader: String?

            func store(blob: Data, authHeader: String?) -> String {
                lock.lock()
                defer { lock.unlock() }
                self.blob = blob
                self.authHeader = authHeader
                return blob.sha256Fingerprint()
            }

            func loadBlob() -> Data {
                lock.lock()
                defer { lock.unlock() }
                return blob
            }

            func loadAuthHeader() -> String? {
                lock.lock()
                defer { lock.unlock() }
                return authHeader
            }
        }
        let store = MockBlossomStore()
        let service = BlossomMediaService(
            defaults: UserDefaults(suiteName: "BlossomOK-\(UUID().uuidString)")!,
            dependencies: .init(
                awaitTorReady: { true },
                isNetworkActivationAllowed: { true },
                performRequest: { request, _ in
                    if request.httpMethod == "PUT" {
                        let hash = store.store(
                            blob: request.httpBody ?? Data(),
                            authHeader: request.value(forHTTPHeaderField: "Authorization")
                        )
                        let json = #"{"url":"https://blossom.example.com/\#(hash).jpg","sha256":"\#(hash)"}"#
                        return (Data(json.utf8), 200)
                    } else {
                        return (store.loadBlob(), 200)
                    }
                },
                now: Date.init
            )
        )

        let uploaded = try await service.uploadImage(rawData: sampleImageData, senderIdentity: identity)
        #expect(store.loadAuthHeader()?.hasPrefix("Nostr ") == true)
        #expect(uploaded.sha256Hex == store.loadBlob().sha256Fingerprint())

        let downloadedImage = try await service.fetchVerifiedImage(for: uploaded)
        #expect(downloadedImage.size.width > 0)
        #expect(service.cachedImage(for: uploaded.sha256Hex) != nil)

        // Panic wipe evicts cached verified media
        service.resetForPanic()
        #expect(service.cachedImage(for: uploaded.sha256Hex) == nil)

        // Tampered blob bytes fail SHA-256 verification
        let tamperedService = BlossomMediaService(
            defaults: UserDefaults(suiteName: "BlossomTamper-\(UUID().uuidString)")!,
            dependencies: .init(
                awaitTorReady: { true },
                isNetworkActivationAllowed: { true },
                performRequest: { _, _ in (Data("tampered".utf8), 200) },
                now: Date.init
            )
        )
        await #expect(throws: BlossomMediaError.hashMismatch) {
            _ = try await tamperedService.fetchVerifiedImage(for: uploaded)
        }
    }

    @Test
    func globeActivityBeaconsCombineChatNotesAndBookmarks() {
        let beacons = GlobeActivityBeacon.buildBeacons(
            chatCounts: ["9q8yy": 5, "u4pru": 2],
            noteCounts: ["9q8yy": 3],
            bookmarks: ["9q8yy", "xn76u"]
        )

        #expect(beacons.count == 3)
        #expect(beacons[0].geohash == "9q8yy")
        #expect(beacons[0].activityCount == 8)
        #expect(beacons[0].isBookmarked)
        #expect(beacons.first(where: { $0.geohash == "xn76u" })?.isBookmarked == true)
        #expect(beacons.first(where: { $0.geohash == "xn76u" })?.activityCount == 0)
    }

    private func makeTinyPNGData() throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = ctx.makeImage() else {
            throw BlossomMediaError.invalidImage
        }
        let mutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutable, UTType.png.identifier as CFString, 1, nil) else {
            throw BlossomMediaError.invalidImage
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw BlossomMediaError.invalidImage
        }
        return mutable as Data
    }
}
