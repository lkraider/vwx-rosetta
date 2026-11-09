#!/usr/bin/env python3
"""Write ledger/COVERAGE.tsv, one row per required pair.

The state of a pair comes from two places. A file under files/<case>/ whose name
matches the profile is `artifact`. A row in ledger/negatives.tsv is `negative` and
carries the reason. Every other pair is `unaccounted`.

The file name follows the driver. It is the case, the suffix that
driver/profile_names.py gives the profile, and the extension of the format. The
extension comes from the route table in driver/ui/sweep-ui.py, so this file reads
that table rather than repeating it.

Usage: coverage.py [--write] [--pending PATH]
"""
import argparse
import collections
import importlib.util
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "driver"))
from profile_names import artifact_suffix  # noqa: E402
REQUIRED = os.path.join(ROOT, "ledger", "required-pairs.tsv")
COVERAGE = os.path.join(ROOT, "ledger", "COVERAGE.tsv")
NEGATIVES = os.path.join(ROOT, "ledger", "negatives.tsv")


def load_formats():
    spec = importlib.util.spec_from_file_location("sw", os.path.join(ROOT, "driver", "ui", "sweep-ui.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.FORMATS


def load_negatives():
    """The set of (case, profile) recorded with a reason."""
    rows = {}
    with open(NEGATIVES) as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 4:
                rows[(parts[0], parts[1])] = parts[3]
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="replace ledger/COVERAGE.tsv")
    parser.add_argument("--pending", metavar="PATH",
                        help="write the unaccounted pairs to PATH as case, profile, format")
    args = parser.parse_args()

    formats = load_formats()
    negatives = load_negatives()
    with open(REQUIRED) as handle:
        header = handle.readline().rstrip("\n").split("\t")
        rows = [line.rstrip("\n").split("\t") for line in handle if line.strip()]

    out = [header + ["state", "artifact", "reason"]]
    counts = collections.Counter()
    per_format = collections.Counter()
    unaccounted = []
    for row in rows:
        case, profile, fmt = row[0], row[1], row[2]
        spec = formats.get(fmt)
        if spec is None:
            state, artifact, reason = "unaccounted", "", "no route in the driver"
        else:
            name = case + artifact_suffix(profile) + "." + spec["ext"]
            path = os.path.join(ROOT, "files", case, name)
            if os.path.exists(path):
                state, artifact, reason = "artifact", name, ""
            elif (case, profile) in negatives:
                state, artifact, reason = "negative", "", negatives[(case, profile)]
            else:
                state, artifact, reason = "unaccounted", "", ""
        counts[state] += 1
        per_format[(fmt, state)] += 1
        out.append(row + [state, artifact, reason])
        if state == "unaccounted":
            unaccounted.append((case, profile, fmt))

    if args.write:
        with open(COVERAGE, "w") as handle:
            for line in out:
                handle.write("\t".join(line) + "\n")

    if args.pending:
        with open(args.pending, "w") as handle:
            for case, profile, fmt in unaccounted:
                handle.write("%s\t%s\t%s\n" % (case, profile, fmt))

    print("pairs %d" % len(rows))
    for state in ("artifact", "negative", "unaccounted"):
        print("  %-12s %d" % (state, counts[state]))
    print()
    print("%-12s %6s %6s %6s" % ("format", "pairs", "held", "unacc"))
    for fmt in sorted({f for f, _ in per_format}):
        total = sum(n for (f, _s), n in per_format.items() if f == fmt)
        held = per_format[(fmt, "artifact")]
        unacc = per_format[(fmt, "unaccounted")]
        print("%-12s %6d %6d %6d" % (fmt, total, held, unacc))
    if unaccounted:
        print()
        print("unaccounted cases")
        cases = collections.Counter(c for c, _p, _f in unaccounted)
        for case, n in cases.most_common():
            print("  %-44s %d" % (case, n))
    if args.write:
        print()
        print("wrote " + COVERAGE)


if __name__ == "__main__":
    main()
