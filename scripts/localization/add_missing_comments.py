#!/usr/bin/env python3
"""
add_missing_comments.py — Populate concise developer comments for .xcstrings entries.

What it does:
- Reads a String Catalog (.xcstrings, JSON format)
- For each string key without a top-level "comment", generates a short
  context comment based on the key namespace and English value.
- Writes back in-place, preserving existing comments and translations.

Notes:
- Comments are added at the entry level (shared across locales), which is how
  Xcode surfaces developer notes to translators.
- Plural/variation entries are supported; the English value is taken from
  the "en" localization when present, otherwise falls back to any available
  value.
"""

import json
import sys
from pathlib import Path
from typing import Dict, Any, Optional


def infer_category(prefix: str) -> str:
    """Map key prefixes to a concise category label used in comments."""
    mapping = {
        'accessibility': 'Screen reader label',
        'actions': 'Action label',
        'alert': 'Alert text',
        'app': 'App text',
        'common': 'Common label',
        'error': 'Error message',
        'location': 'Location feature text',
        'nav': 'Navigation title',
        'placeholder': 'Input placeholder',
        'security': 'Security status text',
        'ui': 'UI label',
    }
    return mapping.get(prefix, 'App text')


def extract_any_value(loc_entry: Dict[str, Any]) -> Optional[str]:
    """Extract a string value from a localization entry, including variations."""
    # Simple string
    su = loc_entry.get('stringUnit')
    if isinstance(su, dict):
        value = su.get('value')
        if isinstance(value, str) and value:
            return value
    # Variations (e.g., plural)
    variations = loc_entry.get('variations')
    if isinstance(variations, dict):
        # Try plural categories in a stable order
        for plural_key in (
            'one', 'other', 'two', 'few', 'many', 'zero'
        ):
            branch = variations.get('plural', {}).get(plural_key)
            if isinstance(branch, dict):
                su2 = branch.get('stringUnit')
                if isinstance(su2, dict):
                    value = su2.get('value')
                    if isinstance(value, str) and value:
                        return value
    return None


def english_value(entry: Dict[str, Any]) -> Optional[str]:
    """Return the English value if present, else any value for context."""
    locs = entry.get('localizations') or {}
    en = locs.get('en')
    if isinstance(en, dict):
        v = extract_any_value(en)
        if v:
            return v
    # Fallback: any locale with a value
    for loc in (locs or {}):
        v = extract_any_value(locs[loc])
        if v:
            return v
    return None


def generate_comment(key: str, value_hint: Optional[str]) -> str:
    """Create a concise developer comment for a given key/value."""
    # Determine category from prefix
    prefix = key.split('.', 1)[0] if '.' in key else key
    category = infer_category(prefix)

    # Identify possible subtype for alert titles/messages, etc.
    subtype = None
    lower_key = key.lower()
    if prefix == 'alert':
        if any(t in lower_key for t in ('.title', '_title', 'title_')):
            subtype = 'title'
        elif any(t in lower_key for t in ('.button', '_button', 'button_')):
            subtype = 'button'
        else:
            subtype = 'message'

    if prefix == 'accessibility':
        # Accessibility comments read better as "Screen reader ..."
        base = 'Screen reader'
        tail = 'announcement' if any(x in lower_key for x in ('count', 'status', 'updated', 'new_')) else 'label'
        if value_hint:
            return f"{base} {tail}: {value_hint}"
        return f"{base} {tail}"

    if subtype == 'title':
        if value_hint:
            return f"Alert title: {value_hint}"
        return "Alert title"
    if subtype == 'button':
        if value_hint:
            return f"Alert button: {value_hint}"
        return "Alert button"

    # For placeholders, keep it concise
    if prefix == 'placeholder':
        if value_hint:
            return f"Input placeholder: {value_hint}"
        return "Input placeholder"

    # For navigation items
    if prefix == 'nav':
        if value_hint:
            return f"Navigation title: {value_hint}"
        return "Navigation title"

    # For actions and common labels, prefer button label phrasing when verb-like
    if prefix in ('actions', 'common', 'ui', 'app', 'security', 'location', 'error'):
        if value_hint:
            # If it starts with a verb, call it a button/action label
            verby = value_hint.strip().split(' ')[0].lower()
            if verby in {'add', 'save', 'send', 'copy', 'block', 'open', 'show', 'cancel', 'ok', 'retry', 'share', 'delete', 'edit', 'view', 'enable', 'disable', 'join'}:
                return f"Button label: {value_hint}"
            return f"{category}: {value_hint}"
        return category

    # Default fallback
    if value_hint:
        return f"App text: {value_hint}"
    return "App text"


def main(path: str) -> int:
    p = Path(path)
    if not p.exists():
        print(f"❌ File not found: {p}", file=sys.stderr)
        return 2
    data = json.loads(p.read_text(encoding='utf-8'))
    strings = data.get('strings', {})

    updated = 0
    total = 0

    for key, entry in strings.items():
        total += 1
        if 'comment' in entry and isinstance(entry['comment'], str) and entry['comment'].strip():
            continue  # keep existing handcrafted comments
        val_hint = english_value(entry)
        comment = generate_comment(key, val_hint)
        entry['comment'] = comment
        updated += 1

    p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding='utf-8')
    print(f"✅ Added comments to {updated}/{total} keys in {p}")
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print('Usage: add_missing_comments.py <path-to-.xcstrings>', file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))

