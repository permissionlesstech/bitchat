# Identity verification card export (#183)

## Scope (this PR)

Public **identity verification card** export only:

- Nickname
- Noise fingerprint
- Nostr npub (when available)

Available from the verification sheet via **copy identity card**.

## Why the signed QR URL is not on the card

The verification sheet's QR encodes a signed `bitchat://verify?...` URL, and it
would be the natural thing to put on a text card. It is deliberately left off:
`VerificationService.verifyScannedQR` rejects a payload older than
`TransportConfig.verificationQRMaxAgeSeconds` (5 minutes), so a URL copied onto
a card people keep and forward would stop verifying almost immediately — while
still reading as the most authoritative line on it.

The fingerprint and npub have no expiry, which is what makes them the right
fields for an out-of-band card. Scan the QR for a live, signed exchange; use the
card when the other person is not in front of a screen.

## Out of scope (future)

- Passphrase-sealed Noise identity backup / restore (see open PR #1520)
- Private key or seed export in any form

The card gives people a safe, shareable way to confirm who they are out-of-band before marking a fingerprint verified.
