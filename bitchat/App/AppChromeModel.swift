import BitFoundation
import Combine
import CoreBluetooth
import Foundation

@MainActor
final class AppChromeModel: ObservableObject {
    @Published private(set) var hasUnreadPrivateMessages = false
    @Published var nickname: String
    @Published var showingFingerprintFor: PeerID?
    @Published var isAppInfoPresented = false
    @Published var isLocationChannelsSheetPresented = false
    @Published var isNoticesSheetPresented = false
    /// When the sheet is opened for "notes left here" (empty mesh timeline),
    /// it should land on the geo tab instead of the channel-derived default.
    @Published var noticesSheetPrefersGeoTab = false
    @Published var showBluetoothAlert = false
    @Published var bluetoothAlertMessage = ""
    @Published var bluetoothState: CBManagerState = .unknown
    /// Tor bootstrap has stalled (network likely blocks it); drives the
    /// connectivity banner. Mirrored from `ChatViewModel.torBlocked`.
    @Published private(set) var torBlocked = false
    @Published var showScreenshotPrivacyWarning = false
    /// Triple-tapping the logo asks first; the dialog lives on the header.
    @Published var showPanicConfirmation = false
    /// Mirrors `ChatViewModel.panicRecoveryBlocked` for the chrome: a wipe
    /// that did not commit must be visible, not just logged — the person who
    /// triggered it needs to know data may remain on the device.
    @Published private(set) var panicWipeBlocked = false
    #if os(iOS)
    /// Whether a screenshot of the split layout shows a place: a geohash
    /// timeline or the location-channel picker, rather than a DM. Nil while
    /// the single column is up. Asked of the panes each time
    /// (`setSplitLayoutScreenshotProbe`), so it is never a copy one of
    /// SwiftUI's change callbacks has to keep current: SwiftUI skips those
    /// past a couple of changes in one frame. Only screenshot routing reads
    /// it, so it isn't published.
    var splitLayoutShowsLocation: Bool? {
        splitLayoutScreenshotProbe?()
    }
    private var splitLayoutScreenshotProbe: (@MainActor () -> Bool?)?
    /// Goes up with every panic wipe. The wipe closes the sheets, which takes
    /// what they hold with them; inline views outlive it (the split layout's
    /// location-channel picker) and drop what they hold when this changes.
    @Published private(set) var panicEpoch: UInt64 = 0
    #endif

    private let chatViewModel: ChatViewModel
    private let onPanicWipe: () -> Void
    private var cancellables = Set<AnyCancellable>()
    /// The composer owns capture state above ChatViewModel. ContentView
    /// installs this hook so both panic entry points synchronously stop it.
    private var prepareForPanic: (@MainActor () -> Void)?

    /// Bulletin-board coordinator, created on first use of the board sheet.
    private(set) lazy var boardManager = BoardManager(transport: chatViewModel.meshService)

    init(
        chatViewModel: ChatViewModel,
        privateInboxModel: PrivateInboxModel,
        onPanicWipe: @escaping () -> Void = {}
    ) {
        self.chatViewModel = chatViewModel
        self.onPanicWipe = onPanicWipe
        self.nickname = chatViewModel.nickname

        bind(privateInboxModel: privateInboxModel)
    }

    var shouldSuppressScreenshotNotification: Bool {
        isLocationChannelsSheetPresented || isAppInfoPresented
    }

    func setNickname(_ nickname: String) {
        self.nickname = nickname
        if chatViewModel.nickname != nickname {
            chatViewModel.nickname = nickname
        }
    }

    func validateAndSaveNickname() {
        chatViewModel.validateAndSaveNickname()
        if nickname != chatViewModel.nickname {
            nickname = chatViewModel.nickname
        }
    }

    func openMostRelevantPrivateChat() {
        chatViewModel.openMostRelevantPrivateChat()
    }

    func showFingerprint(for peerID: PeerID) {
        showingFingerprintFor = peerID
    }

    func clearFingerprint() {
        showingFingerprintFor = nil
    }

    func presentAppInfo() {
        isAppInfoPresented = true
    }

    func presentNotices(geoTab: Bool = false) {
        noticesSheetPrefersGeoTab = geoTab
        isNoticesSheetPresented = true
    }

    /// Builds the mesh topology map model from the transport's gossiped
    /// graph plus the live nickname table. Unknown nodes (heard about via a
    /// neighbor claim but never announced to us) fall back to a short ID.
    func meshTopologyDisplayModel() -> MeshTopologyDisplayModel {
        let mesh = chatViewModel.meshService
        guard let diagnostics = mesh as? MeshDiagnosing,
              let snapshot = diagnostics.currentMeshTopology() else { return .empty }
        let nicknames = mesh.getPeerNicknames()

        let nodes = snapshot.nodes.map { peerID -> MeshTopologyDisplayModel.Node in
            let isSelf = peerID == snapshot.localPeerID
            let label: String
            if isSelf {
                label = chatViewModel.nickname
            } else {
                label = nicknames[peerID] ?? "\(peerID.id.prefix(8))…"
            }
            return MeshTopologyDisplayModel.Node(id: peerID.id, label: label, isSelf: isSelf)
        }
        let edges = snapshot.edges.map { ($0.a.id, $0.b.id) }
        return MeshTopologyDisplayModel(nodes: nodes, edges: edges)
    }

    func triggerScreenshotPrivacyWarning() {
        showScreenshotPrivacyWarning = true
    }

    #if os(iOS)
    /// Whether the split layout's leading pane keeps #mesh on screen beside
    /// the selection: arrivals there batch like the selected timeline's.
    func setMeshPinnedOnScreen(_ pinned: Bool) {
        chatViewModel.conversations.setMeshPinnedOnScreen(pinned)
    }

    /// ContentView's answer to `splitLayoutShowsLocation`, read from the
    /// panes as they are at that moment; nil while it is off screen.
    func setSplitLayoutScreenshotProbe(_ probe: (@MainActor () -> Bool?)?) {
        splitLayoutScreenshotProbe = probe
    }
    #endif

    func setPanicPreparation(_ preparation: (@MainActor () -> Void)?) {
        prepareForPanic = preparation
    }

    /// Entry point for the header triple-tap: confirm before destroying.
    /// The Settings-pane button has always confirmed; the gesture now goes
    /// through the same dialog so a mis-tap can't wipe the device.
    func requestPanicWipe() {
        showPanicConfirmation = true
    }

    func panicClearAllData() {
        // A wipe invalidates everything on screen, and its outcome must be
        // visible: the success message and the failed-wipe banner both live
        // on the root timeline, so a sheet left up (the App Info danger-zone
        // path keeps its sheet presented) would hide the one signal that says
        // whether the wipe worked.
        isAppInfoPresented = false
        isLocationChannelsSheetPresented = false
        isNoticesSheetPresented = false
        showingFingerprintFor = nil
        #if os(iOS)
        panicEpoch &+= 1
        #endif

        prepareForPanic?()
        onPanicWipe()
        chatViewModel.panicClearAllData()
    }

    private func bind(privateInboxModel: PrivateInboxModel) {
        privateInboxModel.$unreadPeerIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] unreadPeerIDs in
                self?.hasUnreadPrivateMessages = !unreadPeerIDs.isEmpty
            }
            .store(in: &cancellables)

        chatViewModel.$nickname
            .receive(on: DispatchQueue.main)
            .sink { [weak self] nickname in
                guard let self, self.nickname != nickname else { return }
                self.nickname = nickname
            }
            .store(in: &cancellables)

        chatViewModel.$showBluetoothAlert
            .receive(on: DispatchQueue.main)
            .assign(to: &$showBluetoothAlert)

        chatViewModel.$bluetoothAlertMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$bluetoothAlertMessage)

        chatViewModel.$bluetoothState
            .receive(on: DispatchQueue.main)
            .assign(to: &$bluetoothState)

        chatViewModel.$torBlocked
            .receive(on: DispatchQueue.main)
            .assign(to: &$torBlocked)

        chatViewModel.$panicRecoveryBlocked
            .receive(on: DispatchQueue.main)
            .assign(to: &$panicWipeBlocked)

        hasUnreadPrivateMessages = !privateInboxModel.unreadPeerIDs.isEmpty
    }
}
