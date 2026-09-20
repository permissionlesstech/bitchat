#!/usr/bin/env python3
"""Strict validator for the reviewed georelay CSV update workflow."""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import math
import re
from dataclasses import dataclass
from pathlib import Path
import sys
import unicodedata
from urllib.parse import urlsplit


MAX_BYTES = 512 * 1024
MAX_ROWS = 5_000
MAX_UNIQUE_RELAYS = 5_000
MIN_UNIQUE_RELAYS = 50
MIN_BASELINE_FRACTION = 0.5
MAX_BASELINE_MULTIPLIER = 2.0
EXPECTED_HEADER = ("relay url", "latitude", "longitude")
ASCII_DECIMAL_PATTERN = re.compile(
    r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\Z"
)


class ValidationError(ValueError):
    pass


@dataclass(frozen=True)
class ValidationSummary:
    data_rows: int
    unique_relays: int
    sha256: str


@dataclass(frozen=True)
class _ValidatedDataset:
    summary: ValidationSummary
    entries: frozenset[tuple[str, float, float]]
    # Original header line, preserved verbatim so deduplicated output can reuse
    # the reviewed casing instead of inventing its own.
    header_line: str
    # First-seen (address, latitude_text, longitude_text) per unique relay, in
    # insertion order. Coordinate text is preserved verbatim so deduplication
    # does not silently rewrite reviewed ASCII-decimal formatting.
    ordered_rows: tuple[tuple[str, str, str], ...]


def _has_disallowed_control(value: str) -> bool:
    return any(
        unicodedata.category(character) in {"Cc", "Cf"}
        and character not in {"\r", "\n", "\t"}
        for character in value
    )


def normalize_relay_address(raw_value: str) -> str:
    value = raw_value.strip()
    if not value or _has_disallowed_control(value):
        raise ValidationError("relay address is empty or contains control characters")
    # urlsplit cannot distinguish an absent query/fragment from an explicitly
    # empty one. Reject the delimiters themselves so this validator matches
    # URLComponents in the client and reviewed data cannot fail closed there.
    if "?" in value or "#" in value:
        raise ValidationError(f"relay query or fragment is not allowed: {value}")

    candidate = value if "://" in value else f"wss://{value}"
    try:
        parsed = urlsplit(candidate)
        port = parsed.port
    except ValueError as error:
        raise ValidationError(f"invalid relay URL: {value}") from error

    if parsed.scheme.lower() not in {"wss", "https"}:
        raise ValidationError(f"relay must use wss/https or a bare hostname: {value}")
    if parsed.username is not None or parsed.password is not None:
        raise ValidationError(f"relay credentials are not allowed: {value}")
    if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise ValidationError(f"relay path, query, or fragment is not allowed: {value}")

    host = (parsed.hostname or "").lower()
    if not host or len(host) > 253 or not host.isascii():
        raise ValidationError(f"relay hostname is missing or non-ASCII: {value}")
    if host.endswith(".") or host == "localhost" or host.endswith((".localhost", ".local", ".internal")):
        raise ValidationError(f"local or absolute relay hostname is not allowed: {value}")

    labels = host.split(".")
    if len(labels) < 2 or all(label.isdigit() for label in labels):
        raise ValidationError(f"relay must use a public DNS hostname: {value}")
    for label in labels:
        if not 1 <= len(label) <= 63:
            raise ValidationError(f"invalid DNS label length: {value}")
        if label[0] == "-" or label[-1] == "-":
            raise ValidationError(f"DNS labels cannot start or end with '-': {value}")
        if any(character not in "abcdefghijklmnopqrstuvwxyz0123456789-" for character in label):
            raise ValidationError(f"invalid DNS hostname character: {value}")

    if port is not None and not 1 <= port <= 65_535:
        raise ValidationError(f"invalid relay port: {value}")
    if port in {None, 443}:
        return host
    return f"{host}:{port}"


def _validated_dataset(
    data: bytes,
    *,
    minimum_unique_relays: int = MIN_UNIQUE_RELAYS,
    maximum_bytes: int = MAX_BYTES,
    maximum_rows: int = MAX_ROWS,
    maximum_unique_relays: int = MAX_UNIQUE_RELAYS,
) -> _ValidatedDataset:
    if not data or len(data) > maximum_bytes:
        raise ValidationError(f"CSV must contain 1..{maximum_bytes} bytes")

    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValidationError("CSV is not valid UTF-8") from error
    if text.startswith("\ufeff"):
        raise ValidationError("UTF-8 BOM is not allowed")
    if _has_disallowed_control(text):
        raise ValidationError("CSV contains disallowed control characters")
    # Runtime intentionally implements the fixed three-field schema without
    # general CSV quoting. Reject quoted variants here so reviewed workflow
    # output and client-side validation cannot disagree.
    if '"' in text:
        raise ValidationError("quoted CSV fields are not allowed")

    reader = csv.reader(io.StringIO(text, newline=""), strict=True)
    try:
        header = next(reader)
    except (StopIteration, csv.Error) as error:
        raise ValidationError("CSV header is missing") from error
    normalized_header = tuple(field.strip().lower() for field in header)
    if normalized_header != EXPECTED_HEADER:
        raise ValidationError(f"unexpected CSV header: {header!r}")

    data_rows = 0
    relays: dict[str, tuple[float, float]] = {}
    row_text: dict[str, tuple[str, str]] = {}
    try:
        for row in reader:
            if not row or all(not field.strip() for field in row):
                continue
            data_rows += 1
            if data_rows > maximum_rows:
                raise ValidationError(f"CSV exceeds {maximum_rows} data rows")
            if len(row) != 3:
                raise ValidationError(f"row {reader.line_num} must contain exactly 3 columns")

            address = normalize_relay_address(row[0])
            latitude_text = row[1].strip()
            longitude_text = row[2].strip()
            if not ASCII_DECIMAL_PATTERN.fullmatch(latitude_text) or not ASCII_DECIMAL_PATTERN.fullmatch(longitude_text):
                raise ValidationError(
                    f"row {reader.line_num} coordinates must be ASCII decimal numbers"
                )
            latitude = float(latitude_text)
            longitude = float(longitude_text)
            if not math.isfinite(latitude) or not -90 <= latitude <= 90:
                raise ValidationError(f"row {reader.line_num} latitude is out of range")
            if not math.isfinite(longitude) or not -180 <= longitude <= 180:
                raise ValidationError(f"row {reader.line_num} longitude is out of range")

            coordinates = (latitude, longitude)
            previous = relays.get(address)
            if previous is not None and previous != coordinates:
                raise ValidationError(f"relay {address} has conflicting coordinates")
            relays[address] = coordinates
            # Keep the first-seen coordinate text for each relay so a later
            # duplicate (same address, same coordinates) cannot rewrite the
            # reviewed formatting of the row that was already accepted.
            if address not in row_text:
                row_text[address] = (latitude_text, longitude_text)
            if len(relays) > maximum_unique_relays:
                raise ValidationError(f"CSV exceeds {maximum_unique_relays} unique relays")
    except csv.Error as error:
        raise ValidationError(f"malformed CSV near line {reader.line_num}") from error

    if len(relays) < minimum_unique_relays:
        raise ValidationError(
            f"CSV has {len(relays)} unique relays; minimum is {minimum_unique_relays}"
        )

    return _ValidatedDataset(
        summary=ValidationSummary(
            data_rows=data_rows,
            unique_relays=len(relays),
            sha256=hashlib.sha256(data).hexdigest(),
        ),
        entries=frozenset(
            (address, coordinates[0], coordinates[1])
            for address, coordinates in relays.items()
        ),
        header_line=",".join(header),
        ordered_rows=tuple(
            (address, texts[0], texts[1]) for address, texts in row_text.items()
        ),
    )


def validate_bytes(
    data: bytes,
    *,
    minimum_unique_relays: int = MIN_UNIQUE_RELAYS,
    maximum_bytes: int = MAX_BYTES,
    maximum_rows: int = MAX_ROWS,
    maximum_unique_relays: int = MAX_UNIQUE_RELAYS,
) -> ValidationSummary:
    return _validated_dataset(
        data,
        minimum_unique_relays=minimum_unique_relays,
        maximum_bytes=maximum_bytes,
        maximum_rows=maximum_rows,
        maximum_unique_relays=maximum_unique_relays,
    ).summary


def validate_update(candidate: bytes, baseline: bytes) -> ValidationSummary:
    baseline_dataset = _validated_dataset(baseline, minimum_unique_relays=1)
    candidate_dataset = _validated_dataset(candidate)
    baseline_summary = baseline_dataset.summary
    candidate_summary = candidate_dataset.summary

    minimum_from_baseline = math.ceil(
        baseline_summary.unique_relays * MIN_BASELINE_FRACTION
    )
    maximum_from_baseline = math.floor(
        baseline_summary.unique_relays * MAX_BASELINE_MULTIPLIER
    )
    if candidate_summary.unique_relays < minimum_from_baseline:
        raise ValidationError(
            "candidate loses more than half of the baseline's unique relays "
            f"({candidate_summary.unique_relays} < {minimum_from_baseline})"
        )
    if candidate_summary.unique_relays > maximum_from_baseline:
        raise ValidationError(
            "candidate more than doubles the baseline's unique relays "
            f"({candidate_summary.unique_relays} > {maximum_from_baseline})"
        )

    retained_entries = len(baseline_dataset.entries & candidate_dataset.entries)
    if retained_entries < minimum_from_baseline:
        raise ValidationError(
            "candidate retains fewer than half of the baseline's exact relay-coordinate entries "
            f"({retained_entries} < {minimum_from_baseline})"
        )
    return candidate_summary


@dataclass(frozen=True)
class DeduplicateResult:
    summary: ValidationSummary
    output: bytes


def deduplicate_bytes(
    data: bytes,
    *,
    minimum_unique_relays: int = MIN_UNIQUE_RELAYS,
    maximum_bytes: int = MAX_BYTES,
    maximum_rows: int = MAX_ROWS,
    maximum_unique_relays: int = MAX_UNIQUE_RELAYS,
) -> DeduplicateResult:
    """Validate ``data`` and return a normalized, duplicate-free CSV.

    The returned ``output`` uses the fixed three-field schema with the original
    header line, one row per unique normalized relay address, sorted ascending
    by address. Original coordinate text is preserved verbatim so reviewed
    ASCII-decimal formatting (e.g. ``01``, ``2E+1``, ``20.``) is not rewritten.

    The same validation rules as :func:`validate_bytes` apply, including the
    rejection of conflicting coordinates for the same relay. The returned
    ``summary`` describes the *output*: ``data_rows`` equals
    ``unique_relays`` (one row per relay) and ``sha256`` is the SHA-256 of the
    deduplicated bytes, so callers that persist ``output`` can trace it back to
    the summary they emit.
    """
    dataset = _validated_dataset(
        data,
        minimum_unique_relays=minimum_unique_relays,
        maximum_bytes=maximum_bytes,
        maximum_rows=maximum_rows,
        maximum_unique_relays=maximum_unique_relays,
    )
    sorted_rows = sorted(dataset.ordered_rows, key=lambda row: row[0])
    lines = [dataset.header_line]
    lines.extend(f"{address},{lat},{lon}" for address, lat, lon in sorted_rows)
    # A trailing newline matches the reviewed file shape and keeps the file
    # diff-stable when re-run. ``\n`` only: the validator rejects ``\r``.
    output = ("\n".join(lines) + "\n").encode("utf-8")
    return DeduplicateResult(
        summary=ValidationSummary(
            data_rows=len(sorted_rows),
            unique_relays=len(sorted_rows),
            sha256=hashlib.sha256(output).hexdigest(),
        ),
        output=output,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--github-output", type=Path)
    parser.add_argument(
        "--deduplicate",
        action="store_true",
        help=(
            "write one row per unique normalized relay address, sorted by "
            "address, instead of the raw candidate bytes"
        ),
    )
    args = parser.parse_args(argv)

    try:
        candidate = args.input.read_bytes()
        baseline = args.baseline.read_bytes()
        # The baseline overlap gate runs on the raw candidate so deduplication
        # cannot widen or narrow the set of relays it is compared against.
        validate_update(candidate, baseline)
        if args.deduplicate:
            result = deduplicate_bytes(candidate)
            output_bytes = result.output
            summary = result.summary
        else:
            output_bytes = candidate
            summary = validate_bytes(candidate)
        args.output.write_bytes(output_bytes)
        if args.github_output is not None:
            with args.github_output.open("a", encoding="utf-8") as output:
                output.write(f"data_rows={summary.data_rows}\n")
                output.write(f"unique_relays={summary.unique_relays}\n")
                output.write(f"sha256={summary.sha256}\n")
    except (OSError, ValidationError) as error:
        print(f"georelay validation failed: {error}", file=sys.stderr)
        return 1

    print(
        f"validated {summary.unique_relays} unique relays across "
        f"{summary.data_rows} rows (sha256 {summary.sha256})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
