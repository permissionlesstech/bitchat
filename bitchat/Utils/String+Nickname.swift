//
// String+Nickname.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import BitFoundation   // PeerID, for the row decoration check

extension String {
    /// Canonical form for nickname storage and comparison (Unicode NFC).
    /// "café" typed with a combining accent and "café" typed precomposed
    /// must resolve to the same user wherever nicknames are stored or
    /// matched (mentions, DM resolution, autocomplete, geo presence).
    var normalizedNickname: String {
        precomposedStringWithCanonicalMapping
    }

    /// The form two nicknames are compared in to decide whether they are the
    /// SAME NAME — used for the verified-name binding.
    ///
    /// NFC plus a locale-independent case fold, twice normalised because case
    /// folding can itself emit decomposed sequences (Turkish İ lowercases to
    /// i + U+0307). Recasing your own nickname is not a rename, so it must not
    /// break the binding.
    ///
    /// Deliberately NFC and not NFKC: a fullwidth `Ｍedic` merely *looks* like
    /// `Medic`, so it is a different name and must break the binding. Folding
    /// look-alikes is `PeerDisplayNameResolver.collisionKey`'s job, which is
    /// asking a different question — whether two peers need telling apart.
    var nicknameBindingKey: String {
        normalizedNickname.lowercased().normalizedNickname
    }

    /// Strips ONLY a trailing `#abcd` collision suffix, leaving everything
    /// else alone.
    ///
    /// Deliberately not `splitSuffix()`: that also removes every `@` in the
    /// string, which is right for parsing a mention but wrong for comparing a
    /// nickname — nothing in `validateNickname` forbids `@`, so `ravi@hq`
    /// would compare unequal to itself.
    var withoutCollisionSuffix: String {
        guard count >= 5 else { return self }
        let tail = suffix(5)
        // ASCII hex only, matching how `splitSuffix()` recognises the suffix
        // this device generates. `Character.isHexDigit` would also accept
        // fullwidth digits, so a nickname literally ending in "#ＡＢＣＤ"
        // would be truncated and could then match a baseline it is not.
        let isAsciiHex: (Character) -> Bool = { c in
            ("0"..."9").contains(c) || ("a"..."f").contains(c) || ("A"..."F").contains(c)
        }
        guard tail.first == "#", tail.dropFirst().allSatisfy(isAsciiHex) else { return self }
        return String(dropLast(5))
    }

    /// Does a seal pinned to `self` still apply beside `rendered` — a name as
    /// it appears on a message row, which the list may have decorated?
    ///
    /// `decoration` is the peer's own `#abcd`, built from its peerID exactly as
    /// `PeerDisplayNameResolver` builds it. That is what makes this answerable
    /// at all: a row string on its own cannot distinguish the list decorating
    /// `ravi` with `#a1b2` from the peer announcing the name `ravi#a1b2`.
    ///
    /// This used to strip any trailing `#` plus four hex, unconditionally, and
    /// was wrong in both directions because a peer announces whatever string it
    /// likes and `#` plus four hex is a legal thing to announce:
    ///
    ///   pinned `ravi#cafe`, row shows `ravi#cafe` → seal LOST with no rename
    ///   pinned `ravi`,      row shows `ravi#cafe` → seal KEPT after a rename
    ///
    /// The second is the one that matters, and it survives a "try the raw name
    /// first" fix — which is why this takes the peerID instead. `#cafe` is
    /// indistinguishable from the decoration this app generates itself, so the
    /// row reads as "ravi, disambiguated": a better disguise than an unrelated
    /// nickname, not a worse one. Only the suffix this peer would actually be
    /// given comes off.
    ///
    /// The live check must NOT use this. What a peer announces has no
    /// decoration to remove.
    func matchesRenderedName(_ rendered: String, decoratedFor peerID: PeerID?) -> Bool {
        if nicknameBindingKey == rendered.nicknameBindingKey { return true }
        guard let peerID else { return false }
        let mine = "#" + String(peerID.id.prefix(4))
        guard rendered.count > mine.count, rendered.hasSuffix(mine) else { return false }
        let undecorated = String(rendered.dropLast(mine.count))
        return nicknameBindingKey == undecorated.nicknameBindingKey
    }

    /// Split a nickname into base and a '#abcd' suffix if present
    func splitSuffix() -> (String, String) {
        let name = self.replacingOccurrences(of: "@", with: "")
        guard name.count >= 5 else { return (name, "") }
        let suffix = String(name.suffix(5))
        if suffix.first == "#", suffix.dropFirst().allSatisfy({ c in
            ("0"..."9").contains(String(c)) || ("a"..."f").contains(String(c)) || ("A"..."F").contains(String(c))
        }) {
            let base = String(name.dropLast(5))
            return (base, suffix)
        }
        return (name, "")
    }
}
