Localization Scripts

Overview of common localization tasks with concise, consistent commands. All scripts are bash, produce clean output, and support --dry-run.

1) Simulator (all simulator-related commands)
- Script: `scripts/localization/simulator.sh`
- Usage:
  - `./scripts/localization/simulator.sh locale --lang fr --region FR --restart`
  - `./scripts/localization/simulator.sh locale --lang es --device <UDID> --launch com.bundle.id`
  - `./scripts/localization/simulator.sh locale --lang de --boot --restart --dry-run`
  - Just: `just set-locale --lang fr --region FR --restart`
- Notes: Auto-detects single booted device; `--boot` picks and boots an iPhone; `--launch` overrides app language without reboot.

2) Sync (all sync-related commands)
 - Script: `scripts/localization/sync.sh`
 - Usage: `./scripts/localization/sync.sh all [--dry-run]`
   - Just: `just sync-all --dry-run`
 - Does: Ensures parity for both `Localizable.xcstrings` and `Infoplist.xcstrings`, adds developer comments, marks non-English auto-filled entries as `needs_review`.

3) Pre-Commit Hook
- Script: `scripts/github/localization_pre_commit_hook.sh`
- Enable:
  - `cp scripts/github/localization_pre_commit_hook.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit`
- Does: Checks for hardcoded UI strings, validates xcstrings JSON/parity, ensures comments exist (auto-adds if missing).

4) Validate (all validation commands)
 - Script: `scripts/localization/validate.sh`
 - Usage: `./scripts/localization/validate.sh build [--dry-run]`
   - Just: `just validate-localization --dry-run`
 - Does: Hardcoded string scan + catalog integrity/parity/comments.

5) Seed (dev-only) — Removed
 - Seeding helpers were removed to keep the surface minimal.

6) Add (add missing comments/values)
 - Script: `scripts/localization/add.sh`
 - Usage: `./scripts/localization/add.sh comments|values [--dry-run]`
 - Does: Adds missing developer comments and/or fills missing values from English.

7) Report (coverage for all or a specific locale)
 - Script: `scripts/localization/report.sh`
 - Usage: `./scripts/localization/report.sh locales | locale <code>`
 - Just: `just locale-report` (all) or `just locale-report-code en` (one locale)


8) CSV Export/Import workflow
 - Export all locales to CSVs:
   - Script: `./scripts/localization/export.sh all [--locales all|en,es,...]`
   - Output: `scripts/localization/tmp/localizable/<locale>.csv` and `tmp/infoplist/<locale>.csv`
 - Import a translated CSV (per catalog/locale):
   - Script: `./scripts/localization/import.sh localizable <locale> [--file path] [--dry-run]`
   - Script: `./scripts/localization/import.sh infoplist  <locale> [--file path] [--dry-run]`
 - Conventions:
   - Column order: key,en,localized,comment,status
   - Plurals are encoded as separate rows with key suffix: `(<variant>)` e.g., `messages.count (plural:one)`
