#!/usr/bin/env python3
"""
helper_import_csv.py — Import per-locale CSV back into a .xcstrings catalog.

CSV format: key,en,localized,comment,status
- Plurals are encoded as key suffix " (<variant>)" where variant is like "plural:one".
"""
import csv
import json
import sys
from pathlib import Path

def set_value(entry, locale, key, variant, value, status):
    loc = entry.setdefault('localizations', {}).setdefault(locale, {})
    if variant is None:
        su = loc.setdefault('stringUnit', {})
        su['value'] = value
        su['state'] = status or 'translated'
        return True
    # plural variant
    var = loc.setdefault('variations', {})
    plural = var.setdefault('plural', {})
    br = plural.setdefault(variant.split(':',1)[1], {})
    su = br.setdefault('stringUnit', {})
    su['value'] = value
    su['state'] = status or 'translated'
    return True

def parse_key(k):
    if k.endswith(')') and ' (' in k:
        base, suf = k.rsplit(' (',1)
        suf = suf[:-1]
        return base, suf
    return k, None

def import_csv(cat_path: Path, csv_path: Path, locale: str, dry: bool=False, force_status: str=None) -> int:
    data = json.loads(cat_path.read_text(encoding='utf-8'))
    strings = data.get('strings', {})
    applied = 0
    with csv_path.open('r', encoding='utf-8') as f:
        r = csv.DictReader(f)
        for row in r:
            key = row.get('key')
            loc_val = row.get('localized')
            status = (row.get('status') or '').strip() or 'translated'
            if force_status:
                status = force_status
            if key is None or loc_val is None:
                continue
            base, variant = parse_key(key)
            entry = strings.get(base)
            if not entry:
                # Unknown key; skip
                continue
            # Skip empty translations to avoid erasing
            if loc_val == '':
                continue
            set_value(entry, locale, base, variant, loc_val, status)
            applied += 1
    if not dry:
        cat_path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding='utf-8')
    print(f"{'[DRY-RUN] ' if dry else ''}✅ Applied {applied} updates from {csv_path} into {cat_path}")
    return 0

if __name__ == '__main__':
    if len(sys.argv) < 4:
        print('Usage: helper_import_csv.py <path-to-.xcstrings> <locale> <csv-file> [--dry-run] [--force-status needs_review|translated]')
        raise SystemExit(2)
    p = Path(sys.argv[1]); loc=sys.argv[2]; csvf=Path(sys.argv[3])
    dry = '--dry-run' in sys.argv or '--check' in sys.argv
    force = None
    if '--force-status' in sys.argv:
        idx = sys.argv.index('--force-status')
        if idx+1 < len(sys.argv):
            force = sys.argv[idx+1]
    raise SystemExit(import_csv(p, csvf, loc, dry, force))
