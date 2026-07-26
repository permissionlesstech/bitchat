# Security policy

bitchat is a security-focused messenger, and reports about its security are taken seriously. This page says how to report, what counts as a vulnerability here, and what to expect.

## Reporting a vulnerability

**Use GitHub's private vulnerability reporting:** [Report a vulnerability](https://github.com/permissionlesstech/bitchat/security/advisories/new) (Security tab → "Report a vulnerability").

Please do not open a public issue for anything that could put people at risk before a fix ships. bitchat is used by people in hostile network environments; a public proof-of-concept can be acted on faster than a patch can reach them.

A useful report says what an attacker can do, against which build (App Store version or commit hash), and how to reproduce it. A failing test or a packet capture is worth more than speculation about impact.

## What to expect

This is a volunteer-maintained project. The aim is to acknowledge reports within a week and to move on confirmed vulnerabilities immediately — historically, confirmed protocol and key-handling issues have been fixed within days. You'll be kept in the loop in the advisory thread, and credited in the fix unless you'd rather not be. There is no bug bounty.

## Supported versions

Fixes ship to the latest App Store release and `main`. Older releases are not patched; the fix is to update.

## Scope

In scope — the properties the app promises:

- Confidentiality and integrity of private messages and media (Noise sessions over BLE; over Nostr, bitchat's own ephemeral private-envelope format — a proprietary scheme, *not* NIP-17/NIP-44/NIP-59, see `WHITEPAPER.md`)
- Identity: key handling, verification, impersonation, session binding
- The panic wipe actually destroying what it claims to destroy
- Metadata exposure beyond what the documentation already discloses (see `PRIVACY_POLICY.md` and `docs/privacy-assessment.md`)
- Downgrade paths: anything that silently moves traffic from an encrypted path to a plaintext one
- Tor routing: anything that makes traffic bypass Tor while the Tor preference is on
- Supply-chain integrity of the source and its vendored binaries (see `docs/VERIFYING-A-BUILD.md`)

Out of scope — documented design properties, not vulnerabilities:

- Public visibility of mesh announces and geohash channels: broadcast content, nicknames, and public keys are public by design
- Bluetooth proximity being observable: anyone in radio range can tell a BLE device is present
- Mesh flooding/relay behavior inherent to a broadcast mesh (rate limits exist; the topology is what it is)
- Behavior of third-party Nostr relays
- Denial of service requiring physical proximity, and battery-drain attacks in general

If you're unsure whether something is in scope, report it privately anyway — a false alarm costs a few minutes; a real issue reported publicly can cost much more.

## Verifying what you're running

If your concern is that the app or source you have has been tampered with, that has its own document: `docs/VERIFYING-A-BUILD.md`.
