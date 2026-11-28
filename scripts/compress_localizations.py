#!/usr/bin/env python3
"""Compress non-plural entries of Localizable.xcstrings into a raw-deflate blob.

Keeps Localizable.xcstrings as the single source of truth while avoiding 30
uncompressed binary-plist .lproj/Localizable.strings files (~1.48 MB) inside
the app bundle. Plural/substitution keys stay in LocalizablePlurals.xcstrings
so Apple's native CLDR .stringsdict engine handles pluralization for all
supported locales (~21 KB total).
"""

import argparse
import json
import os
import zlib


def is_plural_entry(entry: dict) -> bool:
    locs = entry.get("localizations", {})
    return any(
        isinstance(lv, dict) and ("variations" in lv or "substitutions" in lv)
        for lv in locs.values()
    )


def build_compressed_blob(catalog: dict) -> bytes:
    strings = catalog.get("strings", {})
    plain_keys = sorted(
        k for k, v in strings.items()
        if isinstance(v, dict) and not is_plural_entry(v)
    )

    locales = sorted({
        lang
        for k in plain_keys
        for lang in strings[k].get("localizations", {}).keys()
    })

    tables = {}
    for lang in locales:
        values = []
        for key in plain_keys:
            loc = strings[key].get("localizations", {}).get(lang)
            val = loc.get("stringUnit", {}).get("value") if isinstance(loc, dict) else None
            values.append(val if isinstance(val, str) else "")
        tables[lang] = values

    payload = json.dumps(
        {"k": plain_keys, "l": tables},
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")

    # RFC 1951 raw deflate — matches Foundation NSData.decompressed(using: .zlib).
    compressor = zlib.compressobj(level=9, method=zlib.DEFLATED, wbits=-15)
    return compressor.compress(payload) + compressor.flush()


def build_plurals_catalog(catalog: dict) -> dict:
    strings = catalog.get("strings", {})
    plural_strings = {
        k: strings[k]
        for k in sorted(strings.keys())
        if isinstance(strings[k], dict) and is_plural_entry(strings[k])
    }
    return {
        "sourceLanguage": catalog.get("sourceLanguage", "en"),
        "strings": plural_strings,
        "version": catalog.get("version", "1.0"),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, help="Path to Localizable.xcstrings")
    parser.add_argument("--zlib-out", help="Output path for Localizations.zlib")
    parser.add_argument("--plurals-out", help="Output path for LocalizablePlurals.xcstrings")
    args = parser.parse_args()

    with open(args.input, "r", encoding="utf-8") as f:
        catalog = json.load(f)

    if args.zlib_out:
        out_dir = os.path.dirname(os.path.abspath(args.zlib_out))
        os.makedirs(out_dir, exist_ok=True)
        blob = build_compressed_blob(catalog)
        with open(args.zlib_out, "wb") as f:
            f.write(blob)

    if args.plurals_out:
        out_dir = os.path.dirname(os.path.abspath(args.plurals_out))
        os.makedirs(out_dir, exist_ok=True)
        plurals = build_plurals_catalog(catalog)
        with open(args.plurals_out, "w", encoding="utf-8") as f:
            json.dump(plurals, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.write("\n")


if __name__ == "__main__":
    main()
