# SECURITY_WORKPLAN — ASP Mesh Hardening

## Goals
- Implement rotating static keys (X25519) and master identity (Ed25519)
- Add salted/truncated IDs and epoch salts
- Implement Hop-MAC per link
- Replace naive flooding with probabilistic epidemic routing (p, k)
- Salted Bloom dedupe + LRU exact cache
- Fragmentation and robust reassembly (BLE-friendly)
- Key rotation & revocation flows
- Session rekey policies and expiry
- UX: QR/SAS verification + emergency wipe

## Tasks (branches to create)
- feature/rotate-static-keys
- feature/salted-ids
- feature/hopmac
- feature/epidemic-routing
- feature/bloom-dedupe
- feature/revocation
- docs/security-audit

