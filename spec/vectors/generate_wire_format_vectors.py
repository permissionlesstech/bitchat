#!/usr/bin/env python3
"""Generate spec/vectors/wire-format.json from the Wire Format chapter.

This is an independent encoder written from spec/01-wire-format.md §2–§6 only.
It shares no code with any bitchat client; agreement between its output and a
client's encoder is the evidence that the chapter is implementable from its
text. Ed25519 follows RFC 8032 directly and is self-checked against the RFC's
first test vector before any vector is emitted.

Run from anywhere:  python3 spec/vectors/generate_wire_format_vectors.py
"""

import hashlib
import json
from pathlib import Path

# --- Wire Format chapter, §2–§6 ------------------------------------------------

FLAG_HAS_RECIPIENT = 0x01
FLAG_HAS_SIGNATURE = 0x02
FLAG_HAS_ROUTE = 0x08
FLAG_IS_RSR = 0x10

PAD_BLOCKS = (256, 512, 1024, 2048)
PAD_ENCRYPTION_ALLOWANCE = 16


def encode_frame(pkt, padded):
    """§2 header, §4 sections in order, then §6 padding when requested."""
    version = pkt["version"]
    length_width = 4 if version == 2 else 2
    payload = bytes.fromhex(pkt["payload"])
    route = [bytes.fromhex(h) for h in (pkt.get("route") or [])]
    if version == 1:
        assert not route, "v1 packets MUST NOT carry a source route (§1)"

    flags = 0
    if pkt.get("recipient_id"):
        flags |= FLAG_HAS_RECIPIENT
    if pkt.get("signature"):
        flags |= FLAG_HAS_SIGNATURE
    if route:
        flags |= FLAG_HAS_ROUTE
    if pkt.get("is_rsr"):
        flags |= FLAG_IS_RSR

    out = bytearray()
    out += bytes([version, pkt["type"], pkt["ttl"]])
    out += pkt["timestamp"].to_bytes(8, "big")
    out += bytes([flags])
    out += len(payload).to_bytes(length_width, "big")  # §4.2: excludes route
    out += bytes.fromhex(pkt["sender_id"])
    if pkt.get("recipient_id"):
        out += bytes.fromhex(pkt["recipient_id"])
    if route:
        out += bytes([len(route)])
        for hop in route:
            out += hop
    out += payload
    if pkt.get("signature"):
        out += bytes.fromhex(pkt["signature"])
    return pad(bytes(out)) if padded else bytes(out)


def pad(frame):
    """§6: PKCS#7 to the smallest block that fits frame + 16, else unpadded."""
    target = next((b for b in PAD_BLOCKS if len(frame) + PAD_ENCRYPTION_ALLOWANCE <= b), None)
    if target is None:
        return frame
    n = target - len(frame)
    if n <= 0 or n > 255:
        return frame
    return frame + bytes([n]) * n


def signing_transcript(pkt):
    """§5: signature omitted, ttl fixed to 0, isRSR cleared, always padded."""
    unsigned = dict(pkt, signature=None, ttl=0, is_rsr=False)
    return encode_frame(unsigned, padded=True)


# --- RFC 8032 Ed25519 (reference construction, §5.1) ---------------------------

P = 2**255 - 19
Q = 2**252 + 27742317777372353535851937790883648493
D = (-121665 * pow(121666, P - 2, P)) % P


def _pt_add(a, b):
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    A = (y1 - x1) * (y2 - x2) % P
    B = (y1 + x1) * (y2 + x2) % P
    C = 2 * t1 * t2 * D % P
    Dd = 2 * z1 * z2 % P
    e, f, g, h = B - A, Dd - C, Dd + C, B + A
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def _pt_mul(s, pt):
    acc = (0, 1, 1, 0)
    while s:
        if s & 1:
            acc = _pt_add(acc, pt)
        pt = _pt_add(pt, pt)
        s >>= 1
    return acc


def _pt_compress(pt):
    x, y, z, _ = pt
    zi = pow(z, P - 2, P)
    x, y = x * zi % P, y * zi % P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def _recover_x(y, sign):
    x2 = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P:
        x = x * pow(2, (P - 1) // 4, P) % P
    if (x * x - x2) % P:
        raise ValueError("not on curve")
    if (x & 1) != sign:
        x = P - x
    return x


_G_Y = 4 * pow(5, P - 2, P) % P
_G = (_recover_x(_G_Y, 0), _G_Y, 1, _recover_x(_G_Y, 0) * _G_Y % P)


def _sha512_int(*parts):
    return int.from_bytes(hashlib.sha512(b"".join(parts)).digest(), "little")


def _expand(seed):
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def ed25519_public_key(seed):
    a, _ = _expand(seed)
    return _pt_compress(_pt_mul(a, _G))


def ed25519_sign(seed, msg):
    a, prefix = _expand(seed)
    pk = _pt_compress(_pt_mul(a, _G))
    r = _sha512_int(prefix, msg) % Q
    R = _pt_compress(_pt_mul(r, _G))
    k = _sha512_int(R, pk, msg) % Q
    s = (r + k * a) % Q
    return R + int.to_bytes(s, 32, "little")


def _self_check():
    """RFC 8032 §7.1, TEST 1 (empty message)."""
    seed = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
    assert ed25519_public_key(seed).hex() == "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
    assert ed25519_sign(seed, b"").hex() == (
        "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
    )


# --- Vectors --------------------------------------------------------------------

SENDER = "0102030405060708"
RECIPIENT = "1112131415161718"
TIMESTAMP = 1_700_000_000_000  # 0x0000018BCFE56800
SIGNING_SEED = bytes(range(0x20, 0x40))  # fixed, non-secret test key

# Payloads at or above 100 bytes are built from distinct byte values so that
# an encoder with an optional compression heuristic (see §4.3) leaves them
# verbatim; compression is an encoder choice and is not exercised here.
CASES = [
    {
        "name": "v1-announce-broadcast",
        "notes": "Minimal v1 frame: no recipient, no signature, no route. The transmitted frame for a non-Noise type is the unpadded one (§6); padded is given so the §6 algorithm can be checked on a frame that lands in the 256 block.",
        "packet": dict(version=1, type=0x01, ttl=7, timestamp=TIMESTAMP, sender_id=SENDER, recipient_id=None, route=None, payload=b"bitchat".hex(), signature=None, is_rsr=False),
    },
    {
        "name": "v1-directed-signed-rsr",
        "notes": "Directed, signed, isRSR set. The signing transcript has ttl=0, isRSR cleared, no signature section, and is padded (§5) even though the transmitted frame for type 0x02 is unpadded (§6). The signature is Ed25519 over that transcript.",
        "packet": dict(version=1, type=0x02, ttl=3, timestamp=TIMESTAMP, sender_id=SENDER, recipient_id=RECIPIENT, route=None, payload=b"signed body".hex(), signature="SIGN", is_rsr=True),
    },
    {
        "name": "v2-route-two-hops",
        "notes": "v2 header (4-byte payloadLength) with a two-hop source route. payloadLength counts only the payload; the 17 route bytes are outside it (§4.2).",
        "packet": dict(version=2, type=0x21, ttl=5, timestamp=TIMESTAMP, sender_id=SENDER, recipient_id=RECIPIENT, route=["2122232425262728", "3132333435363738"], payload="deadbeef", signature=None, is_rsr=False),
    },
    {
        "name": "v1-noise-handshake-padded-to-256",
        "notes": "A 54-byte frame: 54 + 16 <= 256, so it is padded with 202 bytes of 0xCA to 256 (§6). Noise types are transmitted padded.",
        "packet": dict(version=1, type=0x10, ttl=7, timestamp=TIMESTAMP, sender_id=SENDER, recipient_id=None, route=None, payload=bytes(range(0xA0, 0xC0)).hex(), signature=None, is_rsr=False),
    },
    {
        "name": "v1-noise-encrypted-padded-to-512",
        "notes": "A 262-byte frame: 262 + 16 > 256 so the target is 512; 250 bytes of padding fit in one byte, so it is padded.",
        "packet": dict(version=1, type=0x11, ttl=7, timestamp=TIMESTAMP, sender_id=SENDER, recipient_id=None, route=None, payload=bytes(range(240)).hex(), signature=None, is_rsr=False),
    },
    {
        "name": "v1-noise-encrypted-padding-overflow-unpadded",
        "notes": "A 250-byte frame: 250 + 16 > 256 so the target is 512, but that needs 262 pad bytes, which does not fit in one byte. §6 requires the frame to be emitted unpadded rather than padded to 256, so encoded_padded equals encoded_unpadded.",
        "packet": dict(version=1, type=0x11, ttl=7, timestamp=TIMESTAMP, sender_id=SENDER, recipient_id=None, route=None, payload=bytes(range(228)).hex(), signature=None, is_rsr=False),
    },
]


def build():
    _self_check()
    vectors = []
    for case in CASES:
        pkt = dict(case["packet"])
        entry = {"name": case["name"], "notes": case["notes"]}
        transcript = signing_transcript(pkt)
        if pkt["signature"] == "SIGN":
            sig = ed25519_sign(SIGNING_SEED, transcript)
            pkt["signature"] = sig.hex()
            entry["ed25519"] = {
                "private_key_seed": SIGNING_SEED.hex(),
                "public_key": ed25519_public_key(SIGNING_SEED).hex(),
            }
        entry["packet"] = pkt
        entry["encoded_unpadded"] = encode_frame(pkt, padded=False).hex()
        entry["encoded_padded"] = encode_frame(pkt, padded=True).hex()
        entry["signing_transcript"] = transcript.hex()
        vectors.append(entry)
    return {
        "description": "Wire Format test vectors (spec/01-wire-format.md). For each packet: encoded_unpadded is the §2–§4 frame; encoded_padded is that frame after the §6 algorithm; signing_transcript is the §5 canonical bytes an Ed25519 signature is computed over. Where ed25519 is present, packet.signature is the RFC 8032 signature of signing_transcript under private_key_seed. Hex is lowercase, no separators.",
        "spec_version": "0.1.0",
        "generator": "generate_wire_format_vectors.py",
        "vectors": vectors,
    }


if __name__ == "__main__":
    out = Path(__file__).with_name("wire-format.json")
    out.write_text(json.dumps(build(), indent=2) + "\n")
    print(f"wrote {out} ({len(CASES)} vectors)")
