import Combine
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
import BitFoundation
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
private struct SmokeFeatureModels {
    let publicChatModel: PublicChatModel
    let appChromeModel: AppChromeModel
    let locationChannelsModel: LocationChannelsModel
    let privateInboxModel: PrivateInboxModel
    let privateConversationModel: PrivateConversationModel
    let verificationModel: VerificationModel
    let conversationUIModel: ConversationUIModel
    let peerListModel: PeerListModel
    let boardAlertsModel: BoardAlertsModel
}

@MainActor
private func makeSmokeLocationManager() -> LocationChannelManager {
    let suiteName = "ViewSmokeTests.\(UUID().uuidString)"
    let storage = UserDefaults(suiteName: suiteName) ?? .standard
    storage.removePersistentDomain(forName: suiteName)
    return LocationChannelManager(storage: storage)
}

@MainActor
private func makeSmokeFeatureModels(for viewModel: ChatViewModel) -> SmokeFeatureModels {
    let locationManager = makeSmokeLocationManager()
    let conversations = viewModel.conversations
    let publicChatModel = PublicChatModel(conversations: conversations)
    let locationChannelsModel = LocationChannelsModel(manager: locationManager)
    let privateInboxModel = PrivateInboxModel(conversations: conversations)
    let appChromeModel = AppChromeModel(
        chatViewModel: viewModel,
        privateInboxModel: privateInboxModel
    )
    let privateConversationModel = PrivateConversationModel(
        chatViewModel: viewModel,
        conversations: conversations,
        locationChannelsModel: locationChannelsModel
    )
    let verificationModel = VerificationModel(
        chatViewModel: viewModel,
        privateConversationModel: privateConversationModel
    )
    let conversationUIModel = ConversationUIModel(
        chatViewModel: viewModel,
        privateConversationModel: privateConversationModel,
        conversations: conversations
    )
    let peerListModel = PeerListModel(
        chatViewModel: viewModel,
        conversations: conversations,
        locationChannelsModel: locationChannelsModel
    )

    let boardAlertsModel = BoardAlertsModel(
        arrivals: Empty(completeImmediately: false).eraseToAnyPublisher(),
        dependencies: BoardAlertsModel.Dependencies(
            isOwnPost: { _ in false },
            emitSystemLine: { _, _ in }
        )
    )

    return SmokeFeatureModels(
        publicChatModel: publicChatModel,
        appChromeModel: appChromeModel,
        locationChannelsModel: locationChannelsModel,
        privateInboxModel: privateInboxModel,
        privateConversationModel: privateConversationModel,
        verificationModel: verificationModel,
        conversationUIModel: conversationUIModel,
        peerListModel: peerListModel,
        boardAlertsModel: boardAlertsModel
    )
}

@MainActor
private func installSmokeEnvironment<V: View>(
    _ view: V,
    featureModels: SmokeFeatureModels
) -> some View {
    view
        .environmentObject(featureModels.publicChatModel)
        .environmentObject(featureModels.appChromeModel)
        .environmentObject(featureModels.locationChannelsModel)
        .environmentObject(featureModels.privateInboxModel)
        .environmentObject(featureModels.privateConversationModel)
        .environmentObject(featureModels.verificationModel)
        .environmentObject(featureModels.conversationUIModel)
        .environmentObject(featureModels.peerListModel)
        .environmentObject(featureModels.boardAlertsModel)
}

@MainActor
private struct ContentPeopleSheetHarness: View {
    @State private var showSidebar = true
    @State private var messageText = ""
    @State private var selectedMessageSender: String?
    @State private var selectedMessageSenderID: PeerID?
    @State private var imagePreviewURL: URL?
    @State private var windowCountPublic = 300
    @State private var windowCountPrivate: [PeerID: Int] = [:]
    @State private var isAtBottomPrivate = true
    @State private var autocompleteDebounceTimer: Timer?
    @StateObject private var voiceRecordingVM = VoiceRecordingViewModel()
    @FocusState private var isTextFieldFocused: Bool
    #if os(iOS)
    @State private var showImagePicker = false
    @State private var imagePickerSourceType: UIImagePickerController.SourceType = .photoLibrary
    #else
    @State private var showMacImagePicker = false
    #endif

    var body: some View {
        #if os(iOS)
        ContentPeopleSheetView(
            showSidebar: $showSidebar,
            messageText: $messageText,
            selectedMessageSender: $selectedMessageSender,
            selectedMessageSenderID: $selectedMessageSenderID,
            imagePreviewURL: $imagePreviewURL,
            windowCountPublic: $windowCountPublic,
            windowCountPrivate: $windowCountPrivate,
            isAtBottomPrivate: $isAtBottomPrivate,
            isTextFieldFocused: $isTextFieldFocused,
            voiceRecordingVM: voiceRecordingVM,
            autocompleteDebounceTimer: $autocompleteDebounceTimer,
            headerHeight: 44,
            onSendMessage: {},
            showImagePicker: $showImagePicker,
            imagePickerSourceType: $imagePickerSourceType
        )
        #else
        ContentPeopleSheetView(
            showSidebar: $showSidebar,
            messageText: $messageText,
            selectedMessageSender: $selectedMessageSender,
            selectedMessageSenderID: $selectedMessageSenderID,
            imagePreviewURL: $imagePreviewURL,
            windowCountPublic: $windowCountPublic,
            windowCountPrivate: $windowCountPrivate,
            isAtBottomPrivate: $isAtBottomPrivate,
            isTextFieldFocused: $isTextFieldFocused,
            voiceRecordingVM: voiceRecordingVM,
            autocompleteDebounceTimer: $autocompleteDebounceTimer,
            headerHeight: 44,
            onSendMessage: {},
            showMacImagePicker: $showMacImagePicker
        )
        #endif
    }
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

@Suite("View Smoke Tests", .serialized)
@MainActor
struct ViewSmokeTests {
    @Test
    func fingerprintView_renders_verifiedAndPendingStates() async {
        let (viewModel, transport, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
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

        let verifiedView = FingerprintView(peerID: verifiedPeer)
            .environmentObject(featureModels.verificationModel)
        let pendingView = FingerprintView(peerID: pendingPeer)
            .environmentObject(featureModels.verificationModel)

        _ = mount(verifiedView)
        _ = mount(pendingView)

        #expect(viewModel.verifiedFingerprints.contains(verifiedFingerprint))
    }

    @Test
    func verificationViews_renderCoreBranches() throws {
        let (viewModel, transport, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let peerID = PeerID(str: "2122232425262728")
        let fingerprint = String(repeating: "cd", count: 32)
        var isPresented = true

        transport.peerFingerprints[peerID] = fingerprint
        transport.updatePeerSnapshots([makeSnapshot(peerID: peerID, nickname: "Verifier", noiseByte: 0x33)])
        featureModels.privateConversationModel.startConversation(with: peerID)
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
            .environmentObject(featureModels.verificationModel)
        )
    }

    @Test
    func meshPeerList_renders_emptyAndPopulatedStates() async {
        let (viewModel, transport, identityManager) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let connectedPeer = PeerID(str: "3132333435363738")
        let blockedPeer = PeerID(str: "4142434445464748")
        let blockedFingerprint = String(repeating: "ef", count: 32)

        _ = mount(
            MeshPeerList(
                onTapPeer: { _ in },
                onToggleFavorite: { _ in },
                onShowFingerprint: { _ in }
            )
            .environmentObject(featureModels.peerListModel)
        )
        _ = MeshPeerList(
            onTapPeer: { _ in },
            onToggleFavorite: { _ in },
            onShowFingerprint: { _ in }
        )
        .environmentObject(featureModels.peerListModel)

        transport.peerFingerprints[blockedPeer] = blockedFingerprint
        identityManager.setBlocked(blockedFingerprint, isBlocked: true)
        transport.updatePeerSnapshots([
            makeSnapshot(peerID: connectedPeer, nickname: "Alice", noiseByte: 0x44),
            makeSnapshot(peerID: blockedPeer, nickname: "Mallory", noiseByte: 0x55)
        ])
        try? await Task.sleep(nanoseconds: 50_000_000)
        viewModel.markPrivateChatUnread(blockedPeer)

        _ = mount(
            MeshPeerList(
                onTapPeer: { _ in },
                onToggleFavorite: { _ in },
                onShowFingerprint: { _ in }
            )
            .environmentObject(featureModels.peerListModel)
        )

        #expect(viewModel.hasUnreadMessages(for: blockedPeer))
    }

    @Test
    func commandSuggestionsAndLocationViews_render() {
        let (viewModel, _, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let channel = GeohashChannel(level: .city, geohash: "u4pruy")
        var messageText = "/f"

        featureModels.locationChannelsModel.select(.location(channel))

        _ = mount(
            CommandSuggestionsView(
                messageText: Binding(
                    get: { messageText },
                    set: { messageText = $0 }
                )
            )
            .environmentObject(featureModels.privateConversationModel)
            .environmentObject(featureModels.locationChannelsModel)
        )

        _ = mount(
            LocationChannelsSheet(isPresented: .constant(true))
                .environmentObject(featureModels.locationChannelsModel)
                .environmentObject(featureModels.peerListModel)
        )

        #expect(messageText == "/f")
        featureModels.locationChannelsModel.select(.mesh)
        featureModels.locationChannelsModel.endLiveRefresh()
    }

    @Test
    func noticesView_rendersNoRelayAndLoadedStates() throws {
        let (viewModel, transport, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        featureModels.locationChannelsModel.select(.location(GeohashChannel(level: .building, geohash: "u4pruydq")))
        defer { featureModels.locationChannelsModel.select(.mesh) }
        let board = BoardManager(
            transport: transport,
            store: BoardStore(persistsToDisk: false, fileURL: nil, now: { Date() }),
            publishToNostr: { _, _, _, _, _ in nil },
            deleteFromNostr: { _, _ in }
        )

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
            NoticesView(
                senderNickname: viewModel.nickname,
                board: board,
                initialTab: .geo,
                notesManager: noRelayManager
            )
            .environmentObject(featureModels.locationChannelsModel)
        )
        _ = mount(
            NoticesView(
                senderNickname: viewModel.nickname,
                board: board,
                initialTab: .geo,
                notesManager: loadedManager
            )
            .environmentObject(featureModels.locationChannelsModel)
        )
        _ = mount(
            NoticesView(
                senderNickname: viewModel.nickname,
                board: board,
                initialTab: .mesh
            )
            .environmentObject(featureModels.locationChannelsModel)
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

        // AppInfoView's settings pane reads LocationChannelsModel from the
        // environment, so it can only render mounted with one installed.
        let appInfo = AppInfoView()
            .environmentObject(LocationChannelsModel(manager: makeSmokeLocationManager()))
        let header = SectionHeader("app_info.features.title")
        let featureRow = FeatureRow(info: feature)
        let paymentCashu = PaymentChipView(paymentType: .cashu("cashuA_test-token"))
        let paymentLightning = PaymentChipView(paymentType: .lightning("lightning:lnbc1test"))

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
    func contentShellViews_renderPublicAndPrivateBranches() async {
        let (viewModel, transport, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let peerID = PeerID(str: "5152535455565758")

        transport.updatePeerSnapshots([
            makeSnapshot(peerID: peerID, nickname: "Alice", noiseByte: 0x66)
        ])
        try? await Task.sleep(nanoseconds: 50_000_000)

        _ = mount(installSmokeEnvironment(ContentView(), featureModels: featureModels))
        _ = mount(installSmokeEnvironment(ContentPeopleSheetHarness(), featureModels: featureModels))

        featureModels.privateConversationModel.startConversation(with: peerID)
        try? await Task.sleep(nanoseconds: 50_000_000)

        _ = mount(installSmokeEnvironment(ContentPeopleSheetHarness(), featureModels: featureModels))

        #expect(featureModels.privateConversationModel.selectedPeerID == peerID)
        #expect(featureModels.privateConversationModel.selectedHeaderState?.headerPeerID == peerID)
    }

    @Test
    func geohashAndTextMessageViews_renderCoreBranches() {
        let (viewModel, _, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let geohashPeopleList = GeohashPeopleList(
            onTapPerson: {}
        )
        let truncatableMessage = BitchatMessage(
            sender: viewModel.nickname,
            content: String(repeating: "verylongtoken ", count: 160),
            timestamp: Date(),
            isRelay: false,
            isPrivate: false,
            deliveryStatus: .sent
        )
        let paymentMessage = BitchatMessage(
            sender: viewModel.nickname,
            content: "lightning:lnbc1test cashuA_test-token",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Bob",
            deliveryStatus: .partiallyDelivered(reached: 1, total: 2)
        )

        _ = mount(geohashPeopleList.environmentObject(featureModels.peerListModel))
        _ = mount(geohashPeopleList.environmentObject(featureModels.peerListModel))
        _ = mount(TextMessageView(message: truncatableMessage).environmentObject(featureModels.conversationUIModel))
        _ = mount(TextMessageView(message: paymentMessage).environmentObject(featureModels.conversationUIModel))

        #expect(truncatableMessage.content.count > TransportConfig.uiLongMessageLengthThreshold)
        #expect(paymentMessage.content.contains("lightning:") && paymentMessage.content.contains("cashu"))
    }

    @Test
    func voiceAndMediaViews_renderAndWarmCaches() async throws {
        let audioURL = try makeTemporaryAudioURL()
        // Probed directly below. Deliberately a separate file from `audioURL`:
        // `WaveformCache.shared` is process-wide and the mounted
        // `VoiceNoteView` warms it for `audioURL` at the view's default bin
        // width concurrently, so asserting an exact bin count for that URL
        // races with the view's own cache write.
        let waveformProbeURL = try makeTemporaryAudioURL()
        let imageURL = try makeTemporaryImageURL()
        defer {
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: waveformProbeURL)
            try? FileManager.default.removeItem(at: imageURL)
            WaveformCache.shared.purge(url: audioURL)
            WaveformCache.shared.purge(url: waveformProbeURL)
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
            WaveformCache.shared.waveform(for: waveformProbeURL, bins: 16) { values in
                continuation.resume(returning: values)
            }
        }
        playback.loadDuration()
        // loadDuration hops through a background queue and back to main; poll
        // instead of a fixed sleep so a loaded runner can't outlast the wait.
        _ = await TestHelpers.waitUntil({ playback.duration > 0 })
        playback.seek(to: 1.25)
        playback.stop()
        VoiceNotePlaybackCoordinator.shared.activate(playback)
        VoiceNotePlaybackCoordinator.shared.deactivate(playback)
        await VoiceRecorder.shared.cancelRecording(owner: VoiceRecorder.RecordingOwner())

        #expect(bins.count == 16)
        #expect(WaveformCache.shared.cachedWaveform(for: waveformProbeURL)?.count == 16)
        #expect(playback.duration > 0)
        #expect(playback.progress == 0)
    }

    @Test
    func messageRows_snapshotDeliveryStatusForSwiftUIDiffing() {
        // Regression: `BitchatMessage` is a reference type mutated in place
        // by `ConversationStore.applyDeliveryStatus`, and SwiftUI compares
        // reference-typed view fields by identity — so a status-only change
        // (delivered → read) on the SAME instance is invisible to the row's
        // structural diff and its body gets skipped even when the list
        // re-renders. The row views must therefore snapshot the status as a
        // value-typed stored property at init, so a rebuilt row value
        // compares different and re-renders.
        func deliveryStatusSnapshot(of row: Any) -> DeliveryStatus? {
            Mirror(reflecting: row).children
                .first { $0.label == "deliveryStatus" }?
                .value as? DeliveryStatus
        }

        let delivered = DeliveryStatus.delivered(to: "builder", at: Date(timeIntervalSince1970: 50))
        let message = BitchatMessage(
            id: "dm-status-1",
            sender: "anon",
            content: "hello",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "builder",
            senderPeerID: PeerID(str: "abcdef1234567890"),
            deliveryStatus: delivered
        )

        #expect(deliveryStatusSnapshot(of: TextMessageView(message: message)) == delivered)

        // In-place mutation of the shared instance (what the store does on a
        // READ ack); a freshly built row must carry the new status value.
        let read = DeliveryStatus.read(by: "builder", at: Date(timeIntervalSince1970: 100))
        message.deliveryStatus = read

        #expect(deliveryStatusSnapshot(of: TextMessageView(message: message)) == read)

        let mediaRow = MediaMessageView(
            message: message,
            media: .image(URL(fileURLWithPath: "/tmp/never-loaded.jpg")),
            imagePreviewURL: .constant(nil)
        )
        #expect(deliveryStatusSnapshot(of: mediaRow) == read)
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
