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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args(argv)

    try:
        candidate = args.input.read_bytes()
        baseline = args.baseline.read_bytes()
        summary = validate_update(candidate, baseline)
        args.output.write_bytes(candidate)
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
