//
// BLEServiceCoreTests.swift
// bitchatTests
//
// Focused BLEService tests for packet handling behavior.
//

import Testing
import Foundation
import CoreBluetooth
@testable import bitchat

struct BLEServiceCoreTests {

    @Test
    func duplicatePacket_isDeduped() async throws {
        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let sender = PeerID(publicKey: signer.getStaticPublicKeyData())
        let identityManager = TrackingIdentityManager()
        identityManager.seedVerifiedIdentity(
            noisePublicKey: signer.getStaticPublicKeyData(),
            signingPublicKey: signer.getSigningPublicKeyData(),
            claimedNickname: "HelloPeer"
        )
        let ble = makeService(identityManager: identityManager)
        let delegate = PublicCaptureDelegate()
        ble.delegate = delegate

        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let packet = try makeSignedPublicPacket(content: "Hello", sender: sender, signer: signer, timestamp: timestamp)

        ble._test_handlePacket(packet, fromPeerID: sender, preseedPeer: false)
        let receivedFirst = await TestHelpers.waitUntil(
            { delegate.publicMessagesSnapshot().count == 1 },
            timeout: TestConstants.defaultTimeout
        )
        #expect(receivedFirst)

        ble._test_handlePacket(packet, fromPeerID: sender, preseedPeer: false)
        let receivedDuplicate = await TestHelpers.waitUntil(
            { delegate.publicMessagesSnapshot().count > 1 },
            timeout: TestConstants.shortTimeout
        )
        #expect(!receivedDuplicate)

        let messages = delegate.publicMessagesSnapshot()
        #expect(messages.count == 1)
        #expect(messages.first?.content == "Hello")
    }

    @Test
    func staleBroadcast_isIgnored() async {
        let ble = makeService()
        let delegate = PublicCaptureDelegate()
        ble.delegate = delegate

        let sender = PeerID(str: "A1B2C3D4E5F60708")
        let oldTimestamp = UInt64(Date().addingTimeInterval(-901).timeIntervalSince1970 * 1000)
        let packet = makePublicPacket(content: "Old", sender: sender, timestamp: oldTimestamp)

        ble._test_handlePacket(packet, fromPeerID: sender)

        let didReceive = await TestHelpers.waitUntil({ !delegate.publicMessagesSnapshot().isEmpty }, timeout: 0.3)
        #expect(!didReceive)
        #expect(delegate.publicMessagesSnapshot().isEmpty)
    }

    @Test
    func announceSenderMismatch_isRejected() async throws {
        let ble = makeService()

        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "Spoof",
            noisePublicKey: signer.getStaticPublicKeyData(),
            signingPublicKey: signer.getSigningPublicKeyData(),
            directNeighbors: nil
        )
        let payload = try #require(announcement.encode(), "Failed to encode announcement")

        let derivedPeerID = PeerID(publicKey: announcement.noisePublicKey)
        let wrongFirst = derivedPeerID.bare.first == "0" ? "1" : "0"
        let wrongBare = String(wrongFirst) + String(derivedPeerID.bare.dropFirst())
        let wrongPeerID = PeerID(str: wrongBare)
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: wrongPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )
        let signed = try #require(signer.signPacket(packet), "Failed to sign announce packet")

        ble._test_handlePacket(signed, fromPeerID: wrongPeerID, preseedPeer: false)

        _ = await TestHelpers.waitUntil({ !ble.currentPeerSnapshots().isEmpty }, timeout: 0.3)
        #expect(ble.currentPeerSnapshots().isEmpty)
    }

    @Test
    func firstContactSignedAnnounce_isDiscoverableButNotTrusted() async throws {
        let identityManager = TrackingIdentityManager()
        let ble = makeService(identityManager: identityManager)
        let delegate = PublicCaptureDelegate()
        ble.delegate = delegate

        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let announce = try makeSignedAnnouncementPacket(signer: signer, nickname: "Mallory")

        ble._test_handlePacket(announce.packet, fromPeerID: announce.peerID, preseedPeer: false)

        let sawPeer = await TestHelpers.waitUntil(
            { ble.currentPeerSnapshots().contains(where: { $0.peerID == announce.peerID && $0.nickname == "Mallory" }) },
            timeout: TestConstants.defaultTimeout
        )
        #expect(sawPeer)
        #expect(identityManager.upsertedFingerprints.isEmpty)

        let forgedMessage = makePublicPacket(
            content: "forged",
            sender: announce.peerID,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        ble._test_handlePacket(forgedMessage, fromPeerID: announce.peerID, preseedPeer: false)

        let acceptedUnsignedMessage = await TestHelpers.waitUntil(
            { !delegate.publicMessagesSnapshot().isEmpty },
            timeout: TestConstants.shortTimeout
        )
        #expect(!acceptedUnsignedMessage)
    }

    @Test
    func persistedVerifiedIdentity_canAuthenticateReturningAnnounce() async throws {
        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let peerID = PeerID(publicKey: signer.getStaticPublicKeyData())
        let identityManager = TrackingIdentityManager()
        identityManager.seedVerifiedIdentity(
            noisePublicKey: signer.getStaticPublicKeyData(),
            signingPublicKey: signer.getSigningPublicKeyData(),
            claimedNickname: "Alice"
        )

        let ble = makeService(identityManager: identityManager)
        let delegate = PublicCaptureDelegate()
        ble.delegate = delegate

        let announce = try makeSignedAnnouncementPacket(signer: signer, nickname: "Alice")
        ble._test_handlePacket(announce.packet, fromPeerID: peerID, preseedPeer: false)

        let acceptedAnnounce = await TestHelpers.waitUntil(
            { ble.currentPeerSnapshots().contains(where: { $0.peerID == peerID && $0.nickname == "Alice" }) },
            timeout: TestConstants.defaultTimeout
        )
        #expect(acceptedAnnounce)
        #expect(identityManager.upsertedFingerprints == [signer.getStaticPublicKeyData().sha256Fingerprint()])

        let unsignedPublicPacket = makePublicPacket(
            content: "trusted",
            sender: peerID,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        ble._test_handlePacket(unsignedPublicPacket, fromPeerID: peerID, preseedPeer: false)

        let acceptedUnsignedMessage = await TestHelpers.waitUntil(
            { delegate.publicMessagesSnapshot().contains(where: { $0.content == "trusted" && $0.senderPeerID == peerID }) },
            timeout: TestConstants.shortTimeout
        )
        #expect(!acceptedUnsignedMessage)

        let signedPublicPacket = try makeSignedPublicPacket(
            content: "trusted",
            sender: peerID,
            signer: signer,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        ble._test_handlePacket(signedPublicPacket, fromPeerID: peerID, preseedPeer: false)

        let acceptedSignedMessage = await TestHelpers.waitUntil(
            { delegate.publicMessagesSnapshot().contains(where: { $0.content == "trusted" && $0.senderPeerID == peerID }) },
            timeout: TestConstants.defaultTimeout
        )
        #expect(acceptedSignedMessage)
    }

    @Test
    func revokedVerifiedIdentity_rejectsActiveSessionPublicMessages() async throws {
        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let peerID = PeerID(publicKey: signer.getStaticPublicKeyData())
        let fingerprint = signer.getStaticPublicKeyData().sha256Fingerprint()
        let identityManager = TrackingIdentityManager()
        identityManager.seedVerifiedIdentity(
            noisePublicKey: signer.getStaticPublicKeyData(),
            signingPublicKey: signer.getSigningPublicKeyData(),
            claimedNickname: "Alice"
        )

        let ble = makeService(identityManager: identityManager)
        let delegate = PublicCaptureDelegate()
        ble.delegate = delegate

        let announce = try makeSignedAnnouncementPacket(signer: signer, nickname: "Alice")
        ble._test_handlePacket(announce.packet, fromPeerID: peerID, preseedPeer: false)
        _ = await TestHelpers.waitUntil(
            { ble.currentPeerSnapshots().contains(where: { $0.peerID == peerID && $0.nickname == "Alice" }) },
            timeout: TestConstants.defaultTimeout
        )

        identityManager.setVerified(fingerprint: fingerprint, verified: false)

        let signedPublicPacket = try makeSignedPublicPacket(
            content: "post-revoke",
            sender: peerID,
            signer: signer,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        ble._test_handlePacket(signedPublicPacket, fromPeerID: peerID, preseedPeer: false)

        let acceptedAfterRevocation = await TestHelpers.waitUntil(
            { delegate.publicMessagesSnapshot().contains(where: { $0.content == "post-revoke" && $0.senderPeerID == peerID }) },
            timeout: TestConstants.shortTimeout
        )
        #expect(!acceptedAfterRevocation)
    }

    @Test
    func spoofedAnnounce_cannotOverwriteTrustedPeerIdentity() async throws {
        let trustedSigner = NoiseEncryptionService(keychain: MockKeychain())
        let trustedPeerID = PeerID(publicKey: trustedSigner.getStaticPublicKeyData())
        let identityManager = TrackingIdentityManager()
        identityManager.seedVerifiedIdentity(
            noisePublicKey: trustedSigner.getStaticPublicKeyData(),
            signingPublicKey: trustedSigner.getSigningPublicKeyData(),
            claimedNickname: "Alice"
        )

        let ble = makeService(identityManager: identityManager)
        let legitimateAnnounce = try makeSignedAnnouncementPacket(signer: trustedSigner, nickname: "Alice")
        ble._test_handlePacket(legitimateAnnounce.packet, fromPeerID: trustedPeerID, preseedPeer: false)
        _ = await TestHelpers.waitUntil(
            { ble.currentPeerSnapshots().contains(where: { $0.peerID == trustedPeerID && $0.nickname == "Alice" }) },
            timeout: TestConstants.defaultTimeout
        )

        let attacker = NoiseEncryptionService(keychain: MockKeychain())
        let spoofed = try makeSignedAnnouncementPacket(
            signer: attacker,
            nickname: "Mallory",
            announcedNoisePublicKey: trustedSigner.getStaticPublicKeyData(),
            announcedSigningPublicKey: attacker.getSigningPublicKeyData()
        )

        ble._test_handlePacket(spoofed.packet, fromPeerID: trustedPeerID, preseedPeer: false)
        try await sleep(TestConstants.shortTimeout)

        let peer = ble.currentPeerSnapshots().first(where: { $0.peerID == trustedPeerID })
        #expect(peer?.nickname == "Alice")
        #expect(identityManager.upsertedFingerprints == [trustedSigner.getStaticPublicKeyData().sha256Fingerprint()])
    }

    @Test
    func unverifiedConnectedPeer_fileTransferIsRejected() async throws {
        let ble = makeService()
        let delegate = PublicCaptureDelegate()
        ble.delegate = delegate

        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let announce = try makeSignedAnnouncementPacket(signer: signer, nickname: "Mallory")
        ble._test_handlePacket(announce.packet, fromPeerID: announce.peerID, preseedPeer: false)

        let sawPeer = await TestHelpers.waitUntil(
            { ble.currentPeerSnapshots().contains(where: { $0.peerID == announce.peerID }) },
            timeout: TestConstants.defaultTimeout
        )
        #expect(sawPeer)

        let payload = try #require(
            BitchatFilePacket(
                fileName: "spam.bin",
                fileSize: nil,
                mimeType: MimeType.octetStream.mimeString,
                content: Data([0x01, 0x02, 0x03, 0x04])
            ).encode(),
            "Failed to encode file payload"
        )
        let packet = BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: try #require(Data(hexString: announce.peerID.id), "Failed to encode sender ID"),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )
        ble._test_handlePacket(packet, fromPeerID: announce.peerID, preseedPeer: false)

        let delivered = await TestHelpers.waitUntil(
            { !delegate.receivedMessagesSnapshot().isEmpty },
            timeout: TestConstants.shortTimeout
        )
        #expect(!delivered)
    }
}

private func makeService(identityManager: SecureIdentityStateManagerProtocol? = nil) -> BLEService {
    let keychain = MockKeychain()
    let resolvedIdentityManager = identityManager ?? MockIdentityManager(keychain)
    let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
    return BLEService(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: resolvedIdentityManager,
        initializeBluetoothManagers: false
    )
}

private func makePublicPacket(content: String, sender: PeerID, timestamp: UInt64) -> BitchatPacket {
    BitchatPacket(
        type: MessageType.message.rawValue,
        senderID: Data(hexString: sender.id) ?? Data(),
        recipientID: nil,
        timestamp: timestamp,
        payload: Data(content.utf8),
        signature: nil,
        ttl: 3
    )
}

private func makeSignedPublicPacket(
    content: String,
    sender: PeerID,
    signer: NoiseEncryptionService,
    timestamp: UInt64
) throws -> BitchatPacket {
    let packet = makePublicPacket(content: content, sender: sender, timestamp: timestamp)
    return try #require(signer.signPacket(packet), "Failed to sign public packet")
}

private func makeSignedAnnouncementPacket(
    signer: NoiseEncryptionService,
    nickname: String,
    announcedNoisePublicKey: Data? = nil,
    announcedSigningPublicKey: Data? = nil
) throws -> (peerID: PeerID, packet: BitchatPacket) {
    let noisePublicKey = announcedNoisePublicKey ?? signer.getStaticPublicKeyData()
    let signingPublicKey = announcedSigningPublicKey ?? signer.getSigningPublicKeyData()
    let peerID = PeerID(publicKey: noisePublicKey)

    let announcement = AnnouncementPacket(
        nickname: nickname,
        noisePublicKey: noisePublicKey,
        signingPublicKey: signingPublicKey,
        directNeighbors: nil
    )
    let payload = try #require(announcement.encode(), "Failed to encode announcement")
    let packet = BitchatPacket(
        type: MessageType.announce.rawValue,
        senderID: try #require(Data(hexString: peerID.id), "Failed to encode sender ID"),
        recipientID: nil,
        timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
        payload: payload,
        signature: nil,
        ttl: TransportConfig.messageTTLDefault
    )

    return (peerID: peerID, packet: try #require(signer.signPacket(packet), "Failed to sign announcement"))
}

private final class PublicCaptureDelegate: BitchatDelegate {
    private let lock = NSLock()
    private(set) var publicMessages: [BitchatMessage] = []
    private(set) var receivedMessages: [BitchatMessage] = []

    func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?) {
        let message = BitchatMessage(
            id: messageID,
            sender: nickname,
            content: content,
            timestamp: timestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: peerID,
            mentions: nil
        )
        lock.lock()
        publicMessages.append(message)
        lock.unlock()
    }

    func didReceiveMessage(_ message: BitchatMessage) {
        lock.lock()
        receivedMessages.append(message)
        lock.unlock()
    }
    func didConnectToPeer(_ peerID: PeerID) {}
    func didDisconnectFromPeer(_ peerID: PeerID) {}
    func didUpdatePeerList(_ peers: [PeerID]) {}
    func didUpdateBluetoothState(_ state: CBManagerState) {}

    func publicMessagesSnapshot() -> [BitchatMessage] {
        lock.lock()
        defer { lock.unlock() }
        return publicMessages
    }

    func receivedMessagesSnapshot() -> [BitchatMessage] {
        lock.lock()
        defer { lock.unlock() }
        return receivedMessages
    }
}

private final class TrackingIdentityManager: SecureIdentityStateManagerProtocol {
    private var identities: [String: CryptographicIdentity] = [:]
    private var socialIdentities: [String: SocialIdentity] = [:]
    private var verifiedFingerprints: Set<String> = []
    private var blockedFingerprints: Set<String> = []
    private var blockedNostrPubkeys: Set<String> = []

    private(set) var upsertedFingerprints: [String] = []

    func seedVerifiedIdentity(noisePublicKey: Data, signingPublicKey: Data, claimedNickname: String) {
        let fingerprint = noisePublicKey.sha256Fingerprint()
        identities[fingerprint] = CryptographicIdentity(
            fingerprint: fingerprint,
            publicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            firstSeen: Date(),
            lastHandshake: Date()
        )
        socialIdentities[fingerprint] = SocialIdentity(
            fingerprint: fingerprint,
            localPetname: nil,
            claimedNickname: claimedNickname,
            trustLevel: .verified,
            isFavorite: false,
            isBlocked: false,
            notes: nil
        )
        verifiedFingerprints.insert(fingerprint)
    }

    func forceSave() {}

    func getSocialIdentity(for fingerprint: String) -> SocialIdentity? {
        socialIdentities[fingerprint]
    }

    func upsertCryptographicIdentity(fingerprint: String, noisePublicKey: Data, signingPublicKey: Data?, claimedNickname: String?) {
        identities[fingerprint] = CryptographicIdentity(
            fingerprint: fingerprint,
            publicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            firstSeen: identities[fingerprint]?.firstSeen ?? Date(),
            lastHandshake: Date()
        )
        if let claimedNickname {
            socialIdentities[fingerprint] = SocialIdentity(
                fingerprint: fingerprint,
                localPetname: socialIdentities[fingerprint]?.localPetname,
                claimedNickname: claimedNickname,
                trustLevel: verifiedFingerprints.contains(fingerprint) ? .verified : .unknown,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
        }
        upsertedFingerprints.append(fingerprint)
    }

    func getCryptoIdentitiesByPeerIDPrefix(_ peerID: PeerID) -> [CryptographicIdentity] {
        identities.values.filter { $0.fingerprint.hasPrefix(peerID.id) }
    }

    func updateSocialIdentity(_ identity: SocialIdentity) {
        socialIdentities[identity.fingerprint] = identity
    }

    func getFavorites() -> Set<String> { Set() }
    func setFavorite(_ fingerprint: String, isFavorite: Bool) {}
    func isFavorite(fingerprint: String) -> Bool { false }

    func isBlocked(fingerprint: String) -> Bool { blockedFingerprints.contains(fingerprint) }
    func setBlocked(_ fingerprint: String, isBlocked: Bool) {
        if isBlocked {
            blockedFingerprints.insert(fingerprint)
        } else {
            blockedFingerprints.remove(fingerprint)
        }
    }

    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool { blockedNostrPubkeys.contains(pubkeyHexLowercased) }
    func setNostrBlocked(_ pubkeyHexLowercased: String, isBlocked: Bool) {
        if isBlocked {
            blockedNostrPubkeys.insert(pubkeyHexLowercased)
        } else {
            blockedNostrPubkeys.remove(pubkeyHexLowercased)
        }
    }
    func getBlockedNostrPubkeys() -> Set<String> { blockedNostrPubkeys }

    func registerEphemeralSession(peerID: PeerID, handshakeState: HandshakeState) {}
    func updateHandshakeState(peerID: PeerID, state: HandshakeState) {}
    func clearAllIdentityData() {}
    func removeEphemeralSession(peerID: PeerID) {}

    func setVerified(fingerprint: String, verified: Bool) {
        if verified {
            verifiedFingerprints.insert(fingerprint)
        } else {
            verifiedFingerprints.remove(fingerprint)
        }
    }

    func isVerified(fingerprint: String) -> Bool {
        verifiedFingerprints.contains(fingerprint)
    }

    func getVerifiedFingerprints() -> Set<String> {
        verifiedFingerprints
    }
}
