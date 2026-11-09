#!/usr/bin/env python3
"""tools/index.py [ROOT]: write ROOT/INDEX.md from the ledger and the files on disk.

Every count on the page is read from the file named beside it. The page is written to INDEX.md.new and renamed
over INDEX.md. Run it from the corpus root after the ledger changes: `python3 tools/index.py`."""
import sys, os, json, csv
from collections import Counter, defaultdict

root = sys.argv[1] if len(sys.argv) > 1 else '.'
P = lambda *a: os.path.join(root, *a)
m = json.load(open(P('ledger/manifest.json'), encoding='utf-8'))
intent = json.load(open(P('ledger/intent.json'), encoding='utf-8'))
neg = list(csv.DictReader(open(P('ledger/negatives.tsv'), encoding='utf-8'), delimiter='\t'))
pairs = m['pairs']
cases = sorted(set(p['case'] for p in pairs))
folders = sorted(d for d in os.listdir(P('files')) if os.path.isdir(P('files', d)))
files = [os.path.join(d, f) for d in folders for f in sorted(os.listdir(P('files', d)))]
size = sum(os.path.getsize(P('files', f)) for f in files)
sources = sorted(f for f in os.listdir(P('sources')) if f.endswith('.vwx'))
state = Counter(p['state'] for p in pairs)

out = []
w = out.append
w('# Index')
w('')
w('`tools/index.py` writes this page from `ledger/manifest.json`, `ledger/intent.json`, `ledger/negatives.tsv` and')
w('the files under `files/` and `sources/`. README.md explains the layout and the terms.')
w('')
w('## Counts')
w('')
w('| Item | Count | Source |')
w('|---|---:|---|')
w(f'| Pairs | {len(pairs)} | `ledger/manifest.json` |')
w(f'| Pairs with a reference file | {state["artifact"]} | state `artifact` |')
w(f'| Pairs Vectorworks wrote nothing for | {state["negative"]} | state `negative` |')
w(f'| Cases in the manifest | {len(cases)} | |')
w(f'| Profiles | {len(set(p["profile"] for p in pairs))} | |')
w(f'| Case folders under `files/` | {len(folders)} | a listing of `files/` |')
w(f'| Files under `files/` | {len(files)}, {size / 1e6:.1f} MB | a walk of `files/` |')
w(f'| Source documents under `sources/` | {len(sources)} | a listing of `sources/` |')
w('')
w('## Pairs by format')
w('')
w('| Format | Pairs | With a file | Negative | Profiles |')
w('|---|---:|---:|---:|---|')
byf = defaultdict(list)
for p in pairs: byf[p['format']].append(p)
for f in sorted(byf, key=lambda k: (-len(byf[k]), k)):
    ps = byf[f]
    w(f'| {f} | {len(ps)} | {sum(p["state"] == "artifact" for p in ps)} | {sum(p["state"] == "negative" for p in ps)} | '
      + ', '.join(f'`{x}`' for x in sorted(set(p['profile'] for p in ps))) + ' |')
w('')
w('## Why a pair has no file')
w('')
w(f'`ledger/negatives.tsv` gives the evidence for each. Its {len(neg)} rows, by reason:')
w('')
w('| Reason | Rows |')
w('|---|---:|')
for r, n in Counter(x['status'] for x in neg).most_common():
    w(f'| {r} | {n} |')
w('')
w('## Cases')
w('')
w('Each case of the manifest, with the title of its recipe (`ledger/intent.json`) and its profiles: the ones with a')
w('file, and in brackets the ones Vectorworks wrote nothing for.')
w('')
w('| Case | Recipe title | Profiles |')
w('|---|---|---|')
byc = defaultdict(list)
for p in pairs: byc[p['case']].append(p)
for c in cases:
    title = ((intent['cases'].get(c) or {}).get('recipe') or {}).get('title', '').replace('|', '\\|')
    have = sorted(p['profile'] for p in byc[c] if p['state'] == 'artifact')
    none = sorted(p['profile'] for p in byc[c] if p['state'] == 'negative')
    w(f'| `{c}` | {title} | ' + ', '.join(have) + (f' ({", ".join(none)})' if none else '') + ' |')
w('')
extra = [d for d in folders if d not in set(cases)]
w(f'## Case folders outside the manifest ({len(extra)})')
w('')
w('Later cases, with files and a source document but no manifest pairs yet:')
w('')
w(', '.join(f'`{d}`' for d in extra))
w('')
tmp = P('INDEX.md.new')
with open(tmp, 'x', encoding='utf-8') as f: f.write('\n'.join(out))
os.replace(tmp, P('INDEX.md'))
print(f'INDEX.md: {len(pairs)} pairs, {len(cases)} cases, {len(folders)} case folders')
