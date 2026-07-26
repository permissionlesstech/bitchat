import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEFileTransferHandlerTests {
    private final class Recorder {
        var localNickname = "Me"
        var peers: [PeerID: BLEPeerInfo] = [:]
        var signedName: String?
        var signatureVerifies = false
        var saveResult: URL? = URL(fileURLWithPath: "/tmp/files/incoming/sample.pdf")

        var signatureVerifyCount = 0
        var signedNameQueries: [PeerID] = []
        var blockedPeers: Set<PeerID> = []
        var trackedPackets: [BitchatPacket] = []
        var quotaReservations: [Int] = []
        var saveCalls: [(data: Data, preferredName: String?, subdirectory: String, fallbackExtension: String?, defaultPrefix: String)] = []
        var receiptStates: [String: BLEPrivateMediaReceiptState] = [:]
        var receiptCommits: [(messageID: String, storedURL: URL)] = []
        var receiptCommitSucceeds = true
        var removedIncomingFiles: [URL] = []
        var finishedIncomingFileDeliveries: [URL] = []
        var lastSeenUpdates: [PeerID] = []
        var deliveryAcks: [(messageID: String, peerID: PeerID)] = []
        var deliveredMessages: [BitchatMessage] = []
        var shouldAcceptDelivery = true
        var deliveryOutcome = TransportEventDeliveryOutcome.accepted
        var saveOverride: ((
            _ data: Data,
            _ preferredName: String?,
            _ subdirectory: String,
            _ fallbackExtension: String?,
            _ defaultPrefix: String
        ) -> URL?)?
        var receiptStateOverride: ((String) -> BLEPrivateMediaReceiptState)?
        var receiptCommitOverride: ((String, URL) -> Bool)?
        var removeIncomingFileOverride: ((URL) -> Void)?
        var finishIncomingFileDeliveryOverride: ((URL) -> Void)?
    }

    private let localPeerID = PeerID(str: "0102030405060708")
    private let remotePeerID = PeerID(str: "1122334455667788")
    private let sampleSigningKey = Data(repeating: 0xAB, count: 32)

    @Test @MainActor
    func deliveryGateFinalizesInitialRejection() {
        var completions = 0
        var finalizations = 0

        TransportEventDeliveryGate.attempt(
            shouldDeliver: { false },
            deliver: {
                Issue.record("delivery sink must not run")
                return .accepted
            },
            completion: { completions += 1 },
            finalization: { _ in finalizations += 1 }
        )

        #expect(completions == 0)
        #expect(finalizations == 1)
    }

    @Test @MainActor
    func deliveryGateFinalizesMissingOrRejectingSink() {
        var completions = 0
        var finalizations = 0

        TransportEventDeliveryGate.attempt(
            shouldDeliver: { true },
            deliver: { .rejected },
            completion: { completions += 1 },
            finalization: { _ in finalizations += 1 }
        )

        #expect(completions == 0)
        #expect(finalizations == 1)
    }

    @Test @MainActor
    func deliveryGateFinalizesPostInsertionRejection() {
        var deliveryChecks = 0
        var completions = 0
        var finalizations = 0

        TransportEventDeliveryGate.attempt(
            shouldDeliver: {
                deliveryChecks += 1
                return deliveryChecks == 1
            },
            deliver: { .accepted },
            completion: { completions += 1 },
            finalization: { _ in finalizations += 1 }
        )

        #expect(deliveryChecks == 2)
        #expect(completions == 0)
        #expect(finalizations == 1)
    }

    @Test @MainActor
    func deliveryGatePreservesInvokedUnconfirmedOutcomeWithoutAck() {
        var completions = 0
        var outcomes: [TransportEventDeliveryOutcome] = []

        TransportEventDeliveryGate.attempt(
            shouldDeliver: { true },
            deliver: { .invokedUnconfirmed },
            completion: { completions += 1 },
            finalization: { outcomes.append($0) }
        )

        #expect(completions == 0)
        #expect(outcomes == [.invokedUnconfirmed])
    }

    private func makeHandler(recorder: Recorder) -> BLEFileTransferHandler {
        let environment = BLEFileTransferHandlerEnvironment(
            localPeerID: { [localPeerID] in localPeerID },
            localNickname: { recorder.localNickname },
            peersSnapshot: { recorder.peers },
            verifyPacketSignature: { _, _ in
                recorder.signatureVerifyCount += 1
                return recorder.signatureVerifies
            },
            localSigningPublicKey: { [sampleSigningKey] in sampleSigningKey },
            signedSenderDisplayName: { _, peerID in
                recorder.signedNameQueries.append(peerID)
                return recorder.signedName
            },
            trackPacketSeen: { packet in
                recorder.trackedPackets.append(packet)
            },
            enforceStorageQuota: { reservingBytes in
                recorder.quotaReservations.append(reservingBytes)
            },
            saveIncomingFile: { data, preferredName, subdirectory, fallbackExtension, defaultPrefix in
                recorder.saveCalls.append((data, preferredName, subdirectory, fallbackExtension, defaultPrefix))
                if let saveOverride = recorder.saveOverride {
                    return saveOverride(data, preferredName, subdirectory, fallbackExtension, defaultPrefix)
                }
                return recorder.saveResult
            },
            privateMediaReceiptState: { messageID in
                if let receiptStateOverride = recorder.receiptStateOverride {
                    return receiptStateOverride(messageID)
                }
                return recorder.receiptStates[messageID] ?? .absent
            },
            commitPrivateMediaFile: { messageID, storedURL in
                recorder.receiptCommits.append((messageID, storedURL))
                if let receiptCommitOverride = recorder.receiptCommitOverride {
                    return receiptCommitOverride(messageID, storedURL)
                }
                guard recorder.receiptCommitSucceeds else { return false }
                recorder.receiptStates[messageID] = .accepted(storedURL)
                return true
            },
            removeIncomingFile: { storedURL in
                recorder.removedIncomingFiles.append(storedURL)
                recorder.removeIncomingFileOverride?(storedURL)
            },
            finishIncomingFileDelivery: { storedURL in
                recorder.finishedIncomingFileDeliveries.append(storedURL)
                recorder.finishIncomingFileDeliveryOverride?(storedURL)
            },
            isPrivateMediaSenderBlocked: { peerID in
                recorder.blockedPeers.contains(peerID)
            },
            updatePeerLastSeen: { peerID in
                recorder.lastSeenUpdates.append(peerID)
            },
            acknowledgePrivateMedia: { messageID, peerID in
                recorder.deliveryAcks.append((messageID, peerID))
            },
            deliverMessage: { message, shouldDeliver, completion, finalization in
                var outcome = TransportEventDeliveryOutcome.rejected
                defer { finalization(outcome) }
                guard recorder.shouldAcceptDelivery else { return }
                guard shouldDeliver() else { return }
                recorder.deliveredMessages.append(message)
                guard shouldDeliver() else { return }
                if recorder.deliveryOutcome == .invokedUnconfirmed {
                    outcome = .invokedUnconfirmed
                    return
                }
                outcome = .accepted
                completion()
            }
        )
        return BLEFileTransferHandler(environment: environment)
    }

    @Test
    func broadcastFileFromVerifiedPeerIsSavedAndDelivered() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true, signingPublicKey: sampleSigningKey)]
        recorder.signatureVerifies = true
        let handler = makeHandler(recorder: recorder)
        let content = Data("%PDF-1.7".utf8)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: "application/pdf", content: content)

        #expect(handler.handle(packet, from: remotePeerID))

        #expect(recorder.signatureVerifyCount == 1)
        #expect(recorder.signedNameQueries.isEmpty)
        #expect(recorder.trackedPackets.count == 1)
        #expect(recorder.quotaReservations == [content.count])
        #expect(recorder.saveCalls.count == 1)
        #expect(recorder.saveCalls.first?.data == content)
        #expect(recorder.saveCalls.first?.preferredName == "sample")
        #expect(recorder.saveCalls.first?.subdirectory == "files/incoming")
        #expect(recorder.saveCalls.first?.fallbackExtension == "pdf")
        #expect(recorder.saveCalls.first?.defaultPrefix == "file")
        #expect(recorder.lastSeenUpdates.isEmpty)
        #expect(recorder.deliveredMessages.count == 1)
        let message = recorder.deliveredMessages.first
        #expect(message?.sender == "Alice")
        #expect(message?.content == "[file] sample.pdf")
        #expect(message?.isPrivate == false)
        #expect(message?.senderPeerID == remotePeerID)
        #expect(message?.timestamp == Date(timeIntervalSince1970: 900))
        #expect(message?.deliveryStatus == nil)
    }

    @Test
    func selfEchoIsDropped() throws {
        let recorder = Recorder()
        recorder.signatureVerifies = true
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(sender: localPeerID, mimeType: "application/pdf", content: Data("%PDF-1.7".utf8), ttl: 3)

        #expect(!handler.handle(packet, from: localPeerID))

        expectNoSideEffects(recorder)
    }

    @Test
    func unknownPeerWithoutValidSignatureIsDropped() throws {
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: "application/pdf", content: Data("%PDF-1.7".utf8))

        #expect(!handler.handle(packet, from: remotePeerID))

        #expect(recorder.signedNameQueries == [remotePeerID])
        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func broadcastFromConnectedUnverifiedPeerWithoutSignatureIsDropped() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Bob", isVerified: false, isConnected: true)]
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(
            sender: remotePeerID,
            mimeType: "application/pdf",
            content: Data("%PDF-1.7".utf8),
            hasSignature: false
        )

        // Failed sender authentication must also stop the packet from being
        // relayed to downstream nodes.
        #expect(!handler.handle(packet, from: remotePeerID))

        // Broadcast files carry an attacker-controllable senderID, so — like
        // public messages — a connected-but-unverified peer must present a valid
        // packet signature. No signing key + no signed identity means dropped.
        #expect(recorder.signedNameQueries.isEmpty)
        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func broadcastFromConnectedUnverifiedPeerWithSignedIdentityIsAccepted() throws {
        let recorder = Recorder()
        // Connected but nickname not yet verified and no registry signing key —
        // the persisted-identity signature lookup still authenticates the
        // sender, so the transfer is accepted under that verified name.
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Bob", isVerified: false, isConnected: true)]
        recorder.signedName = "Bob"
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: "application/pdf", content: Data("%PDF-1.7".utf8))

        #expect(handler.handle(packet, from: remotePeerID))

        #expect(recorder.signedNameQueries == [remotePeerID])
        #expect(recorder.deliveredMessages.count == 1)
        #expect(recorder.deliveredMessages.first?.sender == "Bob")
    }

    @Test
    func signedSelfBroadcastReplayIsDelivered() throws {
        // Our own broadcast file replayed via gossip sync arrives with ttl==0;
        // it is verified against our local signing key before delivery.
        let recorder = Recorder()
        recorder.signatureVerifies = true
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(
            sender: localPeerID,
            mimeType: "application/pdf",
            content: Data("%PDF-1.7".utf8),
            ttl: 0
        )

        #expect(handler.handle(packet, from: localPeerID))

        #expect(recorder.signatureVerifyCount == 1)
        #expect(recorder.signedNameQueries.isEmpty)
        #expect(recorder.deliveredMessages.count == 1)
        #expect(recorder.deliveredMessages.first?.sender == "Me")
    }

    @Test
    func broadcastFromPeerNotInRegistryAcceptedViaSignedIdentity() throws {
        let recorder = Recorder()
        recorder.signedName = "Carol"
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: "application/pdf", content: Data("%PDF-1.7".utf8))

        #expect(handler.handle(packet, from: remotePeerID))

        // Peer absent from the registry: fall back to the persisted-identity
        // signature lookup (mirrors BLEPublicMessageHandler).
        #expect(recorder.signedNameQueries == [remotePeerID])
        #expect(recorder.deliveredMessages.count == 1)
        #expect(recorder.deliveredMessages.first?.sender == "Carol")
    }

    @Test
    func spoofedBroadcastVoiceNoteWithoutSignatureIsDropped() throws {
        // Regression for the PR #1406 finding: an in-range peer that observed a
        // public voice burst tries to overwrite the live bubble by broadcasting
        // a `voice_<burstID>.m4a` note under the talker's senderID. Without a
        // valid signature the note never reaches the coordinator's absorption.
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Mallory", isVerified: false, isConnected: true)]
        let handler = makeHandler(recorder: recorder)
        let m4a = Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypM4A ".utf8)
        let packet = try makeFileTransferPacket(
            sender: remotePeerID,
            mimeType: "audio/mp4",
            content: m4a,
            fileName: "voice_1122334455667788",
            hasSignature: false
        )

        // The spoofed note must be dropped locally AND not relayed onward.
        #expect(!handler.handle(packet, from: remotePeerID))

        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func rawDirectedFileWithoutVerifiableSignatureIsDroppedWithoutWriteOrRelay() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Bob", isVerified: false, isConnected: true)]
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(
            sender: remotePeerID,
            mimeType: "application/pdf",
            content: Data("%PDF-1.7".utf8),
            recipientID: Data(hexString: localPeerID.id),
            hasSignature: false
        )

        #expect(!handler.handle(packet, from: remotePeerID))

        #expect(recorder.signatureVerifyCount == 0)
        #expect(recorder.signedNameQueries.isEmpty)
        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.quotaReservations.isEmpty)
        #expect(recorder.saveCalls.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func fileDirectedToAnotherPeerIsIgnored() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true, signingPublicKey: sampleSigningKey)]
        recorder.signatureVerifies = true
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(
            sender: remotePeerID,
            mimeType: "application/pdf",
            content: Data("%PDF-1.7".utf8),
            recipientID: Data(hexString: "AABBCCDDEEFF0011")
        )

        // Not for us, but it must keep relaying toward the real recipient.
        #expect(handler.handle(packet, from: remotePeerID))

        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.quotaReservations.isEmpty)
        #expect(recorder.saveCalls.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func privateFileUpdatesLastSeenAndDeliversPrivateMessage() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true, signingPublicKey: sampleSigningKey)]
        recorder.signatureVerifies = true
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(
            sender: remotePeerID,
            mimeType: "application/pdf",
            content: Data("%PDF-1.7".utf8),
            recipientID: Data(hexString: localPeerID.id)
        )

        #expect(handler.handle(packet, from: remotePeerID))

        // Directed transfers are not tracked for gossip sync.
        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.lastSeenUpdates == [remotePeerID])
        #expect(recorder.deliveredMessages.count == 1)
        #expect(recorder.deliveredMessages.first?.isPrivate == true)
        #expect(recorder.deliveredMessages.first?.id.hasPrefix("media-") == false)
        // Must be explicit: BitchatMessage defaults private messages to
        // .sending, which the media views render as an in-flight send
        // (empty reveal mask, disabled reveal tap).
        #expect(recorder.deliveredMessages.first?.deliveryStatus == .delivered(to: "Me", at: Date(timeIntervalSince1970: 900)))
    }

    @Test
    func bit8EncryptedPrivateFileKeepsStableIDAndAckWithoutBit9Proof() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true)]
        let handler = makeHandler(recorder: recorder)
        let content = Data([0xFF, 0xD8, 0xFF]) + Data(repeating: 0x41, count: 128)
        let fileName = "img_20260725_105708_1CC2760D-76AA-40C3-8013-C7FAA6C2EF99.jpg"
        let file = BitchatFilePacket(
            fileName: fileName,
            fileSize: UInt64(content.count),
            mimeType: "image/jpeg",
            content: content
        )
        let payload = try #require(file.encode())
        let timestamp = Date(timeIntervalSince1970: 1_234)

        #expect(handler.handlePrivatePayload(payload, from: remotePeerID, timestamp: timestamp))

        #expect(recorder.signatureVerifyCount == 0)
        #expect(recorder.signedNameQueries.isEmpty)
        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.quotaReservations == [content.count])
        #expect(recorder.saveCalls.first?.data == content)
        #expect(recorder.lastSeenUpdates == [remotePeerID])
        #expect(recorder.deliveredMessages.count == 1)
        #expect(recorder.deliveredMessages.first?.isPrivate == true)
        #expect(recorder.deliveredMessages.first?.timestamp == timestamp)
        #expect(recorder.deliveredMessages.first?.id == PrivateMediaMessageIdentity.stableID(
            senderPeerID: remotePeerID,
            recipientPeerID: localPeerID,
            fileName: fileName
        ))
        #expect(recorder.receiptCommits.count == 1)
        #expect(recorder.deliveryAcks.count == 1)
        #expect(recorder.deliveryAcks.first?.messageID == recorder.deliveredMessages.first?.id)
    }

    @Test
    func rejectedStableDeliveryReleasesPendingPayloadOwnership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "private-media-handler-rejected-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BLEIncomingFileStore(baseDirectory: root)
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(
            remotePeerID,
            nickname: "Alice",
            isVerified: true
        )]
        recorder.shouldAcceptDelivery = false
        recorder.saveOverride = {
            store.save(
                data: $0,
                preferredName: $1,
                subdirectory: $2,
                fallbackExtension: $3,
                defaultPrefix: $4
            )
        }
        recorder.receiptStateOverride = {
            store.privateMediaReceiptState(messageID: $0)
        }
        recorder.receiptCommitOverride = {
            store.commitPrivateMediaFile(messageID: $0, storedURL: $1)
        }
        recorder.removeIncomingFileOverride = {
            store.removeIncomingFile(at: $0)
        }
        recorder.finishIncomingFileDeliveryOverride = {
            store.finishIncomingFileDelivery(at: $0)
        }

        let content = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let fileName =
            "img_20260725_105708_1CC2760D-76AA-40C3-8013-C7FAA6C2EF99.jpg"
        let file = BitchatFilePacket(
            fileName: fileName,
            fileSize: UInt64(content.count),
            mimeType: "image/jpeg",
            content: content
        )
        let payload = try #require(file.encode())
        let stableID = try #require(PrivateMediaMessageIdentity.stableID(
            senderPeerID: remotePeerID,
            recipientPeerID: localPeerID,
            fileName: fileName
        ))

        #expect(makeHandler(recorder: recorder).handlePrivatePayload(
            payload,
            from: remotePeerID,
            timestamp: Date(timeIntervalSince1970: 1_234)
        ))
        #expect(recorder.deliveredMessages.isEmpty)
        #expect(recorder.deliveryAcks.isEmpty)
        #expect(recorder.finishedIncomingFileDeliveries.count == 1)
        #expect(store.reservePrivateMediaDeletion(
            messageIDs: [stableID],
            payloadRelativePaths: [:]
        ) != nil)
    }

    @Test
    func rawLegacyPrivateFileWithRetryShapedNameNeverUsesReceiptLedger() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(
            remotePeerID,
            nickname: "Alice",
            isVerified: true,
            signingPublicKey: sampleSigningKey
        )]
        recorder.signatureVerifies = true
        let handler = makeHandler(recorder: recorder)
        let content = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let packet = try makeFileTransferPacket(
            sender: remotePeerID,
            mimeType: "image/jpeg",
            content: content,
            recipientID: Data(hexString: localPeerID.id),
            fileName: "img_20260725_105708_1CC2760D-76AA-40C3-8013-C7FAA6C2EF99.jpg"
        )

        #expect(handler.handle(packet, from: remotePeerID))
        #expect(recorder.receiptCommits.isEmpty)
        #expect(recorder.deliveryAcks.isEmpty)
        #expect(recorder.deliveredMessages.count == 1)
        #expect(recorder.deliveredMessages.first?.id.hasPrefix("media-") == false)
    }

    @Test
    func rejectedRawDeliveryRemovesUIUnownedPayload() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(
            remotePeerID,
            nickname: "Alice",
            isVerified: true,
            signingPublicKey: sampleSigningKey
        )]
        recorder.signatureVerifies = true
        recorder.shouldAcceptDelivery = false
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(
            sender: remotePeerID,
            mimeType: "image/jpeg",
            content: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            recipientID: Data(hexString: localPeerID.id),
            fileName: "raw-rejected.jpg"
        )

        #expect(handler.handle(packet, from: remotePeerID))
        #expect(recorder.deliveredMessages.isEmpty)
        #expect(recorder.removedIncomingFiles.count == 1)
        #expect(recorder.removedIncomingFiles.first == recorder.saveResult)
        #expect(recorder.finishedIncomingFileDeliveries.isEmpty)
    }

    @Test
    func plainDelegateRawDeliveryPreservesPayloadWithoutSynchronousAck() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(
            remotePeerID,
            nickname: "Alice",
            isVerified: true,
            signingPublicKey: sampleSigningKey
        )]
        recorder.signatureVerifies = true
        recorder.deliveryOutcome = .invokedUnconfirmed
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(
            sender: remotePeerID,
            mimeType: "image/jpeg",
            content: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            recipientID: Data(hexString: localPeerID.id),
            fileName: "plain-delegate.jpg"
        )

        #expect(handler.handle(packet, from: remotePeerID))
        #expect(recorder.deliveredMessages.count == 1)
        #expect(recorder.deliveryAcks.isEmpty)
        #expect(recorder.removedIncomingFiles.isEmpty)
        #expect(recorder.finishedIncomingFileDeliveries.count == 1)
        #expect(
            recorder.finishedIncomingFileDeliveries.first
                == recorder.saveResult
        )
    }

    @Test
    func repeatedLegacyPrivateImageNamesKeepDistinctRandomMessageIDs() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true)]
        let handler = makeHandler(recorder: recorder)
        let content = Data([0xFF, 0xD8, 0xFF]) + Data(repeating: 0x41, count: 128)
        let file = BitchatFilePacket(
            fileName: "photo.jpg",
            fileSize: UInt64(content.count),
            mimeType: "image/jpeg",
            content: content
        )
        let payload = try #require(file.encode())

        #expect(handler.handlePrivatePayload(
            payload,
            from: remotePeerID,
            timestamp: Date(timeIntervalSince1970: 1_234)
        ))
        #expect(handler.handlePrivatePayload(
            payload,
            from: remotePeerID,
            timestamp: Date(timeIntervalSince1970: 1_235)
        ))

        #expect(recorder.deliveredMessages.count == 2)
        #expect(recorder.deliveredMessages[0].id != recorder.deliveredMessages[1].id)
        #expect(recorder.deliveredMessages.allSatisfy { !$0.id.hasPrefix("media-") })
    }

    @Test
    func lostCapabilityProofThenStableRetryReusesDurableIDWithoutSecondDiskWrite() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true)]
        let handler = makeHandler(recorder: recorder)
        let content = Data([0xFF, 0xD8, 0xFF]) + Data(repeating: 0x41, count: 128)
        let fileName = "img_20260725_105708_1CC2760D-76AA-40C3-8013-C7FAA6C2EF99.jpg"
        let file = BitchatFilePacket(
            fileName: fileName,
            fileSize: UInt64(content.count),
            mimeType: "image/jpeg",
            content: content
        )
        let payload = try #require(file.encode())
        let expectedID = try #require(PrivateMediaMessageIdentity.stableID(
            senderPeerID: remotePeerID,
            recipientPeerID: localPeerID,
            fileName: fileName
        ))

        // First encrypted arrival may precede the sender's authenticated bit-9
        // proof. It still uses the bit-8 stable ID/ACK contract.
        #expect(handler.handlePrivatePayload(
            payload,
            from: remotePeerID,
            timestamp: Date(timeIntervalSince1970: 1_234)
        ))
        // A later automatic retry after proof must resolve the same durable ID
        // rather than create a legacy random-ID bubble.
        #expect(handler.handlePrivatePayload(
            payload,
            from: remotePeerID,
            timestamp: Date(timeIntervalSince1970: 1_235)
        ))

        #expect(recorder.quotaReservations == [content.count])
        #expect(recorder.saveCalls.count == 1)
        // The handler re-offers a durable duplicate so a relaunched UI can
        // restore its bubble; the synchronous conversation sink deduplicates.
        #expect(recorder.deliveredMessages.count == 2)
        #expect(recorder.lastSeenUpdates == [remotePeerID, remotePeerID])
        #expect(recorder.deliveryAcks.count == 2)
        #expect(recorder.deliveryAcks.allSatisfy {
            $0.messageID == expectedID && $0.peerID == remotePeerID
        })
    }

    @Test
    func acceptedPrivateMediaAfterRelaunchRedeliversDurableURLBeforeAck() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "private-media-handler-relaunch-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BLEIncomingFileStore(baseDirectory: root)
        let content = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let file = BitchatFilePacket(
            fileName: "img_20260725_105708_1CC2760D-76AA-40C3-8013-C7FAA6C2EF99.jpg",
            fileSize: UInt64(content.count),
            mimeType: "image/jpeg",
            content: content
        )
        let payload = try #require(file.encode())

        func configure(_ recorder: Recorder) {
            recorder.peers = [remotePeerID: makePeerInfo(
                remotePeerID,
                nickname: "Alice",
                isVerified: true
            )]
            recorder.saveOverride = { data, preferredName, subdirectory, fallbackExtension, defaultPrefix in
                store.save(
                    data: data,
                    preferredName: preferredName,
                    subdirectory: subdirectory,
                    fallbackExtension: fallbackExtension,
                    defaultPrefix: defaultPrefix
                )
            }
            recorder.receiptStateOverride = {
                store.privateMediaReceiptState(messageID: $0)
            }
            recorder.receiptCommitOverride = {
                store.commitPrivateMediaFile(messageID: $0, storedURL: $1)
            }
            recorder.removeIncomingFileOverride = {
                store.removeIncomingFile(at: $0)
            }
            recorder.finishIncomingFileDeliveryOverride = {
                store.finishIncomingFileDelivery(at: $0)
            }
        }

        let first = Recorder()
        configure(first)
        #expect(makeHandler(recorder: first).handlePrivatePayload(
            payload,
            from: remotePeerID,
            timestamp: Date(timeIntervalSince1970: 1_234)
        ))
        let originalMessage = try #require(first.deliveredMessages.first)
        #expect(first.deliveryAcks.count == 1)

        // A fresh handler models process relaunch: its in-memory reservation
        // cache is empty, so only the durable receipt can suppress disk work.
        let relaunched = Recorder()
        configure(relaunched)
        #expect(makeHandler(recorder: relaunched).handlePrivatePayload(
            payload,
            from: remotePeerID,
            timestamp: Date(timeIntervalSince1970: 1_235)
        ))

        #expect(relaunched.quotaReservations.isEmpty)
        #expect(relaunched.saveCalls.isEmpty)
        #expect(relaunched.receiptCommits.isEmpty)
        #expect(relaunched.deliveredMessages.count == 1)
        #expect(relaunched.deliveredMessages.first?.id == originalMessage.id)
        #expect(relaunched.deliveredMessages.first?.content == originalMessage.content)
        #expect(relaunched.deliveryAcks.count == 1)
        #expect(relaunched.deliveryAcks.first?.messageID == originalMessage.id)
    }

    @Test
    func inFlightStableDuplicateIsNotAcknowledgedAndFailedSaveRemainsRetryable() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true)]
        let content = Data([0xFF, 0xD8, 0xFF]) + Data(repeating: 0x41, count: 128)
        let file = BitchatFilePacket(
            fileName: "img_20260725_105708_1CC2760D-76AA-40C3-8013-C7FAA6C2EF99.jpg",
            fileSize: UInt64(content.count),
            mimeType: "image/jpeg",
            content: content
        )
        let payload = try #require(file.encode())
        var handler: BLEFileTransferHandler!
        var nestedResult: Bool?
        var failFirstSave = true
        recorder.saveOverride = { _, _, _, _, _ in
            if failFirstSave {
                failFirstSave = false
                nestedResult = handler.handlePrivatePayload(
                    payload,
                    from: self.remotePeerID,
                    timestamp: Date(timeIntervalSince1970: 1_235)
                )
                return nil
            }
            return recorder.saveResult
        }
        handler = makeHandler(recorder: recorder)

        // The nested arrival sees the first reservation as pending. It is
        // coalesced without an ACK; then the first durable save fails.
        #expect(!handler.handlePrivatePayload(
            payload,
            from: remotePeerID,
            timestamp: Date(timeIntervalSince1970: 1_234)
        ))
        #expect(nestedResult == true)
        #expect(recorder.saveCalls.count == 1)
        #expect(recorder.deliveryAcks.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)

        // Failure released the reservation, so the sender's later retry can
        // persist and deliver normally.
        #expect(handler.handlePrivatePayload(
            payload,
            from: remotePeerID,
            timestamp: Date(timeIntervalSince1970: 1_236)
        ))
        #expect(recorder.saveCalls.count == 2)
        #expect(recorder.deliveryAcks.count == 1)
        #expect(recorder.deliveredMessages.count == 1)
    }

    @Test
    func unavailableDurableReceiptStateWithholdsDiskDeliveryAndAck() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(
            remotePeerID,
            nickname: "Alice",
            isVerified: true
        )]
        let fileName =
            "img_20260725_105708_1CC2760D-76AA-40C3-8013-C7FAA6C2EF99.jpg"
        let messageID = try #require(PrivateMediaMessageIdentity.stableID(
            senderPeerID: remotePeerID,
            recipientPeerID: localPeerID,
            fileName: fileName
        ))
        recorder.receiptStates[messageID] = .unavailable
        let handler = makeHandler(recorder: recorder)
        let content = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let payload = try #require(BitchatFilePacket(
            fileName: fileName,
            fileSize: UInt64(content.count),
            mimeType: "image/jpeg",
            content: content
        ).encode())

        #expect(handler.handlePrivatePayload(
            payload,
            from: remotePeerID,
            timestamp: Date(timeIntervalSince1970: 1_234)
        ))
        #expect(recorder.quotaReservations.isEmpty)
        #expect(recorder.saveCalls.isEmpty)
        #expect(recorder.receiptCommits.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
        #expect(recorder.deliveryAcks.isEmpty)
    }

    @Test
    func durableReceiptCommitFailureRollsBackAndWithholdsDeliveryAck() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(
            remotePeerID,
            nickname: "Alice",
            isVerified: true
        )]
        recorder.receiptCommitSucceeds = false
        let handler = makeHandler(recorder: recorder)
        let content = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let payload = try #require(BitchatFilePacket(
            fileName: "img_20260725_105708_1CC2760D-76AA-40C3-8013-C7FAA6C2EF99.jpg",
            fileSize: UInt64(content.count),
            mimeType: "image/jpeg",
            content: content
        ).encode())

        #expect(!handler.handlePrivatePayload(
            payload,
            from: remotePeerID,
            timestamp: Date(timeIntervalSince1970: 1_234)
        ))
        #expect(recorder.saveCalls.count == 1)
        #expect(recorder.receiptCommits.count == 1)
        #expect(recorder.removedIncomingFiles.count == 1)
        #expect(recorder.removedIncomingFiles.first == recorder.saveResult)
        #expect(recorder.deliveredMessages.isEmpty)
        #expect(recorder.deliveryAcks.isEmpty)
    }

    @Test
    func blockedPrivateMediaIsDroppedBeforeQuotaDiskAndDedupState() throws {
        let recorder = Recorder()
        recorder.blockedPeers = [remotePeerID]
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true)]
        let handler = makeHandler(recorder: recorder)
        let content = Data([0xFF, 0xD8, 0xFF]) + Data(repeating: 0x41, count: 128)
        let file = BitchatFilePacket(
            fileName: "img_20260725_105708_1CC2760D-76AA-40C3-8013-C7FAA6C2EF99.jpg",
            fileSize: UInt64(content.count),
            mimeType: "image/jpeg",
            content: content
        )
        let payload = try #require(file.encode())

        #expect(handler.handlePrivatePayload(
            payload,
            from: remotePeerID,
            timestamp: Date(timeIntervalSince1970: 1_234)
        ))

        #expect(recorder.quotaReservations.isEmpty)
        #expect(recorder.saveCalls.isEmpty)
        #expect(recorder.lastSeenUpdates.isEmpty)
        #expect(recorder.deliveryAcks.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)

        // Unblocking must allow a retry through; the blocked attempt cannot
        // poison the stable-ID dedup reservation.
        recorder.blockedPeers = []
        #expect(handler.handlePrivatePayload(
            payload,
            from: remotePeerID,
            timestamp: Date(timeIntervalSince1970: 1_235)
        ))
        #expect(recorder.saveCalls.count == 1)
        #expect(recorder.deliveredMessages.count == 1)
        #expect(recorder.deliveryAcks.count == 1)
    }

    @Test
    func decryptedPrivateFileOverPayloadCapIsRejectedBeforeQuotaOrDiskWrite() {
        let recorder = Recorder()
        let handler = makeHandler(recorder: recorder)
        let oversizedCount = FileTransferLimits.maxPayloadBytes + 1
        var length = UInt32(oversizedCount).bigEndian
        var payload = Data([0x04]) // BitchatFilePacket CONTENT TLV
        withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
        payload.append(Data(repeating: 0x41, count: oversizedCount))

        #expect(!handler.handlePrivatePayload(
            payload,
            from: remotePeerID,
            timestamp: Date(timeIntervalSince1970: 1_234)
        ))

        #expect(recorder.quotaReservations.isEmpty)
        #expect(recorder.saveCalls.isEmpty)
        #expect(recorder.lastSeenUpdates.isEmpty)
        #expect(recorder.deliveryAcks.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func malformedPayloadIsTrackedForSyncButDropped() {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true, signingPublicKey: sampleSigningKey)]
        recorder.signatureVerifies = true
        let handler = makeHandler(recorder: recorder)
        let packet = BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: Data(hexString: remotePeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: 900_000,
            payload: Data([0x01, 0x02, 0x03]),
            signature: Data(repeating: 0x5A, count: 64),
            ttl: TransportConfig.messageTTLDefault
        )

        // Local decode failures are not proof of forgery; the packet stays relayable.
        #expect(handler.handle(packet, from: remotePeerID))

        // Sync tracking happens before payload validation, matching the original order.
        #expect(recorder.trackedPackets.count == 1)
        #expect(recorder.quotaReservations.isEmpty)
        #expect(recorder.saveCalls.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func unsupportedMimeIsDroppedBeforeQuotaAndSave() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true, signingPublicKey: sampleSigningKey)]
        recorder.signatureVerifies = true
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: nil, content: Data([0x4D, 0x5A, 0x00, 0x00]))

        #expect(handler.handle(packet, from: remotePeerID))

        #expect(recorder.trackedPackets.count == 1)
        #expect(recorder.quotaReservations.isEmpty)
        #expect(recorder.saveCalls.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func saveFailureSkipsDelivery() throws {
        let recorder = Recorder()
        recorder.peers = [remotePeerID: makePeerInfo(remotePeerID, nickname: "Alice", isVerified: true, signingPublicKey: sampleSigningKey)]
        recorder.signatureVerifies = true
        recorder.saveResult = nil
        let handler = makeHandler(recorder: recorder)
        let packet = try makeFileTransferPacket(sender: remotePeerID, mimeType: "application/pdf", content: Data("%PDF-1.7".utf8))

        // A local save failure must not stop the mesh relay.
        #expect(handler.handle(packet, from: remotePeerID))

        #expect(recorder.quotaReservations.count == 1)
        #expect(recorder.saveCalls.count == 1)
        #expect(recorder.lastSeenUpdates.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    @Test
    func quotaEvictionForFinalizedArrivalSkipsInFlightLiveCaptures() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-live-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = BLEIncomingFileStore(baseDirectory: base)
        let incoming = try store.incomingDirectory(subdirectory: "voicenotes/incoming")

        // The in-flight partial is the LRU-oldest eviction candidate; without
        // the voice_live_ pattern guard it would be deleted first, unlinking
        // the inode under the coordinator's open FileHandle.
        let inFlight = incoming.appendingPathComponent("voice_live_00112233445566ff_1122334455667788_dm.aac")
        let evictable = incoming.appendingPathComponent("voice_old.m4a")
        try Data(count: 51 * 1024 * 1024).write(to: inFlight)
        try Data(count: 51 * 1024 * 1024).write(to: evictable)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: inFlight.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: evictable.path)

        // 102 MB used against the 100 MB quota forces one eviction. This is
        // the finalized-file arrival path (BLEFileTransferHandler via
        // BLEService), which knows nothing about in-flight captures — the
        // store itself must protect them.
        store.enforceQuota(reservingBytes: 0)

        #expect(FileManager.default.fileExists(atPath: inFlight.path))
        #expect(!FileManager.default.fileExists(atPath: evictable.path))
    }

    @Test
    func legacyIncomingDeleteUnlinksUnreferencedPayload() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "legacy-unlink-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: base) }
        let store = BLEIncomingFileStore(baseDirectory: base)
        let incoming = try store.incomingDirectory(
            subdirectory: "images/incoming"
        )
        let payload = incoming.appendingPathComponent("legacy.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: payload)

        #expect(store.removeLegacyIncomingFile(
            relativePath: "images/incoming/legacy.jpg"
        ))
        #expect(!FileManager.default.fileExists(atPath: payload.path))

        // Only paths directly inside an incoming media directory qualify.
        let outgoing = base.appendingPathComponent(
            "files/images/outgoing",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outgoing,
            withIntermediateDirectories: true
        )
        let victim = outgoing.appendingPathComponent("victim.jpg")
        try Data([0x01]).write(to: victim)
        #expect(!store.removeLegacyIncomingFile(
            relativePath: "images/outgoing/victim.jpg"
        ))
        #expect(!store.removeLegacyIncomingFile(
            relativePath: "images/incoming/../outgoing/victim.jpg"
        ))
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test
    func legacyIncomingDeleteLeavesPendingDeliveryPayload() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "legacy-pending-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: base) }
        let store = BLEIncomingFileStore(baseDirectory: base)

        // save() marks the stored path pending until delivery finishes; a
        // legacy delete naming the same basename must not unlink it.
        let stored = try #require(store.save(
            data: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            preferredName: "pending.jpg",
            subdirectory: "images/incoming",
            fallbackExtension: "jpg",
            defaultPrefix: "img"
        ))
        let relativePath = "images/incoming/\(stored.lastPathComponent)"

        #expect(!store.removeLegacyIncomingFile(relativePath: relativePath))
        #expect(FileManager.default.fileExists(atPath: stored.path))

        // Once the delivery window closes the same unlink is allowed.
        store.finishIncomingFileDelivery(at: stored)
        #expect(store.removeLegacyIncomingFile(relativePath: relativePath))
        #expect(!FileManager.default.fileExists(atPath: stored.path))
    }

    @Test
    func legacyIncomingDeleteLeavesReceiptProtectedPayload() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "legacy-protected-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: base) }
        let store = BLEIncomingFileStore(baseDirectory: base)
        let incoming = try store.incomingDirectory(
            subdirectory: "images/incoming"
        )
        let payload = incoming.appendingPathComponent("owned.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: payload)

        // The basename belongs to a stable receipt (another record). The
        // legacy delete must leave it for that owner.
        #expect(store.commitPrivateMediaFile(
            messageID: "media-00112233445566778899aabbccddeeff",
            storedURL: payload
        ))
        #expect(!store.removeLegacyIncomingFile(
            relativePath: "images/incoming/owned.jpg"
        ))
        #expect(FileManager.default.fileExists(atPath: payload.path))
    }

    @Test
    func panicWipeDeletesEveryManagedMediaFileAndRecreatesEmptyDirectories() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("panic-media-wipe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = BLEIncomingFileStore(baseDirectory: base)
        let subdirectories = [
            "voicenotes/incoming",
            "voicenotes/outgoing",
            "images/incoming",
            "images/outgoing",
            "files/incoming",
            "files/outgoing"
        ]

        for subdirectory in subdirectories {
            let directory = base
                .appendingPathComponent("files", isDirectory: true)
                .appendingPathComponent(subdirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("secret".utf8).write(to: directory.appendingPathComponent("artifact.bin"))
        }
        let unmanaged = base.appendingPathComponent("files/legacy/secret.bin")
        try FileManager.default.createDirectory(at: unmanaged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: unmanaged)

        try store.panicWipe()

        #expect(!FileManager.default.fileExists(atPath: unmanaged.path))
        for subdirectory in subdirectories {
            let directory = base
                .appendingPathComponent("files", isDirectory: true)
                .appendingPathComponent(subdirectory, isDirectory: true)
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    @Test
    func panicWipeClearsCachedPrivateMediaReceiptDecisions() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "panic-receipt-cache-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: base) }
        let messageID = "media-00112233445566778899aabbccddeeff"

        let seed = BLEPrivateMediaReceiptStore(baseDirectory: base)
        let payload = base
            .appendingPathComponent(
                "files/images/incoming",
                isDirectory: true
            )
            .appendingPathComponent("panic-receipt.jpg")
        try FileManager.default.createDirectory(
            at: payload.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("secret".utf8).write(to: payload, options: .atomic)
        #expect(seed.commitAccepted(
            messageID: messageID,
            storedURL: payload
        ))
        #expect(seed.recordDeleted(messageID: messageID))

        // Production wiring: receipt lookups run against the service's OWN
        // incoming-file store while the panic wipe runs on the separate store
        // `PanicRecoveryOperations.live()` constructs. The test must reset
        // the instance BLEService uses, not a same-instance shortcut.
        let keychain = MockKeychain()
        let identityManager = MockIdentityManager(keychain)
        let service = BLEService(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identityManager,
            initializeBluetoothManagers: false,
            incomingFileStore: BLEIncomingFileStore(baseDirectory: base)
        )
        #expect(
            service._test_privateMediaReceiptState(messageID: messageID)
                == .tombstoned
        )

        service.suspendForPanicReset()
        // A receive callback drained during suspension can still consult the
        // ledger and re-cache the pre-wipe decision before media deletion.
        #expect(
            service._test_privateMediaReceiptState(messageID: messageID)
                == .tombstoned
        )

        // The wipe itself runs on the recovery operations' distinct store,
        // exactly like ChatViewModel's panic transaction.
        let recoveryStore = BLEIncomingFileStore(baseDirectory: base)
        try recoveryStore.panicWipe()
        service.completePanicReset(restartServices: false)

        #expect(
            service._test_privateMediaReceiptState(messageID: messageID)
                == .absent
        )
    }

    @Test
    func panicWipeInvalidatesPayloadCoordinationReservations() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "panic-payload-coordination-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: base) }
        let store = BLEIncomingFileStore(baseDirectory: base)
        let pendingName = "pending-before-panic.jpg"
        let pendingURL = try #require(store.save(
            data: Data("old".utf8),
            preferredName: pendingName,
            subdirectory: "images/incoming",
            fallbackExtension: "jpg",
            defaultPrefix: "image"
        ))
        let messageID = "media-aabbccddeeff00112233445566778899"
        let reservation = try #require(store.reservePrivateMediaDeletion(
            messageIDs: [messageID],
            payloadRelativePaths: [
                messageID: "images/incoming/delete-before-panic.jpg"
            ]
        ))

        try store.panicWipe()

        #expect(!store.commitPrivateMediaDeletion(
            reservation: reservation,
            messageIDs: [messageID],
            payloadRelativePaths: [
                messageID: "images/incoming/delete-before-panic.jpg"
            ],
            protectedPayloadRelativePaths: []
        ))
        let postPanicURL = try #require(store.save(
            data: Data("new".utf8),
            preferredName: pendingName,
            subdirectory: "images/incoming",
            fallbackExtension: "jpg",
            defaultPrefix: "image"
        ))
        #expect(pendingURL.lastPathComponent == pendingName)
        #expect(postPanicURL.lastPathComponent == pendingName)
    }

    @Test
    func panicWipeAttemptsDeletionWhenMarkerPersistenceFails() throws {
        enum MarkerFailure: Error { case unavailable }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "panic-marker-failure-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: base) }
        let secret = base
            .appendingPathComponent("files/images/outgoing", isDirectory: true)
            .appendingPathComponent("secret.jpg")
        try FileManager.default.createDirectory(
            at: secret.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("secret".utf8).write(to: secret)
        let store = BLEIncomingFileStore(
            baseDirectory: base,
            panicMarkerWriter: { _, _ in throw MarkerFailure.unavailable }
        )

        do {
            try store.panicWipe(hasDurablePendingMarker: false)
            Issue.record("Expected the missing durable marker to fail closed")
        } catch {
            // The marker error is reported only after the deletion attempt.
        }

        #expect(!FileManager.default.fileExists(atPath: secret.path))
        #expect(
            FileManager.default.fileExists(
                atPath: secret.deletingLastPathComponent().path
            )
        )
    }

    @Test
    func externalMarkerAllowsDeletionToCommitWhenFileMarkerFails() throws {
        enum MarkerFailure: Error { case unavailable }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "panic-external-marker-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: base) }
        let secret = base
            .appendingPathComponent("files/voicenotes/incoming", isDirectory: true)
            .appendingPathComponent("secret.m4a")
        try FileManager.default.createDirectory(
            at: secret.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("secret".utf8).write(to: secret)
        let store = BLEIncomingFileStore(
            baseDirectory: base,
            panicMarkerWriter: { _, _ in throw MarkerFailure.unavailable }
        )

        try store.panicWipe(hasDurablePendingMarker: true)

        #expect(!FileManager.default.fileExists(atPath: secret.path))
    }

    @Test
    func panicRecoveryMarkerPersistsUntilExplicitCommit() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "panic-recovery-marker-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: base) }
        let store = BLEIncomingFileStore(baseDirectory: base)

        try store.markPanicRecoveryPending()
        #expect(try store.isPanicRecoveryPending())
        try store.panicWipe(hasDurablePendingMarker: true)
        #expect(try store.isPanicRecoveryPending())

        try store.completePanicRecovery()

        #expect(try !store.isPanicRecoveryPending())
    }

    private func expectNoSideEffects(_ recorder: Recorder) {
        #expect(recorder.signedNameQueries.isEmpty)
        #expect(recorder.trackedPackets.isEmpty)
        #expect(recorder.quotaReservations.isEmpty)
        #expect(recorder.saveCalls.isEmpty)
        #expect(recorder.lastSeenUpdates.isEmpty)
        #expect(recorder.deliveredMessages.isEmpty)
    }

    private func makePeerInfo(
        _ peerID: PeerID,
        nickname: String,
        isVerified: Bool,
        isConnected: Bool = true,
        signingPublicKey: Data? = nil
    ) -> BLEPeerInfo {
        BLEPeerInfo(
            peerID: peerID,
            nickname: nickname,
            isConnected: isConnected,
            noisePublicKey: nil,
            signingPublicKey: signingPublicKey,
            isVerifiedNickname: isVerified,
            lastSeen: Date(timeIntervalSince1970: 999)
        )
    }

    private func makeFileTransferPacket(
        sender: PeerID,
        mimeType: String?,
        content: Data,
        ttl: UInt8 = TransportConfig.messageTTLDefault,
        recipientID: Data? = nil,
        fileName: String = "sample",
        hasSignature: Bool = true
    ) throws -> BitchatPacket {
        let filePacket = BitchatFilePacket(
            fileName: fileName,
            fileSize: UInt64(content.count),
            mimeType: mimeType,
            content: content
        )
        let payload = try #require(filePacket.encode())
        return BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: Data(hexString: sender.id) ?? Data(),
            recipientID: recipientID,
            timestamp: 900_000,
            payload: payload,
            signature: hasSignature ? Data(repeating: 0x5A, count: 64) : nil,
            ttl: ttl
        )
    }
}
