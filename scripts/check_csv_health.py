#!/usr/bin/env python3
"""Validate the shipped georelay CSV against the project's own validator.

Reads ``relays/online_relays_gps.csv`` and runs ``validate_georelays.validate_bytes``
against it. This is the same check the ``fetch_georelays.yml`` workflow runs
against candidate data, applied here to the already-reviewed file as a
regression guard. If the shipped file ever drifts into a state the validator
rejects, this script catches it without needing the upstream fetch.

Exit codes:
    0 - the shipped CSV passes validation.
    1 - the shipped CSV is missing or fails validation.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))

import validate_georelays as validator  # noqa: E402

REPOSITORY_ROOT = _SCRIPT_DIR.parent
DEFAULT_CSV = REPOSITORY_ROOT / "relays" / "online_relays_gps.csv"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate the shipped georelay CSV against the project validator.",
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
        summary = validator.validate_bytes(data)
    except (OSError, validator.ValidationError) as error:
        print(f"check_csv_health: {error}", file=sys.stderr)
        return 1

    print(
        f"check_csv_health: {args.input} OK — "
        f"{summary.unique_relays} unique relays across {summary.data_rows} rows "
        f"(sha256 {summary.sha256})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
