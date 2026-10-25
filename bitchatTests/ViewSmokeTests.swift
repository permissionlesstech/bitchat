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
    let sharedContentImportModel: SharedContentImportModel
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
        boardAlertsModel: boardAlertsModel,
        sharedContentImportModel: SharedContentImportModel(store: nil)
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
        .environmentObject(featureModels.sharedContentImportModel)
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
    @StateObject private var voiceRecordingVM: VoiceRecordingViewModel
    @FocusState private var isTextFieldFocused: Bool
    #if os(iOS)
    @State private var showImagePicker = false
    @State private var imagePickerSourceType: UIImagePickerController.SourceType = .photoLibrary
    #else
    @State private var showMacImagePicker = false
    #endif

    init(voiceRecordingVM: VoiceRecordingViewModel? = nil) {
        _voiceRecordingVM = StateObject(wrappedValue: voiceRecordingVM ?? VoiceRecordingViewModel())
    }

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

#if os(iOS)
@MainActor
private final class SmokeVoiceCaptureSession: VoiceCaptureSession {
    let isLive = false
    private(set) var cancelCount = 0
    func requestPermission() async -> Bool { true }
    func start() async throws {}
    func finish() async -> URL? { nil }
    func cancel() async { cancelCount += 1 }
    func panicCancelSynchronously() {}
}
#endif

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
        let fingerprint = Data(repeating: 0x77, count: 32).sha256Fingerprint()
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

        // ContentView + people sheet must mount with the full feature-model
        // set (peerList / publicChat / privateInbox included). Missing any of
        // those crashes the NavigationStack sheet on some iOS versions (#1558).
        _ = mount(installSmokeEnvironment(ContentView(), featureModels: featureModels))
        _ = mount(installSmokeEnvironment(ContentPeopleSheetHarness(), featureModels: featureModels))

        featureModels.privateConversationModel.startConversation(with: peerID)
        try? await Task.sleep(nanoseconds: 50_000_000)

        _ = mount(installSmokeEnvironment(ContentPeopleSheetHarness(), featureModels: featureModels))

        #expect(featureModels.privateConversationModel.selectedPeerID == peerID)
        #expect(featureModels.privateConversationModel.selectedHeaderState?.headerPeerID == peerID)
    }

    #if os(iOS)
    @Test("Resizing the same chat workspace preserves selection and unsent drafts")
    @available(iOS 17.0, *)
    func contentWorkspace_preservesConversationAndDraftAcrossResizing() async throws {
        let previousDrafts = ComposerDraftStore.replaceAllForTesting()
        defer { ComposerDraftStore.replaceAllForTesting(previousDrafts) }
        let (viewModel, transport, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let peerID = PeerID(str: "6162636465666768")
        let fingerprint = Data(repeating: 0x77, count: 32).sha256Fingerprint()
        transport.peerFingerprints[peerID] = fingerprint
        transport.updatePeerSnapshots([
            makeSnapshot(peerID: peerID, nickname: "DuoAlice", noiseByte: 0x77)
        ])
        let peerReady = await TestHelpers.waitUntil {
            featureModels.conversationUIModel.getFingerprint(for: peerID) == fingerprint
                && viewModel.allPeers.contains { $0.peerID == peerID }
        }
        try #require(peerReady)
        let privateKey = ComposerDraftStore.Key.privateChat(stableID: fingerprint)
        ComposerDraftStore.save("saved mesh draft", for: .mesh)
        ComposerDraftStore.save("saved private draft", for: privateKey)

        // Retain one root throughout: replacing rootView would conceal the
        // draft/selection loss caused by rebuilding navigation on a resize.
        let host = UIHostingController(rootView:
            installSmokeEnvironment(ContentView(), featureModels: featureModels)
                .environment(\.scenePhase, .active)
        )
        let container = UIViewController()
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        let sceneReady = await TestHelpers.waitUntil {
            UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene }
        }
        try #require(sceneReady)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // Test-host permission alerts can leave the visible scene temporarily
        // inactive. It still owns the live window used for these layouts.
        let scene = try #require(scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = container
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        func resize(width: CGFloat, height: CGFloat, sizeClass: UIUserInterfaceSizeClass) async {
            container.setOverrideTraitCollection(
                UITraitCollection(horizontalSizeClass: sizeClass), forChild: host
            )
            // Resize the live child, not the scene's window. Scale its rendered
            // surface to fit the real scene so no text field becomes offstage
            // when testing a container larger than the simulator's display.
            host.view.transform = .identity
            host.view.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            host.view.center = CGPoint(x: container.view.bounds.midX, y: container.view.bounds.midY)
            let scale = min(container.view.bounds.width / width, container.view.bounds.height / height)
            host.view.transform = CGAffineTransform(scaleX: scale, y: scale)
            container.view.setNeedsLayout()
            container.view.layoutIfNeeded()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            // Yield a runloop turn for navigation's collapse/expand transaction;
            // the pre-transition field can otherwise satisfy a draft check.
            try? await Task.sleep(nanoseconds: 50_000_000)
            #expect(host.traitCollection.horizontalSizeClass == sizeClass)
            #expect(host.view.window === window)
        }
        func textFields(in view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
        }
        func composerField(privateChat: Bool) -> UITextField? {
            host.view.layoutIfNeeded()
            return textFields(in: host.view).first { field in
                guard field.window === window,
                      field.convert(field.bounds, to: window).intersects(window.bounds) else {
                    return false
                }
                var ancestor: UIView? = field
                while let view = ancestor {
                    guard !view.isHidden, view.alpha > 0 else { return false }
                    ancestor = view.superview
                }
                let placeholder = field.placeholder ?? field.attributedPlaceholder?.string ?? ""
                return privateChat
                    ? placeholder.contains("@DuoAlice")
                    : placeholder == String(localized: "content.input.placeholder.mesh")
            }
        }

        await resize(width: 390, height: 700, sizeClass: .compact)
        let publicMounted = await TestHelpers.waitUntil {
            composerField(privateChat: false)?.text == "saved mesh draft"
        }
        try #require(publicMounted)
        let meshField = try #require(composerField(privateChat: false))
        meshField.text = "mesh draft typed in the workspace"
        meshField.sendActions(for: .editingChanged)

        featureModels.privateConversationModel.startConversation(with: peerID)
        let privateMounted = await TestHelpers.waitUntil {
            composerField(privateChat: true)?.text == "saved private draft"
        }
        try #require(privateMounted)
        #expect(ComposerDraftStore.load(.mesh) == "mesh draft typed in the workspace")
        let privateField = try #require(composerField(privateChat: true))
        privateField.text = "private draft typed before folding"
        privateField.sendActions(for: .editingChanged)

        // Representative container sizes, not assumed hardware dimensions.
        for (width, height, sizeClass) in [
            (CGFloat(1000), CGFloat(800), UIUserInterfaceSizeClass.regular),
            (CGFloat(600), CGFloat(340), UIUserInterfaceSizeClass.compact),
            (CGFloat(800), CGFloat(1000), UIUserInterfaceSizeClass.regular)
        ] {
            await resize(width: width, height: height, sizeClass: sizeClass)
            let preserved = await TestHelpers.waitUntil {
                composerField(privateChat: true)?.text == "private draft typed before folding"
            }
            #expect(preserved)
            #expect(featureModels.privateConversationModel.selectedPeerID == peerID)
        }

        featureModels.privateConversationModel.endConversation()
        let meshRestored = await TestHelpers.waitUntil {
            composerField(privateChat: false)?.text == "mesh draft typed in the workspace"
        }
        #expect(meshRestored)
        #expect(featureModels.privateConversationModel.selectedPeerID == nil)
        #expect(ComposerDraftStore.load(privateKey) == "private draft typed before folding")

        featureModels.privateConversationModel.startConversation(with: peerID)
        let privateRestored = await TestHelpers.waitUntil {
            composerField(privateChat: true)?.text == "private draft typed before folding"
        }
        #expect(privateRestored)
    }
    #endif

    #if os(iOS)
    @Test("Recording HUD keeps capture running; a narrower composer cancels it")
    func voiceCapture_survivesHUDAndCancelsOnResize() async throws {
        let (viewModel, transport, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let peerID = PeerID(str: "7172737475767778")
        transport.updatePeerSnapshots([makeSnapshot(peerID: peerID, nickname: "VoiceAlice", noiseByte: 0x78)])
        featureModels.privateConversationModel.startConversation(with: peerID)
        let capture = SmokeVoiceCaptureSession()
        let recordingVM = VoiceRecordingViewModel()
        recordingVM.sessionProvider = { capture }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try #require(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView:
            installSmokeEnvironment(ContentPeopleSheetHarness(voiceRecordingVM: recordingVM), featureModels: featureModels)
                .environment(\.scenePhase, .active)
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        recordingVM.start(shouldShow: true)
        let started = await TestHelpers.waitUntil { recordingVM.state.isActive }
        try #require(started)
        // Preparing/recording inserts the HUD and changes composer height.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(recordingVM.state.isActive)
        #expect(capture.cancelCount == 0)

        host.view.bounds.size.width -= 80
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let canceled = await TestHelpers.waitUntil {
            recordingVM.state == .idle && capture.cancelCount == 1
        }
        #expect(canceled)
    }
    #endif

    @Test("Root Bluetooth alert waits for location and notices sheets")
    func rootBluetoothAlertGuard_includesHeaderSheets() {
        #expect(!ContentRootModalPresentationState().hasPresentation)
        #expect(
            ContentRootModalPresentationState(
                isLocationChannelsSheetPresented: true
            ).hasPresentation
        )
        #expect(
            ContentRootModalPresentationState(
                isNoticesSheetPresented: true
            ).hasPresentation
        )
    }

    @Test("People-sheet Bluetooth alert waits for local verification sheet")
    func peopleSheetBluetoothAlertGuard_includesVerificationSheet() {
        #expect(!ContentPeopleSheetModalPresentationState().hasPresentation)
        #expect(
            ContentPeopleSheetModalPresentationState(
                isVerificationSheetPresented: true
            ).hasPresentation
        )
    }

    @Test("Bluetooth alerts wait for the voice recording error alert")
    func bluetoothAlertGuards_includeVoiceAlert() {
        #expect(
            ContentRootModalPresentationState(
                isVoiceAlertPresented: true
            ).hasPresentation
        )
        #expect(
            ContentPeopleSheetModalPresentationState(
                isVoiceAlertPresented: true
            ).hasPresentation
        )
    }

    @Test("Root Bluetooth alert waits for screenshot privacy alert")
    @MainActor
    func rootBluetoothAlertGuard_tracksScreenshotPrivacyState() {
        let (viewModel, _, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)

        #expect(
            !ContentRootModalPresentationState(
                appChromeModel: featureModels.appChromeModel
            ).hasPresentation
        )

        featureModels.appChromeModel.showScreenshotPrivacyWarning = true

        #expect(
            ContentRootModalPresentationState(
                appChromeModel: featureModels.appChromeModel
            ).hasPresentation
        )
    }

    @Test("People-sheet Bluetooth alert waits for legacy media consent")
    @MainActor
    func peopleSheetBluetoothAlertGuard_tracksLegacyConsentState() async {
        let (viewModel, _, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)

        #expect(
            !ContentPeopleSheetModalPresentationState(
                legacyPrivateMediaConsentRequest:
                    featureModels.conversationUIModel
                        .legacyPrivateMediaConsentRequest
            ).hasPresentation
        )

        viewModel.enqueueLegacyPrivateMediaConsent(
            for: PeerID(str: "5152535455565758"),
            transferId: "legacy-consent-transfer",
            messageID: "legacy-consent-message"
        ) { _ in }
        defer { viewModel.cancelAllLegacyPrivateMediaConsents() }

        let consentPropagated = await TestHelpers.waitUntil {
            featureModels.conversationUIModel
                .legacyPrivateMediaConsentRequest != nil
        }
        #expect(
            consentPropagated
        )
        #expect(
            ContentPeopleSheetModalPresentationState(
                legacyPrivateMediaConsentRequest:
                    featureModels.conversationUIModel
                        .legacyPrivateMediaConsentRequest
            ).hasPresentation
        )
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
        // Stamped with my peer ID, as every DM I send is, so the row takes
        // the own-DM delivery-status branch.
        let paymentMessage = BitchatMessage(
            sender: viewModel.nickname,
            content: "lightning:lnbc1test cashuA_test-token",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Bob",
            senderPeerID: viewModel.meshService.myPeerID,
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

    @Test
    func cameraScannerView_previewAndCoordinatorSmoke() {
        #if os(iOS) || os(macOS)
        // Avoid constructing AVCaptureDeviceInput (and the TCC prompt it can
        // trigger) unless the host process already has camera authorization —
        // same class of isolation as keeping tests off the login keychain.
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let preview = CameraScannerView.PreviewView(frame: .zero)
        let coordinator = CameraScannerCoordinator()

        #if os(iOS)
        _ = CameraScannerView.PreviewView.layerClass
        #elseif os(macOS)
        preview.layout()
        #endif
        _ = preview.videoPreviewLayer

        if status == .authorized {
            coordinator.setup(previewLayer: preview.videoPreviewLayer) { _ in }
            coordinator.setActive(false)
        }

        #expect(preview.videoPreviewLayer.videoGravity == .resizeAspect)
        #endif
    }
}
