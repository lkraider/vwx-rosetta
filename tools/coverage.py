#!/usr/bin/env python3
"""tools/coverage.py [ROOT]: write the coverage section of ROOT/README.md, between the lines
`<!-- coverage: written by tools/coverage.py -->` and `<!-- /coverage -->`.

Reads only files in this repository:
- ledger/prevalence.tsv: per node type, in how many of a set of real Vectorworks documents it occurs;
- ledger/nodetypes.tsv: the node types of each source document;
- ledger/manifest.json: every source/reference pair and its state;
- ledger/negatives.tsv: why each negative pair has no reference;
- ledger/catalog.tsv: per kind (node types seen in real documents, plug-in objects, export commands), how many are
  covered or why not;
- ledger/versions.tsv: per saved-back copy and its source, the header's version string and where each layer record
  holds the layer name, as a `.vwx` decoder reports them.
It also writes docs/coverage.svg, a chart of ledger/catalog.tsv. Each file is written to
<name>.new and renamed over the old one."""
import collections, csv, json, os, sys, textwrap

root = sys.argv[1] if len(sys.argv) > 1 else '.'
P = lambda *a: os.path.join(root, *a)
START, END = '<!-- coverage: written by tools/coverage.py -->', '<!-- /coverage -->'


def para(text, lead=''):
    """A paragraph or a list item, wrapped at 116 columns like the rest of the README."""
    return textwrap.fill(text, 116, initial_indent=lead, subsequent_indent=' ' * len(lead), break_on_hyphens=False)


def tsv(name):
    return list(csv.DictReader(open(P('ledger', name), encoding='utf-8'), delimiter='\t'))


prev = {int(r['node_type']): r for r in tsv('prevalence.tsv')}
ndocs = int(next(iter(prev.values()))['of_documents'])
real = {t for t, r in prev.items() if int(r['documents']) > 0}
in_cases = set()
for r in tsv('nodetypes.tsv'):
    in_cases |= {int(x.split(':')[0]) for x in r['node_types'].split()}
nsources = len(tsv('nodetypes.tsv'))
pairs = json.load(open(P('ledger/manifest.json'), encoding='utf-8'))['pairs']
ncases = len({p['case'] for p in pairs})
neg_rows = tsv('negatives.tsv')
why = {(r['case'], r['profile']): r['status'] for r in neg_rows}
negs = [p for p in pairs if p['state'] == 'negative']
missing = [(p['case'], p['profile']) for p in negs if (p['case'], p['profile']) not in why]
if missing:
    sys.exit(f'coverage: {len(missing)} negative pairs have no reason in ledger/negatives.tsv, first {missing[0]}')

# The chart: one stacked bar per kind, each block a disposition, colours from the Okabe-Ito colour-blind-safe set.
BLOCKS = [  # disposition in catalog.tsv, label, fill, text colour (each pair has a contrast of at least 4.5:1)
    ('covered', 'covered', '#0072B2', '#ffffff'),
    ('not covered: on purpose', 'not covered: on purpose', '#009E73', '#000000'),
    ('not covered: execution', 'not covered: lack of execution', '#E69F00', '#000000'),
    ('not covered: mapping', 'not covered: lack of mapping', '#D55E00', '#000000'),
    ('not created by the app', 'not created by the app', '#999999', '#000000'),
    ('not offered by the app', 'not offered by the app', '#F0E442', '#000000'),
]
BARS = [  # kind in catalog.tsv, title
    ('node type in real documents', f'Node types found in {ndocs} real documents'),
    ('plug-in object', 'Plug-in objects of the installed library'),
    ('export command', 'Export commands'),
]
cat = collections.defaultdict(collections.Counter)
for r in tsv('catalog.tsv'):
    cat[r['kind']][r['disposition']] += int(r['count'])
unknown = {d for c in cat.values() for d in c} - {b[0] for b in BLOCKS}
if unknown:
    sys.exit(f'coverage: catalog.tsv has dispositions without a block: {sorted(unknown)}')


def esc(t):
    return t.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def chart():
    W, X, BW, BH = 600, 12, 576, 30
    out, y = [], 24
    out.append(f'<text x="{X}" y="{y}" font-size="17" font-weight="bold">Coverage of the format by kind</text>')
    y += 16
    for kind, title in BARS:
        c = cat[kind]
        total = sum(c.values())
        y += 22
        out.append(f'<text x="{X}" y="{y}" font-size="15">{esc(title)}: {total}</text>')
        y += 8
        x = float(X)
        chips, small = [], []
        for d, label, fill, ink in BLOCKS:
            n = c.get(d, 0)
            if not n:
                continue
            w = max(BW * n / total, 3.0)
            out.append(f'<rect x="{x:.1f}" y="{y}" width="{w:.1f}" height="{BH}" fill="{fill}" stroke="#ffffff" '
                       f'stroke-width="1"><title>{esc(label)}: {n}</title></rect>')
            if w >= 9 * len(str(n)) + 8:
                out.append(f'<text x="{x + w / 2:.1f}" y="{y + 20}" font-size="15" text-anchor="middle" '
                           f'fill="{ink}">{n}</text>')
            elif n / total < 0.01:
                small.append((x + w / 2, label, n))
            chips.append((label, n, fill))
            x += w
        if small:
            # A block under 1% of its bar is too thin to find: a leader line from it to a label under the bar.
            for cx, label, n in small:
                out.append(f'<line x1="{cx:.1f}" y1="{y + BH}" x2="{cx:.1f}" y2="{y + BH + 12}" stroke="#222222" '
                           f'stroke-width="1.5"/>')
                out.append(f'<text x="{cx:.1f}" y="{y + BH + 27}" font-size="15" text-anchor="end">'
                           f'{esc(label)}: {n} &#8593;</text>')
            y += 30
        y += BH + 22
        cx = float(X)
        for label, n, fill in chips:
            text = f'{label}: {n}'
            tw = 8.7 * len(text) + 28
            if cx + tw > X + BW:
                cx, y = float(X), y + 23
            out.append(f'<rect x="{cx:.1f}" y="{y - 13}" width="14" height="14" fill="{fill}"/>')
            out.append(f'<text x="{cx + 19:.1f}" y="{y}" font-size="16">{esc(text)}</text>')
            cx += tw
        y += 10
    h = y + 12
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {h}" width="100%" '
            f'font-family="Helvetica, Arial, sans-serif" fill="#222222" role="img" '
            f'aria-label="Coverage of the format by kind">\n'
            f'<rect x="0" y="0" width="{W}" height="{h}" fill="#ffffff"/>\n' + '\n'.join(out) + '\n</svg>\n')


svg_path = P('docs', 'coverage.svg')
with open(svg_path + '.new', 'w', encoding='utf-8') as f:
    f.write(chart())
os.replace(svg_path + '.new', svg_path)

w = [START, '## Coverage', '']
w.append(para('How far Rosetta reaches. The chart counts three kinds, each against its own denominator; the sections '
              'below give the node types, the export profiles and the file versions in detail, each from the ledger '
              'files in its heading or the source its text names.'))
w.append('')
w.append('![Coverage of the format by kind: node types, plug-in objects and export commands](docs/coverage.svg)')
w.append('')
w.append('| kind | ' + ' | '.join(b[1] for b in BLOCKS if any(cat[k].get(b[0]) for k, _ in BARS)) + ' | total |')
w.append('| --- ' * (2 + sum(1 for b in BLOCKS if any(cat[k].get(b[0]) for k, _ in BARS))) + '|')
for kind, title in BARS:
    cells = [str(cat[kind].get(b[0], 0)) for b in BLOCKS if any(cat[k].get(b[0]) for k, _ in BARS)]
    w.append(f'| {title} | ' + ' | '.join(cells) + f' | {sum(cat[kind].values())} |')
w.append('')
w.append(para('Each kind has its own denominator, so the bars do not add up to one figure for the whole format. A '
              'block outside "covered" says why (`ledger/catalog.tsv` gives the reason classes). "Not created by the '
              'app": no call made Vectorworks create the object. "Not offered by the app": this edition has no such '
              'export.'))
w.append('')
w.append('### Node types in real documents (`ledger/prevalence.tsv`, `ledger/nodetypes.tsv`)')
w.append('')
w.append(para(f'A reader tested on Rosetta has seen almost every node type that real documents hold: of the '
              f'{len(real)} types found in {ndocs} real Vectorworks documents, {len(real & in_cases)} occur in a Rosetta '
              f'source. {ndocs} documents show the common types; we expect rarer types to exist that none of them holds.'))
w.append('')
w.append(f'The {len(real - in_cases)} types found in real documents and in no Rosetta source:')
w.append('')
w.append(f'| node type | documents (of {ndocs}) |')
w.append('| --- | --- |')
gap = sorted(real - in_cases)
for t in gap:
    w.append(f"| {t} | {prev[t]['documents']} |")
w.append('')
# Each share in prevalence.tsv is rounded to 0.01, so each true share is below the rounded one plus 0.005.
bound = round(sum(float(prev[t]['share_of_nodes_percent']) for t in gap) + 0.005 * len(gap), 3)
w.append(para(f'Together they make up under {bound:g}% of the nodes of those documents (the ledger rounds each share to '
              '0.01%). The share counts node records, so a type with a small share can still hold an object a reader '
              'needs.'))
w.append('')
only = sorted(in_cases - real)
w.append(para(f'Rosetta also holds types that none of the {ndocs} documents use: {", ".join(map(str, only))}.'))
w.append('')
w.append('### Export profiles (`ledger/manifest.json`, `ledger/negatives.tsv`)')
w.append('')
w.append(para('A pair is captured when the export wrote a file with what the case tests, and negative when it wrote no '
              'file, or a file without what the case tests. A negative pair records what Vectorworks does, with its '
              'reason. The saved-back copies are under File versions.'))
w.append('')
w.append('| format | profile | captured | negative |')
w.append('| --- | --- | --- | --- |')
by = collections.defaultdict(collections.Counter)
for p in pairs:
    by[(p['format'], p['profile'])][p['state']] += 1
for (f, prof), c in sorted(by.items()):
    if f != 'vwx':
        w.append(f"| {f} | `{prof}` | {c['artifact']} | {c['negative']} |")
w.append('')
reasons = collections.Counter(why[(p['case'], p['profile'])] for p in negs)
w.append(f'The reasons of the negative pairs (`ledger/negatives.tsv` also holds {len(neg_rows) - len(negs)} rows for '
         'pairs outside the manifest):')
w.append('')
w.append('| reason | pairs |')
w.append('| --- | --- |')
for r, n in reasons.most_common():
    w.append(f'| {r} | {n} |')
w.append('')
w.append('### File versions (`ledger/versions.tsv`)')
w.append('')
vers = tsv('versions.tsv')
vcases = collections.Counter(r['profile'] for r in vers)
w.append(para('A reader built on the 2027 sources will meet files saved for earlier versions. The copies saved back from '
              'the same documents show how they differ. The version string in the file header names the version, and '
              'the layer record changes its layout: the table gives where it holds the length of the layer name. The '
              'layer elevation moves as well: on the 9 elevated layers it sits at +526 in the sources and at +508 in the '
              '2023 copies.'))
w.append('')
w.append('| profile | cases | version string | layer name at |')
w.append('| --- | --- | --- | --- |')
for prof in sorted(vcases, key=lambda p: (p == 'source', p)):
    rs = [r for r in vers if r['profile'] == prof]
    vs = ', '.join(sorted({f"`{r['version_string']}`" for r in rs}))
    la = ', '.join(sorted({f"+{r['layer_name_at']}" for r in rs}))
    name = 'their 2027 sources' if prof == 'source' else f'`{prof}`'
    w.append(f"| {name} | {len(rs)} | {vs} | {la} |")
w.append('')
w.append('### Modules outside the licence')
w.append('')
w.append(para('Our licence held the Fundamentals and Architect modules only. We believe that is why objects of other '
              'modules (Landmark, Spotlight) are missing or appear only as generic objects.'))
w.append(END)

text = open(P('README.md'), encoding='utf-8').read()
if text.count(START) != 1 or text.count(END) != 1:
    sys.exit('coverage: README.md needs one start and one end marker')
a, rest = text.split(START)
_, b = rest.split(END)
new = a + '\n'.join(w) + b
tmp = P('README.md.new')
open(tmp, 'w', encoding='utf-8').write(new)
os.replace(tmp, P('README.md'))
print(f'coverage: README.md written, {len(w)} lines in the section')
