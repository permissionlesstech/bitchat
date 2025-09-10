Localization Scripts

Overview of common localization tasks with concise, consistent commands. All scripts are bash, produce clean output, and support --dry-run.

1) Set Simulator Locale
- Script: `scripts/localization/simulator_set_locale.sh`
- Usage:
  - `./scripts/localization/simulator_set_locale.sh --lang fr --region FR --restart`
  - `./scripts/localization/simulator_set_locale.sh --lang es --device <UDID> --launch com.bundle.id`
  - `./scripts/localization/simulator_set_locale.sh --lang de --boot --restart --dry-run`
  - Just: `just set-locale --lang fr --region FR --restart`
- Notes: Auto-detects single booted device; `--boot` picks and boots an iPhone; `--launch` overrides app language without reboot.

2) Sync All Localizations (UI + InfoPlist)
 - Script: `scripts/localization/sync_all_localizations.sh`
 - Usage: `./scripts/localization/sync_all_localizations.sh [--dry-run]`
   - Just: `just sync-all --dry-run`
- Does: Ensures parity for both `Localizable.xcstrings` and `Infoplist.xcstrings`, adds developer comments, marks non-English auto-filled entries as `needs_review`.

3) Pre-Commit Hook
- Script: `scripts/github/localization_pre_commit_hook.sh`
- Enable:
  - `cp scripts/github/localization_pre_commit_hook.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit`
- Does: Checks for hardcoded UI strings, validates xcstrings JSON/parity, ensures comments exist (auto-adds if missing).

4) Sync Comments Only
 - Script: `scripts/localization/sync_comments.sh`
 - Usage: `./scripts/localization/sync_comments.sh [--dry-run]`
   - Just: `just sync-comments --dry-run`
- Does: Adds concise developer comments to both catalogs without touching values.

5) Locale Report
 - Script: `scripts/localization/locale_report.sh`
 - Usage: `./scripts/localization/locale_report.sh`
   - Just: `just locale-report`
- Does: Reports total keys, languages, per-language coverage, and keys missing in any locale.

6) Validate Localization Build
 - Script: `scripts/localization/validate_localization_build.sh`
 - Usage: `./scripts/localization/validate_localization_build.sh [--dry-run]`
   - Just: `just validate-localization --dry-run`
- Does: Detects hardcoded UI strings, validates String Catalog integrity, language parity, and presence of comments.

7) (Optional) Developer Helpers
- Internal tools like `add_missing_comments.py` and `sync_xcstrings.py` power the sync scripts.
- For advanced seeding tasks during development, see tools in `scripts/localization/tools/`.
- Does: Syncs `Localizable.xcstrings` and adds developer comments (UI strings only).
