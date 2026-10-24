//
// BLEAnnounceIdentityPersistenceTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// Identity-cache writes caused by verified announces, through the real
/// `BLEAnnounceHandler`, a real `SecureIdentityStateManager` and the body of
/// BLEService's `persistIdentity` closure.
///
/// `@MainActor` keeps the manager's blocking `queue.sync` off the Swift
/// Concurrency cooperative pool (see SecureIdentityStateManagerVouchTests).
@MainActor
struct BLEAnnounceIdentityPersistenceTests {
    private static let cacheKey = "bitchat.identityCache.v2"

    @Test
    func repeatedVerifiedAnnouncesRewriteIdentityCacheOnlyOnChange() throws {
        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let noisePublicKey = signer.getStaticPublicKeyData()
        let peerID = PeerID(publicKey: noisePublicKey)
        let keychain = MockKeychain()
        let manager = SecureIdentityStateManager(keychain)
        let now = Date()
        let handler = makeHandler(manager: manager, signer: signer, now: now)

        func announce(nickname: String, secondsAgo: Int) throws -> BitchatPacket {
            let announcement = AnnouncementPacket(
                nickname: nickname,
                noisePublicKey: noisePublicKey,
                signingPublicKey: signer.getSigningPublicKeyData(),
                directNeighbors: nil
            )
            let packet = BitchatPacket(
                type: MessageType.announce.rawValue,
                senderID: Data(hexString: peerID.id) ?? Data(),
                recipientID: nil,
                timestamp: UInt64(now.addingTimeInterval(TimeInterval(-secondsAgo)).timeIntervalSince1970 * 1000),
                payload: try #require(announcement.encode()),
                signature: nil,
                ttl: TransportConfig.messageTTLDefault
            )
            return try #require(signer.signPacket(packet))
        }

        // Fifty periodic re-announces of an unchanged peer: one first-contact
        // write, then none.
        for index in 0..<50 {
            let result = handler.handle(try announce(nickname: "alice", secondsAgo: 500 - index * 10), from: peerID)
            #expect(result?.isVerified == true)
        }
        #expect(keychain.identityKeySaveCounts[Self.cacheKey] == 1)

        // A rename is a real change.
        handler.handle(try announce(nickname: "alice-renamed", secondsAgo: 0), from: peerID)
        #expect(keychain.identityKeySaveCounts[Self.cacheKey] == 2)
        #expect(manager.getSocialIdentity(for: noisePublicKey.sha256Fingerprint())?.claimedNickname == "alice-renamed")
    }

    private func makeHandler(
        manager: SecureIdentityStateManager,
        signer: NoiseEncryptionService,
        now: Date
    ) -> BLEAnnounceHandler {
        final class RegistryBox {
            var registry = BLEPeerRegistry()
        }
        let box = RegistryBox()
        return BLEAnnounceHandler(environment: BLEAnnounceHandlerEnvironment(
            localPeerID: { PeerID(str: "0102030405060708") },
            messageTTL: TransportConfig.messageTTLDefault,
            now: { now },
            existingPeerKeys: { peerID in
                let info = box.registry.info(for: peerID)
                return (info?.noisePublicKey, info?.signingPublicKey)
            },
            persistedSigningPublicKey: { peerID in
                manager.getCryptoIdentitiesByPeerIDPrefix(peerID)
                    .compactMap { $0.signingPublicKey }
                    .first
            },
            authenticatedSigningPublicKey: { noisePublicKey in
                manager.authenticatedSigningPublicKey(forFingerprint: noisePublicKey.sha256Fingerprint())
            },
            verifySignature: { packet, signingPublicKey in
                signer.verifyPacketSignature(packet, publicKey: signingPublicKey)
            },
            linkState: { _ in (hasPeripheral: true, hasCentral: false) },
            linkBoundToOtherPeer: { _, _ in false },
            withRegistryBarrier: { body in body() },
            upsertVerifiedAnnounce: { peerID, announcement, isConnected, now in
                box.registry.upsertVerifiedAnnounce(
                    peerID: peerID,
                    nickname: announcement.nickname,
                    noisePublicKey: announcement.noisePublicKey,
                    signingPublicKey: announcement.signingPublicKey,
                    isConnected: isConnected,
                    now: now
                )
            },
            shouldEmitReconnectLog: { _, _ in false },
            updateTopology: { _, _ in },
            // Verbatim body of BLEService's persistIdentity closure.
            persistIdentity: { announcement in
                manager.upsertCryptographicIdentity(
                    fingerprint: announcement.noisePublicKey.sha256Fingerprint(),
                    noisePublicKey: announcement.noisePublicKey,
                    signingPublicKey: announcement.signingPublicKey,
                    claimedNickname: announcement.nickname
                )
            },
            dedupContains: { _ in true },
            dedupMarkProcessed: { _ in },
            deliverAnnounceUIEvents: { _, _, _ in },
            trackPacketSeen: { _ in },
            sendAnnounceBack: {},
            scheduleAfterglow: { _ in }
        ))
    }
}
