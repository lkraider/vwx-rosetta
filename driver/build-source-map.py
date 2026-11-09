#!/usr/bin/env python3
"""Build the case-to-source map for the export corpus.

Scans one or more roots for .vwx documents, derives the case id from the
`cases/<case>/` path component, and picks one source per case.

Preference order, highest first:
  1. a file named by `--sealed DIR` through its `SOURCES.tsv`
  2. a path under `source/` (the sealed saved source)
  3. a path under `work/open-*/` (a document the capture run opened)
  4. any other path
Within a rank, a lower attempt number wins, then a shorter path, then the
lexicographically first path. The chosen file's sha256 is recorded, together
with every alternative, so a later run can prove which bytes produced an
artifact. A path under the store root is written relative to it.

A `--sealed` directory holds one copy per document, named `<case>.vwx`, and a
`SOURCES.tsv` whose columns are `source_file`, `sha256`, `bytes`, `batch` and
`case_ids`. A `current_sha256` value, when present, is the digest of a source repaired
after the census and replaces `sha256` in the check. The sealed copy survives a cache cleanup, so it wins over every
path under a cache root.

Usage:
  build-source-map.py --out FILE [--root DIR]... [--sealed DIR] [--print-gaps REQUIRED.tsv]
"""
import argparse
import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "driver"))
from store_path import relative  # noqa: E402

STUB_MAGIC = b"FAKEVWX"


def is_real_document(path, min_bytes):
    """A readiness stub is not a document. Reject the stub magic and tiny files."""
    try:
        if os.path.getsize(path) < min_bytes:
            return False
        with open(path, "rb") as f:
            return not f.read(len(STUB_MAGIC)).startswith(STUB_MAGIC)
    except OSError:
        return False


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


GENERIC_STEMS = {"reopened", "untitled", "initial", "query-1", "readiness-initial"}


def case_of(path):
    parts = path.split(os.sep)
    for i, part in enumerate(parts):
        if part == "cases" and i + 1 < len(parts):
            return parts[i + 1]
    stem = os.path.splitext(os.path.basename(path))[0]
    if stem.lower() in GENERIC_STEMS:
        return None
    return stem


def read_sealed(dirpath):
    """Read a sealed source directory. Return case id -> (path, digest)."""
    tsv = os.path.join(dirpath, "SOURCES.tsv")
    if not os.path.exists(tsv):
        raise SystemExit("%s holds no SOURCES.tsv" % dirpath)
    out = {}
    with open(tsv) as f:
        header = next(f, "").rstrip("\n").split("\t")
        need = {"source_file", "sha256", "case_ids"}
        if not need.issubset(set(header)):
            raise SystemExit("%s lacks the columns %s" % (tsv, sorted(need)))
        i_file = header.index("source_file")
        i_dig = header.index("sha256")
        i_cases = header.index("case_ids")
        i_current = header.index("current_sha256") if "current_sha256" in header else None
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) <= i_cases:
                continue
            path = os.path.join(dirpath, parts[i_file])
            digest = parts[i_dig]
            if i_current is not None and len(parts) > i_current and parts[i_current]:
                digest = parts[i_current]
            for case in parts[i_cases].split(","):
                if case:
                    out[case] = (path, digest)
    return out


def rank(path):
    if "/source/" in path:
        return (0,)
    if "/work/open-" in path:
        return (1,)
    return (2,)


def attempt_number(path):
    m = re.search(r"/attempt-(\d+)/", path)
    return int(m.group(1)) if m else 999


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--root", action="append", default=[])
    ap.add_argument("--sealed")
    ap.add_argument("--print-gaps")
    ap.add_argument("--min-bytes", type=int, default=4096)
    args = ap.parse_args()

    found = {}
    for root in args.root:
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in filenames:
                if not name.lower().endswith(".vwx"):
                    continue
                path = os.path.join(dirpath, name)
                case = case_of(path)
                if not case or not is_real_document(path, args.min_bytes):
                    continue
                found.setdefault(case, []).append(path)

    sealed = read_sealed(args.sealed) if args.sealed else {}
    sealed_bad = []
    for case, (path, _digest) in sorted(sealed.items()):
        if not is_real_document(path, args.min_bytes):
            sealed_bad.append((case, path, "not a document"))
            continue
        found[case] = [path]

    rows = []
    for case in sorted(found):
        candidates = sorted(found[case], key=lambda p: (rank(p), attempt_number(p), len(p), p))
        chosen = candidates[0]
        rows.append((case, chosen, sha256(chosen), len(candidates)))

    if args.sealed:
        for case, path, digest, _count in rows:
            if case in sealed and digest != sealed[case][1]:
                sealed_bad.append((case, path, "digest %s recorded %s"
                                   % (digest[:12], sealed[case][1][:12])))

    with open(args.out, "w") as f:
        for case, path, digest, count in rows:
            f.write("%s\t%s\t%s\t%s\n" % (case, relative(path, ROOT), digest, count))

    missing = []
    extra = []
    if args.print_gaps:
        required = set()
        with open(args.print_gaps) as f:
            for i, line in enumerate(f):
                if i == 0:
                    continue
                parts = line.rstrip("\n").split("\t")
                if parts and parts[0]:
                    required.add(parts[0])
        available = set(found)
        missing = sorted(required - available)
        extra = sorted(available - required)

    print("cases with a source: %d" % len(rows))
    if args.sealed:
        print("sealed directory: %s" % args.sealed)
        print("sealed case ids: %d of %d" % (len(sealed), len(rows)))
        for case, path, why in sealed_bad:
            print("  SEALED PROBLEM %s %s %s" % (case, path, why))
    if args.print_gaps:
        print("required cases without a source: %d" % len(missing))
        for case in missing:
            print("  missing %s" % case)
        print("sources not in the required list: %d" % len(extra))


if __name__ == "__main__":
    main()
