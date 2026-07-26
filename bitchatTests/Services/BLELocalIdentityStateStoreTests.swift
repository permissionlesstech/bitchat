import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLELocalIdentityStateStoreTests {
    @Test
    func identityReplacementUpdatesWireBytesAtomically() throws {
        let initial = PeerID(str: "0011223344556677")
        let replacement = PeerID(str: "8899aabbccddeeff")
        let store = BLELocalIdentityStateStore(peerID: initial, nickname: "alice")

        store.replacePeerIdentity(with: replacement)

        let snapshot = store.snapshot()
        #expect(snapshot.peerID == replacement)
        #expect(snapshot.peerIDData == Data(hexString: replacement.id))
        #expect(snapshot.nickname == "alice")
    }

    @Test
    func concurrentReadsNeverObserveSplitIdentityState() {
        let peerIDs = [
            PeerID(str: "0011223344556677"),
            PeerID(str: "8899aabbccddeeff")
        ]
        let store = BLELocalIdentityStateStore(peerID: peerIDs[0], nickname: "alice")
        let failures = LockedFailureRecorder()

        DispatchQueue.concurrentPerform(iterations: 2_000) { index in
            if index.isMultiple(of: 2) {
                store.replacePeerIdentity(with: peerIDs[index % peerIDs.count])
            } else {
                store.setNickname(index.isMultiple(of: 3) ? "alice" : "bob")
            }

            let snapshot = store.snapshot()
            let expectedWireID = Data(hexString: snapshot.peerID.id) ?? Data()
            if snapshot.peerIDData != expectedWireID {
                failures.record()
            }
        }

        #expect(!failures.hasFailure)
    }
}

private final class LockedFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    var hasFailure: Bool { lock.withLock { failed } }

    func record() {
        lock.withLock { failed = true }
    }
}
