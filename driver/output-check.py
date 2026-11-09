#!/usr/bin/env python3
"""Check exported files before install: present, not empty, read by a reader outside Vectorworks, and
holding the objects of their source.

Usage: output-check.py [--list FILE] [--out TSV] [PATH[=RECORD]]...

Each PATH is one exported file. RECORD is its run record. Without RECORD the newest ledger line whose
path is PATH names the case, profile and run, and the record is runs/<run_id>/records/<case>.<profile>.json.
--list reads one PATH or PATH<tab>RECORD per line. The output is one TSV row per file on stdout, or in
--out.

Columns:
  reader         the reader result. DXF, DWG, PDF and SAT go through the readers of driver/reader-audit.py.
                 VWX gets `header`: the file passes when its header names the version of the year in its
                 profile, as VWX_HEADER lists. Its objects column stays empty. Every other format gets
                 `none`, and the objects column holds the result of its driver/plugin-presence.py reader. `exception` when a reader raised.
  objects        held and total source objects. A combined source has one object per plug-in, and
                 driver/plugin-presence.py decides each one. Any other source counts as one object, held
                 when the presence reader of its format finds geometry, or when qpdf finds an image in
                 a PDF. `unread` when no reader exists for the format: PNG, JPG, STEP and .bin today.
  missing        the plug-ins of a combined source that the file does not hold.
  settings       `recorded` when the record lists the dialog controls the driver set and each one took.
                 `failed` when one did not take. `unknown` when the record lists none or is absent.
  alerts         the count of dialog and alert texts the record holds.
  verdict        pass, partial (some objects missing), unread (no object reader), or fail (absent, empty,
                 rejected by its reader, a reader exception, or no object held).

Exit status 0 when every verdict is pass, 1 otherwise. Run it with the reader Python, which has ezdxf,
and with dwgread and qpdf on PATH.
"""
import argparse
import importlib.util
import json
import os
import re
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEDGER = os.path.join(ROOT, "ledger", "corpus-ledger.jsonl")
RECIPES = os.path.join(ROOT, "driver", "inventory", "recipes")
COLUMNS = ["path", "case", "profile", "format", "bytes", "reader", "objects", "missing", "settings",
           "alerts", "verdict", "detail"]
READ = {".dxf": "read_dxf", ".dwg": "read_dwg", ".pdf": "read_pdf", ".sat": "read_sat", ".vwx": "header"}
# The header string at the start of the VWX files that Vectorworks 2027 saves in each older format.
# Read from the installed files/*.v<year>.vwx.
VWX_HEADER = {"2022": b"VectorWorks 214", "2023": b"VectorWorks 217", "2024": b"VectorWorks 220",
              "2025": b"VectorWorks 223", "2026": b"VectorWorks 228"}


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, "driver", file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


presence = load("plugin_presence", "plugin-presence.py")


def ledger_lines():
    by_path = {}
    if os.path.exists(LEDGER):
        with open(LEDGER) as f:
            for line in f:
                if line.strip():
                    r = json.loads(line)
                    by_path[os.path.realpath(os.path.join(ROOT, r.get("path", "")))] = r
    return by_path


def find_record(path, record, lines):
    if record:
        try:
            with open(record) as f:
                return json.load(f)
        except (OSError, ValueError):
            return None
    line = lines.get(os.path.realpath(path))
    if not line:
        return None
    rec = os.path.join(ROOT, "runs", line.get("run_id", ""), "records",
                       "%s.%s.json" % (line.get("case"), line.get("profile")))
    if os.path.exists(rec):
        with open(rec) as f:
            return json.load(f)
    return {"case": line.get("case"), "profile": line.get("profile")}


def recipe_of(case):
    path = os.path.join(RECIPES, "%s.json" % case)
    if not case or not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


def objects(path, case):
    """(held, total, missing plug-ins, detail), or None when no reader exists for the format."""
    ext = os.path.splitext(path)[1].lower().lstrip(".")
    recipe = recipe_of(case)
    plugins = (recipe or {}).get("parameters", {}).get("plugins")
    if plugins:
        rows = presence.presence(recipe, ext, path)
        if all(r[1] == "unread" for r in rows):
            return None
        missing = [r[0] for r in rows if r[1] != "yes"]
        return len(rows) - len(missing), len(rows), missing, ""
    if ext == "pdf":
        got = presence._pdf_page_points(path)
    elif ext in presence.READERS:
        got = presence.READERS[ext][1](path)
    else:
        return None
    if got is None:
        return None
    count = sum(got.values()) if isinstance(got, dict) else len(list(got))
    return (1 if count else 0), 1, [], "%d %s" % (count, "entities" if isinstance(got, dict) else "points")


def settings(record):
    setup = (record or {}).get("setup") or []
    if not setup:
        return "unknown"
    return "recorded" if all(s.get("ok") for s in setup) else "failed"


def check(path, record, lines, scratch):
    rec = find_record(path, record, lines)
    case = (rec or {}).get("case") or os.path.basename(os.path.dirname(path))
    row = {"path": path, "case": case, "profile": (rec or {}).get("profile", ""),
           "format": os.path.splitext(path)[1].lower().lstrip("."), "bytes": "", "reader": "",
           "objects": "", "missing": "", "settings": settings(rec),
           "alerts": str(len((rec or {}).get("dialogs") or [])), "verdict": "fail", "detail": ""}
    if not os.path.isfile(path):
        row["detail"] = "absent"
        return row
    row["bytes"] = str(os.path.getsize(path))
    if not os.path.getsize(path):
        row["detail"] = "empty"
        return row
    reader = READ.get(os.path.splitext(path)[1].lower())
    if reader == "header":
        return vwx_header(path, row)
    detail_of_reader = ""
    if reader:
        audit = load("reader_audit", "reader-audit.py")
        args = (path, scratch) if reader == "read_dwg" else (path,)
        try:
            result, detail = getattr(audit, reader)(*args)
        except Exception as e:
            row["reader"], row["detail"] = "exception", "reader failed: %s: %s" % (type(e).__name__, str(e)[:160])
            return row
        row["reader"], detail_of_reader = result, detail
        if result == "rejected":
            row["detail"] = detail[:200]
            return row
    else:
        row["reader"] = "none"
    try:
        got = objects(path, case)
    except Exception as e:
        row["detail"] = "object reader failed: %s: %s" % (type(e).__name__, str(e)[:160])
        return row
    if got is None:
        row["objects"], row["verdict"] = "unread", "unread"
        return row
    held, total, missing, detail = got
    images = re.search(r" images=(\d+)", detail_of_reader)
    if not held and total == 1 and images and int(images.group(1)):
        held, detail = 1, "%s images" % images.group(1)
    row["objects"], row["missing"], row["detail"] = "%d/%d" % (held, total), ",".join(missing), detail
    row["verdict"] = "fail" if held == 0 else "partial" if held < total else "pass"
    return row


def vwx_header(path, row):
    year = re.fullmatch(r"vwx\.(20\d\d)", row["profile"]) or re.search(r"\.v(20\d\d)\.vwx$", path)
    want = VWX_HEADER.get(year.group(1) if year else "")
    with open(path, "rb") as f:
        head = f.read(64)
    row["reader"] = "header"
    if not want:
        row["detail"] = "no VWX header known for profile %r" % row["profile"]
    elif want not in head:
        row["detail"] = "header %r, want %s" % (head[12:40], want.decode())
    else:
        row["verdict"], row["detail"] = "pass", "header %s, objects not read" % want.decode()
    return row


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--list")
    ap.add_argument("--out")
    ap.add_argument("paths", nargs="*")
    args = ap.parse_args()
    items = [p.partition("=")[::2] for p in args.paths]
    if args.list:
        with open(args.list) as f:
            items += [line.rstrip("\n").partition("\t")[::2] for line in f if line.strip()]
    if not items:
        ap.error("no files")
    lines = ledger_lines()
    with tempfile.TemporaryDirectory() as scratch:
        rows = [check(os.path.abspath(p), r, lines, scratch) for p, r in items]
    for row, (_p, record) in zip(rows, items):
        if record and not os.path.isfile(record):
            row["detail"] = ("record %s not found. %s" % (record, row["detail"])).strip()
    text = "".join("\t".join(str(r[c]).replace("\t", " ").replace("\n", " ") for c in COLUMNS) + "\n"
                   for r in rows)
    out = "\t".join(COLUMNS) + "\n" + text
    if args.out:
        with open(args.out, "w") as f:
            f.write(out)
    else:
        sys.stdout.write(out)
    return 0 if all(r["verdict"] == "pass" for r in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
