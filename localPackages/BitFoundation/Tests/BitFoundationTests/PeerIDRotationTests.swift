import Foundation
import Testing
import CryptoKit
@testable import BitFoundation

/// Executable test vectors for peer ID rotation.
///
/// These are the numbers the Android implementation must reproduce. Two rules
/// for keeping them useful:
///
/// 1. **Reproduce them from `docs/PEER-ID-ROTATION.md`, not from this code.**
///    Deriving the expected values by reading the other platform's
///    implementation proves only that both share a bug.
/// 2. **If a derivation changes, the hex here changes too, deliberately.** A
///    vector that gets "fixed" to match new behavior has stopped being a vector.
///
/// The three `VECTOR:` values below were cross-checked against an independent
/// HKDF/HMAC implementation written from the specification alone (Python
/// `hmac`/`hashlib`, empty salt, extract-then-expand) and matched byte for byte.
/// So the spec text is sufficient to reproduce them without reading this code —
/// which is the property Android needs.
struct PeerIDRotationTests {
    // A fixed, obviously-fake private key so the vectors are stable.
    private let staticPrivateA = Data((0..<32).map { UInt8($0 + 1) })          // 01..20
    private let staticPrivateB = Data((0..<32).map { UInt8(0xA0 &+ $0) })      // a0..bf

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Epochs

    @Test func epochIsWallClockDivision() {
        #expect(PeerIDRotation.rotationPeriod == 3600)
        #expect(PeerIDRotation.epoch(at: Date(timeIntervalSince1970: 0)) == 0)
        #expect(PeerIDRotation.epoch(at: Date(timeIntervalSince1970: 3599)) == 0)
        #expect(PeerIDRotation.epoch(at: Date(timeIntervalSince1970: 3600)) == 1)
        // 2026-07-26T00:00:00Z
        #expect(PeerIDRotation.epoch(at: Date(timeIntervalSince1970: 1_784_000_000)) == 495_555)
    }

    @Test func candidateEpochsCoverTheBoundaryBothWays() {
        // Two devices seconds apart across a boundary must still recognise each
        // other, so the window spans the neighbouring epochs.
        let date = Date(timeIntervalSince1970: 3600 * 100)
        #expect(PeerIDRotation.candidateEpochs(around: date) == [99, 100, 101])
    }

    @Test func candidateEpochsDoNotUnderflowAtTheOrigin() {
        // UInt32 underflow here would produce 4294967295 and break matching.
        #expect(PeerIDRotation.candidateEpochs(around: Date(timeIntervalSince1970: 0)) == [0, 1])
    }

    // MARK: - Rotating peer ID

    @Test func rotationSecretIsStableForAKey() {
        let first = PeerIDRotation.rotationSecret(noiseStaticPrivateKey: staticPrivateA)
        let second = PeerIDRotation.rotationSecret(noiseStaticPrivateKey: staticPrivateA)
        #expect(first == second)
        #expect(first.count == 32)
        // VECTOR: HKDF-SHA256(ikm: 01..20, salt: empty, info: "bitchat-peer-rotation-v1", 32)
        #expect(hex(first) == "fb82dfec0c0a2a4677beca44e2f72c80e7c5de773dd5fce6ee47af83d3c25f09")
    }

    @Test func peerIDIsEightBytesAndEpochDependent() {
        let secret = PeerIDRotation.rotationSecret(noiseStaticPrivateKey: staticPrivateA)
        let a = PeerIDRotation.peerID(rotationSecret: secret, epoch: 100)
        let b = PeerIDRotation.peerID(rotationSecret: secret, epoch: 101)

        #expect(a.count == PeerIDRotation.idLength)
        #expect(b.count == PeerIDRotation.idLength)
        // VECTOR: HMAC-SHA256(rotationSecret, "bitchat-peer-id-v2" || uint32be(100))[0..8]
        #expect(hex(a) == "f7c08c528506a374")
        // The whole point: consecutive epochs are unrelated to an observer.
        #expect(a != b)
        // Deterministic within an epoch, so a restart keeps the same ID.
        #expect(a == PeerIDRotation.peerID(rotationSecret: secret, epoch: 100))
    }

    @Test func peerIDDiffersBetweenDevices() {
        let secretA = PeerIDRotation.rotationSecret(noiseStaticPrivateKey: staticPrivateA)
        let secretB = PeerIDRotation.rotationSecret(noiseStaticPrivateKey: staticPrivateB)
        #expect(PeerIDRotation.peerID(rotationSecret: secretA, epoch: 100)
                != PeerIDRotation.peerID(rotationSecret: secretB, epoch: 100))
    }

    @Test func currentPeerIDMatchesTheExplicitEpochForm() {
        let date = Date(timeIntervalSince1970: 3600 * 100 + 17)
        let viaConvenience = PeerIDRotation.currentPeerID(
            noiseStaticPrivateKey: staticPrivateA,
            at: date
        )
        let viaParts = PeerIDRotation.peerID(
            rotationSecret: PeerIDRotation.rotationSecret(noiseStaticPrivateKey: staticPrivateA),
            epoch: 100
        )
        #expect(viaConvenience == viaParts)
    }

    // MARK: - Recognition tags

    private var pubA: Data { Data(repeating: 0x0A, count: 32) }
    private var pubB: Data { Data(repeating: 0x0B, count: 32) }
    private var idA: Data { Data(repeating: 0xA1, count: 8) }

    /// The property that makes handshake-free recognition possible: both sides
    /// reach the same tag from opposite halves of the key pair.
    @Test func bothSidesDeriveTheSameRecognitionTag() throws {
        let privA = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivateA)
        let privB = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivateB)

        let sharedFromA = try privA.sharedSecretFromKeyAgreement(with: privB.publicKey)
        let sharedFromB = try privB.sharedSecretFromKeyAgreement(with: privA.publicKey)
        let rawA = sharedFromA.withUnsafeBytes { Data($0) }
        let rawB = sharedFromB.withUnsafeBytes { Data($0) }
        #expect(rawA == rawB)

        let keyA = PeerIDRotation.recognitionKey(sharedSecret: rawA)
        let keyB = PeerIDRotation.recognitionKey(sharedSecret: rawB)
        #expect(keyA == keyB)

        // A emits its A->B tag; B computes the same value to look for it.
        let emitted = PeerIDRotation.recognitionTag(
            recognitionKey: keyA, epoch: 100,
            senderStaticPublicKey: privA.publicKey.rawRepresentation,
            recipientStaticPublicKey: privB.publicKey.rawRepresentation,
            peerID: idA
        )
        let expected = PeerIDRotation.recognitionTag(
            recognitionKey: keyB, epoch: 100,
            senderStaticPublicKey: privA.publicKey.rawRepresentation,
            recipientStaticPublicKey: privB.publicKey.rawRepresentation,
            peerID: idA
        )
        #expect(emitted == expected)
        #expect(emitted.count == PeerIDRotation.idLength)
    }

    /// Regression, Codex #1487 P1: a symmetric tag means A and B broadcast the
    /// identical 8 bytes, so an observer who sees one value in two announces
    /// learns those two are mutual favourites and can link their rotating IDs.
    /// Tags must therefore differ by direction.
    @Test func recognitionTagsAreDirectional() {
        let key = PeerIDRotation.recognitionKey(sharedSecret: Data(repeating: 0x42, count: 32))
        let aToB = PeerIDRotation.recognitionTag(
            recognitionKey: key, epoch: 100,
            senderStaticPublicKey: pubA, recipientStaticPublicKey: pubB, peerID: idA
        )
        let bToA = PeerIDRotation.recognitionTag(
            recognitionKey: key, epoch: 100,
            senderStaticPublicKey: pubB, recipientStaticPublicKey: pubA, peerID: idA
        )
        #expect(aToB != bToA)
    }

    /// Regression, Codex #1487 P1: without the peer ID in the MAC, a tag lifted
    /// from someone's announce could be replayed under an attacker-chosen ID and
    /// the recipient would accept that ID as the favourite.
    @Test func recognitionTagIsBoundToTheAnnouncedPeerID() {
        let key = PeerIDRotation.recognitionKey(sharedSecret: Data(repeating: 0x42, count: 32))
        let real = PeerIDRotation.recognitionTag(
            recognitionKey: key, epoch: 100,
            senderStaticPublicKey: pubA, recipientStaticPublicKey: pubB, peerID: idA
        )
        let underAttackerID = PeerIDRotation.recognitionTag(
            recognitionKey: key, epoch: 100,
            senderStaticPublicKey: pubA, recipientStaticPublicKey: pubB,
            peerID: Data(repeating: 0xFF, count: 8)
        )
        #expect(real != underAttackerID)

        // And the lifted tag must not verify against the attacker's ID.
        let block = PeerIDRotation.tagBlock(tags: [real])
        #expect(!PeerIDRotation.blockMatches(
            block, recognitionKey: key,
            senderStaticPublicKey: pubA, recipientStaticPublicKey: pubB,
            peerID: Data(repeating: 0xFF, count: 8),
            at: Date(timeIntervalSince1970: 3600 * 100)
        ))
    }

    @Test func recognitionTagRotatesWithTheEpoch() {
        let key = PeerIDRotation.recognitionKey(sharedSecret: Data(repeating: 0x42, count: 32))
        let now = PeerIDRotation.recognitionTag(
            recognitionKey: key, epoch: 100,
            senderStaticPublicKey: pubA, recipientStaticPublicKey: pubB, peerID: idA
        )
        let next = PeerIDRotation.recognitionTag(
            recognitionKey: key, epoch: 101,
            senderStaticPublicKey: pubA, recipientStaticPublicKey: pubB, peerID: idA
        )
        #expect(now != next)
        // VECTOR: HMAC-SHA256(HKDF(ikm: 0x42*32, info: "bitchat-recognition-v1"),
        //         uint32be(100) || 0x0A*32 || 0x0B*32 || 0xA1*8)[0..8]
        #expect(hex(now) == "4568f61d61d6cbfb")
    }

    @Test func aThirdPartyCannotDeriveAPairsTag() {
        // An observer holding a *different* shared secret gets a different tag,
        // which is what stops it from tracking the pair.
        let pair = PeerIDRotation.recognitionKey(sharedSecret: Data(repeating: 0x01, count: 32))
        let other = PeerIDRotation.recognitionKey(sharedSecret: Data(repeating: 0x02, count: 32))
        #expect(PeerIDRotation.recognitionTag(
            recognitionKey: pair, epoch: 7,
            senderStaticPublicKey: pubA, recipientStaticPublicKey: pubB, peerID: idA
        ) != PeerIDRotation.recognitionTag(
            recognitionKey: other, epoch: 7,
            senderStaticPublicKey: pubA, recipientStaticPublicKey: pubB, peerID: idA
        ))
    }

    // MARK: - Tag block

    @Test func tagBlockIsAlwaysFullWidth() {
        let expected = PeerIDRotation.tagSlots * PeerIDRotation.idLength
        for count in 0...PeerIDRotation.tagSlots {
            let tags = (0..<count).map { Data(repeating: UInt8($0 + 1), count: 8) }
            #expect(PeerIDRotation.tagBlock(tags: tags).count == expected)
        }
    }

    /// A device with one favourite and a device with six must be
    /// indistinguishable from the block, or the block leaks social-graph size.
    @Test func tagBlockHidesHowManyFavouritesThereAre() {
        let one = PeerIDRotation.tagBlock(tags: [Data(repeating: 0xAA, count: 8)])
        let six = PeerIDRotation.tagBlock(
            tags: (1...6).map { Data(repeating: UInt8($0), count: 8) }
        )
        #expect(one.count == six.count)
    }

    @Test func tagBlockDropsOverflowRatherThanGrowing() {
        let tags = (1...(PeerIDRotation.tagSlots + 5)).map { Data(repeating: UInt8($0), count: 8) }
        #expect(PeerIDRotation.tagBlock(tags: tags).count == PeerIDRotation.tagSlots * 8)
    }

    @Test func padOnlyBlockUsesFreshRandomnessEachTime() {
        // Repeated identical padding would make an empty block recognisable.
        let first = PeerIDRotation.tagBlock(tags: [])
        let second = PeerIDRotation.tagBlock(tags: [])
        #expect(first != second)
    }

    @Test func tagsRoundTripThroughTheBlock() throws {
        let real = Data(repeating: 0xC3, count: 8)
        let block = PeerIDRotation.tagBlock(
            tags: [real],
            randomBytes: { Data(repeating: 0x00, count: $0) }
        )
        let slots = try #require(PeerIDRotation.tags(fromBlock: block))
        #expect(slots.count == PeerIDRotation.tagSlots)
        #expect(slots.contains(real))
    }

    @Test func malformedBlockIsRejectedRatherThanPartiallyRead() {
        #expect(PeerIDRotation.tags(fromBlock: Data()) == nil)
        #expect(PeerIDRotation.tags(fromBlock: Data(repeating: 0, count: 7)) == nil)
        #expect(PeerIDRotation.tags(fromBlock: Data(repeating: 0, count: 65)) == nil)
    }

    // MARK: - Matching

    private func matchFixture() -> (key: Data, tag: Data, date: Date) {
        let date = Date(timeIntervalSince1970: 3600 * 100)
        let key = PeerIDRotation.recognitionKey(sharedSecret: Data(repeating: 0x77, count: 32))
        let tag = PeerIDRotation.recognitionTag(
            recognitionKey: key,
            epoch: PeerIDRotation.epoch(at: date),
            senderStaticPublicKey: pubA,
            recipientStaticPublicKey: pubB,
            peerID: idA
        )
        return (key, tag, date)
    }

    @Test func blockMatchesRecogniseAPeerAnywhereInTheBlock() {
        let (key, tag, date) = matchFixture()
        // Slot order must not matter, so assert across many shuffles.
        for _ in 0..<20 {
            let block = PeerIDRotation.tagBlock(tags: [tag])
            #expect(PeerIDRotation.blockMatches(
                block, recognitionKey: key,
                senderStaticPublicKey: pubA, recipientStaticPublicKey: pubB,
                peerID: idA, at: date
            ))
        }
    }

    /// Testing the wrong direction must fail, or the directional fix would be
    /// cosmetic.
    @Test func blockDoesNotMatchTheOppositeDirection() {
        let (key, tag, date) = matchFixture()
        let block = PeerIDRotation.tagBlock(tags: [tag])
        #expect(!PeerIDRotation.blockMatches(
            block, recognitionKey: key,
            senderStaticPublicKey: pubB, recipientStaticPublicKey: pubA,
            peerID: idA, at: date
        ))
    }

    @Test func blockMatchesToleratesTheEpochBoundary() {
        let date = Date(timeIntervalSince1970: 3600 * 100)
        let key = PeerIDRotation.recognitionKey(sharedSecret: Data(repeating: 0x11, count: 32))

        func tag(epoch: UInt32) -> Data {
            PeerIDRotation.recognitionTag(
                recognitionKey: key, epoch: epoch,
                senderStaticPublicKey: pubA, recipientStaticPublicKey: pubB, peerID: idA
            )
        }
        func matches(_ candidate: Data) -> Bool {
            PeerIDRotation.blockMatches(
                PeerIDRotation.tagBlock(tags: [candidate]), recognitionKey: key,
                senderStaticPublicKey: pubA, recipientStaticPublicKey: pubB,
                peerID: idA, at: date
            )
        }

        // A peer whose clock has already ticked over still matches.
        #expect(matches(tag(epoch: 101)))
        // Two epochs out is outside the window and must not.
        #expect(!matches(tag(epoch: 98)))
    }

    @Test func randomBlockDoesNotMatch() {
        let (key, _, date) = matchFixture()
        #expect(!PeerIDRotation.blockMatches(
            PeerIDRotation.tagBlock(tags: []), recognitionKey: key,
            senderStaticPublicKey: pubA, recipientStaticPublicKey: pubB,
            peerID: idA, at: date
        ))
    }

    // MARK: - Identity binding

    @Test func bindingMessageIsFixedWidthAndContextSeparated() {
        let message = PeerIDRotation.bindingMessage(
            epoch: 100,
            peerID: Data(repeating: 0xAB, count: 8),
            noiseStaticPublicKey: Data(repeating: 0xCD, count: 32)
        )
        let context = Data("bitchat-peerid-binding-v1".utf8)
        #expect(message.count == context.count + 4 + 8 + 32)
        #expect(message.starts(with: context))
        // Must not collide with the production-dead announce-signature helpers,
        // which use "bitchat-announce-v1".
        #expect(!message.starts(with: Data("bitchat-announce-v1".utf8)))
    }

    @Test func bindingMessagePadsShortInputsRatherThanShifting() {
        // Fixed-width fields mean a short ID cannot shift the key into the ID's
        // position and produce a message that verifies for the wrong pairing.
        let short = PeerIDRotation.bindingMessage(
            epoch: 1,
            peerID: Data([0x01]),
            noiseStaticPublicKey: Data([0x02])
        )
        let padded = PeerIDRotation.bindingMessage(
            epoch: 1,
            peerID: Data([0x01]) + Data(repeating: 0, count: 7),
            noiseStaticPublicKey: Data([0x02]) + Data(repeating: 0, count: 31)
        )
        #expect(short == padded)
    }

    @Test func bindingMessageChangesWithEveryField() {
        let base = PeerIDRotation.bindingMessage(
            epoch: 1,
            peerID: Data(repeating: 0x01, count: 8),
            noiseStaticPublicKey: Data(repeating: 0x02, count: 32)
        )
        #expect(base != PeerIDRotation.bindingMessage(
            epoch: 2,
            peerID: Data(repeating: 0x01, count: 8),
            noiseStaticPublicKey: Data(repeating: 0x02, count: 32)
        ))
        #expect(base != PeerIDRotation.bindingMessage(
            epoch: 1,
            peerID: Data(repeating: 0x03, count: 8),
            noiseStaticPublicKey: Data(repeating: 0x02, count: 32)
        ))
        #expect(base != PeerIDRotation.bindingMessage(
            epoch: 1,
            peerID: Data(repeating: 0x01, count: 8),
            noiseStaticPublicKey: Data(repeating: 0x04, count: 32)
        ))
    }

    @Test func bindingMessageVerifiesUnderTheIdentityKey() throws {
        let signing = Curve25519.Signing.PrivateKey()
        let message = PeerIDRotation.bindingMessage(
            epoch: 100,
            peerID: Data(repeating: 0xAB, count: 8),
            noiseStaticPublicKey: Data(repeating: 0xCD, count: 32)
        )
        let signature = try signing.signature(for: message)
        #expect(signing.publicKey.isValidSignature(signature, for: message))

        // A different epoch must not verify: replaying a binding into a later
        // epoch is exactly what this prevents.
        let other = PeerIDRotation.bindingMessage(
            epoch: 101,
            peerID: Data(repeating: 0xAB, count: 8),
            noiseStaticPublicKey: Data(repeating: 0xCD, count: 32)
        )
        #expect(!signing.publicKey.isValidSignature(signature, for: other))
    }
}
