#!/usr/bin/env python3
"""Compare two DXF files group by group and print where they differ.

Usage: python3 driver/dxf-diff.py A.dxf B.dxf

A DWG file compares after `dwg2dxf` from LibreDWG converts it. The program prints each HEADER
variable whose values differ, then one line per section with the count of differing values by
group code, then the differing values of each section.
"""
import collections
import sys


def pairs(path):
    with open(path, encoding="latin-1") as f:
        lines = f.read().splitlines()
    return [(lines[i].strip(), lines[i + 1]) for i in range(0, len(lines) - 1, 2)]


def sections(groups):
    out = collections.OrderedDict()
    name = None
    for i, (code, value) in enumerate(groups):
        if code == "2" and i and groups[i - 1] == ("0", "SECTION"):
            name = value
            out[name] = []
        elif name:
            out[name].append((code, value))
    return out


def header(groups):
    out = {}
    var = None
    for code, value in groups:
        if code == "9":
            var = value
            out[var] = []
        elif var and code != "0":
            out[var].append((code, value))
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.split("\n\n")[1])
    a, b = sections(pairs(sys.argv[1])), sections(pairs(sys.argv[2]))
    ha, hb = header(a.get("HEADER", [])), header(b.get("HEADER", []))
    for var in sorted(set(ha) | set(hb)):
        if ha.get(var) != hb.get(var):
            print("HEADER %s %s -> %s" % (var, ha.get(var), hb.get(var)))
    for name in list(a) + [n for n in b if n not in a]:
        x, y = a.get(name, []), b.get(name, [])
        if x == y:
            print("SECTION %s identical, %d groups" % (name, len(x)))
            continue
        if len(x) != len(y) or any(c1 != c2 for (c1, _), (c2, _) in zip(x, y)):
            print("SECTION %s differs in structure, %d and %d groups" % (name, len(x), len(y)))
            continue
        changed = [(c, v1, v2) for (c, v1), (_, v2) in zip(x, y) if v1 != v2]
        counts = collections.Counter(c for c, _, _ in changed)
        print("SECTION %s same structure, %d groups, differing values by group code %s"
              % (name, len(x), dict(sorted(counts.items()))))
        for code, v1, v2 in changed:
            print("  %s: %s -> %s" % (code, v1, v2))


if __name__ == "__main__":
    main()
