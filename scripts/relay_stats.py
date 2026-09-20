#!/usr/bin/env python3
"""Print summary statistics for the reviewed georelay CSV.

Reads ``relays/online_relays_gps.csv`` (or a path given on the command line)
and prints human-readable counts: total rows, unique normalized relays,
duplicate rows, and the SHA-256 of the file. This is a diagnostics tool for
contributors and does not gate CI.

Exit codes:
    0 - the file was read and stats were printed.
    1 - the file could not be read or failed validation.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Allow running both as ``python3 scripts/relay_stats.py`` (repository root is
# cwd) and as ``python3 relay_stats.py`` from inside ``scripts/``.
_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))

import validate_georelays as validator  # noqa: E402

REPOSITORY_ROOT = _SCRIPT_DIR.parent
DEFAULT_CSV = REPOSITORY_ROOT / "relays" / "online_relays_gps.csv"


def collect_stats(data: bytes) -> dict[str, object]:
    """Return a dict of stats for the given CSV bytes.

    Keys: ``data_rows``, ``unique_relays``, ``duplicate_rows``, ``sha256``,
    ``sample_duplicates`` (up to 5 normalized addresses that appeared more
    than once). Raises ``validator.ValidationError`` if the bytes are not a
    valid georelay CSV.
    """
    import csv
    import hashlib
    import io

    summary = validator.validate_bytes(data, minimum_unique_relays=1)
    # Re-parse to count duplicates without re-running the full validator.
    text = data.decode("utf-8")
    reader = csv.reader(io.StringIO(text, newline=""), strict=True)
    next(reader)  # header
    seen: dict[str, int] = {}
    for row in reader:
        if not row or all(not f.strip() for f in row):
            continue
        address = validator.normalize_relay_address(row[0])
        seen[address] = seen.get(address, 0) + 1
    duplicates = {addr: count for addr, count in seen.items() if count > 1}
    sample = sorted(duplicates.items(), key=lambda item: (-item[1], item[0]))[:5]
    return {
        "data_rows": summary.data_rows,
        "unique_relays": summary.unique_relays,
        "duplicate_rows": summary.data_rows - summary.unique_relays,
        "sha256": summary.sha256,
        "sample_duplicates": sample,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Print summary statistics for a georelay CSV.",
    )
    parser.add_argument(
        "--input",
        type=Path,
        default=DEFAULT_CSV,
        help=f"path to the CSV (default: {DEFAULT_CSV})",
    )
    args = parser.parse_args(argv)

    try:
        data = args.input.read_bytes()
        stats = collect_stats(data)
    except (OSError, validator.ValidationError) as error:
        print(f"relay_stats: {error}", file=sys.stderr)
        return 1

    print(f"file: {args.input}")
    print(f"data rows: {stats['data_rows']}")
    print(f"unique relays: {stats['unique_relays']}")
    print(f"duplicate rows: {stats['duplicate_rows']}")
    print(f"sha256: {stats['sha256']}")
    if stats["sample_duplicates"]:
        print("sample duplicates (address: count):")
        for address, count in stats["sample_duplicates"]:
            print(f"  {address}: {count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
