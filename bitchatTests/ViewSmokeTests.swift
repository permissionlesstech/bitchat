import Testing
import Foundation
import SwiftUI
import CoreGraphics
import AVFoundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import bitchat

@MainActor
private func makeSmokeViewModel() -> (viewModel: ChatViewModel, transport: MockTransport, identityManager: MockIdentityManager) {
    let keychain = MockKeychain()
    let keychainHelper = MockKeychainHelper()
    let idBridge = NostrIdentityBridge(keychain: keychainHelper)
    let identityManager = MockIdentityManager(keychain)
    let transport = MockTransport()

    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        transport: transport
    )

    return (viewModel, transport, identityManager)
}

@MainActor
@discardableResult
private func mount<V: View>(_ view: V) -> AnyObject {
    #if os(iOS)
    let host = UIHostingController(rootView: view)
    _ = host.view
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    return host
    #else
    let host = NSHostingView(rootView: view)
    host.layoutSubtreeIfNeeded()
    _ = host.fittingSize
    return host
    #endif
}

private func makeSnapshot(
    peerID: PeerID,
    nickname: String,
    connected: Bool = true,
    noiseByte: UInt8
) -> TransportPeerSnapshot {
    TransportPeerSnapshot(
        peerID: peerID,
        nickname: nickname,
        isConnected: connected,
        noisePublicKey: Data(repeating: noiseByte, count: 32),
        lastSeen: Date()
    )
}

private func makeCGImage() throws -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let context = try #require(
        CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    return try #require(context.makeImage())
}

private func makeTemporaryAudioURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let frameCount: AVAudioFrameCount = 1_600
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    let channel = try #require(buffer.floatChannelData?[0])
    for index in 0..<Int(frameCount) {
        channel[index] = sinf(Float(index) * 0.2) * 0.5
    }

    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
}

private func makeTemporaryImageURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("png")
    let image = try makeCGImage()
    #if os(iOS)
    let data = try #require(UIImage(cgImage: image).pngData())
    #else
    let rep = NSBitmapImageRep(cgImage: image)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    #endif
    try data.write(to: url)
    return url
}

@MainActor
struct ViewSmokeTests {
    @Test
    func fingerprintView_renders_verifiedAndPendingStates() async {
        let (viewModel, transport, _) = makeSmokeViewModel()
        let verifiedPeer = PeerID(str: "0102030405060708")
        let pendingPeer = PeerID(str: "1112131415161718")
        let verifiedFingerprint = String(repeating: "ab", count: 32)

        transport.peerFingerprints[verifiedPeer] = verifiedFingerprint
        transport.peerFingerprints[pendingPeer] = nil
        transport.updatePeerSnapshots([
            makeSnapshot(peerID: verifiedPeer, nickname: "Alice", noiseByte: 0x11),
            makeSnapshot(peerID: pendingPeer, nickname: "Bob", noiseByte: 0x22)
        ])
        try? await Task.sleep(nanoseconds: 50_000_000)

        viewModel.verifiedFingerprints.insert(verifiedFingerprint)

        let verifiedView = FingerprintView(viewModel: viewModel, peerID: verifiedPeer)
        let pendingView = FingerprintView(viewModel: viewModel, peerID: pendingPeer)

        _ = verifiedView.body
        _ = pendingView.body
        _ = mount(verifiedView)
        _ = mount(pendingView)

        #expect(viewModel.verifiedFingerprints.contains(verifiedFingerprint))
    }

    @Test
    func verificationViews_renderCoreBranches() throws {
        let (viewModel, transport, _) = makeSmokeViewModel()
        let peerID = PeerID(str: "2122232425262728")
        let fingerprint = String(repeating: "cd", count: 32)
        var isPresented = true

        transport.peerFingerprints[peerID] = fingerprint
        transport.updatePeerSnapshots([makeSnapshot(peerID: peerID, nickname: "Verifier", noiseByte: 0x33)])
        viewModel.selectedPrivateChatPeer = peerID
        viewModel.verifiedFingerprints.insert(fingerprint)

        let image = try makeCGImage()

        let myQR = MyQRView(qrString: "bitchat://verify?name=alice&npub=npub1test")
        let qrCode = QRCodeImage(data: "bitchat://verify?hello=world", size: 96)
        let imageWrapper = ImageWrapper(image: image)

        _ = myQR.body
        _ = qrCode.body
        _ = imageWrapper.body
        _ = mount(myQR)
        _ = mount(qrCode)
        _ = mount(imageWrapper)
        _ = mount(
            VerificationSheetView(
                isPresented: Binding(
                    get: { isPresented },
                    set: { isPresented = $0 }
                )
            )
            .environmentObject(viewModel)
        )
    }

    @Test
    func meshPeerList_renders_emptyAndPopulatedStates() async {
        let (viewModel, transport, identityManager) = makeSmokeViewModel()
        let connectedPeer = PeerID(str: "3132333435363738")
        let blockedPeer = PeerID(str: "4142434445464748")
        let blockedFingerprint = String(repeating: "ef", count: 32)

        _ = mount(
            MeshPeerList(
                viewModel: viewModel,
                textColor: .green,
                secondaryTextColor: .gray,
                onTapPeer: { _ in },
                onToggleFavorite: { _ in },
                onShowFingerprint: { _ in }
            )
        )
        _ = MeshPeerList(
            viewModel: viewModel,
            textColor: .green,
            secondaryTextColor: .gray,
            onTapPeer: { _ in },
            onToggleFavorite: { _ in },
            onShowFingerprint: { _ in }
        ).body

        transport.peerFingerprints[blockedPeer] = blockedFingerprint
        identityManager.setBlocked(blockedFingerprint, isBlocked: true)
        transport.updatePeerSnapshots([
            makeSnapshot(peerID: connectedPeer, nickname: "Alice", noiseByte: 0x44),
            makeSnapshot(peerID: blockedPeer, nickname: "Mallory", noiseByte: 0x55)
        ])
        try? await Task.sleep(nanoseconds: 50_000_000)
        viewModel.unreadPrivateMessages.insert(blockedPeer)

        _ = mount(
            MeshPeerList(
                viewModel: viewModel,
                textColor: .green,
                secondaryTextColor: .gray,
                onTapPeer: { _ in },
                onToggleFavorite: { _ in },
                onShowFingerprint: { _ in }
            )
        )

        #expect(viewModel.hasUnreadMessages(for: blockedPeer))
    }

    @Test
    func commandSuggestionsAndLocationViews_render() {
        let (viewModel, _, _) = makeSmokeViewModel()
        let channel = GeohashChannel(level: .city, geohash: "u4pruy")
        var messageText = "/f"

        LocationChannelManager.shared.select(.location(channel))

        _ = mount(
            CommandSuggestionsView(
                messageText: Binding(
                    get: { messageText },
                    set: { messageText = $0 }
                ),
                textColor: .green,
                backgroundColor: .black,
                secondaryTextColor: .gray
            )
            .environmentObject(viewModel)
        )

        _ = mount(
            LocationChannelsSheet(isPresented: .constant(true))
                .environmentObject(viewModel)
        )

        #expect(messageText == "/f")
        LocationChannelManager.shared.select(.mesh)
        LocationChannelManager.shared.endLiveRefresh()
    }

    @Test
    func locationNotesView_rendersNoRelayAndLoadedStates() throws {
        let (viewModel, _, _) = makeSmokeViewModel()

        let noRelayManager = LocationNotesManager(
            geohash: "u4pruydq",
            dependencies: LocationNotesDependencies(
                relayLookup: { _, _ in [] },
                subscribe: { _, _, _, _, _ in },
                unsubscribe: { _ in },
                sendEvent: { _, _ in },
                deriveIdentity: { _ in try NostrIdentity.generate() },
                now: { Date() }
            )
        )

        var noteHandler: ((NostrEvent) -> Void)?
        var eose: (() -> Void)?
        let loadedManager = LocationNotesManager(
            geohash: "u4pruydq",
            dependencies: LocationNotesDependencies(
                relayLookup: { _, _ in ["wss://relay.one"] },
                subscribe: { _, _, _, handler, onEOSE in
                    noteHandler = handler
                    eose = onEOSE
                },
                unsubscribe: { _ in },
                sendEvent: { _, _ in },
                deriveIdentity: { _ in try NostrIdentity.generate() },
                now: { Date() }
            )
        )

        let identity = try NostrIdentity.generate()
        let event = try NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: Date(),
            kind: .textNote,
            tags: [["g", "u4pruydq"], ["n", "Builder"]],
            content: "hello from a note"
        ).sign(with: identity.schnorrSigningKey())
        noteHandler?(event)
        eose?()

        _ = mount(
            LocationNotesView(geohash: "u4pruydq", manager: noRelayManager)
                .environmentObject(viewModel)
        )
        _ = mount(
            LocationNotesView(geohash: "u4pruydq", manager: loadedManager)
                .environmentObject(viewModel)
        )

        #expect(loadedManager.notes.count == 1)
        #expect(noRelayManager.state == .noRelays)
    }

    @Test
    func appInfoAndComponentViews_render() {
        let feature = AppInfoFeatureInfo(
            icon: "lock.fill",
            title: "app_info.privacy.title",
            description: "app_info.features.encryption.description"
        )

        let appInfo = AppInfoView()
        let header = SectionHeader("app_info.features.title")
        let featureRow = FeatureRow(info: feature)
        let paymentCashu = PaymentChipView(paymentType: .cashu("cashuA_test-token"))
        let paymentLightning = PaymentChipView(paymentType: .lightning("lightning:lnbc1test"))

        _ = appInfo.body
        _ = header.body
        _ = featureRow.body
        _ = paymentCashu.body
        _ = paymentLightning.body
        _ = DeliveryStatusView(status: .sending).body
        _ = DeliveryStatusView(status: .sent).body
        _ = DeliveryStatusView(status: .delivered(to: "Alice", at: Date())).body
        _ = DeliveryStatusView(status: .read(by: "Alice", at: Date())).body
        _ = DeliveryStatusView(status: .failed(reason: "offline")).body
        _ = DeliveryStatusView(status: .partiallyDelivered(reached: 2, total: 3)).body
        _ = mount(appInfo)
        _ = mount(header)
        _ = mount(featureRow)
        _ = mount(paymentCashu)
        _ = mount(paymentLightning)

        #expect(PaymentChipView.PaymentType.cashu("cashuA_test-token").url?.scheme == "cashu")
        #expect(PaymentChipView.PaymentType.cashu("https://example.com/cashu").url?.absoluteString == "https://example.com/cashu")
        #expect(PaymentChipView.PaymentType.lightning("lightning:lnbc1test").url?.scheme == "lightning")
    }

    @Test
    func geohashAndTextMessageViews_renderCoreBranches() {
        let (viewModel, _, _) = makeSmokeViewModel()
        let geohashPeopleList = GeohashPeopleList(
            viewModel: viewModel,
            textColor: .green,
            secondaryTextColor: .gray,
            onTapPerson: {}
        )
        var expandedMessageIDs: Set<String> = []
        let longMessage = BitchatMessage(
            sender: viewModel.nickname,
            content: String(repeating: "verylongtoken", count: 12) + " lightning:lnbc1test cashuA_test-token",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Bob",
            deliveryStatus: .partiallyDelivered(reached: 1, total: 2)
        )

        _ = geohashPeopleList.body
        _ = mount(geohashPeopleList)
        _ = mount(
            TextMessageView(
                message: longMessage,
                expandedMessageIDs: Binding(
                    get: { expandedMessageIDs },
                    set: { expandedMessageIDs = $0 }
                )
            )
            .environmentObject(viewModel)
        )

        #expect(expandedMessageIDs.isEmpty)
    }

    @Test
    func voiceAndMediaViews_renderAndWarmCaches() async throws {
        let audioURL = try makeTemporaryAudioURL()
        let imageURL = try makeTemporaryImageURL()
        defer {
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: imageURL)
            WaveformCache.shared.purge(url: audioURL)
        }

        let waveformView = WaveformView(
            samples: [0.1, 0.6, 0.3, 0.8],
            playbackProgress: 0.25,
            sendProgress: 0.75,
            onSeek: nil,
            isInteractive: false
        )
        let imageView = BlockRevealImageView(
            url: imageURL,
            revealProgress: 0.5,
            isSending: true,
            onCancel: {},
            initiallyBlurred: true,
            onOpen: {},
            onDelete: {}
        )
        let voiceNoteView = VoiceNoteView(
            url: audioURL,
            isSending: true,
            sendProgress: 0.4,
            onCancel: {}
        )
        let playback = VoiceNotePlaybackController(url: audioURL)

        _ = waveformView.body
        _ = imageView.body
        _ = mount(waveformView)
        _ = mount(imageView)
        _ = mount(voiceNoteView)

        let bins = await withCheckedContinuation { continuation in
            WaveformCache.shared.waveform(for: audioURL, bins: 16) { values in
                continuation.resume(returning: values)
            }
        }
        playback.loadDuration()
        try? await Task.sleep(nanoseconds: 250_000_000)
        playback.seek(to: 1.25)
        playback.stop()
        VoiceNotePlaybackCoordinator.shared.activate(playback)
        VoiceNotePlaybackCoordinator.shared.deactivate(playback)
        VoiceRecorder.shared.cancelRecording()

        #expect(bins.count == 16)
        #expect(WaveformCache.shared.cachedWaveform(for: audioURL)?.count == 16)
        #expect(playback.duration > 0)
        #expect(playback.progress == 0)
        #expect(VoiceRecorder.shared.currentAveragePower() <= 0)
    }

    #if os(iOS)
    @Test
    func cameraScannerView_previewAndCoordinatorSmoke() {
        let preview = CameraScannerView.PreviewView(frame: .zero)
        let coordinator = CameraScannerView.Coordinator()

        _ = CameraScannerView.PreviewView.layerClass
        _ = preview.videoPreviewLayer
        coordinator.setup(sessionOwner: preview) { _ in }
        coordinator.setActive(false)

        #expect(preview.videoPreviewLayer.videoGravity == .resizeAspectFill)
    }
    #endif
}
