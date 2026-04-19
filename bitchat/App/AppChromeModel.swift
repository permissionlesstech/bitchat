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

    private let chatViewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()

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
