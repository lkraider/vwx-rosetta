#!/usr/bin/env python3
"""Read every DXF, DWG, PDF, SAT and STEP file under `files/` with a reader outside Vectorworks.

DXF goes through `ezdxf.readfile` and `doc.audit()`. DWG goes through LibreDWG
`dwgread -O JSON`, the route a .vwx reader's DWG reference check takes. PDF goes through
`qpdf --check` and `qpdf --json=2`. SAT goes through `ezdxf.acis.sat.parse_sat`, and
`driver/acis-types.py` counts its surface and curve types. STEP is scanned for the
`LENGTH_UNIT` of its unit context. The rows go to `ledger/reader-audit.tsv`, and
`driver/build-index.py` copies the DXF, DWG, PDF and SAT rows into the `reader` field of the manifest.

Run it with a Python that has ezdxf, and with `dwgread` and `qpdf` on PATH:
  <venv>/bin/python driver/reader-audit.py --write   write ledger/reader-audit.tsv
  <venv>/bin/python driver/reader-audit.py --check   exit 1 when the table on disk differs, or a file
                                                     fails its reader and ACCEPTED names no reason
"""
import argparse
import collections
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile

import ezdxf

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = os.path.join(ROOT, "files")
OUT = os.path.join(ROOT, "ledger", "reader-audit.tsv")
COLUMNS = ["case", "path", "sha256", "format", "reader", "result", "detail"]
EXTENSIONS = {".dxf": "dxf", ".dwg": "dwg", ".pdf": "pdf", ".sat": "sat", ".step": "step"}

_spec = importlib.util.spec_from_file_location("acis_types", os.path.join(ROOT, "driver", "acis-types.py"))
acis_types = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(acis_types)

# Vectorworks writes the unit as a complex instance:
# ( LENGTH_UNIT () NAMED_UNIT (*) SI_UNIT (.MILLI., .METRE.) )
PASS = {"dxf": "parsed", "dwg": "parsed", "pdf": "parsed", "sat": "parsed", "step": "LENGTH_UNIT"}
SAT_EMPTY = re.compile(r" bodies=0 | faces=\{\} ")
# path: the reason the store keeps a file whose reader result fails
ACCEPTED = {}

STEP_LENGTH = re.compile(r"LENGTH_UNIT\s*\(\s*\)\s*NAMED_UNIT\s*\(\s*\*\s*\)\s*SI_UNIT\s*\(([^)]*)\)")


def dwgread_version():
    out = subprocess.run(["dwgread", "--version"], capture_output=True, text=True)
    return out.stdout.strip()


def read_dxf(path):
    try:
        doc = ezdxf.readfile(path)
    except (IOError, ezdxf.DXFError) as e:
        return "rejected", "%s: %s" % (type(e).__name__, e)
    audit = doc.audit()
    detail = "version=%s audit_errors=%d audit_fixes=%d" % (doc.dxfversion, len(audit.errors),
                                                             len(audit.fixes))
    codes = collections.Counter(str(e.code) for e in audit.errors + audit.fixes)
    if codes:
        detail += " codes=%s" % json.dumps(dict(sorted(codes.items())), separators=(",", ":"))
    return "parsed", detail


def read_dwg(path, scratch):
    out = os.path.join(scratch, "out.json")
    if os.path.exists(out):
        os.remove(out)
    run = subprocess.run(["dwgread", "-O", "JSON", "-o", out, path], capture_output=True, text=True)
    errors = sum(1 for line in run.stderr.splitlines() if line.startswith("ERROR"))
    if run.returncode != 0 or not os.path.exists(out):
        return "rejected", "exit=%d stderr_errors=%d" % (run.returncode, errors)
    try:
        with open(out) as f:
            doc = json.load(f)
    except ValueError as e:
        return "rejected", "exit=%d json: %s" % (run.returncode, e)
    entities = collections.Counter(o["entity"] for o in doc.get("OBJECTS", []) if "entity" in o)
    return "parsed", "version=%s objects=%d stderr_errors=%d entities=%s" % (
        doc.get("FILEHEADER", {}).get("version"), len(doc.get("OBJECTS", [])), errors,
        json.dumps(dict(sorted(entities.items())), separators=(",", ":")))


def qpdf_version():
    out = subprocess.run(["qpdf", "--version"], capture_output=True, text=True)
    return out.stdout.splitlines()[0].strip()


def read_pdf(path):
    check = subprocess.run(["qpdf", "--check", path], capture_output=True, text=True)
    if check.returncode == 2:
        last = check.stderr.strip().splitlines()[-1]
        return "rejected", "exit=2 %s" % last.replace(path, os.path.relpath(path, ROOT))
    run = subprocess.run(["qpdf", "--json=2", "--json-key=pages", "--json-key=qpdf", path],
                         capture_output=True, text=True)
    doc = json.loads(run.stdout)
    header, objects = doc["qpdf"]
    pages = doc["pages"]
    boxes = [objects["obj:" + p["object"]]["value"].get("/MediaBox") for p in pages]
    detail = "version=%s pages=%d objects=%d images=%d mediabox=%s" % (
        header["pdfversion"], len(pages), len(objects) - 1, sum(len(p["images"]) for p in pages),
        json.dumps(boxes, separators=(",", ":")))
    if check.returncode == 3:
        return "warnings", detail
    return "parsed", detail


def read_sat(path):
    with open(path, encoding="latin-1") as f:
        text = f.read()
    try:
        header, bodies, faces, curves = acis_types.sat_types(text)
    except Exception as e:
        return "rejected", "%s: %s" % (type(e).__name__, e)
    return "parsed", "version=%d product=%s units_in_mm=%g bodies=%d faces=%s curves=%s" % (
        header.version, header.product_id, header.units_in_mm, bodies,
        json.dumps(dict(sorted(faces.items())), separators=(",", ":")),
        json.dumps(dict(sorted(curves.items())), separators=(",", ":")))


def read_step(path):
    with open(path, encoding="latin-1") as f:
        text = f.read()
    unit = STEP_LENGTH.search(text)
    schema = re.search(r"FILE_SCHEMA\s*\(\(\s*'([^']*)'", text)
    if not unit:
        return "no LENGTH_UNIT", "schema=%s" % (schema.group(1) if schema else None)
    return "LENGTH_UNIT", "schema=%s si_unit=%s" % (schema.group(1) if schema else None,
                                                     re.sub(r"\s+", "", unit.group(1)))


def rows():
    readers = {"dxf": "ezdxf %s" % ezdxf.__version__, "dwg": dwgread_version(), "pdf": qpdf_version(),
               "sat": "ezdxf %s acis.sat" % ezdxf.__version__, "step": "LENGTH_UNIT text scan"}
    out = []
    with tempfile.TemporaryDirectory() as scratch:
        for case in sorted(os.listdir(FILES)):
            folder = os.path.join(FILES, case)
            if not os.path.isdir(folder):
                continue
            for name in sorted(os.listdir(folder)):
                fmt = EXTENSIONS.get(os.path.splitext(name)[1].lower())
                if not fmt:
                    continue
                path = os.path.join(folder, name)
                if fmt == "dxf":
                    result, detail = read_dxf(path)
                elif fmt == "dwg":
                    result, detail = read_dwg(path, scratch)
                elif fmt == "pdf":
                    result, detail = read_pdf(path)
                elif fmt == "sat":
                    result, detail = read_sat(path)
                else:
                    result, detail = read_step(path)
                with open(path, "rb") as f:
                    digest = hashlib.sha256(f.read()).hexdigest()
                out.append([case, os.path.relpath(path, ROOT), digest, fmt, readers[fmt], result, detail])
    return out


def failures(table):
    out = []
    for case, path, _digest, fmt, _reader, result, detail in table:
        failed = result != PASS[fmt] or (fmt == "sat" and SAT_EMPTY.search(detail + " "))
        if failed and path not in ACCEPTED:
            out.append("%s: %s %s" % (path, result, detail))
        if not failed and path in ACCEPTED:
            out.append("%s: ACCEPTED names a reason and the file passes" % path)
    for path in sorted(set(ACCEPTED) - {r[1] for r in table}):
        out.append("%s: ACCEPTED names a file that is not in files/" % path)
    return out


def render(table):
    return "".join("\t".join(r) + "\n" for r in [COLUMNS] + table)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    table = rows()
    text = render(table)
    counts = collections.Counter((r[3], r[5]) for r in table)
    for (fmt, result), n in sorted(counts.items()):
        print("%s\t%s\t%d" % (fmt, result, n))
    if args.write:
        with open(OUT, "w") as f:
            f.write(text)
    if args.check:
        failed = failures(table)
        for line in failed:
            print("failed " + line)
        with open(OUT) as f:
            if f.read() != text:
                print("ledger/reader-audit.tsv differs from what the readers give")
                return 1
        if failed:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
