# Nix development shell (#1556)

BitChat’s iOS/macOS targets are built with **Xcode**. A Nix flake cannot replace
the Apple toolchain, but it can pin ordinary CLI helpers for contributors who
already use `nix develop`.

## What the flake provides

```bash
nix develop
```

Currently: `git`, `jq`, `python3`, plus a shell hook that checks `xcode-select`.

It does **not** vend `xcodebuild`, simulators, or signing identities.

## What you still need

1. Xcode from the Mac App Store (version matching `Configs/` / CI).
2. Accept the Xcode license: `sudo xcodebuild -license`
3. Open `bitchat.xcodeproj` / use the project’s documented test commands.

## Why this is intentionally small

Shipping a “full” Swift/Nix app shell that pretends to compile BitChat without
Xcode would rot against Apple’s SDK and confuse CI. Prefer documenting the
boundary (#1556) over a brittle xcframework rebuild inside Nix.

If you need reproducible **Rust** pieces (e.g. Arti tooling), add those packages
explicitly in a follow-up rather than expanding this flake by default.

## Lockfile

If you have Nix installed, run `nix flake lock` and commit `flake.lock` so the
nixpkgs input is pinned for everyone.

## CI

GitHub Actions continues to use macOS runners with Xcode. This flake is for
local contributor convenience only and is not wired into CI yet.

