#!/usr/bin/env python3
"""Compare the files of a `sweep-ui.py --defaults` run with the stored files of the same pairs.

Usage: defaults-compare.py RUN_DIR [--store ROOT]

Run it with the reader Python, $ROSETTA_READER_PYTHON. tools/measure.py counts PDF ink with PIL, which
the system python3 lacks. A count that measure.py cannot take reads as a difference.

RUN_DIR is runs/<run_id> of the defaults run. Every record in it with a case is read. Each record of an exported pair names its file. The stored
file is files/<case>/<same name> under ROOT, which defaults to this checkout. The output is one TSV row per
pair and item on stdout:
  item     `count`, the tools/measure.py count, or `not measured: <fact>` when measure.py reports ok no, or a value read from the file below, or `dialog: <label>`
  stored   the value in the stored file. Empty for a dialog row.
  new      the value in the new file, or the value of the dialog control as the dialog opened
  equal    yes or no. Empty for a dialog row.

File values:
  pdf  `pdf layers`: on with the count of /Type /OCG objects, or off when the catalog has no /OCProperties.
       `images`: the count of /Subtype /Image objects. Both come from `qpdf --qdf`.
  3ds  `3d loci`: the count of the string Locus in the file.
  sat  `version`: field 1 of line 1. `faces`: the count of single and double sided face records.
  png  `size`: width x height from the IHDR chunk.

Exit status 0 when every file row is equal, 1 when one differs or a file is absent.
"""
import argparse
import collections
import glob
import json
import os
import re
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MEASURE = os.path.join(ROOT, "tools", "measure.py")


def qpdf(path):
    return subprocess.run(["qpdf", "--qdf", "--object-streams=disable", path, "-"],
                          capture_output=True).stdout


def pdf(path):
    text = qpdf(path)
    layers = len(re.findall(rb"/Type /OCG\b", text))
    return {"pdf layers": "on (%d)" % layers if b"/OCProperties" in text else "off",
            "images": str(len(re.findall(rb"/Subtype /Image\b", text)))}


def tds(path):
    with open(path, "rb") as f:
        return {"3d loci": str(f.read().count(b"Locus"))}


def sat(path):
    with open(path, "rb") as f:
        data = f.read()
    first = data.split(b"\n", 1)[0].split()
    sides = collections.Counter(m.group(1).decode() for m in re.finditer(rb" face \$.*? (single|double)", data))
    return {"version": first[0].decode() if first else "",
            "faces": "single %d double %d" % (sides["single"], sides["double"])}


def png(path):
    with open(path, "rb") as f:
        head = f.read(24)
    return {"size": "%dx%d" % struct.unpack(">II", head[16:24])}


READERS = {"pdf": pdf, "3ds": tds, "sat": sat, "png": png}


def counts(paths):
    out = subprocess.run([sys.executable, "-I", MEASURE] + paths, capture_output=True, text=True).stdout
    found = {}
    for line in out.splitlines():
        cells = line.split("\t")
        if len(cells) >= 4:
            found[cells[0]] = cells[2] if cells[3] == "yes" else "not measured: %s" % (cells[4:] or [""])[0]
    return found


def values(path, fmt):
    try:
        return READERS[fmt](path) if fmt in READERS else {}
    except (OSError, ValueError, struct.error) as exc:
        return {"read": "%s: %s" % (type(exc).__name__, exc)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("run_dir")
    ap.add_argument("--store", default=ROOT)
    args = ap.parse_args()
    evidence = os.path.dirname(os.path.dirname(os.path.abspath(args.run_dir)))
    rows, differ = [], False
    for record in sorted(glob.glob(os.path.join(args.run_dir, "records", "*.json"))):
        with open(record) as f:
            rec = json.load(f)
        if not rec.get("case"):
            continue
        tag = [rec.get("case", ""), rec.get("profile", ""), rec.get("format", "")]
        status = rec.get("status") if rec.get("defaults") or rec.get("status") != "ok" else "ok without --defaults"
        if status != "ok":
            rows.append(tag + ["status", "", status, "no"])
            differ = True
            continue
        new = os.path.join(evidence, rec["path"])
        stored = os.path.join(args.store, "files", rec["case"], os.path.basename(new))
        if not os.path.isfile(stored):
            rows.append(tag + ["stored file", "absent", os.path.basename(new), "no"])
            differ = True
            continue
        measured = counts([stored, new])
        pairs = [("count", measured.get(stored, "not measured"), measured.get(new, "not measured"))]
        old, now = values(stored, tag[2]), values(new, tag[2])
        pairs += [(key, old.get(key, ""), now.get(key, "")) for key in sorted(set(old) | set(now))]
        for item, a, b in pairs:
            equal = a == b and not a.startswith("not measured")
            rows.append(tag + [item, a, b, "yes" if equal else "no"])
            differ = differ or not equal
        for control in rec.get("dialog_read", []):
            rows.append(tag + ["dialog: %s %s" % (control["role"], control["label"]), "",
                               control["value"] + ("" if control["enabled"] == "true" else " (disabled)"), ""])
    sys.stdout.write("case\tprofile\tformat\titem\tstored\tnew\tequal\n")
    for row in rows:
        sys.stdout.write("\t".join(str(c).replace("\t", " ").replace("\n", " ") for c in row) + "\n")
    return 1 if differ or not rows else 0


if __name__ == "__main__":
    sys.exit(main())
