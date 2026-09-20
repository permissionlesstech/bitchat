# `scripts/` — Python tooling for the GeoRelay data pipeline

This directory holds the Python scripts that validate, lint, and report on the
reviewed georelay CSV at `relays/online_relays_gps.csv`. None of these scripts
require Xcode; they run on any system with Python 3.9+ and are exercised by CI
on Ubuntu.

## Scripts

| Script | Purpose |
|---|---|
| [`validate_georelays.py`](validate_georelays.py) | Strict validator for candidate relay CSV updates. Enforces schema, coordinate ranges, hostname rules, and a baseline-overlap gate. Used by `.github/workflows/fetch_georelays.yml`. |
| [`relay_stats.py`](relay_stats.py) | Diagnostics: prints row/unique/duplicate counts and the top duplicated addresses for a CSV. |
| [`check_csv_health.py`](check_csv_health.py) | Regression guard: runs the validator against the shipped CSV to catch drift without the upstream fetch. |
| [`check_links.py`](check_links.py) | Lint: scans `.md` files for broken internal links. |
| [`generate-mac-appicon.swift`](generate-mac-appicon.swift) | Swift script for generating the macOS app icon set (requires Swift). |

## Tests

Tests live in [`tests/`](tests/) and are run with:

```bash
python3 -m unittest discover -s scripts/tests -p "test_*.py" -v
```

This is the same command the `fetch_georelays.yml` workflow runs in CI. The
discovery pattern `test_*.py` means every test module must start with `test_`.

## Justfile recipes

The `Justfile` at the repository root exposes:

```bash
just test-georelays     # run the Python test suite
just relay-stats        # print CSV statistics
just check-links        # lint internal markdown links
just check-csv-health   # validate the shipped CSV
```

## Conventions

- **Style**: `from __future__ import annotations`, type hints,
  `dataclass(frozen=True)` for value types, explicit `ValidationError`
  subclasses for user-facing failures.
- **Imports**: scripts that need the validator add their own directory to
  `sys.path` so they work whether invoked from the repository root or from
  inside `scripts/`.
- **Exit codes**: `0` on success, `1` on validation or I/O error. Scripts
  never raise unhandled exceptions on bad input.
- **No external dependencies**: the standard library only. This keeps CI
  fast and avoids supply-chain risk for a security-sensitive pipeline.
