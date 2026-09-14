import Foundation
import BitFoundation
import Testing

@testable import bitchat

/// Binds a trust seal to the nickname it was earned under.
///
/// `VouchAttestation` signs `voucheeFingerprint | voucheeSigningKey |
/// timestampMs` and deliberately says nothing about a name — a name-free
/// attestation is the right wire format. But the seal is *rendered* beside a
/// self-claimed nickname, so the binding has to live on the receiver, which is
/// the only party that knows what name the key was presenting when it decided
/// to trust it. These tests pin that rule.
///
/// `@MainActor` for the same reason as `SecureIdentityStateManagerVouchTests`:
/// the manager's blocking `queue.sync` reads must stay off the Swift
/// Concurrency cooperative pool, or CI's few-core runners deadlock.
@MainActor
struct SecureIdentityStateManagerNicknameBindingTests {
    private let voucher = String(repeating: "0a", count: 32)
    private let secondVoucher = String(repeating: "0c", count: 32)
    private let vouchee = String(repeating: "0b", count: 32)

    private func makeManager() -> SecureIdentityStateManager {
        SecureIdentityStateManager(MockKeychain())
    }

    /// Mirrors the announce path: the peer tells us what it calls itself.
    private func announce(_ manager: SecureIdentityStateManager,
                          _ fingerprint: String,
                          as nickname: String) {
        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: Data(repeating: 0x01, count: 32),
            signingPublicKey: nil,
            claimedNickname: nickname
        )
    }

    private func setPetname(_ manager: SecureIdentityStateManager,
                            _ fingerprint: String,
                            _ petname: String?) {
        guard var identity = manager.getSocialIdentity(for: fingerprint) else { return }
        identity.localPetname = petname
        manager.updateSocialIdentity(identity)
    }

    // MARK: - The attack this closes

    @Test
    func vouchPinsTheNicknameItWasEarnedUnder() {
        let manager = makeManager()
        announce(manager, vouchee, as: "ravi")
        manager.setVerified(fingerprint: voucher, verified: true)

        #expect(manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: Date()))
        #expect(!manager.trustedNicknameMismatch(fingerprint: vouchee))
    }

    @Test
    func renamingOntoATrustedNameAfterEarningAVouchIsAMismatch() {
        let manager = makeManager()
        announce(manager, vouchee, as: "ravi")
        manager.setVerified(fingerprint: voucher, verified: true)
        manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: Date())

        announce(manager, vouchee, as: "medic")

        #expect(manager.isVouched(fingerprint: vouchee),
                "the vouch itself is still valid; only its binding to a name broke")
        #expect(manager.trustedNicknameMismatch(fingerprint: vouchee))
    }

    @Test
    func aLaterVoucherCannotReanchorTheBaselineToTheNewName() {
        let manager = makeManager()
        announce(manager, vouchee, as: "ravi")
        manager.setVerified(fingerprint: voucher, verified: true)
        manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: Date())
        announce(manager, vouchee, as: "medic")

        manager.setVerified(fingerprint: secondVoucher, verified: true)
        manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: secondVoucher, timestamp: Date())

        #expect(manager.trustedNicknameMismatch(fingerprint: vouchee),
                "the second vouch did not launder the rename")
    }

    // MARK: - Vouches for peers we have not seen yet

    @Test
    func aVouchForAnUnseenPeerBindsOnTheirFirstAnnounce() {
        // The usual case: the vouch arrives over Noise from someone else and
        // the vouchee is not in our announce set yet, so there is no name to
        // bind to at record time.
        let manager = makeManager()
        manager.setVerified(fingerprint: voucher, verified: true)
        manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: Date())
        #expect(!manager.trustedNicknameMismatch(fingerprint: vouchee),
                "nothing is bound yet, so nothing can mismatch")

        announce(manager, vouchee, as: "ravi")
        #expect(!manager.trustedNicknameMismatch(fingerprint: vouchee))

        announce(manager, vouchee, as: "medic")
        #expect(manager.trustedNicknameMismatch(fingerprint: vouchee))
    }

    @Test
    func theAnnouncePathDoesNotBindBeforeTrustExists() {
        // Otherwise a peer who renamed BEFORE being vouched would be bound to
        // the name we happened to see first, and lose a legitimate seal.
        let manager = makeManager()
        announce(manager, vouchee, as: "rav")
        announce(manager, vouchee, as: "ravi")

        manager.setVerified(fingerprint: voucher, verified: true)
        manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: Date())

        #expect(!manager.trustedNicknameMismatch(fingerprint: vouchee),
                "bound to the name it was vouched under, not the name seen first")
    }

    @Test
    func aFirstAnnounceThatIsAlreadyTheImpersonatingNameIsNotCaught() {
        // The documented limit of receiver-side binding: if we never saw this
        // key under its real name, the impersonating name IS the baseline.
        // Only signing the nickname into the attestation closes this, which is
        // a wire change and deliberately not attempted here.
        let manager = makeManager()
        manager.setVerified(fingerprint: voucher, verified: true)
        manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: Date())

        announce(manager, vouchee, as: "medic")

        #expect(!manager.trustedNicknameMismatch(fingerprint: vouchee),
                "known gap, pinned here so it is explicit rather than a surprise")
    }

    // MARK: - Not fooled by display decoration

    @Test
    func theCheckIsUnaffectedByCollisionSuffixes() {
        // `PeerDisplayNameResolver` renders two CONNECTED peers who both claim
        // "medic" as "medic#a1b2" and "medic#c3d4" — which is exactly what
        // happens during this attack. Comparing a rendered name would drop the
        // real medic's seal at the worst possible moment, so the check reads
        // announced names only. This pins that the resolver really does
        // decorate, and that the binding ignores it.
        let real = PeerDisplayNameResolver.resolve(
            [(peerID: PeerID(str: "a1b2c3d4"), nickname: "medic", isConnected: true),
             (peerID: PeerID(str: "c3d4e5f6"), nickname: "medic", isConnected: true)],
            selfNickname: "me")
        #expect(real[PeerID(str: "a1b2c3d4")] == "medic#a1b2", "the resolver does decorate")

        let manager = makeManager()
        announce(manager, vouchee, as: "medic")
        manager.setVerified(fingerprint: vouchee, verified: true)
        announce(manager, vouchee, as: "medic")   // still "medic" on the wire

        #expect(!manager.trustedNicknameMismatch(fingerprint: vouchee),
                "the impersonated peer keeps its seal while a namesake is connected")
    }

    @Test
    func aLocalPetnameKeepsTheSeal() {
        // A petname outranks the claimed nickname everywhere it is displayed,
        // so a rename cannot spoof anything and the seal stands.
        let manager = makeManager()
        announce(manager, vouchee, as: "ravi")
        manager.setVerified(fingerprint: vouchee, verified: true)
        announce(manager, vouchee, as: "medic")
        #expect(manager.trustedNicknameMismatch(fingerprint: vouchee))

        setPetname(manager, vouchee, "my neighbour")
        #expect(!manager.trustedNicknameMismatch(fingerprint: vouchee))

        setPetname(manager, vouchee, nil)
        #expect(manager.trustedNicknameMismatch(fingerprint: vouchee))
    }

    @Test
    func namesAreComparedInCanonicalForm() {
        // Same rule as `normalizedNickname` everywhere else: a decomposed and a
        // precomposed "café" are one name, not a rename.
        let manager = makeManager()
        announce(manager, vouchee, as: "cafe\u{0301}")        // e + combining acute
        manager.setVerified(fingerprint: vouchee, verified: true)

        announce(manager, vouchee, as: "caf\u{00E9}")          // precomposed é
        #expect(!manager.trustedNicknameMismatch(fingerprint: vouchee))

        announce(manager, vouchee, as: "cafe")
        #expect(manager.trustedNicknameMismatch(fingerprint: vouchee))
    }

    // MARK: - A seal beside a name frozen on a message row

    @Test
    func renamingBackDoesNotRestoreTheSealOnARowPostedUnderTheOtherName() {
        // The hole in checking only the CURRENT name: a message row renders
        // `message.sender` frozen at receipt, so rename away, post, rename
        // back, and the live name matches the baseline again while the archived
        // row still reads the name it was posted under.
        let manager = makeManager()
        announce(manager, vouchee, as: "ravi")
        manager.setVerified(fingerprint: vouchee, verified: true)

        announce(manager, vouchee, as: "medic")          // rename
        #expect(manager.trustedNicknameMismatch(fingerprint: vouchee))
        announce(manager, vouchee, as: "ravi")           // ...and back
        #expect(!manager.trustedNicknameMismatch(fingerprint: vouchee),
                "the live name is bound again, which is why the live check alone is not enough")

        #expect(!manager.sealAppliesToRow(fingerprint: vouchee, renderedSender: "medic"),
                "the row posted as medic must not be sealed")
        #expect(manager.sealAppliesToRow(fingerprint: vouchee, renderedSender: "ravi"),
                "a row posted as ravi still is — that row really was ravi")
    }

    @Test
    func aHistoricalRowKeepsItsSealWhileTheKeyIsCurrentlyRenamed() {
        // The converse, so the rule is not simply "suppress harder": a row
        // posted under the verified name stays truthful even once that key has
        // moved on, otherwise ordinary renames retroactively unseal history.
        let manager = makeManager()
        announce(manager, vouchee, as: "ravi")
        manager.setVerified(fingerprint: vouchee, verified: true)
        announce(manager, vouchee, as: "medic")

        #expect(manager.trustedNicknameMismatch(fingerprint: vouchee), "live name is unbound")
        #expect(manager.sealAppliesToRow(fingerprint: vouchee, renderedSender: "ravi"),
                "but the archived ravi row is still accurate")
        #expect(!manager.sealAppliesToRow(fingerprint: vouchee, renderedSender: "medic"))
    }

    @Test
    func aRowSenderCarryingACollisionSuffixIsStillMatched() {
        // Message senders render as "ravi#a1b2" when nicknames collide. Only a
        // trailing #abcd is stripped — `splitSuffix()` would also remove every
        // "@", and nothing forbids one in a nickname.
        let manager = makeManager()
        announce(manager, vouchee, as: "ravi@hq")
        manager.setVerified(fingerprint: vouchee, verified: true)

        #expect(manager.sealAppliesToRow(fingerprint: vouchee, renderedSender: "ravi@hq"))
        #expect(manager.sealAppliesToRow(fingerprint: vouchee, renderedSender: "ravi@hq#a1b2"))
        #expect(!manager.sealAppliesToRow(fingerprint: vouchee, renderedSender: "ravi"))
        #expect(!manager.sealAppliesToRow(fingerprint: vouchee, renderedSender: "medic#a1b2"))
    }

    @Test
    func aRowIsNotSealedForAnUnverifiedKeyAndFailsOpenWithNoBaseline() {
        let manager = makeManager()
        announce(manager, vouchee, as: "ravi")
        #expect(!manager.sealAppliesToRow(fingerprint: vouchee, renderedSender: "ravi"),
                "no verification, no seal")

        // Verified before any announce: nothing bound, so rows stay sealed as
        // they did before this existed.
        let unbound = makeManager()
        unbound.setVerified(fingerprint: vouchee, verified: true)
        #expect(unbound.sealAppliesToRow(fingerprint: vouchee, renderedSender: "anything"))
    }

    @Test
    func theBaselineIsKeptSoASheetCanNameIt() {
        // Suppressing the seal is the security fix; saying WHICH name was
        // verified is what lets a reader recognise the peer instead of
        // guessing. The baseline therefore survives the rename it detects.
        let manager = makeManager()
        announce(manager, vouchee, as: "ravi")
        manager.setVerified(fingerprint: vouchee, verified: true)
        #expect(manager.trustedNickname(fingerprint: vouchee) == "ravi")

        announce(manager, vouchee, as: "medic")
        #expect(manager.trustedNicknameMismatch(fingerprint: vouchee))
        #expect(manager.trustedNickname(fingerprint: vouchee) == "ravi",
                "the baseline is what the sheet needs to name")
    }

    // MARK: - What counts as the same name

    @Test
    func recasingYourOwnNicknameIsNotARename() {
        // Found auditing my own revision: the binding compared NFC only, so
        // changing "Ravi" to "ravi" broke it and silently dropped the seal.
        let manager = makeManager()
        announce(manager, vouchee, as: "Ravi")
        manager.setVerified(fingerprint: vouchee, verified: true)

        announce(manager, vouchee, as: "ravi")
        #expect(!manager.trustedNicknameMismatch(fingerprint: vouchee))
        #expect(manager.sealAppliesToRow(fingerprint: vouchee, renderedSender: "RAVI"))
    }

    @Test
    func aLookAlikeNameDoesBreakTheBinding() {
        // The other half of that: the binding key is NFC, deliberately not
        // NFKC. A fullwidth Ｍ merely LOOKS like M, so it is a different name
        // and must break the binding — folding look-alikes is the collision
        // resolver's job, which answers a different question.
        let manager = makeManager()
        announce(manager, vouchee, as: "Medic")
        manager.setVerified(fingerprint: vouchee, verified: true)

        announce(manager, vouchee, as: "\u{FF2D}edic")
        #expect(manager.trustedNicknameMismatch(fingerprint: vouchee))
        #expect(!manager.sealAppliesToRow(fingerprint: vouchee, renderedSender: "\u{FF2D}edic"))
    }

    @Test
    func onlyAnAsciiCollisionSuffixIsStripped() {
        // `Character.isHexDigit` also accepts fullwidth digits, so a nickname
        // literally ending in "#ＡＢＣＤ" was being truncated and could then
        // match a baseline it is not. ASCII only, like `splitSuffix()`.
        let manager = makeManager()
        announce(manager, vouchee, as: "medic")
        manager.setVerified(fingerprint: vouchee, verified: true)

        #expect(manager.sealAppliesToRow(fingerprint: vouchee, renderedSender: "medic#a1b2"))
        #expect(!manager.sealAppliesToRow(fingerprint: vouchee,
                                          renderedSender: "medic#\u{FF21}\u{FF22}\u{FF23}\u{FF24}"),
                "a fullwidth tail is part of the name, not a suffix this device generates")
        #expect(!manager.sealAppliesToRow(fingerprint: vouchee, renderedSender: "medic#zzzz"),
                "non-hex is part of the name too")
    }

    // MARK: - Rebinding and clearing

    @Test
    func verifyingInPersonRebindsToTheCurrentName() {
        let manager = makeManager()
        announce(manager, vouchee, as: "ravi")
        manager.setVerified(fingerprint: voucher, verified: true)
        manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: Date())
        announce(manager, vouchee, as: "medic")
        #expect(manager.trustedNicknameMismatch(fingerprint: vouchee))

        // The user scanned this key themselves, under the name it shows now.
        manager.setVerified(fingerprint: vouchee, verified: true)

        #expect(!manager.trustedNicknameMismatch(fingerprint: vouchee))
    }

    @Test
    func unverifyingClearsTheBaselineOnlyWhenNoVouchRemains() {
        let manager = makeManager()
        announce(manager, vouchee, as: "ravi")

        manager.setVerified(fingerprint: vouchee, verified: true)
        announce(manager, vouchee, as: "medic")
        #expect(manager.trustedNicknameMismatch(fingerprint: vouchee))

        manager.setVerified(fingerprint: vouchee, verified: false)
        #expect(!manager.trustedNicknameMismatch(fingerprint: vouchee),
                "with no trust left there is no baseline, so nothing to mismatch")

        // With a vouch still standing, the baseline has to survive: it is what
        // that vouch's seal is bound to.
        announce(manager, vouchee, as: "ravi")
        manager.setVerified(fingerprint: voucher, verified: true)
        manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: Date())
        manager.setVerified(fingerprint: vouchee, verified: true)
        manager.setVerified(fingerprint: vouchee, verified: false)
        announce(manager, vouchee, as: "medic")
        #expect(manager.trustedNicknameMismatch(fingerprint: vouchee),
                "the vouch's seal still needs the name it was bound to")
    }

    // MARK: - Failing open

    @Test
    func aMissingBaselineNeverSuppressesASeal() {
        // Verified before the peer ever announced a name — there is nothing to
        // bind to, and pinning "" would read as a mismatch against every later
        // announce. Peers trusted by builds before this shipped land here too,
        // so an upgrade must not silently drop their seals.
        let manager = makeManager()
        manager.setVerified(fingerprint: vouchee, verified: true)
        #expect(!manager.trustedNicknameMismatch(fingerprint: vouchee))

        announce(manager, vouchee, as: "medic")
        #expect(!manager.trustedNicknameMismatch(fingerprint: vouchee))
    }

    @Test
    func anEmptyClaimedNicknameIsNotAMismatch() {
        let manager = makeManager()
        announce(manager, vouchee, as: "ravi")
        manager.setVerified(fingerprint: vouchee, verified: true)
        announce(manager, vouchee, as: "")

        #expect(!manager.trustedNicknameMismatch(fingerprint: vouchee))
    }

    // MARK: - Persistence compatibility

    @Test
    func aCacheWrittenBeforeThisFieldExistedStillLoads() throws {
        let legacyJSON = Data("""
        {"socialIdentities":{},"nicknameIndex":{},"verifiedFingerprints":["\(vouchee)"],\
        "lastInteractions":{},"blockedNostrPubkeys":[],"cryptographicIdentities":{},"version":1}
        """.utf8)

        let decoded = try JSONDecoder().decode(IdentityCache.self, from: legacyJSON)

        #expect(decoded.trustedNicknames == nil)
        #expect(decoded.verifiedFingerprints.contains(vouchee))
    }

    @Test
    func theBaselineSurvivesAnEncodeDecodeRoundTrip() throws {
        var cache = IdentityCache()
        cache.trustedNicknames = [vouchee: "ravi"]

        let decoded = try JSONDecoder().decode(IdentityCache.self, from: JSONEncoder().encode(cache))

        #expect(decoded.trustedNicknames?[vouchee] == "ravi")
    }
}
