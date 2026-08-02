# Identity verification card export (#183)

## Scope (this PR)

Public **identity verification card** export only:

- Nickname
- Noise fingerprint
- Nostr npub (when available)
- Signed verification QR URL (public keys only)

Available from the verification sheet via **copy identity card**.

## Out of scope (future)

- Passphrase-sealed Noise identity backup / restore (see open PR #1520)
- Private key or seed export in any form

The card gives people a safe, shareable way to confirm who they are out-of-band before marking a fingerprint verified.
