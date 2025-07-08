import XCTest
@testable import bitchat

class DisplayNameTests: XCTestCase {
    func testDuplicateNicknamesAppendFingerprint() {
        let nicknames = ["peerA": "alice", "peerB": "alice", "peerC": "bob"]
        let nameA = ChatViewModel.computeDisplayName(peerID: "peerA",
                                                    nickname: "alice",
                                                    allNicknames: nicknames,
                                                    myNickname: "carol",
                                                    fingerprint: "abcd1234")
        let nameB = ChatViewModel.computeDisplayName(peerID: "peerB",
                                                    nickname: "alice",
                                                    allNicknames: nicknames,
                                                    myNickname: "carol",
                                                    fingerprint: "efgh5678")
        XCTAssertEqual(nameA, "alice-abcd")
        XCTAssertEqual(nameB, "alice-efgh")
    }

    func testUniqueNicknameNoFingerprint() {
        let nicknames = ["peerA": "alice", "peerB": "bob"]
        let name = ChatViewModel.computeDisplayName(peerID: "peerB",
                                                   nickname: "bob",
                                                   allNicknames: nicknames,
                                                   myNickname: "carol",
                                                   fingerprint: "1234")
        XCTAssertEqual(name, "bob")
    }

    func testDuplicateWithSelf() {
        let nicknames = ["peerA": "carol"]
        let name = ChatViewModel.computeDisplayName(peerID: "peerA",
                                                   nickname: "carol",
                                                   allNicknames: nicknames,
                                                   myNickname: "carol",
                                                   fingerprint: "abcd")
        XCTAssertEqual(name, "carol-abcd")
    }

    func testMentionReplacesWithDisplayName() {
        let nicknames = ["peerA": "alice", "peerB": "alice"]
        let fingerprints = ["peerA": "abcd1234", "peerB": "efgh5678"]

        let display = ChatViewModel.computeDisplayName(peerID: "peerA",
                                                      nickname: nicknames["peerA"],
                                                      allNicknames: nicknames,
                                                      myNickname: "carol",
                                                      fingerprint: fingerprints["peerA"])

        XCTAssertEqual("@" + display, "@alice-abcd")
    }
}
