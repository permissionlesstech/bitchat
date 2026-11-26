import Foundation
import BitFoundation
import Testing

@testable import bitchat

/// The `#abcd` suffix exists so two peers claiming one nickname are
/// distinguishable. It is therefore only as good as the notion of "one
/// nickname" it counts with — anything that renders alike has to collide, or
/// the guard stays silent exactly when two rows look the same.
@MainActor
struct PeerDisplayNameResolverTests {
    private let real = PeerID(str: "aaaa1111")
    private let other = PeerID(str: "bbbb2222")

    /// True when the resolver decided these two need telling apart.
    private func suffixed(_ a: String, _ b: String,
                          connected: Bool = true, selfNickname: String = "me") -> Bool {
        let out = PeerDisplayNameResolver.resolve(
            [(peerID: real, nickname: a, isConnected: true),
             (peerID: other, nickname: b, isConnected: connected)],
            selfNickname: selfNickname)
        return (out[real] ?? "").contains("#") || (out[other] ?? "").contains("#")
    }

    @Test
    func namesThatRenderAlikeCollide() {
        #expect(suffixed("Medic", "Medic"), "exact duplicate")
        #expect(suffixed("Medic", "medic"), "case alone must not make two peers look distinct")
        #expect(suffixed("Medic", "\u{FF2D}edic"), "fullwidth Ｍ")
        #expect(suffixed("Medic", "\u{1D40C}edic"), "mathematical bold 𝐌")
        #expect(suffixed("Medic", "\u{2133}edic"), "script ℳ")
        #expect(suffixed("Medic", "\u{216F}edic"), "roman numeral Ⅿ")
        #expect(suffixed("Jos\u{00E9}", "Jose\u{0301}"), "canonically equivalent spellings")
    }

    @Test
    func unrelatedNamesDoNotCollide() {
        #expect(!suffixed("Medic", "Zebra"))
        #expect(!suffixed("Medic", "Medic2"))
        #expect(!suffixed("Medic", ""))
    }

    @Test
    func crossScriptHomoglyphsAreStillMissed() {
        // Cyrillic М and Greek Ο have their own compatibility forms, so
        // folding cannot reach them — that needs a UTS #39 confusables table.
        // Pinned as a KNOWN gap so it is explicit rather than a surprise, and
        // so whoever adds the table has a test to flip.
        #expect(!suffixed("Medic", "\u{041C}\u{0435}dic"), "Cyrillic М + е: known gap")
        #expect(!suffixed("Organizer", "\u{039F}rganizer"), "Greek Ο: known gap")
    }

    @Test
    func onlyConnectedPeersAreSuffixed() {
        // Unchanged by the folding: an offline namesake still gets no suffix,
        // which is its own gap and not one this touches.
        #expect(!suffixed("Medic", "medic", connected: false))
    }

    @Test
    func ourOwnNicknameCountsTowardCollisions() {
        // A remote peer claiming a folded variant of MY nickname must be
        // suffixed, or it renders as me.
        let out = PeerDisplayNameResolver.resolve(
            [(peerID: other, nickname: "\u{FF2D}edic", isConnected: true)],
            selfNickname: "Medic")
        #expect((out[other] ?? "").contains("#"))
    }

    @Test
    func theSenderDisplayNameResolverFoldsTheSameWay() {
        // Collisions are counted in TWO places. This one feeds sender names on
        // file transfers and had the same exact-match blind spot; folding only
        // the peer-list resolver would have left it behind.
        let mine = PeerID(str: "cccc3333")
        func info(_ id: PeerID, _ nickname: String) -> BLEPeerInfo {
            BLEPeerInfo(peerID: id, nickname: nickname, isConnected: true,
                        noisePublicKey: nil, signingPublicKey: nil,
                        isVerifiedNickname: true, lastSeen: Date())
        }
        let peers: [PeerID: BLEPeerInfo] = [
            real: info(real, "Medic"),
            other: info(other, "\u{FF2D}edic"),
        ]
        let name = BLEPeerSenderDisplayName.resolveKnownPeer(
            peerID: other, localPeerID: mine, localNickname: "me",
            peers: peers, allowConnectedUnverified: true)
        #expect(name?.contains("#") == true,
                "a fullwidth namesake must be suffixed here too")
    }

    @Test
    func theDisplayedNameIsNeverFolded() {
        // Only the collision KEY folds. What is shown stays as its owner typed
        // it, suffix aside.
        let out = PeerDisplayNameResolver.resolve(
            [(peerID: real, nickname: "Medic", isConnected: true),
             (peerID: other, nickname: "\u{FF2D}edic", isConnected: true)],
            selfNickname: "me")
        #expect(out[real]?.hasPrefix("Medic") == true)
        #expect(out[other]?.hasPrefix("\u{FF2D}edic") == true, "the fullwidth Ｍ is preserved on screen")
    }
}
