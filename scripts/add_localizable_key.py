#!/usr/bin/env python3
"""Add localization keys to Localizable.xcstrings with en + needs_review placeholders."""

from __future__ import annotations

import json
import sys
from pathlib import Path

LOCALES = [
    "ar", "bn", "de", "en", "es", "fa", "fil", "fr", "he", "hi", "id", "it",
    "ja", "ko", "ms", "ne", "nl", "pl", "pt", "pt-BR", "ru", "sv", "ta", "th",
    "tr", "uk", "ur", "vi", "zh-Hans", "zh-Hant",
]

XCSTRINGS = Path(__file__).resolve().parents[1] / "bitchat" / "Localizable.xcstrings"


def add_key(key: str, en_value: str, comment: str) -> None:
    with XCSTRINGS.open(encoding="utf-8") as f:
        data = json.load(f)

    if key in data["strings"]:
        print(f"skip existing: {key}", file=sys.stderr)
        return

    localizations = {}
    for locale in LOCALES:
        state = "translated" if locale == "en" else "needs_review"
        localizations[locale] = {"stringUnit": {"state": state, "value": en_value}}

    data["strings"][key] = {
        "comment": comment,
        "extractionState": "manual",
        "localizations": localizations,
    }

    with XCSTRINGS.open("w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"added: {key}")


def main() -> None:
    if len(sys.argv) < 3:
        print("usage: add_localizable_key.py <key> <en_value> [comment]", file=sys.stderr)
        sys.exit(1)
    add_key(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")


if __name__ == "__main__":
    main()
