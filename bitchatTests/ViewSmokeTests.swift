import Combine
import Testing
import Foundation
import SwiftUI
import CoreGraphics
import AVFoundation
#if os(iOS)
import CoreLocation
import UIKit
#else
import AppKit
#endif
import BitFoundation
@testable import bitchat

/// `locationManager` drives the view model's channel switching; pass the
/// one the feature models select through for a selection to reach the
/// timelines, as `AppRuntime` shares `LocationChannelManager.shared`.
@MainActor
private func makeSmokeViewModel(
    locationManager: LocationChannelManager = .shared
) -> (viewModel: ChatViewModel, transport: MockTransport, identityManager: MockIdentityManager) {
    let keychain = MockKeychain()
    let keychainHelper = MockKeychainHelper()
    let idBridge = NostrIdentityBridge(keychain: keychainHelper)
    let identityManager = MockIdentityManager(keychain)
    let transport = MockTransport()

    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        transport: transport,
        locationManager: locationManager
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

/// `sharedContentStore` backs the share-import review; without one no share
/// is ever pending. `locationManager` backs the location model; by default
/// a fresh one of its own.
@MainActor
private func makeSmokeFeatureModels(
    for viewModel: ChatViewModel,
    sharedContentStore: SharedContentStore? = nil,
    locationManager: LocationChannelManager? = nil
) -> SmokeFeatureModels {
    let locationManager = locationManager ?? makeSmokeLocationManager()
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
        sharedContentImportModel: SharedContentImportModel(store: sharedContentStore)
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
        // As the app scene hands them to ContentView: plain references.
        .environment(\.contentModelReferences, ContentModelReferences(
            publicChatModel: featureModels.publicChatModel,
            privateInboxModel: featureModels.privateInboxModel,
            peerListModel: featureModels.peerListModel
        ))
}

@MainActor
private struct ContentPeopleSheetHarness: View {
    /// The open DM, as ContentView's secondary slot targets it.
    var target: ConversationTarget?
    @State private var showSidebar = true
    @State private var selectedMessageSender: String?
    @State private var selectedMessageSenderID: PeerID?
    @State private var imagePreviewURL: URL?
    @State private var windowCountPublic = 300
    @State private var windowCountPrivate: [PeerID: Int] = [:]
    @State private var isAtBottomPrivate = true
    @StateObject private var voiceRecordingVM = VoiceRecordingViewModel()
    @StateObject private var composers = ComposerSessions(drafts: InMemoryComposerDraftStore())
    @FocusState private var focusedComposer: ComposerSlot?
    @State private var mediaPickRequest: MediaPickRequest?

    var body: some View {
        #if os(iOS)
        ContentPeopleSheetView(
            showSidebar: $showSidebar,
            selectedMessageSender: $selectedMessageSender,
            selectedMessageSenderID: $selectedMessageSenderID,
            imagePreviewURL: $imagePreviewURL,
            windowCountPublic: $windowCountPublic,
            windowCountPrivate: $windowCountPrivate,
            isAtBottomPrivate: $isAtBottomPrivate,
            composer: composers.secondary,
            target: target,
            focusedComposer: $focusedComposer,
            voiceRecordingVM: voiceRecordingVM,
            headerHeight: 44,
            onSendMessage: {},
            onPickMedia: { _ in },
            mediaPickRequest: $mediaPickRequest
        )
        #else
        ContentPeopleSheetView(
            showSidebar: $showSidebar,
            selectedMessageSender: $selectedMessageSender,
            selectedMessageSenderID: $selectedMessageSenderID,
            imagePreviewURL: $imagePreviewURL,
            windowCountPublic: $windowCountPublic,
            windowCountPrivate: $windowCountPrivate,
            isAtBottomPrivate: $isAtBottomPrivate,
            composer: composers.secondary,
            target: target,
            focusedComposer: $focusedComposer,
            voiceRecordingVM: voiceRecordingVM,
            headerHeight: 44,
            onSendMessage: {},
            onPickMedia: {},
            mediaPickRequest: $mediaPickRequest
        )
        #endif
    }
}

#if os(iOS)
@MainActor
private struct ContentConversationColumnHarness: View {
    /// The open DM, as ContentView's secondary slot targets it.
    var target: ConversationTarget?
    @State private var showSidebar = false
    @State private var selectedMessageSender: String?
    @State private var selectedMessageSenderID: PeerID?
    @State private var imagePreviewURL: URL?
    @State private var windowCountPublic = 300
    @State private var windowCountPrivate: [PeerID: Int] = [:]
    @State private var isAtBottomPrivate = true
    @StateObject private var voiceRecordingVM = VoiceRecordingViewModel()
    @StateObject private var composers = ComposerSessions(drafts: InMemoryComposerDraftStore())
    @FocusState private var focusedComposer: ComposerSlot?

    var body: some View {
        ContentConversationColumnView(
            showSidebar: $showSidebar,
            selectedMessageSender: $selectedMessageSender,
            selectedMessageSenderID: $selectedMessageSenderID,
            imagePreviewURL: $imagePreviewURL,
            windowCountPublic: $windowCountPublic,
            windowCountPrivate: $windowCountPrivate,
            isAtBottomPrivate: $isAtBottomPrivate,
            composer: composers.secondary,
            target: target,
            focusedComposer: $focusedComposer,
            voiceRecordingVM: voiceRecordingVM,
            onPickMedia: { _ in },
            headerHeight: 44,
            trailingCornerReach: 0,
            onSendMessage: {}
        )
    }
}
#endif

/// One composer on the session and target a slot would give it.
@MainActor
private struct ComposerHarness: View {
    @ObservedObject var session: ComposerSession
    let target: ConversationTarget?
    @StateObject private var voiceRecordingVM = VoiceRecordingViewModel()
    @FocusState private var focusedComposer: ComposerSlot?

    var body: some View {
        #if os(iOS)
        ContentComposerView(
            session: session,
            target: target,
            focus: $focusedComposer,
            voiceRecordingVM: voiceRecordingVM,
            onSend: {},
            onPickMedia: { _ in }
        )
        #else
        ContentComposerView(
            session: session,
            target: target,
            focus: $focusedComposer,
            voiceRecordingVM: voiceRecordingVM,
            onSend: {},
            onPickMedia: {}
        )
        #endif
    }
}

/// A public `MessageListView` with its own bindings; the timeline it shows
/// is whatever `PublicChatModel` the environment hands it.
@MainActor
private struct MessageListHarness: View {
    @State private var isAtBottom = true
    @State private var selectedMessageSender: String?
    @State private var selectedMessageSenderID: PeerID?
    @State private var imagePreviewURL: URL?
    @State private var windowCountPublic = TransportConfig.uiWindowInitialCountPublic
    @State private var windowCountPrivate: [PeerID: Int] = [:]
    @State private var showSidebar = false
    @StateObject private var composers = ComposerSessions(drafts: InMemoryComposerDraftStore())
    @FocusState private var focusedComposer: ComposerSlot?

    var body: some View {
        MessageListView(
            privateTarget: nil,
            isAtBottom: $isAtBottom,
            composer: composers.primary,
            selectedMessageSender: $selectedMessageSender,
            selectedMessageSenderID: $selectedMessageSenderID,
            imagePreviewURL: $imagePreviewURL,
            windowCountPublic: $windowCountPublic,
            windowCountPrivate: $windowCountPrivate,
            showSidebar: $showSidebar,
            focusedComposer: $focusedComposer
        )
    }
}

/// The header bar as each layout configures it.
@MainActor
private struct ContentHeaderHarness: View {
    var paneChannel: ChannelID?
    var carriesAppChrome = true
    var isBadgeStatic = false
    var handlesPaneTaps = false
    @FocusState private var isNicknameFieldFocused: Bool

    var body: some View {
        ContentHeaderView(
            showSidebar: .constant(false),
            showVerifySheet: .constant(false),
            isNicknameFieldFocused: $isNicknameFieldFocused,
            headerHeight: 44,
            headerPeerIconSize: 11,
            headerPeerCountFontSize: 12,
            trailingCornerReach: 55,
            paneChannel: paneChannel,
            carriesAppChrome: carriesAppChrome,
            onPeopleTap: handlesPaneTaps ? {} : nil,
            onBadgeTap: handlesPaneTaps ? {} : nil,
            isBadgeStatic: isBadgeStatic
        )
    }
}

#if os(iOS)
/// Hosts `view` in a visible window, so SwiftUI runs its appear and
/// disappear actions (a bare hosting controller never appears). Returns the
/// teardown that takes it off screen again.
@MainActor
private func present<V: View>(_ view: V) -> () -> Void {
    let host = UIHostingController(rootView: view)
    let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    let window = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first
        .map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
    window.frame = frame
    window.rootViewController = host
    window.isHidden = false
    host.view.layoutIfNeeded()
    return {
        window.isHidden = true
        window.rootViewController = nil
    }
}

/// How many views hold the shared nearby-notes counter. A public list takes
/// the hold exactly when the timeline it renders is #mesh, which makes it the
/// list's one channel decision visible from outside. Read by reflection: the
/// count is private state of a singleton.
@MainActor
private func nearbyNotesHolderCount() -> Int? {
    Mirror(reflecting: NearbyNotesCounter.shared).children
        .first { $0.label == "activeHolders" }?
        .value as? Int
}

/// A `LocationChannelsModel` whose CoreLocation seam (`location`) reports
/// `status`, settled once the permission has reached the model.
@MainActor
private func makeSmokeLocationChannelsModel(
    authorizationStatus: CLAuthorizationStatus
) async -> (model: LocationChannelsModel, location: MockLocationStateManaging) {
    let suiteName = "ViewSmokeTests.\(UUID().uuidString)"
    let storage = UserDefaults(suiteName: suiteName) ?? .standard
    storage.removePersistentDomain(forName: suiteName)
    let location = MockLocationStateManaging(authorizationStatus: authorizationStatus)
    let manager = LocationStateManager(
        storage: storage,
        locationManager: location,
        geocoder: MockLocationStateGeocoder(),
        shouldInitializeCoreLocation: true
    )
    let model = LocationChannelsModel(manager: manager)
    if authorizationStatus != .notDetermined {
        _ = await TestHelpers.waitUntil(
            { model.permissionState != .notDetermined },
            timeout: TestConstants.settleTimeout
        )
    }
    return (model, location)
}

/// Hosts a view in a visible window of the test host's scene, so it appears
/// and updates as it would on screen: `onAppear` and `onChange` run, and
/// UIKit-backed controls exist to read.
@MainActor
private final class WindowHost {
    let window: UIWindow

    init<V: View>(_ view: V, size: CGSize) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }

    /// The first text field in the hosted hierarchy.
    var textField: UITextField? {
        Self.firstTextField(in: window)
    }

    /// The prompts of the text fields whose centre lies in `frame` (window
    /// coordinates): which composers, or which picker, a region shows.
    func placeholders(in frame: CGRect) -> [String] {
        // The hierarchy as SwiftUI last rendered it, whatever the run loop
        // has drawn so far.
        window.layoutIfNeeded()
        return Self.textFields(in: window).compactMap { field in
            let center = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: window)
            guard frame.contains(center) else { return nil }
            return field.attributedPlaceholder?.string ?? field.placeholder
        }
    }

    /// Every text field's prompt and window frame, for failure messages,
    /// with whether the window is key.
    var fieldReport: String {
        window.layoutIfNeeded()
        return "key \(window.isKeyWindow): " + Self.textFields(in: window).map { field in
            let frame = field.convert(field.bounds, to: window)
            let prompt = field.attributedPlaceholder?.string ?? field.placeholder ?? ""
            return "\(prompt)@\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
                + (field.window == nil ? " (no window)" : "")
                + (field.isHidden ? " (hidden)" : "")
        }
        .joined(separator: "; ")
    }

    /// A touch going down at `point` (window coordinates), as the split
    /// layout's window-level touch observer reports it. False without one.
    func touchDown(at point: CGPoint) -> Bool {
        guard let observer = Self.first(PaneTouchObserverView.self, in: window) else { return false }
        observer.recognizer.onTouchDown?(point)
        return true
    }

    private static func textFields(in view: UIView) -> [UITextField] {
        if let field = view as? UITextField { return [field] }
        return view.subviews.flatMap { textFields(in: $0) }
    }

    private static func first<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = first(type, in: subview) { return match }
        }
        return nil
    }

    func close() {
        // A field left first responder outlives its window and keeps the
        // keyboard, and a sheet left up outlives its presenter: either way
        // later test windows stop catching up with their views.
        window.endEditing(true)
        window.rootViewController?.dismiss(animated: false)
        window.resignKey()
        window.isHidden = true
        window.rootViewController = nil
    }

    private static func firstTextField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }
}

/// Stands in for `AppChromeModel.panicEpoch`.
@MainActor
private final class SmokePanicEpoch: ObservableObject {
    @Published var value: UInt64 = 0
}

/// The idle inline picker, its epoch driven by the test.
@MainActor
private struct LocationChannelsPaneHarness: View {
    @ObservedObject var panicEpoch: SmokePanicEpoch

    var body: some View {
        LocationChannelsPicker(
            presentation: .pane(headerHeight: 44, trailingCornerReach: 0, panicEpoch: panicEpoch.value),
            onChoose: {},
            onClose: nil
        )
    }
}

/// Stands in for the device's width class, which decides the split layout.
@MainActor
private final class SmokeSizeClass: ObservableObject {
    @Published var value: UserInterfaceSizeClass = .regular
}

/// ContentView in a window wide enough for the split layout: two 480pt
/// panes either side of a 40pt gap at the window's centre. The view model
/// switches channels on the same location manager the location model
/// selects through, as the app's do, so a selection reaches the timelines;
/// its CoreLocation is a mock that counts every request. Bob is a connected
/// mesh peer.
@MainActor
private final class SplitContentHost {
    let geohash = GeohashChannel(level: .city, geohash: "u4pru")
    let bob = PeerID(str: "b0b0b0b0b0b0b0b0")
    let viewModel: ChatViewModel
    let models: SmokeFeatureModels
    let location: MockLocationStateManaging
    let sizeClass: SmokeSizeClass
    private let meshPaneTimeline: PublicChatModel
    private let host: WindowHost

    private static let size = CGSize(width: 1000, height: 800)
    private static let leadingRegion = CGRect(x: 0, y: 0, width: 480, height: 800)
    private static let trailingRegion = CGRect(x: 520, y: 0, width: 480, height: 800)

    private init(
        viewModel: ChatViewModel,
        models: SmokeFeatureModels,
        location: MockLocationStateManaging,
        sizeClass: SmokeSizeClass,
        theme: AppTheme
    ) {
        self.viewModel = viewModel
        self.models = models
        self.location = location
        self.sizeClass = sizeClass
        meshPaneTimeline = PublicChatModel(conversations: viewModel.conversations, pinnedTo: .mesh)
        host = WindowHost(
            installSmokeEnvironment(
                ContentViewSizeClassHarness(sizeClass: sizeClass, meshPaneTimeline: meshPaneTimeline, theme: theme),
                featureModels: models
            ),
            size: Self.size
        )
    }

    /// - Parameters:
    ///   - compact: Start folded (the single column).
    ///   - theme: Matrix (opaque bars) or glass (panels floating over the
    ///     timelines).
    static func make(
        compact: Bool = false,
        theme: AppTheme = .matrix,
        sharedContentStore: SharedContentStore? = nil
    ) async -> SplitContentHost {
        let suiteName = "ViewSmokeTests.split.\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName) ?? .standard
        storage.removePersistentDomain(forName: suiteName)
        let location = MockLocationStateManaging(authorizationStatus: .authorizedWhenInUse)
        let manager = LocationStateManager(
            storage: storage,
            locationManager: location,
            geocoder: MockLocationStateGeocoder(),
            shouldInitializeCoreLocation: true
        )
        let (viewModel, transport, _) = makeSmokeViewModel(locationManager: manager)
        let models = makeSmokeFeatureModels(
            for: viewModel,
            sharedContentStore: sharedContentStore,
            locationManager: manager
        )
        _ = await TestHelpers.waitUntil(
            { models.locationChannelsModel.permissionState == .authorized },
            timeout: TestConstants.settleTimeout
        )
        let sizeClass = SmokeSizeClass()
        sizeClass.value = compact ? .compact : .regular
        let split = SplitContentHost(
            viewModel: viewModel,
            models: models,
            location: location,
            sizeClass: sizeClass,
            theme: theme
        )
        transport.updatePeerSnapshots([
            makeSnapshot(peerID: split.bob, nickname: "Bob", noiseByte: 0xB0)
        ])
        _ = await TestHelpers.waitUntil(
            { models.peerListModel.meshRows.contains { $0.peerID == split.bob } },
            timeout: TestConstants.settleTimeout
        )
        _ = await split.settle { split.chrome.splitLayoutShowsLocation != nil || compact }
        return split
    }

    var chrome: AppChromeModel { models.appChromeModel }
    var channels: LocationChannelsModel { models.locationChannelsModel }
    var openPeer: PeerID? { models.privateConversationModel.selectedPeerID }
    /// The channel the selection's timeline renders.
    var timelineChannel: ChannelID { models.publicChatModel.channel }
    var isMeshPinned: Bool { viewModel.conversations.isMeshPinnedOnScreen }
    /// The window presents something over the panes (the share review).
    var isPresenting: Bool { host.window.rootViewController?.presentedViewController != nil }
    /// The prompts of the text fields in each pane: its composer's names
    /// its conversation; the picker's teleport field reads "geohash".
    var leadingPrompts: [String] { host.placeholders(in: Self.leadingRegion) }
    var trailingPrompts: [String] { host.placeholders(in: Self.trailingRegion) }

    func settle(_ condition: @escaping () -> Bool) async -> Bool {
        await TestHelpers.waitUntil(condition, timeout: TestConstants.settleTimeout)
    }

    /// Selects `channel` and waits until the timeline renders it.
    func select(_ channel: ChannelID) async -> Bool {
        channels.select(channel)
        return await settle { self.timelineChannel == channel }
    }

    func open(_ peer: PeerID) async -> Bool {
        models.privateConversationModel.startConversation(with: peer)
        return await settle { self.openPeer == peer }
    }

    /// A touch going down in the middle of `pane`.
    func touch(_ pane: ContentPane) -> Bool {
        let region = pane == .leading ? Self.leadingRegion : Self.trailingRegion
        return host.touchDown(at: CGPoint(x: region.midX, y: region.midY))
    }

    func fold() async -> Bool {
        sizeClass.value = .compact
        return await settle { self.chrome.splitLayoutShowsLocation == nil }
    }

    func unfold() async -> Bool {
        sizeClass.value = .regular
        return await settle { self.chrome.splitLayoutShowsLocation != nil }
    }

    func close() {
        host.close()
    }

    /// The state a failed expectation reports: the selection, the timeline,
    /// the DM, the layout flags and every text field's prompt with where it
    /// sits in the window.
    var diagnostics: String {
        "selection \(channels.selectedChannel), timeline \(timelineChannel), DM \(String(describing: openPeer)), "
            + "split flag \(String(describing: chrome.splitLayoutShowsLocation)), pinned \(isMeshPinned), "
            + "fields \(host.fieldReport)"
    }
}

/// ContentView with a test-driven width class and, for the split layout,
/// the pinned #mesh timeline the app scene hands it (`meshPaneTimeline`).
@MainActor
private struct ContentViewSizeClassHarness: View {
    @ObservedObject var sizeClass: SmokeSizeClass
    var meshPaneTimeline: PublicChatModel?
    var theme: AppTheme = .matrix

    var body: some View {
        ContentView()
            .environment(\.horizontalSizeClass, sizeClass.value)
            .environment(\.meshPaneTimeline, meshPaneTimeline)
            .environment(\.appTheme, theme)
    }
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
                ),
                target: .publicChannel(.location(channel))
            )
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

        _ = mount(installSmokeEnvironment(
            ContentPeopleSheetHarness(target: ConversationTarget(channel: .mesh, privatePeer: peerID)),
            featureModels: featureModels
        ))

        #expect(featureModels.privateConversationModel.selectedPeerID == peerID)
        #expect(featureModels.privateConversationModel.selectedHeaderState?.headerPeerID == peerID)
    }

    /// Each slot's composer mounts on its own session: the public
    /// timeline's (#mesh with photo and mic, a geohash with neither) and the
    /// DM sheet's, with its text, command suggestions and mention panel, and
    /// with no conversation at all.
    @Test
    func composer_mountsForEitherSlot() {
        let (viewModel, _, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let peerID = PeerID(str: "7172737475767778")
        let geohash = ChannelID.location(GeohashChannel(level: .city, geohash: "u4pru"))
        let cases: [(ComposerSlot, ConversationTarget?, String)] = [
            (.primary, .mesh, ""),
            (.primary, .publicChannel(geohash), "/f"),
            (.secondary, ConversationTarget(channel: .mesh, privatePeer: peerID), "hi @al"),
            (.secondary, ConversationTarget(channel: geohash, privatePeer: peerID), "/"),
            (.secondary, nil, "left behind")
        ]

        for (slot, target, text) in cases {
            let session = ComposerSession(slot: slot)
            session.text = text
            if text.contains("@") {
                session.autocomplete = ComposerAutocompleteState(
                    suggestions: ["@alice", "@albert"],
                    range: NSRange(location: 3, length: 3)
                )
            }
            _ = mount(installSmokeEnvironment(
                ComposerHarness(session: session, target: target),
                featureModels: featureModels
            ))
            #expect(session.text == text, "mounting changed \(slot)'s text")
        }
    }

    /// The split layout's leading list is handed the pinned #mesh model while
    /// a geohash is selected: it renders #mesh, never the selection, as its
    /// one channel decision visible from outside shows (the mesh-only
    /// nearby-notes hold). Its neighbour renders the geohash it is given.
    /// (Both are pinned so the view model's own startup selection cannot
    /// race the test.)
    @Test
    func messageList_rendersItsOwnTimelineWhileAGeohashIsSelected() async {
        let (viewModel, _, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let store = viewModel.conversations
        let geohash = ChannelID.location(GeohashChannel(level: .city, geohash: "u4pru"))
        // The selection the lists must not follow.
        featureModels.locationChannelsModel.select(geohash)
        #expect(await TestHelpers.waitUntil(
            { featureModels.locationChannelsModel.selectedChannel == geohash },
            timeout: TestConstants.settleTimeout
        ))

        let meshPane = PublicChatModel(conversations: store, pinnedTo: .mesh)
        let geohashPane = PublicChatModel(conversations: store, pinnedTo: geohash)
        store.append(BitchatMessage(
            id: "mesh-row",
            sender: "dave",
            content: "hello from the mesh pane",
            timestamp: Date(),
            isRelay: false,
            senderPeerID: PeerID(str: "1122334455667788")
        ), to: .mesh)
        store.append(BitchatMessage(
            id: "geo-row",
            sender: "carol#cdcd",
            content: "hello from the geohash pane",
            timestamp: Date(),
            isRelay: false,
            senderPeerID: PeerID(nostr: String(repeating: "cd", count: 32))
        ), to: .geohash("u4pru"))
        #expect(meshPane.messages.map(\.id) == ["mesh-row"])
        #expect(geohashPane.messages.map(\.id) == ["geo-row"])

        let bothLists = installSmokeEnvironment(
            VStack(spacing: 0) {
                MessageListHarness().environmentObject(meshPane)
                MessageListHarness().environmentObject(geohashPane)
            },
            featureModels: featureModels
        )

        #if os(iOS)
        let baseline = nearbyNotesHolderCount() ?? 0
        let dismiss = present(bothLists)
        // Both lists appear in the same pass; only the #mesh one holds.
        let held = await TestHelpers.waitUntil(
            { nearbyNotesHolderCount() == baseline + 1 },
            timeout: TestConstants.settleTimeout
        )
        #expect(held, "holders \(String(describing: nearbyNotesHolderCount())), baseline \(baseline)")
        #expect(nearbyNotesHolderCount() == baseline + 1)
        dismiss()
        #expect(await TestHelpers.waitUntil(
            { nearbyNotesHolderCount() == baseline },
            timeout: TestConstants.settleTimeout
        ))
        #else
        _ = mount(bothLists)
        #endif
    }

    #if os(iOS)
    @Test
    func conversationColumn_rendersTheConversation() async {
        let (viewModel, transport, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let peerID = PeerID(str: "6162636465666768")

        transport.updatePeerSnapshots([
            makeSnapshot(peerID: peerID, nickname: "Bob", noiseByte: 0x77)
        ])
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Unlike the sheet, the column gets no re-injected models: it must
        // mount on exactly the environment ContentView's own tree provides.
        _ = mount(installSmokeEnvironment(ContentConversationColumnHarness(), featureModels: featureModels))

        featureModels.privateConversationModel.startConversation(with: peerID)
        #expect(featureModels.privateConversationModel.selectedPeerID == peerID)

        _ = mount(installSmokeEnvironment(
            ContentConversationColumnHarness(target: ConversationTarget(channel: .mesh, privatePeer: peerID)),
            featureModels: featureModels
        ))
    }

    @Test
    func peopleList_rendersEachPresentationForEitherChannel() async {
        let (viewModel, _, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let geohash = GeohashChannel(level: .city, geohash: "u4pru")
        let presentations: [ContentPeopleListView.Presentation] = [
            .sheet,
            .popover(onClose: {}, onShowFingerprint: { _ in })
        ]

        featureModels.locationChannelsModel.select(.location(geohash))
        defer { featureModels.locationChannelsModel.select(.mesh) }
        let selected = await TestHelpers.waitUntil(
            { featureModels.locationChannelsModel.selectedChannel.isLocation },
            timeout: TestConstants.settleTimeout
        )
        #expect(selected)
        for presentation in presentations {
            // #mesh's people while a geohash is selected, and the geohash's.
            for channel in [ChannelID?.none, .mesh, .location(geohash)] {
                _ = mount(installSmokeEnvironment(
                    ContentPeopleListView(
                        showSidebar: .constant(false),
                        showVerifySheet: .constant(false),
                        presentation: presentation,
                        channel: channel
                    ),
                    featureModels: featureModels
                ))
            }
        }
    }

    @Test
    func peoplePopover_rendersMeshAndGeohashPeople() {
        let (viewModel, _, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let geohash = GeohashChannel(level: .city, geohash: "u4pru")
        var closes = 0

        _ = mount(installSmokeEnvironment(
            ContentPeoplePopoverView(channel: .mesh, paneWidth: 455.5, onClose: { closes += 1 }),
            featureModels: featureModels
        ))
        _ = mount(installSmokeEnvironment(
            ContentPeoplePopoverView(channel: .location(geohash), paneWidth: 371.5, onClose: { closes += 1 }),
            featureModels: featureModels
        ))
        // The presenter, closed: only the models the people tree reads.
        _ = mount(installSmokeEnvironment(
            Color.clear.contentPeoplePopover(
                isPresented: .constant(false),
                channel: .mesh,
                paneWidth: 455.5,
                onClose: {}
            ),
            featureModels: featureModels
        ))

        // At most a phone sheet's width, and 16pt clear of either pane edge.
        #expect(ContentPeoplePopoverView.idealWidth(forPaneWidth: 455.5) == 360)
        #expect(ContentPeoplePopoverView.idealWidth(forPaneWidth: 371.5) == 339.5)
        #expect(ContentPeoplePopoverView.idealWidth(forPaneWidth: 20) == 0)
        #expect(closes == 0)
    }

    @Test
    func locationChannelsPane_rendersEachPermissionAndBrowsing() async {
        let (viewModel, _, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let pane = LocationChannelsPicker.Presentation.pane(headerHeight: 44, trailingCornerReach: 55, panicEpoch: 0)

        for status in [CLAuthorizationStatus.notDetermined, .denied, .authorizedAlways] {
            let (model, _) = await makeSmokeLocationChannelsModel(authorizationStatus: status)
            // Idle: no close control, no #mesh row.
            _ = mount(installSmokeEnvironment(
                LocationChannelsPicker(presentation: pane, onChoose: {}, onClose: nil)
                    .environmentObject(model),
                featureModels: featureModels
            ))
            // Browsing away from a geohash: close, and the #mesh row back.
            model.select(.location(GeohashChannel(level: .city, geohash: "u4pru")))
            _ = await TestHelpers.waitUntil(
                { model.selectedChannel.isLocation },
                timeout: TestConstants.settleTimeout
            )
            _ = mount(installSmokeEnvironment(
                LocationChannelsPicker(presentation: pane, onChoose: {}, onClose: {})
                    .environmentObject(model),
                featureModels: featureModels
            ))
            #expect(model.selectedChannel.isLocation)
        }
    }

    /// I4: a panic wipe closes the sheet, which takes what it held with it.
    /// The inline picker stays up, so the wipe has to empty it: a teleport
    /// typed but not taken names a place.
    @Test
    func locationChannelsPane_panicWipeDropsWhatWasTyped() async throws {
        let (viewModel, _, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let (model, location) = await makeSmokeLocationChannelsModel(authorizationStatus: .authorizedAlways)
        let panicEpoch = SmokePanicEpoch()
        let host = WindowHost(
            installSmokeEnvironment(
                LocationChannelsPaneHarness(panicEpoch: panicEpoch).environmentObject(model),
                featureModels: featureModels
            ),
            size: CGSize(width: 400, height: 800)
        )
        defer { host.close() }

        // It appeared: one fix, nothing more.
        let appeared = await TestHelpers.waitUntil(
            { location.requestLocationCallCount == 1 },
            timeout: TestConstants.settleTimeout
        )
        #expect(appeared)
        let field = try #require(host.textField)

        // The field's own filter rewriting the typed text proves the
        // picker's state took it.
        field.becomeFirstResponder()
        field.insertText("#9Q8YYK")
        let typed = await TestHelpers.waitUntil(
            { host.textField?.text == "9q8yyk" },
            timeout: TestConstants.settleTimeout
        )
        #expect(typed)

        panicEpoch.value &+= 1

        let emptied = await TestHelpers.waitUntil(
            { host.textField?.text?.isEmpty == true },
            timeout: TestConstants.settleTimeout
        )
        #expect(emptied)
        // The nearby cells now come from a fix taken after the wipe.
        #expect(location.requestLocationCallCount == 2)
        #expect(location.startUpdatingLocationCallCount == 0)
        #expect(location.requestAuthorizationCallCount == 0)
    }

    // MARK: - The split layout

    /// #mesh leads, pinned on screen, beside the idle picker; the trailing
    /// pane then shows the selected geohash with its own composer, and a DM
    /// covering it until it ends. Each pane's composer names its own
    /// conversation, and the screenshot flag follows what the trailing pane
    /// shows as each selection lands (E10). In either theme's layout.
    @Test(arguments: AppTheme.allCases)
    func contentView_splitShowsEachTrailingPane(theme: AppTheme) async {
        let split = await SplitContentHost.make(theme: theme)
        defer { split.close() }

        let idle = await split.settle {
            split.isMeshPinned
                && split.chrome.splitLayoutShowsLocation == true
                && split.leadingPrompts.contains { $0.contains("#mesh") }
                && split.trailingPrompts == ["geohash"]
        }
        #expect(idle, "idle picker beside #mesh: \(split.diagnostics)")

        #expect(await split.select(.location(split.geohash)))
        let channel = await split.settle {
            split.trailingPrompts.contains { $0.contains("#\(split.geohash.geohash)") }
                && split.chrome.splitLayoutShowsLocation == true
        }
        #expect(channel, "geohash pane: \(split.diagnostics)")

        #expect(await split.open(split.bob))
        let conversation = await split.settle {
            split.trailingPrompts.contains { $0.contains("Bob") }
                && split.chrome.splitLayoutShowsLocation == false
        }
        #expect(conversation, "DM pane: \(split.diagnostics)")
        // #mesh keeps its composer beside the DM.
        #expect(split.leadingPrompts.contains { $0.contains("#mesh") })

        split.models.privateConversationModel.endConversation()
        let back = await split.settle {
            split.trailingPrompts.contains { $0.contains("#\(split.geohash.geohash)") }
                && split.chrome.splitLayoutShowsLocation == true
        }
        #expect(back, "geohash again: \(split.diagnostics)")
        // The picker never prompted, nor kept location running (I3).
        #expect(split.location.requestAuthorizationCallCount == 0)
        #expect(split.location.startUpdatingLocationCallCount == 0)
    }

    /// E3, then E4: folding from #mesh parks the geohash and the mesh DM
    /// (#mesh selected, the DM ended, #mesh unpinned); unfolding brings both
    /// back, the DM over the geohash.
    @Test
    func contentView_foldFromMeshParksTheGeohashAndDMUntilUnfold() async {
        let split = await SplitContentHost.make()
        defer { split.close() }
        #expect(await split.select(.location(split.geohash)))
        #expect(await split.open(split.bob))
        #expect(split.touch(.leading))

        #expect(await split.fold())
        let parked = await split.settle {
            split.timelineChannel == .mesh
                && split.channels.selectedChannel == .mesh
                && split.openPeer == nil
        }
        #expect(parked)
        #expect(!split.isMeshPinned)

        #expect(await split.unfold())
        let restored = await split.settle {
            split.timelineChannel == .location(split.geohash)
                && split.openPeer == split.bob
                && split.chrome.splitLayoutShowsLocation == false
        }
        #expect(restored)
        #expect(split.isMeshPinned)
    }

    /// E2: folding from the trailing pane keeps the geohash and the DM
    /// (into the sheet); nothing is selected away or ended.
    @Test
    func contentView_foldFromTheTrailingPaneKeepsEverything() async {
        let split = await SplitContentHost.make()
        defer { split.close() }
        #expect(await split.select(.location(split.geohash)))
        // Opening the DM gives the trailing pane the focus.
        #expect(await split.open(split.bob))

        #expect(await split.fold())
        let moved = await TestHelpers.waitUntil(
            { split.channels.selectedChannel != .location(split.geohash) || split.openPeer != split.bob },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!moved)
    }

    /// E3's exception: a geohash DM needs its geohash live, so even a fold
    /// from #mesh keeps both.
    @Test
    func contentView_foldKeepsAGeohashDMWithItsGeohash() async {
        let split = await SplitContentHost.make()
        defer { split.close() }
        let geoDM = PeerID(nostr_: String(repeating: "ef", count: 32))
        #expect(await split.select(.location(split.geohash)))
        #expect(await split.open(geoDM))
        #expect(split.touch(.leading))

        #expect(await split.fold())
        let moved = await TestHelpers.waitUntil(
            { split.channels.selectedChannel != .location(split.geohash) || split.openPeer != geoDM },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!moved)
    }

    /// E5: choosing a location channel while folded drops what was parked,
    /// for good: back on #mesh before unfolding, neither the parked geohash
    /// nor the parked DM returns, and the trailing pane is the idle picker.
    @Test
    func contentView_compactLocationChoiceDropsWhatWasParked() async {
        let split = await SplitContentHost.make()
        defer { split.close() }
        let other = GeohashChannel(level: .neighborhood, geohash: "9q8yyk")
        #expect(await split.select(.location(split.geohash)))
        #expect(await split.open(split.bob))
        #expect(split.touch(.leading))
        #expect(await split.fold())
        #expect(await split.settle { split.timelineChannel == .mesh && split.openPeer == nil })

        #expect(await split.select(.location(other)))
        #expect(await split.select(.mesh))
        #expect(await split.unfold())
        let idle = await split.settle { split.trailingPrompts == ["geohash"] }
        #expect(idle, "\(split.diagnostics)")
        let restored = await TestHelpers.waitUntil(
            { split.channels.selectedChannel != .mesh || split.openPeer != nil },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!restored)
    }

    /// I4/E6: a panic wipe while folded leaves nothing for the unfold to
    /// rejoin or reopen: the trailing pane comes back as the idle picker.
    @Test
    func contentView_panicWhileFoldedLeavesNothingToRestore() async {
        let split = await SplitContentHost.make()
        defer { split.close() }
        #expect(await split.select(.location(split.geohash)))
        #expect(await split.open(split.bob))
        #expect(split.touch(.leading))
        #expect(await split.fold())
        #expect(await split.settle { split.timelineChannel == .mesh && split.openPeer == nil })

        split.chrome.panicClearAllData()

        #expect(await split.unfold())
        let idle = await split.settle { split.trailingPrompts == ["geohash"] }
        #expect(idle, "\(split.diagnostics)")
        let restored = await TestHelpers.waitUntil(
            { split.channels.selectedChannel != .mesh || split.openPeer != nil },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!restored)
    }

    /// I4: a wipe in the split layout takes the trailing geohash with it:
    /// the pane goes back to the idle picker once #mesh lands.
    @Test
    func contentView_panicReturnsTheTrailingPaneToThePicker() async {
        let split = await SplitContentHost.make()
        defer { split.close() }
        #expect(await split.select(.location(split.geohash)))
        let channel = await split.settle { split.trailingPrompts.contains { $0.contains("#\(split.geohash.geohash)") } }
        #expect(channel, "\(split.diagnostics)")

        split.chrome.panicClearAllData()

        let idle = await split.settle {
            split.timelineChannel == .mesh
                && split.trailingPrompts == ["geohash"]
                && split.chrome.splitLayoutShowsLocation == true
        }
        #expect(idle, "\(split.diagnostics)")
    }

    /// E8: the location sheet up at unfold closes, and the trailing pane
    /// shows the picker in its place, browsing from the selected geohash
    /// rather than showing it.
    @Test
    func contentView_unfoldTurnsTheLocationSheetIntoThePicker() async {
        let split = await SplitContentHost.make(compact: true)
        defer { split.close() }
        #expect(await split.select(.location(split.geohash)))
        split.chrome.isLocationChannelsSheetPresented = true

        #expect(await split.unfold())
        let browsing = await split.settle {
            !split.chrome.isLocationChannelsSheetPresented
                && split.trailingPrompts == ["geohash"]
                && split.chrome.splitLayoutShowsLocation == true
        }
        #expect(browsing, "\(split.diagnostics)")
        #expect(split.channels.selectedChannel == .location(split.geohash))
    }

    /// E1 and E11: shared content goes to the last-touched pane's composer,
    /// and the review names that pane's conversation; a pane without a
    /// composer (the picker) leaves it to #mesh's. Each share is reviewed
    /// in an alert, over the panes, so each pane is touched before its share
    /// arrives.
    @Test
    func contentView_shareGoesToTheLastTouchedPane() async throws {
        let suite = "ViewSmokeTests.split.share.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SharedContentStore(defaults: defaults)
        let split = await SplitContentHost.make(sharedContentStore: store)
        let shares = split.models.sharedContentImportModel
        defer {
            shares.discardAll()
            split.close()
        }
        let geohash = SharedContentDestination.geohash(split.geohash.geohash)
        /// A share arriving under the runtime's `label`, which the root
        /// relabels for the composer it fills; then reviewed away.
        func share(labelled label: SharedContentDestination, settlesOn expected: SharedContentDestination) async -> Bool {
            let now = Date()
            try? store.stage(.text("shared from another app", createdAt: now), now: now)
            shares.refresh(destination: label, now: now)
            let settled = await split.settle { shares.offer?.destination == expected }
            shares.discardAll()
            _ = await split.settle { !split.isPresenting }
            return settled
        }

        // The picker has no composer: #mesh takes it, whichever pane.
        #expect(split.touch(.trailing))
        #expect(await share(labelled: geohash, settlesOn: .mesh))

        #expect(await split.select(.location(split.geohash)))
        #expect(split.touch(.trailing))
        #expect(await share(labelled: .mesh, settlesOn: geohash))

        #expect(split.touch(.leading))
        #expect(await share(labelled: geohash, settlesOn: .mesh))
    }

    /// E11: the share review names the composer the share would fill. The
    /// runtime labels a share from the selection each time it looks for one
    /// (launch, the share link, becoming active), and the selection need not
    /// be where that composer sends (the split layout's other pane, or a
    /// switch still landing). The root relabels it on every look, not only
    /// when a new share arrives.
    @Test
    func contentView_namesTheComposerAShareFillsAfterEveryLook() async throws {
        let suite = "ViewSmokeTests.share.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SharedContentStore(defaults: defaults)
        let (viewModel, _, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel, sharedContentStore: store)
        let shares = featureModels.sharedContentImportModel
        let sizeClass = SmokeSizeClass()
        sizeClass.value = .compact
        let host = WindowHost(
            installSmokeEnvironment(ContentViewSizeClassHarness(sizeClass: sizeClass), featureModels: featureModels),
            size: CGSize(width: 390, height: 844)
        )
        defer {
            shares.discardAll()
            host.close()
        }
        let now = Date()
        try store.stage(.text("shared from another app", createdAt: now), now: now)
        // The public composer sends to #mesh, the timeline on screen; the
        // runtime's selection names a geohash.
        let selection = SharedContentDestination.geohash("u4pruy")

        // A share arriving takes the composer's conversation.
        shares.refresh(destination: selection, now: now)
        let labelled = await TestHelpers.waitUntil(
            { shares.offer?.destination == .mesh },
            timeout: TestConstants.settleTimeout
        )
        #expect(labelled)

        // The runtime looks again and labels the same share from the
        // selection once more.
        shares.refresh(destination: selection, now: now)
        #expect(shares.offer?.destination == selection)
        let relabelled = await TestHelpers.waitUntil(
            { shares.offer?.destination == .mesh },
            timeout: TestConstants.settleTimeout
        )
        #expect(relabelled)
        #expect(shares.offer?.payload.content == "shared from another app")
    }

    /// E13: a fingerprint asked for in a popover is the popover's own, so it
    /// can't come back as the root's fingerprint sheet once the popover goes.
    @Test
    func peopleList_popoverKeepsItsFingerprintToItself() {
        let (viewModel, _, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let chrome = featureModels.appChromeModel
        let peerID = PeerID(str: "7172737475767778")
        var shownInPopover: [PeerID] = []

        ContentPeopleListView.showFingerprint(
            for: peerID,
            presentation: .popover(onClose: {}, onShowFingerprint: { shownInPopover.append($0) }),
            appChromeModel: chrome
        )
        #expect(shownInPopover == [peerID])
        #expect(chrome.showingFingerprintFor == nil)

        // The sheet pushes the app-wide one, as before.
        ContentPeopleListView.showFingerprint(for: peerID, presentation: .sheet, appChromeModel: chrome)
        #expect(chrome.showingFingerprintFor == peerID)
        #expect(shownInPopover == [peerID])
    }

    /// A popover row closes the popover once its DM is open, and only then:
    /// a blocked peer's DM doesn't open, so the popover stays.
    @Test
    func peopleList_popoverClosesOnlyOnceTheDMIsOpen() async {
        let (viewModel, transport, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let conversations = featureModels.privateConversationModel
        let blocked = PeerID(str: "8182838485868788")
        let reachable = PeerID(str: "9192939495969798")
        transport.updatePeerSnapshots([
            makeSnapshot(peerID: blocked, nickname: "Mallory", noiseByte: 0x81),
            makeSnapshot(peerID: reachable, nickname: "Carol", noiseByte: 0x91)
        ])
        let known = await TestHelpers.waitUntil(
            { featureModels.peerListModel.meshRows.contains { $0.peerID == blocked } },
            timeout: TestConstants.settleTimeout
        )
        #expect(known)
        featureModels.conversationUIModel.block(peerID: blocked, displayName: "Mallory", from: .mesh)
        #expect(viewModel.isPeerBlocked(blocked))

        #expect(!ContentPeopleListView.openConversationFromPopover(with: blocked, in: conversations))
        #expect(conversations.selectedPeerID == nil)

        #expect(ContentPeopleListView.openConversationFromPopover(with: reachable, in: conversations))
        #expect(conversations.selectedPeerID == reachable)
    }

    @Test
    func paneTouchObserver_mounts() {
        _ = mount(PaneTouchObserver { _ in })
        _ = mount(Color.clear.background(PaneTouchObserver { _ in }))
    }
    #endif

    @Test
    func contentHeader_rendersTheSingleColumnAndBothPaneBars() async {
        let (viewModel, _, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let geohash = GeohashChannel(level: .city, geohash: "u4pru")
        let configurations = [
            // The single column (compact iOS, macOS): today's bar.
            ContentHeaderHarness(),
            // Split, leading: #mesh as a label, the app chrome, mesh people.
            ContentHeaderHarness(paneChannel: .mesh, isBadgeStatic: true, handlesPaneTaps: true),
            // Split, trailing: the geohash's badge, bookmark and people only.
            ContentHeaderHarness(paneChannel: .location(geohash), carriesAppChrome: false, handlesPaneTaps: true)
        ]

        for configuration in configurations {
            _ = mount(installSmokeEnvironment(configuration, featureModels: featureModels))
        }
        // With the geohash selected, as the split layout runs it.
        featureModels.locationChannelsModel.select(.location(geohash))
        defer { featureModels.locationChannelsModel.select(.mesh) }
        _ = await TestHelpers.waitUntil(
            { featureModels.locationChannelsModel.selectedChannel.isLocation },
            timeout: TestConstants.settleTimeout
        )
        for configuration in configurations {
            _ = mount(installSmokeEnvironment(configuration, featureModels: featureModels))
        }
        #expect(featureModels.locationChannelsModel.selectedChannel == .location(geohash))
    }

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

    @Test("Root alerts wait for the legacy media consent dialog")
    func rootAlertGuards_includeLegacyMediaConsent() {
        #expect(
            ContentRootModalPresentationState(
                isLegacyMediaConsentPresented: true
            ).hasPresentation
        )
    }

    /// E13: the root presents a pane's people popover, so nothing else may
    /// present from the root until it closes.
    @Test("Root alerts wait for a people popover")
    func rootAlertGuards_includeThePeoplePopover() {
        let (viewModel, _, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)

        #expect(ContentRootModalPresentationState(isPeoplePopoverPresented: true).hasPresentation)
        #expect(!ContentRootModalPresentationState(appChromeModel: featureModels.appChromeModel).hasPresentation)
        #expect(ContentRootModalPresentationState(
            appChromeModel: featureModels.appChromeModel,
            isPeoplePopoverPresented: true
        ).hasPresentation)
    }

    @Test("Only the people column's consent dialog holds back root alerts")
    func rootAlertGuards_legacyConsentDefersOnlyOnSplitLayout() {
        #expect(ContentRootModalPresentationState.legacyConsentDefersRoot(
            isSplitLayout: true,
            hasPendingRequest: true
        ))
        // Compact: the people sheet hosts the dialog and defers the root on
        // its own; a request left behind once it closed has no presenter.
        #expect(!ContentRootModalPresentationState.legacyConsentDefersRoot(
            isSplitLayout: false,
            hasPendingRequest: true
        ))
        #expect(!ContentRootModalPresentationState.legacyConsentDefersRoot(
            isSplitLayout: true,
            hasPendingRequest: false
        ))
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

        #expect(preview.videoPreviewLayer.videoGravity == .resizeAspectFill)
        #endif
    }
}
