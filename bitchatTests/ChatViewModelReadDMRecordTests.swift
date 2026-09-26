import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// The view model's read record lives in the read-receipts store, so it
/// outlives the view model the way the receipts do.
@MainActor
struct ChatViewModelReadDMRecordTests {
    private func makeViewModel(readReceiptsDefaults: UserDefaults) -> ChatViewModel {
        let locationSuite = "ChatViewModelReadDMRecordTests.\(UUID().uuidString)"
        let locationStorage = UserDefaults(suiteName: locationSuite) ?? .standard
        locationStorage.removePersistentDomain(forName: locationSuite)
        return ChatViewModel(
            keychain: MockKeychain(),
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(MockKeychain()),
            transport: MockTransport(),
            conversations: ConversationStore(),
            locationManager: LocationChannelManager(storage: locationStorage),
            readReceiptsDefaults: readReceiptsDefaults
        )
    }

    @Test
    func aRecordedDMIsStillReadInANewViewModel() {
        let defaults = UserDefaults(suiteName: "chat.bitchat.tests.readDMs.\(UUID().uuidString)")!

        let first = makeViewModel(readReceiptsDefaults: defaults)
        first.recordDMRead("geo-1")
        #expect(first.hasReadDM("geo-1"))
        #expect(!first.hasReadDM("geo-2"))

        let second = makeViewModel(readReceiptsDefaults: defaults)
        #expect(second.hasReadDM("geo-1"))
        #expect(!second.hasReadDM("geo-2"))
    }

    @Test
    func thePanicWipeForgetsReadDMsOnDiskToo() {
        let defaults = UserDefaults(suiteName: "chat.bitchat.tests.readDMs.\(UUID().uuidString)")!
        let wiped = makeViewModel(readReceiptsDefaults: defaults)
        wiped.recordDMRead("geo-1")
        wiped.panicClearAllData(restartServices: false)
        #expect(!wiped.hasReadDM("geo-1"))
        #expect(!makeViewModel(readReceiptsDefaults: defaults).hasReadDM("geo-1"))
    }
}
