#!/usr/bin/env python3
"""tools/structure.py [ROOT]: write ROOT/STRUCTURE.md, the corpus explained by its structure.

Reads only files in this repository:
- ledger/intent.json: the objects and calls of each case;
- ledger/nodetypes.tsv: the node types of each source document, as a `.vwx` decoder reports them; the file ships
  with Rosetta;
- ledger/prevalence.tsv: per node type, in how many of a set of real Vectorworks documents it occurs and its share of
  their nodes. The documents themselves are private; only these totals are published.
The reading layers are our proposal; every other figure is derived from those files. The page is written to
STRUCTURE.md.new and renamed over STRUCTURE.md."""
import sys, os, json, csv, collections

root = sys.argv[1] if len(sys.argv) > 1 else '.'
P = lambda *a: os.path.join(root, *a)
intent = json.load(open(P('ledger/intent.json'), encoding='utf-8'))['cases']
def parse(s): return {int(a): int(b) for a, b in (x.split(':') for x in s.split())} if s.strip() else {}
nt = {r['case']: parse(r['node_types']) for r in csv.DictReader(open(P('ledger/nodetypes.tsv')), delimiter='\t')}
prev = {int(r['node_type']): r for r in csv.DictReader(open(P('ledger/prevalence.tsv')), delimiter='\t')}
ndocs = int(next(iter(prev.values()))['of_documents']) if prev else 0
blank = nt['control.blank.mm']
added = {c: {t: n - blank.get(t, 0) for t, n in v.items() if n > blank.get(t, 0)} for c, v in nt.items()}

LAYERS = [  # our proposal: the reading order, families per layer
    ('1 document and containers', ('document', 'container', 'control')),
    ('2 basic geometry', ('planar', 'solid', 'nurbs', 'spatial', 'extrude')),
    ('3 annotation and resources', ('annotation', 'resource', 'option')),
    ('4 parametric objects', ('building', 'landscape', 'entertainment')),
    ('5 plug-ins', ('plugin',)),
    ('pairwise interactions', ('ix',)),
]

def objects(c):
    return [o for o in intent.get(c, {}).get('objects', [])]

def kind(c):
    if c.split('.')[0] == 'plugin': return 'plug-in'
    return 'plug-in' if any(o.get('type') == 'plug-in object' for o in objects(c)) else 'native'

def comes_with():
    """Per node type: among the native cases that create one kind of object, the most common kind in the cases that
    add the type, with its ratio; 'shared' when no kind holds half."""
    by = collections.defaultdict(collections.Counter)
    for c, d in added.items():
        kinds = {o.get('type') for o in objects(c)}
        if len(kinds) != 1 or kinds == {'plug-in object'}: continue
        k = next(iter(kinds))
        for t in d: by[t][k] += 1
    out = {}
    for t, cnt in by.items():
        k, n = cnt.most_common(1)[0]; s = sum(cnt.values())
        out[t] = f'{k} ({n} of {s})' if n * 2 >= s else f'shared ({len(cnt)} kinds)'
    return out

CW = comes_with()
use = collections.Counter(t for d in added.values() for t in d)
w = []
w.append('# Structure')
w.append('')
w.append('How Rosetta\'s cases group, which node types each brings, and which node types real documents use.')
w.append('`tools/structure.py` writes this page from `ledger/intent.json`, `ledger/nodetypes.tsv` and')
w.append('`ledger/prevalence.tsv`.')
w.append('')
w.append('A node is one record of a `.vwx` document\'s decoded stream, and its node type is a small number. A case\'s')
w.append('node types are those of its source document, as a `.vwx` decoder reports them (`ledger/nodetypes.tsv`).')
w.append(f'"Added" means over the blank control `control.blank.mm`, the empty document, which holds {len(blank)} node')
w.append('types of its own.')
w.append('')
w.append('## Reading layers')
w.append('')
w.append('We propose this order for reading Rosetta; it is our reading and not yet confirmed. Each layer shows what its')
w.append('cases add.')
w.append('')
w.append('| layer | families | cases | node types its cases add, most cases first |')
w.append('|---|---|---:|---|')
placed = set()
for name, fams in LAYERS:
    cs = [c for c in added if c.split('.')[0] in fams]; placed |= set(fams)
    tc = collections.Counter(t for c in cs for t in added[c])
    w.append(f'| {name} | {", ".join(fams)} | {len(cs)} | ' + ', '.join(str(t) for t, _ in tc.most_common(8)) + ' |')
rest = sorted({c.split('.')[0] for c in added} - placed)
if rest: w.append(f'\nFamilies in no layer: {", ".join(rest)}.')
w.append('')
w.append('## Node types')
w.append('')
w.append(f'Ranked by how many of {ndocs} real Vectorworks documents (private; only these totals are published) hold the')
w.append('type. The share of nodes is shown beside it and does not affect the rank, because one large object can hold most')
w.append('of a document\'s nodes. "Comes with" is derived from the cases: among the native cases that create one kind of')
w.append('object and add the type, the most common kind, with its ratio.')
w.append('')
w.append(f'| node type | comes with | cases that add it | real documents holding it, of {ndocs} | share of real nodes |')
w.append('|---:|---|---:|---:|---:|')
types = sorted(set(use) | set(prev), key=lambda t: (-int(prev[t]['documents']) if t in prev else 0, -use[t], t))
for t in types:
    p = prev.get(t)
    w.append(f'| {t} | {CW.get(t, "-")} | {use[t]} | {p["documents"] if p else 0} | {p["share_of_nodes_percent"] + "%" if p else "-"} |')
gaps = [t for t in prev if t not in {x for d in nt.values() for x in d}]
only = sorted({x for d in nt.values() for x in d} - set(prev))
w.append('')
w.append(f'Node types in real documents and in no source here: {", ".join(f"{t} ({prev[t]["documents"]} of {ndocs})" for t in sorted(gaps, key=lambda t: -int(prev[t]["documents"]))) or "none"}.')
w.append(f'Node types in sources here and in no real document: {", ".join(map(str, only)) or "none"}.')
w.append('')
w.append('## Cases')
w.append('')
w.append('| case | family | kind | objects (intent) | calls (intent) | node types added |')
w.append('|---|---|---|---|---|---|')
for c in sorted(added):
    o = objects(c); tcount = collections.Counter(x.get('type') for x in o)
    objs = ', '.join(f'{k} x{v}' if v > 1 else str(k) for k, v in tcount.most_common()) or '-'
    calls = ', '.join(sorted({x.get('api') for x in o if x.get('api')})) or '-'
    tds = ' '.join(f'{t}' + (f'x{n}' if n > 1 else '') for t, n in sorted(added[c].items())) or '-'
    w.append(f'| `{c}` | {c.split(".")[0]} | {kind(c)} | {objs} | {calls} | {tds} |')
w.append('')
w.append('"kind" is plug-in when the family is `plugin` or the case\'s intent creates a plug-in object. A case with no intent')
w.append('record (a later case) shows "-" for objects and calls.')
tmp = P('STRUCTURE.md.new')
with open(tmp, 'x', encoding='utf-8') as f: f.write('\n'.join(w) + '\n')
os.replace(tmp, P('STRUCTURE.md'))
print(f'STRUCTURE.md: {len(added)} cases, {len(types)} node types, {ndocs} real documents in the prevalence totals')
