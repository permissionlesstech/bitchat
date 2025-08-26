# Localization Guide

This document summarizes how localization is organized in Bitchat and how to add, edit, and validate translations.

## Structure

- `bitchat/Localization/Localizable.xcstrings` — Main string catalog (Base/en + locales).
- `bitchat/Localization/<locale>.lproj/InfoPlist.strings` — Permission prompt strings per locale.
- Tests:
  - `bitchatTests/Localization` — Unit tests validating keys across locales.
  - `bitchatUITests/Localization` — UI tests asserting labels resolve from the bundle.
- Scripts (Python stdlib only): `bitchatUITests/Localization/Scripts` with a Makefile.

## Common Tasks (Makefile)

Run these in `bitchatUITests/Localization/Scripts`:

- `make help` — list tasks/variables.
- `make audit` — heuristic audit of the `.xcstrings` file.
- `make export LOCALES=es,fr OUT=localization_exports` — export CSVs.
- `make import CSV=localization_exports/es.csv LOCALE=es` — import a CSV update.
- `make sync` — fill missing/empty locale values with Base (en) while preserving existing translations.
- `make reset LOCALES=es,fr` — copy English to specific locales (or all when LOCALES is omitted).
- `make update KEY=… LOCALE=… VALUE=…` — set a single key/locale value.
- `make check-required` — verify required locales have no missing keys.
- `make ui-test SCHEME="bitchat (iOS)" DEST="platform=iOS Simulator,name=iPhone 15,OS=latest"` — run UI tests.

All Python scripts include `--help` style usage in their headers.

## Adding a New Locale

1) InfoPlist strings
   - Create `bitchat/Localization/<locale>.lproj/InfoPlist.strings`.
   - Copy keys from `Base.lproj/InfoPlist.strings` and translate both values.

2) Seed catalog
   - Option A: run `make sync` to seed missing entries with Base (en). Then update values for the new locale.
   - Option B: export/import CSV flow:
     - `make export LOCALES=<locale> OUT=localization_exports`
     - Translate `<locale>.csv` externally.
     - `make import CSV=localization_exports/<locale>.csv LOCALE=<locale>`

3) Tests
   - Unit tests iterate across `Bundle.main.localizations`, so the new locale will be covered automatically.
   - Run `swift build -c release` then your preferred xcodebuild test invocations.

## Editing Keys

- Update Base/en first in `Localizable.xcstrings`.
- Run `make sync` to fill gaps in other locales (preserves any existing translation values).
- For surgical edits, use `make update KEY=… LOCALE=… VALUE=…`.

## Validation Checklist

- `make check-required` (required locales must not have missing values).
- `make audit` to catch possible wrong-locale strings.
- iOS tests: run on a Simulator (set via `test-sim-locale.sh` if desired).
- Visual QA for RTL and CJK locales where appropriate.

## Conventions

- Keep command/brand/tech tokens literal: `/msg`, `/block`, `#mesh`, `bitchat`, `Geohash`, `Nostr`, `Lightning`, `Cashu`.
- Keep `test.baseOnly` in English (unit test sentinel).
- Plural rules are anchored at `accessibility.people_count` (forms translated per locale).
