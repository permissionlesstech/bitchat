//
// PeerIDRotation.swift
// BitFoundation
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
private import CryptoKit

/// Derivations for rotating peer IDs and pairwise recognition tags.
///
/// See `docs/PEER-ID-ROTATION.md` for the design, the threat model, and the
/// open questions. This type is the executable half of that document: it is
/// deliberately pure (no I/O, no clock of its own, no dependency on the BLE
/// stack) so both platforms can agree on the numbers before anyone wires it
/// into a transport.
///
/// Nothing here is used by the shipping mesh yet.
///
/// ## Why the derivations look like this
///
/// The rotating ID comes from **private** key material. Deriving it from the
/// public key would let anyone who has ever seen that key compute every past
/// and future ID, which is worse than not rotating because it would look like
/// protection. The same mistake is live in `CourierEnvelope.recipientTag`,
/// which is keyed on the recipient's *public* static key — and since that key
/// is broadcast in cleartext in every announce today, any observer in radio
/// range can compute a peer's courier tags for any day.
///
/// Recognition tags come from the X25519 shared secret between two static
/// keys, so exactly two parties can compute a given tag and an observer can
/// compute none of them.
// periphery:ignore - intentionally unreferenced by production code. These are
// the reviewable primitives for a protocol change that cannot ship until both
// platforms agree on it; wiring them into the transport is the next step, not
// this one. Delete this annotation when the mesh starts using them.
public enum PeerIDRotation {
    // MARK: - Parameters

    /// Seconds per rotation epoch. One hour is a starting position, not a
    /// settled one: shorter is less linkable but churns sessions, routes, and
    /// in-flight fragment reassembly more often. See open question O1.
    public static let rotationPeriod: TimeInterval = 3600

    /// Bytes of an ID or tag placed on the wire. Matches the existing 8-byte
    /// header sender ID, so the packet layout is unchanged.
    public static let idLength = 8

    /// Fixed number of tag slots in an announce. Padding to a constant hides
    /// how many mutual favourites a device has, which is itself identifying.
    public static let tagSlots = 8

    // MARK: - Context strings
    //
    // Distinct per use so a value derived for one purpose can never be
    // substituted for another. `bitchat-announce-v1` is deliberately NOT reused:
    // it belongs to the production-dead announce-signature helpers in
    // NoiseEncryptionService, and confusing the two would be a real bug.

    private static let rotationInfo = Data("bitchat-peer-rotation-v1".utf8)
    private static let peerIDContext = Data("bitchat-peer-id-v2".utf8)
    private static let recognitionInfo = Data("bitchat-recognition-v1".utf8)
    private static let bindingContext = Data("bitchat-peerid-binding-v1".utf8)

    // MARK: - Epochs

    /// Epoch number for a point in time. Wall-clock derived so two devices that
    /// have never met agree on the current epoch without negotiating.
    public static func epoch(at date: Date) -> UInt32 {
        let seconds = max(0, date.timeIntervalSince1970)
        return UInt32(truncatingIfNeeded: Int(seconds / rotationPeriod))
    }

    /// Epochs to test when matching, oldest first.
    ///
    /// The ±1 window absorbs clock skew and the moment either side crosses a
    /// boundary, mirroring `CourierEnvelope.candidateTags`. Without it, two
    /// devices a few seconds apart across a boundary would fail to recognise
    /// each other for no reason a person could understand.
    public static func candidateEpochs(around date: Date) -> [UInt32] {
        let current = epoch(at: date)
        return current == 0 ? [0, 1] : [current - 1, current, current + 1]
    }

    // MARK: - Rotating peer ID

    /// Long-lived rotation secret for this device. Derived from the Noise
    /// static **private** key, so it never leaves the device and no observer
    /// can predict any ID it produces.
    public static func rotationSecret(noiseStaticPrivateKey: Data) -> Data {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: noiseStaticPrivateKey),
            info: rotationInfo,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    /// This device's peer ID for a given epoch.
    public static func peerID(rotationSecret: Data, epoch: UInt32) -> Data {
        var message = peerIDContext
        message.append(bigEndianBytes(epoch))
        let mac = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: rotationSecret)
        )
        return Data(mac).prefix(idLength)
    }

    /// Convenience: the ID this device should be using at `date`.
    public static func currentPeerID(noiseStaticPrivateKey: Data, at date: Date) -> Data {
        peerID(
            rotationSecret: rotationSecret(noiseStaticPrivateKey: noiseStaticPrivateKey),
            epoch: epoch(at: date)
        )
    }

    // MARK: - Pairwise recognition tags

    /// Symmetric recognition key for a pair, from their X25519 shared secret.
    ///
    /// Both sides compute the identical value from opposite key halves, which
    /// is the whole point: recognition needs no round trip, and no third party
    /// can derive it.
    public static func recognitionKey(sharedSecret: Data) -> Data {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            info: recognitionInfo,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    /// The tag a peer holding this pair's recognition key expects this epoch.
    public static func recognitionTag(recognitionKey: Data, epoch: UInt32) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(
            for: bigEndianBytes(epoch),
            using: SymmetricKey(data: recognitionKey)
        )
        return Data(mac).prefix(idLength)
    }

    // MARK: - Tag block

    /// Packs tags into the fixed-size announce block, padding with uniform
    /// random bytes.
    ///
    /// Random padding is indistinguishable from a real tag to anyone who cannot
    /// compute the real ones, so the block discloses neither how many mutual
    /// favourites a device has nor which slot belongs to whom. Tags beyond
    /// `tagSlots` are dropped here; choosing *which* to carry across successive
    /// announces is the caller's problem (open question O2).
    public static func tagBlock(
        tags: [Data],
        randomBytes: (Int) -> Data = Self.secureRandomBytes
    ) -> Data {
        var slots = tags.prefix(tagSlots).map { $0.prefix(idLength) }
        // Order must carry no information, so shuffle rather than appending
        // real tags at the front.
        slots.shuffle()
        var block = Data()
        for slot in slots {
            block.append(slot)
            if slot.count < idLength {
                block.append(Data(repeating: 0, count: idLength - slot.count))
            }
        }
        let padding = (tagSlots - slots.count) * idLength
        if padding > 0 {
            block.append(randomBytes(padding))
        }
        return block
    }

    /// Splits a received block back into candidate tags.
    ///
    /// Returns nil for a block that is not exactly `tagSlots * idLength`, so a
    /// malformed announce is rejected rather than partially interpreted.
    public static func tags(fromBlock block: Data) -> [Data]? {
        guard block.count == tagSlots * idLength else { return nil }
        return stride(from: 0, to: block.count, by: idLength).map {
            block.subdata(in: (block.startIndex + $0)..<(block.startIndex + $0 + idLength))
        }
    }

    /// Whether any slot in `block` matches a tag this pair expects at `date`.
    ///
    /// Comparison is constant-time per candidate, and every slot is examined
    /// even after a match, so neither the presence of a match nor its slot
    /// index is observable through timing.
    public static func blockMatches(
        _ block: Data,
        recognitionKey: Data,
        at date: Date
    ) -> Bool {
        guard let slots = tags(fromBlock: block) else { return false }
        let expected = candidateEpochs(around: date).map {
            recognitionTag(recognitionKey: recognitionKey, epoch: $0)
        }
        var matched = false
        for slot in slots {
            for candidate in expected where constantTimeEquals(slot, candidate) {
                matched = true
            }
        }
        return matched
    }

    // MARK: - Identity binding

    /// Canonical bytes proving a rotating ID belongs to a static key.
    ///
    /// Signed with the Ed25519 identity key and exchanged **inside** a
    /// completed Noise session, this replaces the derivation check that today
    /// makes peer IDs unforgeable (`peerID == SHA-256(staticKey)[0..8]`, checked
    /// in the announce preflight and again at handshake completion). Once IDs
    /// are independent of the key, those checks fail for every peer, so a
    /// replacement has to exist before rotation can ship.
    ///
    /// Fixed-width fields throughout: no length prefixes are needed and no two
    /// distinct inputs can produce the same bytes.
    public static func bindingMessage(
        epoch: UInt32,
        peerID: Data,
        noiseStaticPublicKey: Data
    ) -> Data {
        var out = bindingContext
        out.append(bigEndianBytes(epoch))
        out.append(fixedWidth(peerID, idLength))
        out.append(fixedWidth(noiseStaticPublicKey, 32))
        return out
    }

    // MARK: - Helpers

    /// Padding must be indistinguishable from a real tag, so it comes from the
    /// system CSPRNG via key generation rather than a general-purpose RNG.
    public static func secureRandomBytes(_ count: Int) -> Data {
        guard count > 0 else { return Data() }
        let key = SymmetricKey(size: SymmetricKeySize(bitCount: count * 8))
        return key.withUnsafeBytes { Data($0) }
    }

    private static func bigEndianBytes(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func fixedWidth(_ data: Data, _ width: Int) -> Data {
        var out = data.prefix(width)
        if out.count < width {
            out.append(Data(repeating: 0, count: width - out.count))
        }
        return Data(out)
    }

    /// Length-independent comparison, so a match cannot be found byte by byte
    /// through timing.
    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
