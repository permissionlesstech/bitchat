import Foundation
import Testing
@testable import bitchat

@Suite("BLE scheduled relay store tests")
struct BLEScheduledRelayStoreTests {
    @Test("schedule tracks relay count and remove returns work item")
    func scheduleAndRemove() {
        var store = BLEScheduledRelayStore()
        let first = DispatchWorkItem {}
        let second = DispatchWorkItem {}

        store.schedule(first, messageID: "one")
        store.schedule(second, messageID: "two")

        #expect(store.count == 2)
        #expect(!store.isEmpty)
        let removed = store.remove(messageID: "one")
        #expect(removed.map { $0 === first } == true)
        #expect(store.count == 1)
        let missing = store.remove(messageID: "missing")
        #expect(missing == nil)
    }

    @Test("cancel removes and cancels a scheduled relay")
    func cancelScheduledRelay() {
        var store = BLEScheduledRelayStore()
        let workItem = DispatchWorkItem {}

        store.schedule(workItem, messageID: "relay")

        let didCancel = store.cancel(messageID: "relay")
        #expect(didCancel)
        #expect(workItem.isCancelled)
        #expect(store.isEmpty)
        let didCancelAgain = store.cancel(messageID: "relay")
        #expect(!didCancelAgain)
    }

    @Test("cancel all cancels every scheduled relay")
    func cancelAllScheduledRelays() {
        var store = BLEScheduledRelayStore()
        let first = DispatchWorkItem {}
        let second = DispatchWorkItem {}

        store.schedule(first, messageID: "first")
        store.schedule(second, messageID: "second")
        store.cancelAll()

        #expect(first.isCancelled)
        #expect(second.isCancelled)
        #expect(store.isEmpty)
    }

    @Test("capacity guard only removes when over limit")
    func capacityGuardRemovesOnlyWhenOverLimit() {
        var store = BLEScheduledRelayStore()

        store.schedule(DispatchWorkItem {}, messageID: "one")
        store.schedule(DispatchWorkItem {}, messageID: "two")
        store.removeAllIfOverCapacity(2)
        #expect(store.count == 2)

        store.schedule(DispatchWorkItem {}, messageID: "three")
        store.removeAllIfOverCapacity(2)
        #expect(store.isEmpty)
    }

    @Test("protected relays ignore duplicate cancellation while opportunistic relays cancel")
    func protectedRelaysIgnoreDuplicateCancellation() {
        var store = BLEScheduledRelayStore()
        let protectedWork = DispatchWorkItem {}
        let opportunisticWork = DispatchWorkItem {}

        store.schedule(protectedWork, messageID: "protected", isProtectedFromDuplicateCancellation: true)
        store.schedule(opportunisticWork, messageID: "opportunistic", isProtectedFromDuplicateCancellation: false)

        let cancelledProtected = store.cancelIfDuplicateCancellable(messageID: "protected")
        #expect(!cancelledProtected)
        #expect(!protectedWork.isCancelled)
        #expect(store.count == 2)

        let cancelledOpportunistic = store.cancelIfDuplicateCancellable(messageID: "opportunistic")
        #expect(cancelledOpportunistic)
        #expect(opportunisticWork.isCancelled)
        #expect(store.count == 1)
    }
}
