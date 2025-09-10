#!/usr/bin/env python3
"""
helper_export_csv.py — Export a .xcstrings catalog to per-locale CSV.

CSV format (no BOM, UTF-8):
key,en,localized,comment,status

Notes:
- Plural variants are exported as separate rows with key suffix:
  "<key> (plural:one)", "<key> (plural:other)", etc.
- "localized" contains the value for the target locale.
- "status" is the stringUnit.state for the target locale if present.
"""
import csv
import json
import sys
from pathlib import Path


PLURAL_CATS = ["zero","one","two","few","many","other"]


def get_en_entries(entry):
    locs = entry.get('localizations') or {}
    en = locs.get('en') or {}
    rows = []
    # Simple value
    en_su = (en.get('stringUnit') or {})
    if 'value' in en_su and en_su['value'] is not None:
        rows.append((None, en_su['value']))
    # Plurals
    plural = ((en.get('variations') or {}).get('plural') or {})
    for cat in PLURAL_CATS:
        br = plural.get(cat)
        if br:
            val = ((br.get('stringUnit') or {}).get('value'))
            if val is not None:
                rows.append((f"plural:{cat}", val))
    return rows


def localized_for(entry, locale, variant):
    locs = entry.get('localizations') or {}
    loc = locs.get(locale) or {}
    if variant is None:
        su = (loc.get('stringUnit') or {})
        return su.get('value'), su.get('state')
    # plural
    plural = ((loc.get('variations') or {}).get('plural') or {})
    br = plural.get(variant.split(':',1)[1]) if ':' in variant else None
    su = (br or {}).get('stringUnit') or {}
    return su.get('value'), su.get('state')


def export_catalog(xcstrings_path: Path, out_dir: Path, locale: str) -> int:
    data = json.loads(xcstrings_path.read_text(encoding='utf-8'))
    strings = data.get('strings', {})
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"{locale}.csv"
    rows = []
    for key, entry in strings.items():
        comment = entry.get('comment','')
        en_rows = get_en_entries(entry)
        for variant, en_val in en_rows:
            loc_val, state = localized_for(entry, locale, variant)
            display_key = key if variant is None else f"{key} ({variant})"
            rows.append([display_key, en_val or '', loc_val or '', comment or '', state or ''])

    with out_file.open('w', encoding='utf-8', newline='') as f:
        w = csv.writer(f)
        w.writerow(['key','en','localized','comment','status'])
        w.writerows(rows)
    print(f"✅ Exported {len(rows)} rows to {out_file}")
    return 0


def main(argv):
    if len(argv) != 3:
        print('Usage: helper_export_csv.py <path-to-.xcstrings> <locale>')
        return 2
    return export_catalog(Path(argv[1]), Path(argv[0]).parent.parent / 'tmp' / ('localizable' if argv[1].endswith('Localizable.xcstrings') else 'infoplist'), argv[2])


if __name__ == '__main__':
    # We don't actually use main signature above; keep explicit parse for clarity
    if len(sys.argv) != 3:
        print('Usage: helper_export_csv.py <path-to-.xcstrings> <locale>')
        raise SystemExit(2)
    p = Path(sys.argv[1])
    loc = sys.argv[2]
    # Determine output dir based on catalog name
    out_root = Path(__file__).resolve().parents[1] / 'tmp'
    if p.name.lower().startswith('localizable'):
        out_dir = out_root / 'localizable'
    else:
        out_dir = out_root / 'infoplist'
    raise SystemExit(export_catalog(p, out_dir, loc))

