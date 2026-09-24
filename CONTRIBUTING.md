# Contributing to bitchat

BitChat is a decentralized peer-to-peer messaging app with a dual-transport
architecture: Bluetooth mesh for offline communication and the Nostr protocol
for global reach. This guide describes how to contribute effectively.

## Table of contents

- [Getting a copy you can trust](#getting-a-copy-you-can-trust)
- [Ways to contribute](#ways-to-contribute)
- [Development environment](#development-environment)
- [Building and running](#building-and-running)
- [Running the tests](#running-the-tests)
- [The GeoRelay data pipeline](#the-georelay-data-pipeline)
- [Code style and review expectations](#code-style-and-review-expectations)
- [Opening a pull request](#opening-a-pull-request)
- [Reporting security issues](#reporting-security-issues)
- [License](#license)

## Getting a copy you can trust

Install from the App Store, or build from source you have verified. A compiled
build from anywhere else cannot be verified — see
[Verifying bitchat](docs/VERIFYING-A-BUILD.md) for how to check source against
the per-release hash manifest.

This matters more than it usually would: this repository has been the target
of takedown demands, and when a repository or releases page disappears, mirrors
appear that nobody can check. If you are contributing, start from a clone of
`https://github.com/permissionlesstech/bitchat` and verify the upstream commit
hash before building.

## Ways to contribute

- **Bug reports** — open an issue with a clear reproduction and the transport
  (Bluetooth mesh, Nostr, or both) you were using.
- **GeoRelay data issues** — relays that are offline, mislocated, or missing.
  The relay list is sourced from the upstream `permissionlesstech/georelays`
  repository and validated by `scripts/validate_georelays.py` before it ships.
- **Protocol and cryptography review** — the Noise Protocol and BitChat private
  envelope constructions are security-critical. See
  [BRING_THE_NOISE.md](BRING_THE_NOISE.md) and the
  [whitepaper](WHITEPAPER.md).
- **Localization** — app strings live in `bitchat/Localizable.xcstrings`.
  Prefer keys that describe intent and reuse existing ones where possible.
- **Documentation** — improvements to `docs/`, the README, or the whitepaper.
- **Tests** — the SwiftPM and Xcode test suites are the regression backbone.
  New tests that lock down existing behaviour are always welcome.

## Development environment

BitChat is a native Apple-platform app. Building it requires:

- **macOS 13 or later** (for the macOS app and the iOS simulator)
- **Xcode 15 or later** (full Xcode, not just Command Line Tools)
- **Swift 5.9+** (bundled with Xcode)
- **Bluetooth-capable hardware** for mesh testing (physical devices; the
  simulator does not exercise CoreBluetooth)

For the Python-side GeoRelay tooling under `scripts/`, only **Python 3.9+** is
required. That tooling runs in CI on Ubuntu and does not need Xcode.

Verify your environment with:

```bash
just check
```

## Building and running

```bash
# macOS Debug build without signing
xcodebuild -project bitchat.xcodeproj -scheme "bitchat (macOS)" \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build

# Or, using just:
just build
just run
```

For a signed device build, create your ignored local configuration and replace
the example team ID with your Apple Developer Team ID:

```bash
cp Configs/Local.xcconfig.example Configs/Local.xcconfig
```

`Local.xcconfig.example` derives unique app and App Group identifiers from that
team ID. The entitlement files already reference `$(APP_GROUP_ID)`, so tracked
project or entitlement files do not need to be edited.

## Running the tests

```bash
# Full SwiftPM test suite
swift test
# Or: just test

# iOS simulator tests
xcodebuild -project bitchat.xcodeproj -scheme "bitchat (iOS)" \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

# GeoRelay validator tests (Python; no Xcode required)
python3 -m unittest discover -s scripts/tests -p "test_*.py" -v
```

If `iPhone 17` is unavailable, choose an installed simulator from:

```bash
xcodebuild -showdestinations -project bitchat.xcodeproj -scheme "bitchat (iOS)"
```

## The GeoRelay data pipeline

The reviewed relay list at `relays/online_relays_gps.csv` is updated by an
automated workflow (`.github/workflows/fetch_georelays.yml`) that runs weekly.
The workflow:

1. Fetches the candidate CSV from `permissionlesstech/georelays` over a pinned
   HTTPS policy.
2. Validates it with `scripts/validate_georelays.py` against the current
   baseline, enforcing schema, coordinate ranges, hostname rules, and a
   baseline-overlap gate (the candidate must retain at least half of the
   baseline's exact relay-coordinate entries and cannot more than double it).
3. Opens a pull request with the validated candidate, or a tracking issue if
   the PR cannot be opened.

If you are changing the validator itself, run the Python test suite locally —
the same command the workflow runs in CI:

```bash
python3 -m unittest discover -s scripts/tests -p "test_*.py" -v
```

## Code style and review expectations

- **Swift** — the project uses SwiftLint in CI; violations are blocking. Run
  `swiftlint` locally before pushing. The violation backlog is at zero, and
  the goal is to keep it there.
- **Python** (under `scripts/`) — follow the existing style: `from __future__
  import annotations`, type hints, `dataclass(frozen=True)` for value types,
  and explicit `ValidationError` subclasses for user-facing failures.
- **Tests** — every behaviour change or new guard should come with a test that
  fails without the change and passes with it. Prefer `subTest` for
  parameterised cases.
- **Commits** — write a clear subject line in the imperative mood
  (`Add ...`, not `Added ...`), and a body that explains *why*. Keep changes
  focused; one logical change per commit.
- **No source-restoring clean recipes** — `just clean` removes only build
  artifacts and never touches tracked files. `scripts/check-just-clean-safety.sh`
  is a blocking guard against reintroducing source-restoring behaviour.

## Opening a pull request

1. Fork the repository and create a feature branch off `main`.
2. Make your changes with focused commits and tests.
3. Run the relevant test suite (Swift for app code, Python for `scripts/`).
4. Open a pull request against `main`. Describe the problem, the change, and
   the test plan. Link any related issues.
5. CI runs `swift-tests.yml`, `periphery.yml`, and (for `scripts/` changes)
   the `fetch_georelays.yml` validator tests.
6. Address review feedback by pushing new commits (or amending if the PR is
   small and you prefer a clean history). Force-pushing is fine on your own
   feature branch.

Small, focused PRs merge faster than large ones. If a change touches both app
code and `scripts/`, consider splitting it.

## Reporting security issues

Do not open a public issue for security vulnerabilities. See [SECURITY.md](SECURITY.md)
for the responsible disclosure process.

## License

By contributing, you agree that your contributions are released into the
public domain under the terms of the [LICENSE](LICENSE) file.
