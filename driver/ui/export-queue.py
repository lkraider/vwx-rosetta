#!/usr/bin/env python3
"""Write driver/ui/export-queue.jsonl, one row per required (case, profile) pair.

Inputs are ledger/coverage.tsv, driver/source-map.tsv, the Routes and Fit steps
tables of driver/EXPORT-ROUTES-TABLE.md and the PROFILES setup steps of driver/ui/sweep-ui.py.
A profile in PROFILES gets the setup steps of its format in FORMATS, then its own setup
steps, then the Options pairs of its route row. A setup step replaces the pair with the
same selector. A coverage row in state `artifact` gets
needs_live_app true. A `negative` row gets needs_live_app false and its ledger reason.
Every path in the file is relative to the store root.

  export-queue.py [--out PATH]
  export-queue.py --check     exit 1 when driver/ui/export-queue.jsonl differs
"""
import argparse
import ast
import fnmatch
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "driver"))
from store_path import resolve  # noqa: E402
COVERAGE = os.path.join(ROOT, "ledger", "coverage.tsv")
SOURCE_MAP = os.path.join(ROOT, "driver", "source-map.tsv")
ROUTES = os.path.join(ROOT, "driver", "EXPORT-ROUTES-TABLE.md")
DRIVER = os.path.join(ROOT, "driver", "ui", "sweep-ui.py")
OUT = os.path.join(ROOT, "driver", "ui", "export-queue.jsonl")

PAIR = re.compile(r"`([^`]+)` = (`[^`]*`|\d+)(?:\s*\(([^)]*(?:`[^`]*`[^)]*)*)\))?")
CONDITIONS = {"rescue", "design layer", "sheet layer"}


def table(lines, heading):
    """Rows of the first markdown table after the heading, as lists of cells."""
    rows, inside = [], False
    for line in lines:
        if line.startswith("## "):
            if inside and rows:
                break
            inside = line.strip() == heading
            continue
        if inside and line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if set(cells[0]) <= {"-"}:
                continue
            rows.append(cells)
    if not rows:
        sys.exit("export-queue: no table under %r in %s" % (heading, ROUTES))
    return rows[1:]


def first_code(cell):
    if cell.lower().startswith("none"):
        return None
    m = re.search(r"`([^`]+)`", cell)
    return m.group(1) if m else cell


def options(cell):
    out = []
    for sel, value, paren in PAIR.findall(cell):
        value = value.strip("`")
        item = {"control": sel, "value": value}
        if sel == "key:Tab":
            item["action"] = "key Tab"
        elif sel == "key:type":
            item["action"] = "type"
        elif sel == "script":
            item["action"] = "script"
        else:
            item["action"] = "set"
        if paren in CONDITIONS:
            item["when"] = paren
        elif paren:
            item["note"] = paren.replace("`", "")
        out.append(item)
    return out


def load_routes():
    with open(ROUTES) as f:
        lines = f.read().splitlines()
    routes = {}
    for cells in table(lines, "## Routes"):
        fmt, profiles, menu, dialog, opts, accept, save = cells[:7]
        source = cells[9]
        for profile in re.findall(r"`([^`]+)`", profiles):
            if profile in routes:
                sys.exit("export-queue: profile %s has two route rows" % profile)
            item = first_code(menu)
            routes[profile] = {
                "row": fmt,
                "menu": ["File", "Export", item] if item else None,
                "dialog": first_code(dialog),
                "accept": None if accept.startswith("none") else accept.replace("`", ""),
                "save_panel": None if save.startswith("none") else save.replace("`", ""),
                "options": options(opts),
                "source": source.replace("`", ""),
            }
    fits = [(applies.strip("`"), step.replace("`", ""), source.replace("`", ""))
            for applies, step, source in table(lines, "## Fit steps")]
    return routes, fits


def assigned(tree, name):
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == name for t in node.targets):
            return node.value
    sys.exit("export-queue: no %s in %s" % (name, DRIVER))


def setup_of(dict_node, key):
    for k, v in zip(dict_node.keys, dict_node.values):
        if ast.literal_eval(k) == key:
            for kk, vv in zip(v.keys, v.values):
                if ast.literal_eval(kk) == "setup":
                    return ast.literal_eval(vv)
    return []


def profile_steps():
    """Options items for each profile in PROFILES of sweep-ui.py, in the order the driver sets them."""
    with open(DRIVER) as f:
        tree = ast.parse(f.read())
    formats, profiles = assigned(tree, "FORMATS"), assigned(tree, "PROFILES")
    steps = {}
    for key in profiles.keys:
        profile = ast.literal_eval(key)
        items = []
        for step in setup_of(formats, profile.split(".")[0]) + setup_of(profiles, profile):
            if step[0] == "pane":
                items.append({"control": "pane", "value": step[1], "action": "pane"})
                continue
            item = {"control": step[0], "value": step[1], "action": "set"}
            if len(step) > 2:
                item["note"] = "profile option " + step[2]
            items.append(item)
        steps[profile] = items
    return steps


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    routes, fits = load_routes()
    setups = profile_steps()
    with open(SOURCE_MAP) as f:
        sources = {p[0]: os.path.relpath(resolve(p[1], ROOT), ROOT) for p in (l.rstrip("\n").split("\t") for l in f) if len(p) > 1}
    with open(COVERAGE) as f:
        header = f.readline().rstrip("\n").split("\t")
        coverage = [dict(zip(header, l.rstrip("\n").split("\t"))) for l in f if l.strip()]
    rows = []
    for c in coverage:
        case, profile, fmt = c["case"], c["profile"], c["format"]
        if profile not in routes:
            sys.exit("export-queue: profile %s has no route row" % profile)
        r = routes[profile]
        live = c["state"] == "artifact"
        art = os.path.join("files", case, c["artifact"]) if c["artifact"] else None
        src = sources.get(case)
        setup = setups.get(profile, [])
        set_by_profile = {o["control"] for o in setup}
        opts = setup + [dict(o, value=o["value"].replace("<artifact>", art or "<artifact>"))
                        for o in r["options"] if o["control"] not in set_by_profile]
        steps = [{"step": step, "source": source} for applies, step, source in fits
                 if applies == "all" or fnmatch.fnmatch(profile, applies)]
        rows.append({
            "case_id": case, "format": fmt, "profile": profile,
            "needs_live_app": live, "reason": c["reason"] or None,
            "source_path": src, "source_exists": bool(src and os.path.exists(os.path.join(ROOT, src))),
            "artifact_path": art, "artifact_exists": bool(art and os.path.exists(os.path.join(ROOT, art))),
            "route": {k: r[k] for k in ("row", "menu", "dialog", "accept", "save_panel", "source")},
            "options": opts, "fit_steps": steps,
        })
        if not live and not c["reason"]:
            sys.exit("export-queue: negative row %s %s has no reason" % (case, profile))
    rows.sort(key=lambda x: (x["case_id"], x["format"], x["profile"]))
    text = "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows)
    if args.check:
        with open(args.out) as f:
            if f.read() != text:
                sys.exit("export-queue: %s differs from ledger/coverage.tsv and the routes table. "
                         "Run export-queue.py." % os.path.relpath(args.out, ROOT))
        print("export-queue: %s matches" % os.path.relpath(args.out, ROOT))
        return
    with open(args.out, "w") as f:
        f.write(text)
    live = sum(r["needs_live_app"] for r in rows)
    print("rows\t%d\nneeds_live_app_true\t%d\nneeds_live_app_false\t%d\nout\t%s"
          % (len(rows), live, len(rows) - live, os.path.relpath(args.out, ROOT)))


if __name__ == "__main__":
    main()
