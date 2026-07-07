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
    @Published var showBluetoothAlert = false
    @Published var bluetoothAlertMessage = ""
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var showScreenshotPrivacyWarning = false
    /// Latch for the people / conversation-list sheet. Owned here (rather than as
    /// `ContentView` local `@State`) so non-view launch code can raise it: on launch
    /// `AppRuntime` sets this to `true` when the last-active conversation resolves to
    /// "present the conversation list" (first-ever launch or a stale/unrestorable DM
    /// peer). `ContentView` binds the people sheet directly to this, and every
    /// competing sheet/cover already gates on `!showSidebar`, so a single latch keeps
    /// the launch presentation from colliding with the fingerprint / image-picker
    /// sheets (#1064).
    @Published var showSidebar = false

    private let chatViewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()

    /// Bulletin-board coordinator, created on first use of the board sheet.
    private(set) lazy var boardManager = BoardManager(transport: chatViewModel.meshService)

    init(chatViewModel: ChatViewModel, privateInboxModel: PrivateInboxModel) {
        self.chatViewModel = chatViewModel
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

    /// Builds the mesh topology map model from the transport's gossiped
    /// graph plus the live nickname table. Unknown nodes (heard about via a
    /// neighbor claim but never announced to us) fall back to a short ID.
    func meshTopologyDisplayModel() -> MeshTopologyDisplayModel {
        let mesh = chatViewModel.meshService
        guard let snapshot = mesh.currentMeshTopology() else { return .empty }
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

    func panicClearAllData() {
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

        hasUnreadPrivateMessages = !privateInboxModel.unreadPeerIDs.isEmpty
    }
}
