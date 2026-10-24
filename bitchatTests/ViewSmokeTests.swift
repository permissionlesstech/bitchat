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

/// A photo button that picks nothing.
#if os(iOS)
private let noMediaPick: MediaPickAction = { _ in }
#else
private let noMediaPick: MediaPickAction = {}
#endif

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
            onPickMedia: noMediaPick,
            mediaPickRequest: $mediaPickRequest
        )
    }
}

/// One composer on a slot's session, pointed at its conversation.
@MainActor
private struct ComposerHarness: View {
    @ObservedObject var session: ComposerSession
    @StateObject private var voiceRecordingVM = VoiceRecordingViewModel()
    @FocusState private var focusedComposer: ComposerSlot?

    var body: some View {
        ContentComposerView(
            session: session,
            focus: $focusedComposer,
            voiceRecordingVM: voiceRecordingVM,
            onSend: {},
            onPickMedia: noMediaPick
        )
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
    /// The pane's own people button (split layout).
    var handlesPeopleTap = false
    /// The pane's own badge action (split layout, trailing); without one a
    /// pane's badge is a label.
    var handlesBadgeTap = false
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
            onPeopleTap: handlesPeopleTap ? {} : nil,
            onBadgeTap: handlesBadgeTap ? {} : nil
        )
    }
}

#if os(iOS)
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

/// A `LocationStateManager` on a fresh defaults suite whose CoreLocation
/// seam (`location`) reports `status`. Its permission reaches a model a hop
/// or more after the model is made.
@MainActor
private func makeMockLocationManager(
    authorizationStatus: CLAuthorizationStatus
) -> (manager: LocationStateManager, location: MockLocationStateManaging) {
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
    return (manager, location)
}

/// A `LocationChannelsModel` whose CoreLocation seam (`location`) reports
/// `status`, settled once the permission has reached the model.
@MainActor
private func makeSmokeLocationChannelsModel(
    authorizationStatus: CLAuthorizationStatus
) async -> (model: LocationChannelsModel, location: MockLocationStateManaging) {
    let (manager, location) = makeMockLocationManager(authorizationStatus: authorizationStatus)
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
        Self.first(UITextField.self, in: window)
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

    /// What the window presents over the hosted view, if anything.
    var presented: UIViewController? {
        window.rootViewController?.presentedViewController
    }

    /// The text field whose centre lies in `region` (window coordinates)
    /// and whose prompt `matches`.
    func textField(in region: CGRect, prompt matches: (String) -> Bool) -> UITextField? {
        window.layoutIfNeeded()
        return Self.textFields(in: window).first { field in
            let center = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: window)
            let prompt = field.attributedPlaceholder?.string ?? field.placeholder ?? ""
            return region.contains(center) && matches(prompt)
        }
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
            onChoose: { _ in },
            onClose: nil
        )
    }
}

/// Stands in for the device's width class, which decides the split layout.
@MainActor
private final class SmokeSizeClass: ObservableObject {
    @Published var value: UserInterfaceSizeClass = .regular
}

/// Counts the frames the main run loop renders, so a test can wait for
/// SwiftUI to catch up with something UIKit did: a field taking the
/// keyboard reaches its `FocusState` a render later.
@MainActor
private final class FrameCounter: NSObject {
    private(set) var count = 0
    private var link: CADisplayLink?

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// The display link holds its target until it is invalidated.
    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        count += 1
    }
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
    /// The share-import store on a temporary defaults suite (`make(shares:)`):
    /// stage a share in it, and the runtime's refresh offers it.
    let sharedContentStore: SharedContentStore?
    private let sharesSuite: String?
    private let frames = FrameCounter()
    /// Taps on the panes' people buttons (`splitLayoutTestTaps`).
    private let taps = PassthroughSubject<SplitLayoutTestTap, Never>()

    private static let size = CGSize(width: 1000, height: 800)
    private static let leadingRegion = CGRect(x: 0, y: 0, width: 480, height: 800)
    private static let trailingRegion = CGRect(x: 520, y: 0, width: 480, height: 800)

    private init(
        viewModel: ChatViewModel,
        models: SmokeFeatureModels,
        location: MockLocationStateManaging,
        sizeClass: SmokeSizeClass,
        theme: AppTheme,
        sharedContentStore: SharedContentStore?,
        sharesSuite: String?,
        sceneIsActive: Bool
    ) {
        self.viewModel = viewModel
        self.models = models
        self.location = location
        self.sizeClass = sizeClass
        self.sharedContentStore = sharedContentStore
        self.sharesSuite = sharesSuite
        meshPaneTimeline = PublicChatModel(conversations: viewModel.conversations, pinnedTo: .mesh)
        host = WindowHost(
            installSmokeEnvironment(
                ContentViewSizeClassHarness(
                    sizeClass: sizeClass,
                    meshPaneTimeline: meshPaneTimeline,
                    theme: theme,
                    testTaps: taps,
                    scenePhase: sceneIsActive ? .active : nil
                ),
                featureModels: models
            ),
            size: Self.size
        )
    }

    /// - Parameters:
    ///   - compact: Start folded (the single column).
    ///   - theme: Matrix (opaque bars) or glass (panels floating over the
    ///     timelines).
    ///   - shares: Back the share-import review with a store of its own
    ///     (`sharedContentStore`), whose shares and defaults suite `close()`
    ///     discards. Without one no share is ever pending.
    ///   - sceneIsActive: Report an active scene, as the app's does, so the
    ///     root alerts that wait for one (Bluetooth, recording errors) can
    ///     present. Off by default: the simulator's Bluetooth state can
    ///     raise the Bluetooth alert on its own, and a presentation left up
    ///     when a test closes its window stalls the windows after it.
    /// - Throws: When the host can't show the layout: the test host is in
    ///   the background (its windows stop catching up with their views),
    ///   the window isn't key, or the setup never settles. The failure
    ///   says which, with the host's diagnostics, at once: every later
    ///   step would only run its own deadline out.
    static func make(
        compact: Bool = false,
        theme: AppTheme = .matrix,
        shares: Bool = false,
        sceneIsActive: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> SplitContentHost {
        try #require(
            UIApplication.shared.applicationState != .background,
            "the test host is in the background, where its windows don't render",
            sourceLocation: sourceLocation
        )
        let (manager, location) = makeMockLocationManager(authorizationStatus: .authorizedWhenInUse)
        let sharesSuite = shares ? "ViewSmokeTests.split.shares.\(UUID().uuidString)" : nil
        let sharedContentStore = sharesSuite
            .flatMap { UserDefaults(suiteName: $0) }
            .map { SharedContentStore(defaults: $0) }
        let (viewModel, transport, _) = makeSmokeViewModel(locationManager: manager)
        let models = makeSmokeFeatureModels(
            for: viewModel,
            sharedContentStore: sharedContentStore,
            locationManager: manager
        )
        let authorized = await TestHelpers.waitUntil(
            { models.locationChannelsModel.permissionState == .authorized },
            timeout: TestConstants.settleTimeout
        )
        try #require(authorized, "location permission never reached the model", sourceLocation: sourceLocation)
        let sizeClass = SmokeSizeClass()
        sizeClass.value = compact ? .compact : .regular
        let split = SplitContentHost(
            viewModel: viewModel,
            models: models,
            location: location,
            sizeClass: sizeClass,
            theme: theme,
            sharedContentStore: sharedContentStore,
            sharesSuite: sharesSuite,
            sceneIsActive: sceneIsActive
        )
        // A failed setup closes its window: the test never gets to.
        do {
            try #require(
                split.host.window.isKeyWindow,
                "the host window isn't key: \(split.diagnostics)",
                sourceLocation: sourceLocation
            )
            transport.updatePeerSnapshots([
                makeSnapshot(peerID: split.bob, nickname: "Bob", noiseByte: 0xB0)
            ])
            try await split.require(
                "Bob in the people list",
                sourceLocation: sourceLocation
            ) { models.peerListModel.meshRows.contains { $0.peerID == split.bob } }
            try await split.require("the layout", sourceLocation: sourceLocation) {
                split.chrome.splitLayoutShowsLocation != nil || compact
            }
        } catch {
            split.close()
            throw error
        }
        return split
    }

    var chrome: AppChromeModel { models.appChromeModel }
    var channels: LocationChannelsModel { models.locationChannelsModel }
    var openPeer: PeerID? { models.privateConversationModel.selectedPeerID }
    /// Bob's Noise key ID: his DM moves there when he drops out of range.
    var bobStableID: PeerID { PeerID(hexData: Data(repeating: 0xB0, count: 32)) }
    /// The channel the selection's timeline renders.
    var timelineChannel: ChannelID { models.publicChatModel.channel }
    var isMeshPinned: Bool { viewModel.conversations.isMeshPinnedOnScreen }
    /// The window presents something over the panes (the share review).
    var isPresenting: Bool { host.presented != nil }
    /// What the window presents, if it is an alert (`.alert`) or a dialog
    /// (`.actionSheet`, the legacy-media consent).
    var presentedAlert: UIAlertController? { host.presented as? UIAlertController }
    /// A people popover is up: presented as a popover, and neither an alert
    /// nor a dialog (which wide layouts also present as popovers).
    var isPresentingPopover: Bool {
        guard let presented = host.presented else { return false }
        return !(presented is UIAlertController) && presented.modalPresentationStyle == .popover
    }
    /// The prompts of the text fields in each pane: its composer's names
    /// its conversation; the picker's teleport field reads "geohash".
    var leadingPrompts: [String] { host.placeholders(in: Self.leadingRegion) }
    var trailingPrompts: [String] { host.placeholders(in: Self.trailingRegion) }

    /// Waits until `condition` holds, up to the settle deadline. A test host
    /// in the background stops rendering its windows, so a wait on what
    /// they show would only run the deadline out: it gives up at once
    /// instead, and the diagnostics say the app isn't active.
    func settle(_ condition: @escaping () -> Bool) async -> Bool {
        _ = await TestHelpers.waitUntil(
            { condition() || UIApplication.shared.applicationState == .background },
            timeout: TestConstants.settleTimeout
        )
        return condition()
    }

    /// `settle`, as a step the test needs: one that never settles stops the
    /// test there, with the host's diagnostics, rather than leave every
    /// later step to wait out its own deadline.
    func require(
        _ step: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @escaping () -> Bool
    ) async throws {
        let settled = await settle(condition)
        try #require(settled, "\(step): \(diagnostics)", sourceLocation: sourceLocation)
    }

    /// Selects `channel` and waits until the timeline renders it.
    func select(_ channel: ChannelID, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        channels.select(channel)
        try await require("select \(channel)", sourceLocation: sourceLocation) { self.timelineChannel == channel }
    }

    func open(_ peer: PeerID, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        models.privateConversationModel.startConversation(with: peer)
        try await require("open \(peer)", sourceLocation: sourceLocation) { self.openPeer == peer }
    }

    /// A touch going down in the middle of `pane`.
    func touch(_ pane: ContentPane) -> Bool {
        let region = Self.region(of: pane)
        return host.touchDown(at: CGPoint(x: region.midX, y: region.midY))
    }

    private static func region(of pane: ContentPane) -> CGRect {
        pane == .leading ? leadingRegion : trailingRegion
    }

    /// A tap on a people button: a bar's, or the open popover's close.
    func tap(_ tap: SplitLayoutTestTap) {
        taps.send(tap)
    }

    /// The open DM handed to another ID of the same person, as a
    /// disconnect (the Noise key's ID) or a reconnect (a new short ID)
    /// hands it: its messages move, then the selection.
    func handOffDM(to peer: PeerID) {
        guard let current = viewModel.selectedPrivateChatPeer else { return }
        viewModel.migratePrivateChat(from: current, to: peer)
        viewModel.selectedPrivateChatPeer = peer
    }

    /// A private-media send to Bob's legacy client asking for consent;
    /// `answer` gets the answer it is given.
    func requestLegacyConsent(answer: @escaping @MainActor (Bool) -> Void = { _ in }) {
        viewModel.enqueueLegacyPrivateMediaConsent(
            for: bob,
            transferId: "split-consent-transfer",
            messageID: "split-consent-message",
            completion: answer
        )
    }

    /// A location fix arriving: the device's cells, its building cell
    /// included, become known.
    func deliverLocationFix(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        location.delegate?.locationManager?(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 48.8566, longitude: 2.3522)]
        )
        try await require("the building cell", sourceLocation: sourceLocation) {
            self.channels.currentBuildingGeohash != nil
        }
    }

    /// Presents something over the panes that the root doesn't know about,
    /// as a list's own dialog or a bar's share sheet is.
    func presentUntracked() {
        host.window.rootViewController?.present(UIViewController(), animated: false)
    }

    /// Whether what the window presents is `presentUntracked()`'s.
    var isPresentingUntracked: Bool {
        guard let presented = host.presented else { return false }
        return type(of: presented) == UIViewController.self
    }

    func dismissUntracked() {
        host.window.rootViewController?.dismiss(animated: false)
    }

    /// The composer field in `pane`: the picker's teleport field
    /// ("geohash") isn't one.
    func composerField(in pane: ContentPane) -> UITextField? {
        host.textField(in: Self.region(of: pane)) { $0 != "geohash" }
    }

    /// The text field, anywhere in the window (a sheet's included), whose
    /// prompt `matches`.
    func field(prompt matches: (String) -> Bool) -> UITextField? {
        host.textField(in: CGRect(origin: .zero, size: Self.size), prompt: matches)
    }

    /// Types `text` into `field` and presses return, as the keyboard does:
    /// its return key types a newline, which a text field turns into its
    /// submit. The composer sends.
    func submit(_ text: String, in field: UITextField) {
        _ = field.becomeFirstResponder()
        field.insertText(text)
        field.insertText("\n")
    }

    /// Waits for `count` more frames: by then SwiftUI has applied what
    /// UIKit reported before the wait (a field taking the keyboard).
    func settleFrames(_ count: Int = 5) async -> Bool {
        frames.start()
        let target = frames.count + count
        return await settle { self.frames.count >= target }
    }

    /// A share arriving under the runtime's `label`, which the root
    /// relabels for the composer it would fill; then reviewed away. Whether
    /// the review came to name `expected`. Needs a share store (`make`).
    func share(
        labelled label: SharedContentDestination,
        settlesOn expected: SharedContentDestination
    ) async -> Bool {
        guard let store = sharedContentStore else { return false }
        let shares = models.sharedContentImportModel
        let now = Date()
        try? store.stage(.text("shared from another app", createdAt: now), now: now)
        shares.refresh(destination: label, now: now)
        let settled = await settle { shares.offer?.destination == expected }
        shares.discardAll()
        _ = await settle { !self.isPresenting }
        return settled
    }

    func fold(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        sizeClass.value = .compact
        try await require("fold", sourceLocation: sourceLocation) { self.chrome.splitLayoutShowsLocation == nil }
    }

    func unfold(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        sizeClass.value = .regular
        try await require("unfold", sourceLocation: sourceLocation) { self.chrome.splitLayoutShowsLocation != nil }
    }

    func close() {
        frames.stop()
        if sharedContentStore != nil {
            models.sharedContentImportModel.discardAll()
        }
        host.close()
        if let sharesSuite {
            UserDefaults(suiteName: sharesSuite)?.removePersistentDomain(forName: sharesSuite)
        }
    }

    /// The state a failed expectation reports: the selection, the timeline,
    /// the DM, the layout flags, what is presented, whether the app is in
    /// the foreground (a backgrounded test host stops rendering its windows,
    /// whatever the state says) and every text field's prompt with where it
    /// sits in the window.
    var diagnostics: String {
        "selection \(channels.selectedChannel), timeline \(timelineChannel), DM \(String(describing: openPeer)), "
            + "split flag \(String(describing: chrome.splitLayoutShowsLocation)), pinned \(isMeshPinned), "
            + "presented \(String(describing: host.presented))"
            + (presentedAlert.map { " \"\($0.title ?? "")\" style \($0.preferredStyle.rawValue)" } ?? "") + ", "
            + "app \(UIApplication.shared.applicationState == .active ? "active" : "not active"), "
            + "fields \(host.fieldReport)"
    }
}

/// ContentView with a test-driven width class and, for the split layout,
/// the pinned #mesh timeline the app scene hands it
/// (`ContentModelReferences.meshPaneTimeline`).
@MainActor
private struct ContentViewSizeClassHarness: View {
    @ObservedObject var sizeClass: SmokeSizeClass
    var meshPaneTimeline: PublicChatModel?
    var theme: AppTheme = .matrix
    var testTaps: PassthroughSubject<SplitLayoutTestTap, Never>?
    /// The scene's phase as the app's scene would report it. A view hosted
    /// in a test window gets none, and the root alerts that wait for an
    /// active scene (Bluetooth, recording errors) never present there.
    var scenePhase: ScenePhase?

    var body: some View {
        ContentView()
            .environment(\.horizontalSizeClass, sizeClass.value)
            .transformEnvironment(\.contentModelReferences) { references in
                references?.meshPaneTimeline = meshPaneTimeline
            }
            .environment(\.appTheme, theme)
            .environment(\.splitLayoutTestTaps, testTaps)
            .transformEnvironment(\.scenePhase) { phase in
                if let scenePhase {
                    phase = scenePhase
                }
            }
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

    #if os(iOS)
    /// I3: the notices sheet keeps the geo scope it opened with. Opened on a
    /// location channel, a selection it didn't make (a fold selecting
    /// #mesh beneath it) never moves it onto the device's location: no
    /// continuous location updates start, though the device's building
    /// cell is known.
    @Test
    func noticesView_keepsTheGeoScopeItOpenedWith() async throws {
        let suiteName = "ViewSmokeTests.notices.\(UUID().uuidString)"
        let storage = try #require(UserDefaults(suiteName: suiteName))
        defer { storage.removePersistentDomain(forName: suiteName) }
        let location = MockLocationStateManaging(authorizationStatus: .authorizedWhenInUse)
        let manager = LocationStateManager(
            storage: storage,
            locationManager: location,
            geocoder: MockLocationStateGeocoder(),
            shouldInitializeCoreLocation: true
        )
        let channels = LocationChannelsModel(manager: manager)
        let authorized = await TestHelpers.waitUntil(
            { channels.permissionState == .authorized },
            timeout: TestConstants.settleTimeout
        )
        try #require(authorized)
        location.delegate?.locationManager?(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 48.8566, longitude: 2.3522)]
        )
        let located = await TestHelpers.waitUntil(
            { channels.currentBuildingGeohash != nil },
            timeout: TestConstants.settleTimeout
        )
        try #require(located)
        let remote = GeohashChannel(level: .city, geohash: "9q8yy")
        channels.select(.location(remote))
        let selected = await TestHelpers.waitUntil(
            { channels.selectedChannel == .location(remote) },
            timeout: TestConstants.settleTimeout
        )
        try #require(selected)

        let board = BoardManager(
            transport: MockTransport(),
            store: BoardStore(persistsToDisk: false, fileURL: nil, now: { Date() }),
            publishToNostr: { _, _, _, _, _ in nil },
            deleteFromNostr: { _, _ in }
        )
        let notes = LocationNotesManager(
            geohash: remote.geohash,
            dependencies: LocationNotesDependencies(
                relayLookup: { _, _ in [] },
                subscribe: { _, _, _, _, _ in },
                unsubscribe: { _ in },
                sendEvent: { _, _ in },
                deriveIdentity: { _ in try NostrIdentity.generate() },
                now: { Date() }
            )
        )
        let host = WindowHost(
            NoticesView(senderNickname: "me", board: board, initialTab: .geo, notesManager: notes)
                .environmentObject(channels),
            size: CGSize(width: 390, height: 844)
        )
        defer { host.close() }
        let updates = location.startUpdatingLocationCallCount

        channels.select(.mesh)
        let deselected = await TestHelpers.waitUntil(
            { channels.selectedChannel == .mesh },
            timeout: TestConstants.settleTimeout
        )
        try #require(deselected)
        let started = await TestHelpers.waitUntil(
            { location.startUpdatingLocationCallCount > updates },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!started, "the sheet moved onto the device's location")
        channels.endLiveRefresh()
    }
    #endif

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
        // Each slot's conversation, as the single column points the slots:
        // #mesh or a geohash, a DM in either scope, and no DM (no target).
        let cases: [(ComposerSlot, ComposerTargets, String)] = [
            (.primary, .single(activeChannel: .mesh, privatePeer: nil), ""),
            (.primary, .single(activeChannel: geohash, privatePeer: nil), "/f"),
            (.secondary, .single(activeChannel: .mesh, privatePeer: peerID), "hi @al"),
            (.secondary, .single(activeChannel: geohash, privatePeer: peerID), "/"),
            (.secondary, .single(activeChannel: .mesh, privatePeer: nil), "left behind")
        ]

        for (slot, targets, text) in cases {
            let composers = ComposerSessions(drafts: InMemoryComposerDraftStore())
            composers.retarget(targets, fingerprint: { _ in nil })
            let session = composers[slot]
            session.text = text
            if text.contains("@") {
                session.autocomplete = ComposerAutocompleteState(
                    suggestions: ["@alice", "@albert"],
                    range: NSRange(location: 3, length: 3)
                )
            }
            _ = mount(installSmokeEnvironment(
                ComposerHarness(session: session),
                featureModels: featureModels
            ))
            #expect(session.target == targets[slot])
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
        let host = WindowHost(bothLists, size: CGSize(width: 390, height: 844))
        // Both lists appear in the same pass; only the #mesh one holds.
        let held = await TestHelpers.waitUntil(
            { nearbyNotesHolderCount() == baseline + 1 },
            timeout: TestConstants.settleTimeout
        )
        #expect(held, "holders \(String(describing: nearbyNotesHolderCount())), baseline \(baseline)")
        #expect(nearbyNotesHolderCount() == baseline + 1)
        host.close()
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
                LocationChannelsPicker(presentation: pane, onChoose: { _ in }, onClose: nil)
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
                LocationChannelsPicker(presentation: pane, onChoose: { _ in }, onClose: {})
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
    func contentView_splitShowsEachTrailingPane(theme: AppTheme) async throws {
        let split = try await SplitContentHost.make(theme: theme)
        defer { split.close() }

        try await split.require("idle picker beside #mesh") {
            split.isMeshPinned
                && split.chrome.splitLayoutShowsLocation == true
                && split.leadingPrompts.contains { $0.contains("#mesh") }
                && split.trailingPrompts == ["geohash"]
        }

        try await split.select(.location(split.geohash))
        try await split.require("geohash pane") {
            split.trailingPrompts.contains { $0.contains("#\(split.geohash.geohash)") }
                && split.chrome.splitLayoutShowsLocation == true
        }

        try await split.open(split.bob)
        try await split.require("DM pane") {
            split.trailingPrompts.contains { $0.contains("Bob") }
                && split.chrome.splitLayoutShowsLocation == false
        }
        // #mesh keeps its composer beside the DM.
        #expect(split.leadingPrompts.contains { $0.contains("#mesh") })

        split.models.privateConversationModel.endConversation()
        try await split.require("geohash again") {
            split.trailingPrompts.contains { $0.contains("#\(split.geohash.geohash)") }
                && split.chrome.splitLayoutShowsLocation == true
        }
        // The picker never prompted, nor kept location running (I3).
        #expect(split.location.requestAuthorizationCallCount == 0)
        #expect(split.location.startUpdatingLocationCallCount == 0)
    }

    /// E3, then E4: folding from #mesh parks the geohash and the mesh DM
    /// (#mesh selected, the DM ended, #mesh unpinned); unfolding brings both
    /// back, the DM over the geohash.
    @Test
    func contentView_foldFromMeshParksTheGeohashAndDMUntilUnfold() async throws {
        let split = try await SplitContentHost.make()
        defer { split.close() }
        try await split.select(.location(split.geohash))
        try await split.open(split.bob)
        try #require(split.touch(.leading))

        try await split.fold()
        try await split.require("parked") {
            split.timelineChannel == .mesh
                && split.channels.selectedChannel == .mesh
                && split.openPeer == nil
        }
        #expect(!split.isMeshPinned)

        try await split.unfold()
        try await split.require("restored") {
            split.timelineChannel == .location(split.geohash)
                && split.openPeer == split.bob
                && split.chrome.splitLayoutShowsLocation == false
        }
        #expect(split.isMeshPinned)
    }

    /// While a selected geohash lands (here E4 re-selecting the parked
    /// geohash: applied a hop after the unfold, rendered later still) the
    /// trailing pane holds a neutral placeholder. The picker never mounts
    /// for a pane about to show the geohash, so it never asks for a
    /// location fix.
    @Test
    func contentView_aGeohashLandingAfterAnUnfoldNeverMountsThePicker() async throws {
        let split = try await SplitContentHost.make()
        defer { split.close() }
        try await split.select(.location(split.geohash))
        try #require(split.touch(.leading))
        try await split.fold()
        try await split.require("parked") {
            split.timelineChannel == .mesh && split.channels.selectedChannel == .mesh
        }
        // Whatever the single column asked for itself (#mesh's building
        // cell, for the notices pin) has been asked.
        try #require(await split.settleFrames(), "\(split.diagnostics)")
        let fixes = split.location.requestLocationCallCount

        try await split.unfold()
        try await split.require("the geohash back") {
            split.trailingPrompts.contains { $0.contains("#\(split.geohash.geohash)") }
        }
        #expect(
            split.location.requestLocationCallCount == fixes,
            "the picker mounted while the geohash landed: \(split.diagnostics)"
        )
    }

    /// E2: folding from the trailing pane keeps the geohash and the DM
    /// (into the sheet); nothing is selected away or ended.
    @Test
    func contentView_foldFromTheTrailingPaneKeepsEverything() async throws {
        let split = try await SplitContentHost.make()
        defer { split.close() }
        try await split.select(.location(split.geohash))
        // Opening the DM gives the trailing pane the focus.
        try await split.open(split.bob)

        try await split.fold()
        let moved = await TestHelpers.waitUntil(
            { split.channels.selectedChannel != .location(split.geohash) || split.openPeer != split.bob },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!moved, "\(split.diagnostics)")
    }

    /// E3's exception: a geohash DM needs its geohash live, so even a fold
    /// from #mesh keeps both.
    @Test
    func contentView_foldKeepsAGeohashDMWithItsGeohash() async throws {
        let split = try await SplitContentHost.make()
        defer { split.close() }
        let geoDM = PeerID(nostr_: String(repeating: "ef", count: 32))
        try await split.select(.location(split.geohash))
        try await split.open(geoDM)
        try #require(split.touch(.leading))

        try await split.fold()
        let moved = await TestHelpers.waitUntil(
            { split.channels.selectedChannel != .location(split.geohash) || split.openPeer != geoDM },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!moved, "\(split.diagnostics)")
    }

    /// A geohash DM is scoped to the geohash it was opened over. A selection
    /// made beside it (a #geohash link or the nearby hint in the #mesh pane)
    /// ends it rather than moving it onto the new geohash's identity, and
    /// the trailing pane shows the channel that was asked for.
    @Test
    func contentView_aGeohashDMEndsWhenTheSelectionLeavesItsGeohash() async throws {
        let split = try await SplitContentHost.make()
        defer { split.close() }
        let geoDM = PeerID(nostr_: String(repeating: "ef", count: 32))
        let other = GeohashChannel(level: .neighborhood, geohash: "9q8yyk")
        try await split.select(.location(split.geohash))
        try await split.open(geoDM)

        split.channels.select(.location(other))

        try await split.require("the DM ended, the new geohash on screen") {
            split.timelineChannel == .location(other)
                && split.openPeer == nil
                && split.trailingPrompts.contains { $0.contains("#\(other.geohash)") }
        }
    }

    /// E5: choosing a location channel while folded drops what was parked,
    /// for good: back on #mesh before unfolding, neither the parked geohash
    /// nor the parked DM returns, and the trailing pane is the idle picker.
    @Test
    func contentView_compactLocationChoiceDropsWhatWasParked() async throws {
        let split = try await SplitContentHost.make()
        defer { split.close() }
        let other = GeohashChannel(level: .neighborhood, geohash: "9q8yyk")
        try await split.select(.location(split.geohash))
        try await split.open(split.bob)
        try #require(split.touch(.leading))
        try await split.fold()
        try await split.require("parked") { split.timelineChannel == .mesh && split.openPeer == nil }

        try await split.select(.location(other))
        try await split.select(.mesh)
        try await split.unfold()
        try await split.require("idle picker") { split.trailingPrompts == ["geohash"] }
        let restored = await TestHelpers.waitUntil(
            { split.channels.selectedChannel != .mesh || split.openPeer != nil },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!restored, "\(split.diagnostics)")
    }

    /// I4/E6: a panic wipe while folded leaves nothing for the unfold to
    /// rejoin or reopen: the trailing pane comes back as the idle picker.
    @Test
    func contentView_panicWhileFoldedLeavesNothingToRestore() async throws {
        let split = try await SplitContentHost.make()
        defer { split.close() }
        try await split.select(.location(split.geohash))
        try await split.open(split.bob)
        try #require(split.touch(.leading))
        try await split.fold()
        try await split.require("parked") { split.timelineChannel == .mesh && split.openPeer == nil }

        split.chrome.panicClearAllData()

        try await split.unfold()
        try await split.require("idle picker") { split.trailingPrompts == ["geohash"] }
        let restored = await TestHelpers.waitUntil(
            { split.channels.selectedChannel != .mesh || split.openPeer != nil },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!restored, "\(split.diagnostics)")
    }

    /// I4: a wipe in the split layout takes the trailing geohash with it:
    /// the pane goes back to the idle picker once #mesh lands.
    @Test
    func contentView_panicReturnsTheTrailingPaneToThePicker() async throws {
        let split = try await SplitContentHost.make()
        defer { split.close() }
        try await split.select(.location(split.geohash))
        try await split.require("geohash pane") {
            split.trailingPrompts.contains { $0.contains("#\(split.geohash.geohash)") }
        }

        split.chrome.panicClearAllData()

        try await split.require("idle picker") {
            split.timelineChannel == .mesh
                && split.trailingPrompts == ["geohash"]
                && split.chrome.splitLayoutShowsLocation == true
        }
    }

    /// E8: the location sheet up at unfold closes, and the trailing pane
    /// shows the picker in its place, browsing from the selected geohash
    /// rather than showing it.
    @Test
    func contentView_unfoldTurnsTheLocationSheetIntoThePicker() async throws {
        let split = try await SplitContentHost.make(compact: true)
        defer { split.close() }
        try await split.select(.location(split.geohash))
        split.chrome.isLocationChannelsSheetPresented = true
        try await split.require("location sheet") { split.isPresenting }

        try await split.unfold()
        try await split.require("browsing picker") {
            !split.chrome.isLocationChannelsSheetPresented
                && split.trailingPrompts == ["geohash"]
                && split.chrome.splitLayoutShowsLocation == true
        }
        #expect(split.channels.selectedChannel == .location(split.geohash))

        // The sheet's live updates end as it goes, which cancels the fix the
        // pane asked for as it appeared: the pane asks again.
        try await split.require("the sheet's updates end") {
            !split.isPresenting && split.location.stopUpdatingLocationCallCount > 0
        }
        #expect(split.location.isFixPending, "the pane's fix died with the sheet's updates")
        #expect(split.location.requestAuthorizationCallCount == 0)
    }

    /// I3 across an E3 fold: the notices sheet, opened on the trailing
    /// geohash's geo tab, closes as the fold selects #mesh, and never moves
    /// onto the device's location on the way: no continuous location
    /// updates start (beginLiveRefresh), so no building-cell notes request
    /// goes out either.
    @Test
    func contentView_aFoldNeverMovesTheNoticesSheetOntoDeviceLocation() async throws {
        let split = try await SplitContentHost.make()
        defer {
            split.chrome.isNoticesSheetPresented = false
            split.close()
        }
        try await split.deliverLocationFix()
        try await split.select(.location(split.geohash))
        try #require(split.touch(.leading))
        split.chrome.presentNotices()
        try await split.require("the notices sheet") { split.isPresenting }
        let updates = split.location.startUpdatingLocationCallCount

        try await split.fold()
        try await split.require("the notices sheet closed, #mesh selected") {
            !split.chrome.isNoticesSheetPresented
                && !split.isPresenting
                && split.channels.selectedChannel == .mesh
        }
        let started = await TestHelpers.waitUntil(
            { split.location.startUpdatingLocationCallCount > updates },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!started, "the notices sheet started live location updates: \(split.diagnostics)")
    }

    /// E1 and E11: shared content goes to the last-touched pane's composer,
    /// and the review names that pane's conversation; a pane without a
    /// composer (the picker) leaves it to #mesh's. Each share is reviewed
    /// in an alert, over the panes, so each pane is touched before its share
    /// arrives.
    @Test
    func contentView_shareGoesToTheLastTouchedPane() async throws {
        let split = try await SplitContentHost.make(shares: true)
        defer { split.close() }
        let geohash = SharedContentDestination.geohash(split.geohash.geohash)

        // The picker has no composer: #mesh takes it, whichever pane.
        try #require(split.touch(.trailing))
        try #require(await split.share(labelled: geohash, settlesOn: .mesh), "\(split.diagnostics)")

        try await split.select(.location(split.geohash))
        try #require(split.touch(.trailing))
        try #require(await split.share(labelled: .mesh, settlesOn: geohash), "\(split.diagnostics)")

        try #require(split.touch(.leading))
        try #require(await split.share(labelled: geohash, settlesOn: .mesh), "\(split.diagnostics)")
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

    /// E13: a people popover holds the root's alerts back (the Bluetooth
    /// alert here), and a fold closes it; the alert shows then.
    @Test
    func contentView_aPeoplePopoverHoldsRootAlertsBackUntilAFoldClosesIt() async throws {
        let split = try await SplitContentHost.make(sceneIsActive: true)
        defer {
            split.chrome.showBluetoothAlert = false
            split.close()
        }
        split.tap(.peopleButton(.leading))
        try await split.require("popover") { split.isPresentingPopover }

        split.chrome.showBluetoothAlert = true
        let presented = await TestHelpers.waitUntil(
            { split.presentedAlert != nil },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!presented, "\(split.diagnostics)")
        #expect(split.isPresentingPopover)

        try await split.fold()
        try await split.require("the alert after the fold") { split.presentedAlert?.preferredStyle == .alert }

        split.chrome.showBluetoothAlert = false
        try await split.require("the alert dismissed") { !split.isPresenting }
    }

    /// E13 and I5: while a people popover is up nothing else presents from
    /// the root. The screenshot warning (the leading bar's), the
    /// fingerprint sheet and the share review each wait, and show once the
    /// popover closes.
    @Test
    func contentView_aPeoplePopoverHoldsTheOtherPresentationsBack() async throws {
        let split = try await SplitContentHost.make(shares: true)
        let store = try #require(split.sharedContentStore)
        let shares = split.models.sharedContentImportModel
        defer {
            split.chrome.showScreenshotPrivacyWarning = false
            split.chrome.clearFingerprint()
            split.close()
        }
        /// `present` while the #mesh popover is up shows nothing over it;
        /// once it closes, `isShown` holds; `dismiss` takes that away.
        func waitsForThePopover(
            _ name: String,
            present: () -> Void,
            isShown: @escaping () -> Bool,
            dismiss: () -> Void
        ) async throws {
            split.tap(.peopleButton(.leading))
            try await split.require("\(name): the popover") { split.isPresentingPopover }
            present()
            let shownOver = await TestHelpers.waitUntil(
                { !split.isPresentingPopover || isShown() },
                timeout: TestConstants.negativeWaitWindow
            )
            #expect(!shownOver, "\(name) over the popover: \(split.diagnostics)")
            split.tap(.popoverCloseButton)
            try await split.require("\(name) after the popover") { isShown() }
            dismiss()
            try await split.require("\(name) dismissed") { !split.isPresenting }
        }

        try await waitsForThePopover(
            "screenshot warning",
            present: { split.chrome.showScreenshotPrivacyWarning = true },
            isShown: { split.presentedAlert?.preferredStyle == .alert },
            dismiss: { split.chrome.showScreenshotPrivacyWarning = false }
        )
        try await waitsForThePopover(
            "fingerprint sheet",
            present: { split.chrome.showFingerprint(for: split.bob) },
            isShown: { split.isPresenting && !split.isPresentingPopover && split.presentedAlert == nil },
            dismiss: { split.chrome.clearFingerprint() }
        )
        try await waitsForThePopover(
            "share review",
            present: {
                let now = Date()
                try? store.stage(.text("shared from another app", createdAt: now), now: now)
                shares.refresh(destination: .mesh, now: now)
            },
            isShown: { split.presentedAlert?.preferredStyle == .alert },
            dismiss: { shares.discardAll() }
        )
    }

    /// E13: the trailing bar's people button opens the geohash's people as
    /// a popover, through the action ContentView hands the button, and
    /// only while that bar is on screen: over the idle picker there is no
    /// button. Its close button closes it.
    @Test
    func contentView_theTrailingPeopleButtonOpensItsPopoverOverItsGeohash() async throws {
        let split = try await SplitContentHost.make()
        defer { split.close() }
        split.tap(.peopleButton(.trailing))
        let opened = await TestHelpers.waitUntil(
            { split.isPresentingPopover },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!opened, "a popover over the idle picker: \(split.diagnostics)")

        try await split.select(.location(split.geohash))
        try await split.require("the geohash pane") {
            split.trailingPrompts.contains { $0.contains("#\(split.geohash.geohash)") }
        }
        split.tap(.peopleButton(.trailing))
        try await split.require("the trailing popover") { split.isPresentingPopover }
        split.tap(.popoverCloseButton)
        try await split.require("the popover closed") { !split.isPresenting }
    }

    /// E1: choosing the DM that is already open from the #mesh pane (its
    /// sender's "direct message" in the #mesh list) moves the focus to it,
    /// as choosing anyone else would: a fold keeps it as the sheet (E2)
    /// rather than parking it with the geohash (E3).
    @Test
    func contentView_choosingTheOpenDMFromMeshTakesTheFocus() async throws {
        let split = try await SplitContentHost.make()
        defer { split.close() }
        try await split.select(.location(split.geohash))
        try await split.open(split.bob)
        try #require(split.touch(.leading))

        split.models.privateConversationModel.openConversation(for: split.bob, from: .mesh)

        try await split.fold()
        let moved = await TestHelpers.waitUntil(
            { split.channels.selectedChannel != .location(split.geohash) || split.openPeer != split.bob },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!moved, "\(split.diagnostics)")
    }

    /// A peer-ID handoff of the open DM (Bob drops out of range and his DM
    /// moves to his Noise key's ID) opens no DM: the #mesh people popover
    /// in use stays up, and a fold from #mesh still parks the geohash and
    /// the DM (E3) rather than keeping both (E2).
    @Test
    func contentView_aPeerIDHandoffOfTheOpenDMOpensNothing() async throws {
        let split = try await SplitContentHost.make()
        defer { split.close() }
        try await split.select(.location(split.geohash))
        try await split.open(split.bob)
        split.tap(.peopleButton(.leading))
        try await split.require("popover") { split.isPresentingPopover }

        split.handOffDM(to: split.bobStableID)
        try await split.require("handed off") { split.openPeer == split.bobStableID }
        let closed = await TestHelpers.waitUntil(
            { !split.isPresentingPopover },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!closed, "the popover closed under the handoff")

        try await split.fold()
        try await split.require("parked") {
            split.channels.selectedChannel == .mesh
                && split.timelineChannel == .mesh
                && split.openPeer == nil
        }
    }

    /// Brief item 6: the trailing pane hosts the legacy-media consent dialog
    /// whatever it shows, here the idle picker: a pending request always
    /// has a presenter, so the root alerts waiting on it can't wait for
    /// good.
    @Test
    func contentView_splitPresentsAPendingLegacyConsentRequest() async throws {
        let split = try await SplitContentHost.make()
        defer {
            split.viewModel.cancelAllLegacyPrivateMediaConsents()
            split.close()
        }
        try await split.require("idle picker") { split.trailingPrompts == ["geohash"] }

        split.requestLegacyConsent()
        try await split.require("the dialog") { split.presentedAlert?.preferredStyle == .actionSheet }

        split.viewModel.cancelAllLegacyPrivateMediaConsents()
        try await split.require("the dialog dismissed") { !split.isPresenting }
    }

    /// I5: a consent request arriving while a people popover is up waits
    /// for it, still pending, and shows once the popover closes.
    @Test
    func contentView_aPeoplePopoverHoldsTheConsentDialogBack() async throws {
        let split = try await SplitContentHost.make()
        defer {
            split.viewModel.cancelAllLegacyPrivateMediaConsents()
            split.close()
        }
        split.tap(.peopleButton(.leading))
        try await split.require("popover") { split.isPresentingPopover }

        split.requestLegacyConsent()
        let presented = await TestHelpers.waitUntil(
            { split.presentedAlert != nil },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!presented, "\(split.diagnostics)")
        #expect(split.isPresentingPopover)
        #expect(split.models.conversationUIModel.legacyPrivateMediaConsentRequest != nil)

        split.tap(.popoverCloseButton)
        try await split.require("the dialog after the popover") { split.presentedAlert?.preferredStyle == .actionSheet }
    }

    /// I5: whatever is on screen first keeps it. The screenshot warning
    /// (the leading bar's) flagged while the trailing pane's consent dialog
    /// shows waits for it, with its flag kept, and shows once the request
    /// is answered; the dialog isn't taken down unanswered.
    @Test
    func contentView_aShowingConsentDialogHoldsTheScreenshotWarningBack() async throws {
        let split = try await SplitContentHost.make()
        var answers: [Bool] = []
        defer {
            split.viewModel.cancelAllLegacyPrivateMediaConsents()
            split.chrome.showScreenshotPrivacyWarning = false
            split.close()
        }
        split.requestLegacyConsent { answers.append($0) }
        try await split.require("the dialog") { split.presentedAlert?.preferredStyle == .actionSheet }

        split.chrome.showScreenshotPrivacyWarning = true
        let replaced = await TestHelpers.waitUntil(
            { split.presentedAlert?.preferredStyle != .actionSheet || !answers.isEmpty },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!replaced, "\(split.diagnostics)")
        #expect(split.chrome.showScreenshotPrivacyWarning, "the warning's flag went")

        split.viewModel.cancelAllLegacyPrivateMediaConsents()
        try await split.require("the warning") { split.presentedAlert?.preferredStyle == .alert }
    }

    /// I5: a consent request arriving while another presentation is up
    /// waits behind it: the root fingerprint sheet (the trailing DM
    /// header's name opens it), the share review, the screenshot warning,
    /// and one the root doesn't track at all. It neither takes that
    /// presentation down nor gets answered unseen, and the dialog shows
    /// once the presentation has gone.
    @Test
    func contentView_aConsentRequestWaitsBehindTheRootPresentationUp() async throws {
        let split = try await SplitContentHost.make(shares: true)
        let store = try #require(split.sharedContentStore)
        let shares = split.models.sharedContentImportModel
        var answers: [Bool] = []
        defer {
            split.viewModel.cancelAllLegacyPrivateMediaConsents()
            split.chrome.showScreenshotPrivacyWarning = false
            split.chrome.clearFingerprint()
            split.close()
        }
        /// `present`, then a request; `isShown` holds throughout, and the
        /// dialog shows once `dismiss` takes the presentation away.
        func waitsBehind(
            _ name: String,
            present: () -> Void,
            isShown: @escaping () -> Bool,
            dismiss: () -> Void
        ) async throws {
            present()
            try await split.require(name) { isShown() }
            split.requestLegacyConsent { answers.append($0) }
            try await split.require("\(name): the request pending") {
                split.models.conversationUIModel.legacyPrivateMediaConsentRequest != nil
            }
            let disturbed = await TestHelpers.waitUntil(
                { !isShown() || !answers.isEmpty },
                timeout: TestConstants.negativeWaitWindow
            )
            #expect(!disturbed, "\(name) under the request: \(split.diagnostics)")
            #expect(answers.isEmpty, "\(name): the request was answered unseen")

            dismiss()
            try await split.require("\(name): the dialog once it closed") {
                split.presentedAlert?.preferredStyle == .actionSheet
            }
            #expect(answers.isEmpty)
            split.viewModel.cancelAllLegacyPrivateMediaConsents()
            try await split.require("\(name): the dialog gone") { !split.isPresenting }
            answers.removeAll()
        }

        try await waitsBehind(
            "fingerprint sheet",
            present: { split.chrome.showFingerprint(for: split.bob) },
            isShown: {
                split.chrome.showingFingerprintFor == split.bob
                    && split.isPresenting
                    && split.presentedAlert == nil
                    && !split.isPresentingPopover
            },
            dismiss: { split.chrome.clearFingerprint() }
        )
        try await waitsBehind(
            "share review",
            present: {
                let now = Date()
                try? store.stage(.text("shared from another app", createdAt: now), now: now)
                shares.refresh(destination: .mesh, now: now)
            },
            isShown: { shares.offer != nil && split.presentedAlert?.preferredStyle == .alert },
            dismiss: { shares.discardAll() }
        )
        try await waitsBehind(
            "screenshot warning",
            present: { split.chrome.showScreenshotPrivacyWarning = true },
            isShown: {
                split.chrome.showScreenshotPrivacyWarning && split.presentedAlert?.preferredStyle == .alert
            },
            dismiss: { split.chrome.showScreenshotPrivacyWarning = false }
        )
        // The root can't hold the dialog back for what it doesn't know of:
        // the dialog waits for the window itself to be free, so it is
        // never refused (and never left on screen untracked).
        try await waitsBehind(
            "an untracked presentation",
            present: { split.presentUntracked() },
            isShown: { split.isPresentingUntracked },
            dismiss: { split.dismissUntracked() }
        )
    }

    /// I1: a composer's session follows its pane wherever the panes change,
    /// not only through onChange, which SwiftUI skips past two changes in
    /// one frame and never delivers later. The selection landing, a DM
    /// opening and a fold all reach the root in one frame here; the
    /// composer on screen afterwards (the DM sheet's) sends to the
    /// conversation it shows, and its session points where its prompt says
    /// (a debug assertion at the send).
    @Test
    func contentView_aComposerSendsWhereItsPaneShowsAfterChangesInOneFrame() async throws {
        let split = try await SplitContentHost.make()
        defer { split.close() }
        split.channels.select(.location(split.geohash))
        // The timeline's model, not the rendered pane: the landing reaches
        // the root in the same frame as what follows.
        try await split.require("the selection landing") { split.timelineChannel == .location(split.geohash) }
        split.models.privateConversationModel.startConversation(with: split.bob)
        split.sizeClass.value = .compact

        try await split.require("folded, the DM in the sheet") {
            split.chrome.splitLayoutShowsLocation == nil && split.field(prompt: { $0.contains("Bob") }) != nil
        }
        let field = try #require(split.field(prompt: { $0.contains("Bob") }), "\(split.diagnostics)")
        split.submit("hello bob", in: field)

        let sent = await split.settle {
            split.viewModel.privateMessages(for: split.bob).contains { $0.content == "hello bob" }
        }
        try #require(sent, "Bob's DM has it; the field reads \"\(field.text ?? "")\": \(split.diagnostics)")
        #expect(!split.viewModel.publicMessages(for: .location(split.geohash)).contains { $0.content == "hello bob" })
        #expect(!split.viewModel.publicMessages(for: .mesh).contains { $0.content == "hello bob" })
    }

    /// E1: a composer taking the keyboard makes its pane the last touched,
    /// whatever was touched before it: the share goes to that composer
    /// (E11), and a fold keeps the trailing geohash (E2) rather than
    /// parking it (E3).
    @Test
    func contentView_aComposerTakingTheKeyboardTakesItsPane() async throws {
        let split = try await SplitContentHost.make(shares: true)
        defer { split.close() }
        let geohash = SharedContentDestination.geohash(split.geohash.geohash)
        try await split.select(.location(split.geohash))
        try #require(split.touch(.leading))
        try #require(await split.share(labelled: geohash, settlesOn: .mesh), "\(split.diagnostics)")

        let trailingField = split.composerField(in: .trailing)
        let field = try #require(trailingField, "\(split.diagnostics)")
        try #require(field.becomeFirstResponder())
        try #require(await split.share(labelled: .mesh, settlesOn: geohash), "\(split.diagnostics)")

        try await split.fold()
        let parked = await TestHelpers.waitUntil(
            { split.channels.selectedChannel != .location(split.geohash) },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!parked, "\(split.diagnostics)")
    }

    /// E1: typing makes the composer's pane the last touched again. A touch
    /// in #mesh (a scroll, say) leaves the keyboard with the trailing
    /// composer; typing on there takes the trailing pane back, so a fold
    /// keeps the geohash being typed in (E2) instead of parking it with the
    /// half-typed text (E3).
    @Test
    func contentView_typingTakesTheComposersPaneBack() async throws {
        let split = try await SplitContentHost.make()
        defer { split.close() }
        try await split.select(.location(split.geohash))
        let trailingField = split.composerField(in: .trailing)
        let field = try #require(trailingField, "\(split.diagnostics)")
        try #require(field.becomeFirstResponder())
        // The keyboard's focus reaches the panes before the touch.
        try #require(await split.settleFrames(), "\(split.diagnostics)")
        try #require(split.touch(.leading))

        field.insertText("still typing here")

        try await split.fold()
        let parked = await TestHelpers.waitUntil(
            { split.channels.selectedChannel != .location(split.geohash) },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!parked, "\(split.diagnostics)")
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

    /// E1's report of a DM chosen from a list: an open from a list (a
    /// popover's row, a list's "direct message") reports itself, the DM
    /// already open included; a refused one (a blocked peer's) doesn't, nor
    /// does an open no list asked for (the unfold's reopening).
    @Test
    func privateConversations_reportEveryDMChosenFromAList() async {
        let (viewModel, transport, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let conversations = featureModels.privateConversationModel
        let blocked = PeerID(str: "8182838485868788")
        let carol = PeerID(str: "9192939495969798")
        transport.updatePeerSnapshots([
            makeSnapshot(peerID: blocked, nickname: "Mallory", noiseByte: 0x81),
            makeSnapshot(peerID: carol, nickname: "Carol", noiseByte: 0x91)
        ])
        let known = await TestHelpers.waitUntil(
            { featureModels.peerListModel.meshRows.contains { $0.peerID == blocked } },
            timeout: TestConstants.settleTimeout
        )
        #expect(known)
        featureModels.conversationUIModel.block(peerID: blocked, displayName: "Mallory", from: .mesh)
        var chosen = 0
        let subscription = conversations.conversationChosen.sink { chosen += 1 }
        defer { subscription.cancel() }

        conversations.startConversation(with: carol)
        #expect(chosen == 0, "an open no list asked for")
        conversations.startConversation(with: carol, from: .mesh)
        #expect(chosen == 1, "a popover row, for the DM open already")
        conversations.openConversation(for: carol, from: .mesh)
        #expect(chosen == 2, "a list's direct message, for the DM open already")
        conversations.openConversation(for: blocked, from: .mesh)
        conversations.startConversation(with: blocked, from: .mesh)
        #expect(chosen == 2, "refused opens")
        #expect(conversations.selectedPeerID == carol)
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

        #expect(!ContentPeopleListView.openConversationFromPopover(with: blocked, from: .mesh, in: conversations))
        #expect(conversations.selectedPeerID == nil)

        #expect(ContentPeopleListView.openConversationFromPopover(with: reachable, from: .mesh, in: conversations))
        #expect(conversations.selectedPeerID == reachable)
    }

    /// I1: a blocked peer tapped in the #mesh popover has its refusal land
    /// in #mesh, where the tap was, not in the geohash selected beside it.
    @Test
    func peopleList_aPopoverRefusalLandsInTheListedChannel() async {
        let manager = makeSmokeLocationManager()
        let (viewModel, transport, _) = makeSmokeViewModel(locationManager: manager)
        let featureModels = makeSmokeFeatureModels(for: viewModel, locationManager: manager)
        let blocked = PeerID(str: "8182838485868788")
        transport.peerNicknames[blocked] = "Mallory"
        transport.updatePeerSnapshots([makeSnapshot(peerID: blocked, nickname: "Mallory", noiseByte: 0x81)])
        let known = await TestHelpers.waitUntil(
            { featureModels.peerListModel.meshRows.contains { $0.peerID == blocked } },
            timeout: TestConstants.settleTimeout
        )
        #expect(known)
        featureModels.conversationUIModel.block(peerID: blocked, displayName: "Mallory", from: .mesh)
        let geohash = ChannelID.location(GeohashChannel(level: .city, geohash: "u4pru"))
        featureModels.locationChannelsModel.select(geohash)
        let selected = await TestHelpers.waitUntil(
            { viewModel.activeChannel == geohash },
            timeout: TestConstants.settleTimeout
        )
        #expect(selected)
        func lines(_ channel: ChannelID) -> [String] {
            viewModel.conversations.conversationsByID[ConversationID(channelID: channel)]?.messages.map(\.content) ?? []
        }
        let meshBefore = lines(.mesh)
        let geohashBefore = lines(geohash)

        #expect(!ContentPeopleListView.openConversationFromPopover(
            with: blocked,
            from: .mesh,
            in: featureModels.privateConversationModel
        ))

        let refusal = lines(.mesh).dropFirst(meshBefore.count)
        #expect(refusal.count == 1)
        #expect(refusal.first?.contains("Mallory") == true, "\(Array(refusal))")
        #expect(lines(geohash) == geohashBefore)
    }

    @Test
    func paneTouchObserver_mounts() {
        _ = mount(PaneTouchObserver { _ in })
        _ = mount(Color.clear.background(PaneTouchObserver { _ in }))
    }
    #endif

    /// I1: "direct message" in a message list opens the DM from the list's
    /// own conversation. A blocked sender's refusal lands there: in #mesh
    /// for the #mesh list beside a selected geohash, never in the geohash;
    /// in a group chat's own thread for its list, not the public timeline
    /// under it.
    @Test
    func messageList_aDirectMessageRefusalLandsInTheListsOwnConversation() async {
        let manager = makeSmokeLocationManager()
        let (viewModel, transport, _) = makeSmokeViewModel(locationManager: manager)
        let featureModels = makeSmokeFeatureModels(for: viewModel, locationManager: manager)
        let blocked = PeerID(str: "8182838485868788")
        transport.peerNicknames[blocked] = "Mallory"
        transport.updatePeerSnapshots([makeSnapshot(peerID: blocked, nickname: "Mallory", noiseByte: 0x81)])
        let known = await TestHelpers.waitUntil(
            { featureModels.peerListModel.meshRows.contains { $0.peerID == blocked } },
            timeout: TestConstants.settleTimeout
        )
        #expect(known)
        featureModels.conversationUIModel.block(peerID: blocked, displayName: "Mallory", from: .mesh)
        let geohash = ChannelID.location(GeohashChannel(level: .city, geohash: "u4pru"))
        featureModels.locationChannelsModel.select(geohash)
        let selected = await TestHelpers.waitUntil(
            { viewModel.activeChannel == geohash },
            timeout: TestConstants.settleTimeout
        )
        #expect(selected)
        func lines(_ channel: ChannelID) -> [String] {
            viewModel.conversations.conversationsByID[ConversationID(channelID: channel)]?.messages.map(\.content) ?? []
        }
        let meshBefore = lines(.mesh)
        let geohashBefore = lines(geohash)
        let conversations = featureModels.privateConversationModel

        conversations.openConversation(for: blocked, from: .mesh)

        #expect(conversations.selectedPeerID == nil)
        let refusal = Array(lines(.mesh).dropFirst(meshBefore.count))
        #expect(refusal.count == 1)
        #expect(lines(geohash) == geohashBefore)

        let group = PeerID(groupID: Data(repeating: 0x42, count: 16))
        conversations.openConversation(for: blocked, from: ConversationTarget(channel: geohash, privatePeer: group))
        let groupLines = viewModel.privateMessages(for: group).map(\.content)
        #expect(lines(geohash) == geohashBefore)
        #expect(conversations.selectedPeerID == nil)

        // Each is the refusal the selection gets when no list asks: the same
        // line, whatever the string table holds (SwiftPM's run has none).
        viewModel.startPrivateChat(with: blocked)
        let selectionRefusal = Array(lines(geohash).dropFirst(geohashBefore.count))
        #expect(selectionRefusal.count == 1)
        #expect(refusal == selectionRefusal)
        #expect(groupLines == selectionRefusal)
    }

    /// I1: /msg to a blocked peer typed into the #mesh composer posts the
    /// refusal in #mesh, where the command was typed, and nothing in the
    /// geohash selected beside it.
    @Test
    func command_aMsgRefusalLandsWhereTheCommandWasTyped() async {
        let manager = makeSmokeLocationManager()
        let (viewModel, transport, _) = makeSmokeViewModel(locationManager: manager)
        let featureModels = makeSmokeFeatureModels(for: viewModel, locationManager: manager)
        let blocked = PeerID(str: "8182838485868788")
        transport.peerNicknames[blocked] = "Mallory"
        transport.updatePeerSnapshots([makeSnapshot(peerID: blocked, nickname: "Mallory", noiseByte: 0x81)])
        let known = await TestHelpers.waitUntil(
            { featureModels.peerListModel.meshRows.contains { $0.peerID == blocked } },
            timeout: TestConstants.settleTimeout
        )
        #expect(known)
        featureModels.conversationUIModel.block(peerID: blocked, displayName: "Mallory", from: .mesh)
        let geohash = ChannelID.location(GeohashChannel(level: .city, geohash: "u4pru"))
        featureModels.locationChannelsModel.select(geohash)
        let selected = await TestHelpers.waitUntil(
            { viewModel.activeChannel == geohash },
            timeout: TestConstants.settleTimeout
        )
        #expect(selected)
        func lines(_ channel: ChannelID) -> [String] {
            viewModel.conversations.conversationsByID[ConversationID(channelID: channel)]?.messages.map(\.content) ?? []
        }
        let meshBefore = lines(.mesh)
        let geohashBefore = lines(geohash)

        viewModel.handleCommand("/msg @Mallory", from: .mesh)

        #expect(viewModel.selectedPrivateChatPeer == nil)
        #expect(lines(geohash) == geohashBefore, "\(lines(geohash).dropFirst(geohashBefore.count))")
        // The refusal, then the command's own line (its wording unchanged).
        let meshLines = Array(lines(.mesh).dropFirst(meshBefore.count))
        #expect(meshLines.count == 2, "\(meshLines)")

        // The first is the refusal the selection gets when no command asks:
        // the same line, whatever the string table holds (SwiftPM's run has
        // none).
        viewModel.startPrivateChat(with: blocked)
        let selectionRefusal = Array(lines(geohash).dropFirst(geohashBefore.count))
        #expect(selectionRefusal.count == 1)
        #expect(meshLines.first == selectionRefusal.first)
    }

    @Test
    func contentHeader_rendersTheSingleColumnAndBothPaneBars() async {
        let (viewModel, _, _) = makeSmokeViewModel()
        let featureModels = makeSmokeFeatureModels(for: viewModel)
        let geohash = GeohashChannel(level: .city, geohash: "u4pru")
        let configurations = [
            // The single column (compact iOS, macOS): today's bar.
            ContentHeaderHarness(),
            // Split, leading: #mesh as a label, the app chrome, mesh people.
            ContentHeaderHarness(paneChannel: .mesh, handlesPeopleTap: true),
            // Split, trailing: the geohash's badge, bookmark and people only.
            ContentHeaderHarness(
                paneChannel: .location(geohash),
                carriesAppChrome: false,
                handlesPeopleTap: true,
                handlesBadgeTap: true
            )
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
        #expect(!ContentRootModalPresentationState(
            appChromeModel: featureModels.appChromeModel,
            isPeoplePopoverPresented: false
        ).hasPresentation)
        #expect(ContentRootModalPresentationState(
            appChromeModel: featureModels.appChromeModel,
            isPeoplePopoverPresented: true
        ).hasPresentation)
    }

    @Test("Only a split consent dialog on screen holds back root alerts")
    func rootAlertGuards_legacyConsentTakesTheScreenOnlyWhenFreeAndThenKeepsIt() {
        func mayTake(split: Bool = true, pending: Bool = true, other: Bool) -> Bool {
            ContentRootModalPresentationState.legacyConsentMayTakeScreen(
                isSplitLayout: split,
                hasPendingRequest: pending,
                hasOtherPresentation: other
            )
        }
        func defers(split: Bool = true, pending: Bool = true, onScreen: Bool) -> Bool {
            ContentRootModalPresentationState.legacyConsentDefersRoot(
                isSplitLayout: split,
                hasPendingRequest: pending,
                isOnScreen: onScreen
            )
        }
        // Every other root presentation goes first: a request arriving
        // under one waits behind it rather than taking the screen.
        #expect(mayTake(other: false))
        #expect(!mayTake(other: true))
        // Whatever is on screen first keeps it: only a dialog showing holds
        // the root back, and it does whatever is flagged after it.
        #expect(defers(onScreen: true))
        #expect(!defers(onScreen: false))
        // Compact: the people sheet hosts the dialog and defers the root on
        // its own; a request left behind once it closed has no presenter.
        #expect(!mayTake(split: false, other: false))
        #expect(!defers(split: false, onScreen: true))
        #expect(!mayTake(pending: false, other: false))
        #expect(!defers(pending: false, onScreen: true))
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
                appChromeModel: featureModels.appChromeModel,
                isPeoplePopoverPresented: false
            ).hasPresentation
        )

        featureModels.appChromeModel.showScreenshotPrivacyWarning = true

        #expect(
            ContentRootModalPresentationState(
                appChromeModel: featureModels.appChromeModel,
                isPeoplePopoverPresented: false
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
