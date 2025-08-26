#!/usr/bin/env python3
"""
sync_xcstrings.py — Ensure every locale has all keys in a .xcstrings catalog.

For any missing locale entries, this script copies the Base (en) value and
marks the unit as translated. Existing translations are preserved.

Usage:
  python3 scripts/sync_xcstrings.py bitchat/Localization/Localizable.xcstrings
"""
import json
import sys
from pathlib import Path

def main(path: str) -> int:
    p = Path(path)
    if not p.exists():
        print(f"❌ File not found: {p}", file=sys.stderr)
        return 2

    data = json.loads(p.read_text())
    strings = data.get("strings", {})

    # Gather the union of locales present anywhere in the catalog
    all_locales = set()
    for entry in strings.values():
        all_locales.update(entry.get("localizations", {}).keys())

    if "en" not in all_locales:
        # Ensure we include Base language even if no key explicitly listed it yet
        all_locales.add("en")

    added = 0
    touched_keys = 0
    for key, entry in strings.items():
        locs = entry.setdefault("localizations", {})
        base = locs.get("en", {}).get("stringUnit", {}).get("value")
        if not base:
            # If the base value is missing or empty, skip filling for this key
            continue
        before = len(locs)
        for loc in all_locales:
            if loc in locs:
                # Ensure it has a stringUnit/value shape, otherwise skip
                # (we don't handle variations here)
                if "stringUnit" not in locs[loc]:
                    continue
                if "value" not in locs[loc]["stringUnit"] or locs[loc]["stringUnit"]["value"] is None:
                    locs[loc]["stringUnit"]["value"] = base
                    locs[loc]["stringUnit"]["state"] = "translated"
                    added += 1
                continue
            # Add missing locale using base value
            locs[loc] = {
                "stringUnit": {"state": "translated", "value": base}
            }
            added += 1
        if len(locs) != before:
            touched_keys += 1

    if added:
        # Write back with stable formatting
        p.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=False) + "\n")
        print(f"✅ Filled {added} missing entries across {touched_keys} keys.")
    else:
        print("✅ No missing entries detected.")
    return 0

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: sync_xcstrings.py <path-to-.xcstrings>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))

