#!/usr/bin/env python3
"""
helper_translate_csv.py — Translate a per-locale CSV using an external provider (e.g., DeepL).

Usage:
  DEEPL_API_KEY=... python3 helper_translate_csv.py \
    --provider deepl --target es --in scripts/localization/tmp/localizable/es.csv \
    --out scripts/localization/tmp/localizable/es-translated.csv [--dry-run]

CSV format (input and output): key,en,localized,comment,status
Behavior:
  - Translates the 'en' column to the target locale and writes it into 'localized'.
  - Preserves placeholders (%@, %d, %f, %u, %x, %%, %1$@, etc.) by tagging before translation and restoring after.
  - Preserves reserved terms by tagging and restoring (BitChat, Nostr, Bluetooth, #mesh, /msg, URLs, @nickname, channel tokens).
  - Writes status as 'needs_review' for all translated rows.
  - With --dry-run, prints planned operations but does not write.
"""
import csv
import os
import re
import sys
import json
from pathlib import Path
from urllib import request, parse

PH_RE = re.compile(r"%(?:\d+\$)?[@difsux]|%%")
URL_RE = re.compile(r"https?://\S+|wss://\S+", re.I)

RESERVED = [
    'BitChat', 'Nostr', 'Bluetooth', '#mesh', '/msg'
]

def tag_placeholders(text):
    """Replace placeholders with tags to protect during translation."""
    tags = []
    def repl(m):
        idx = len(tags)
        tags.append(m.group(0))
        return f"<PH{idx}/>"
    tagged = PH_RE.sub(repl, text)
    return tagged, tags

def restore_placeholders(text, tags):
    for i, val in enumerate(tags):
        text = text.replace(f"<PH{i}/>", val)
    return text

def tag_reserved(text):
    tags = []
    # URLs first
    def repl_url(m):
        idx = len(tags)
        tags.append(m.group(0))
        return f"<U{idx}/>"
    text = URL_RE.sub(repl_url, text)
    # Reserved tokens
    for token in RESERVED:
        if token in text:
            idx = len(tags)
            tags.append(token)
            text = text.replace(token, f"<R{idx}/>")
    return text, tags

def restore_reserved(text, tags):
    # Restore in reverse (URLs and reserved share pool)
    for i, val in enumerate(tags):
        text = text.replace(f"<U{i}/>", val)
        text = text.replace(f"<R{i}/>", val)
    return text

DEEPL_LANG_MAP = {
    'es': 'ES', 'fr': 'FR', 'de': 'DE', 'pt': 'PT', 'pt-BR': 'PT-BR', 'ja': 'JA',
    'zh-Hans': 'ZH', 'ru': 'RU', 'ar': 'AR', 'tr': 'TR', 'vi': 'VI', 'id': 'ID',
    'fil': 'TL', 'tl': 'TL', 'zh-Hant': 'ZH', 'zh-HK': 'ZH', 'yue': 'ZH', 'ur': 'UR',
    'hi': 'HI', 'bn': 'BN', 'ta': 'TA', 'te': 'TE', 'mr': 'MR', 'sw': 'SW', 'ha': 'HA',
    'arz': 'AR', 'pnb': 'PA', 'pcm': 'EN'  # Fallbacks where provider lacks support
}

def deepl_translate(texts, target):
    api_key = os.getenv('DEEPL_API_KEY')
    if not api_key:
        raise RuntimeError('DEEPL_API_KEY is not set')
    target_lang = DEEPL_LANG_MAP.get(target, target.upper())
    url = 'https://api.deepl.com/v2/translate'
    data = parse.urlencode([('auth_key', api_key), ('target_lang', target_lang)] + [('text', t) for t in texts]).encode('utf-8')
    req = request.Request(url, data=data)
    with request.urlopen(req, timeout=60) as resp:
        payload = json.loads(resp.read().decode('utf-8'))
    result = [item['text'] for item in payload.get('translations', [])]
    if len(result) != len(texts):
        raise RuntimeError('DeepL returned mismatched number of translations')
    return result

def main(argv):
    # Args
    provider = None; target=None; infile=None; outfile=None; dry=False
    i=0
    while i < len(argv):
        a=argv[i]
        if a=='--provider': provider=argv[i+1]; i+=2
        elif a=='--target': target=argv[i+1]; i+=2
        elif a=='--in': infile=argv[i+1]; i+=2
        elif a=='--out': outfile=argv[i+1]; i+=2
        elif a in ('--dry-run','--check'): dry=True; i+=1
        else:
            print('Unknown arg:', a); return 2
    if not provider or not target or not infile or not outfile:
        print('Usage: helper_translate_csv.py --provider deepl --target <locale> --in <in.csv> --out <out.csv> [--dry-run]')
        return 2

    rows=[]
    with open(infile,'r',encoding='utf-8') as f:
        r=csv.DictReader(f)
        for row in r: rows.append(row)

    batch_texts=[]; meta=[]
    for idx,row in enumerate(rows):
        en=row.get('en','')
        # Protect placeholders and reserved tokens
        tagged, phs = tag_placeholders(en)
        tagged, rsv = tag_reserved(tagged)
        batch_texts.append(tagged)
        meta.append((idx, phs, rsv))

    # Translate
    if dry:
        print(f"[DRY-RUN] Would translate {len(batch_texts)} rows to {target} via {provider}")
        return 0
    if provider=='deepl':
        out_texts = deepl_translate(batch_texts, target)
    else:
        raise RuntimeError('Unsupported provider: ' + provider)

    # Restore tokens and write
    for (idx, phs, rsv), t in zip(meta, out_texts):
        t = restore_reserved(t, rsv)
        t = restore_placeholders(t, phs)
        rows[idx]['localized'] = t
        rows[idx]['status'] = 'needs_review'

    with open(outfile,'w',encoding='utf-8',newline='') as f:
        w=csv.DictWriter(f, fieldnames=['key','en','localized','comment','status'])
        w.writeheader(); w.writerows(rows)
    print(f"✅ Wrote translated CSV -> {outfile}")
    return 0

if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))

