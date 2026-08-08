# Conformance

**Spec:** 1.0.1

This file is a living checklist. Golden hex vectors for every mesh type are a
planned follow-up (see issue
[#1448](https://github.com/permissionlesstech/bitchat/issues/1448)); until
then, independent clients SHOULD lock behaviour against the reference tests
listed below and against byte-identical round-trips with
`localPackages/BitFoundation`.

---

## 1. Existing vector / test assets

| Asset | Path | Covers |
|-------|------|--------|
| Noise explorer XX vectors | `bitchatTests/Noise/NoiseTestVectors.json` | Crypto core for `Noise_XX_25519_ChaChaPoly_SHA256` (prologue/payloads differ from production mesh XX — see [`03-noise.md`](03-noise.md)) |
| Noise protocol tests | `bitchatTests/Noise/NoiseProtocolTests.swift` | Handshake + cipher behaviour |
| Binary protocol tests | `localPackages/BitFoundation/Tests/BitFoundationTests/BinaryProtocolTests.swift` | Header, flags, padding |
| Courier envelope tests | `localPackages/BitFoundation/Tests/BitFoundationTests/CourierEnvelopeTests.swift` | TLV encode/decode, tags |
| Fragmentation tests | `bitchatTests/Fragmentation/FragmentationTests.swift` | Split/reassembly |
| Protocol contract tests | `bitchatTests/ProtocolContractTests.swift` | Type surface smoke checks |
| Private media E2E | `bitchatTests/EndToEnd/PrivateMediaEndToEndTests.swift` | `0x20` private file path |
| Prekey E2E | `bitchatTests/EndToEnd/PrekeyEndToEndTests.swift` | Prekey seal/open |

Run from repo root:

```bash
swift test
# or
just test
```

---

## 2. Minimum interoperability checklist

### Wire format

- [ ] Encode/decode v1 and v2 packets with correct endianness.
- [ ] Honor optional recipient, signature, compression, route flags.
- [ ] Exclude TTL/`isRSR` from signature canonicalization; include PKCS#7
      padding from `encode(padding: true)` in the preimage.
- [ ] Derive 8-byte peer IDs as `SHA256(noiseStatic)[0..<8]`.

### BLE

- [ ] Use release GATT service UUID `…4B5C` and characteristic `…4C5D`.
- [ ] Advertise service UUID only (no local name).
- [ ] Fragment with 13-byte header; reassemble with first-wins metadata.
- [ ] Dispatch reassembled packets by decoded type, not header `originalType`.
- [ ] Default origination TTL = 7.

### Noise

- [ ] XX live sessions, empty prologue, empty handshake payloads.
- [ ] Transport frames use 4-byte extracted nonce prefix.
- [ ] Typed inner payloads; ignore unknown types.
- [ ] Courier X seals with prologue `bitchat-courier-v1`.
- [ ] Optional prekey X seals with `bitchat-prekey-v1` ‖ id.

### Payloads

- [ ] Announce TLVs (nickname + Noise + Ed25519) with outer signature.
- [ ] Capability bitfield little-endian.
- [ ] File TLV content length 4-byte BE; private files via Noise `0x20`.
- [ ] Courier recipient tag HMAC construction.
- [ ] Unknown-TLV skip only where listed; private-message unknown tags reject.

### Nostr

- [ ] Proprietary `v2:` private envelopes (not NIP-44).
- [ ] Geohash kinds 20000 / 20001 per `docs/GeohashPresenceSpec.md`.

---

## 3. Planned vector work (non-blocking for this draft)

1. Hex fixtures for: empty announce, signed announce, public message, fragment
   set, XX handshake transcript with production parameters, one courier
   envelope, one file TLV.
2. Version the fixture directory under `spec/vectors/` and cite it from this
   file.
3. Cross-check fixtures against the Android reference client.

House style for vectors can follow patterns already used by Noise JSON vectors
and any courier fixtures maintainers add alongside BitFoundation tests.
