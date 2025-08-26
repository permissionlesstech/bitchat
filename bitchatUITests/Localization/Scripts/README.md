# Localization Scripts

Python-based helpers for working with the `.xcstrings` catalog and simulator localization.

All scripts here use only the Python 3 standard library (no third‑party deps). Shell
helpers remain in Bash. Paths below are relative to the repo root.

## Catalog Utilities (Python)

- `audit_xcstrings.py`
  - Heuristic audit of a `.xcstrings` file. Flags likely wrong-locale values by
    script mismatch (e.g., Latin in Arabic locales) and cross-language tokens in
    Latin locales.
  - Usage: `python3 bitchatUITests/Localization/Scripts/audit_xcstrings.py bitchat/Localization/Localizable.xcstrings`

- `export_xcstrings_csv.py`
  - Export one CSV per locale (columns: `key,en,<locale>`).
  - Usage: `python3 .../export_xcstrings_csv.py <xcstrings> <out_dir> [--locales es,fr]`

- `import_xcstrings_csv.py`
  - Import a locale CSV back into the `.xcstrings` catalog.
  - Usage: `python3 .../import_xcstrings_csv.py <xcstrings> <csv_file> <locale>`

- `reset_xcstrings_to_en.py`
  - Copy English values to specified locales (or all). Useful for seeding/fallbacks.
  - Usage: `python3 .../reset_xcstrings_to_en.py <xcstrings> [--locales es,fr]`

- `sync_xcstrings.py`
  - Ensure every locale has entries for every key; fill missing/empty with English.
  - Usage: `python3 .../sync_xcstrings.py <xcstrings>`

- `update_xcstrings_value.py`
  - Update a single key/locale value and mark it translated.
  - Usage: `python3 .../update_xcstrings_value.py <file> <key> <locale> <value>`

## Shell Helpers (Bash)

- `check-translations.sh`
  - Reports missing/empty translations for required locales (uses embedded Python).
  - Usage: `./bitchatUITests/Localization/Scripts/check-translations.sh`

- `test-sim-locale.sh`
  - Get/set simulator locale and run UITests on a chosen scheme/destination.
  - Usage:
    - Get: `./.../test-sim-locale.sh --get`
    - Set: `./.../test-sim-locale.sh --set --locale es_ES`
    - Test: `./.../test-sim-locale.sh --test [--scheme "bitchat (iOS)"] [--dest "platform=iOS Simulator,name=iPhone 15"]`

- `seed-missing-translations.sh`
  - Project-specific helper to seed obvious values; optional.

- `cleanup_localization_artifacts.sh`
  - Removes `localization_exports/` and stray CSV/temp files.

## Makefile Tasks

This folder includes a Makefile to simplify common workflows. Run `make help` here to see available targets.

Common targets
- `make help`: lists tasks and variables.
- `make audit`: runs `audit_xcstrings.py` on `XCSTR`.
- `make export [LOCALES=a,b] [OUT=dir]`: exports CSVs for locales (or all) to `OUT`.
- `make import CSV=path LOCALE=xx`: imports a locale CSV back into the catalog.
- `make sync`: fills missing/empty values with Base (en) while preserving translations.
- `make reset [LOCALES=a,b]`: copies English to the given locales (or all except en).
- `make update KEY=... LOCALE=.. VALUE=..`: updates one key/locale value.
- `make check-required`: runs the required-locales completeness checker.
- `make ui-test [SCHEME][DEST][UDID]`: runs iOS UI tests via `test-sim-locale.sh`.
- `make sim-get [UDID]`: prints the booted simulator locale.
- `make sim-set TAG=xx_XX [UDID]`: sets simulator locale.

Variables
- `XCSTR` (default: `bitchat/Localization/Localizable.xcstrings`)
- `OUT` (default: `localization_exports`)
- `LOCALES` (comma-separated, e.g. `es,fr`)
- `CSV` (path to exported CSV), `LOCALE` (e.g. `es`)
- `KEY`, `VALUE` for single-value updates
- `SCHEME` (default: `bitchat (iOS)`), `DEST` (default: `platform=iOS Simulator,name=iPhone 15,OS=latest`), `UDID`, `TAG`

Examples
- `make audit`
- `make export LOCALES=es,fr OUT=localization_exports`
- `make import CSV=localization_exports/es.csv LOCALE=es`
- `make sync`
- `make reset LOCALES=es,fr`
- `make update KEY=accessibility.add_favorite LOCALE=es VALUE="Añadir a favoritos"`
- `make check-required`
- `make ui-test SCHEME="bitchat (iOS)" DEST="platform=iOS Simulator,name=iPhone 15,OS=latest"`
- `make sim-get`
- `make sim-set TAG=es_ES`

## Tips

- Ensure you have Python 3: `python3 --version`.
- CSV import/export assumes simple UTF‑8 CSV with header `key,en,<locale>`.
- For automation, prefer the Python tools here (no extra dependencies) or the Makefile targets.
