#!/usr/bin/env python3
"""Write the stage-2 and stage-3 plans: one row per route and profile, in the route order of the batch brief.

Usage: build-stage2.py COVERING_SET.TSV [INVENTORY.TSV] > driver/batch/stage2.tsv
       build-stage2.py --stage3 COVERING_SET.TSV [INVENTORY.TSV] > driver/batch/stage3.tsv
       build-stage2.py --scripted COVERING_SET.TSV [INVENTORY.TSV] > driver/batch/stage2-scripted.tsv

The default writes the ui rows of the routes that tell the VWX data apart best. --stage3 writes the ui
rows of the STAGE3 routes, then the item 7 rows of stage1.tsv that set an active layer, for their rerun.
--scripted writes the scripted rows, which run without the front.

COVERING_SET.TSV has the columns case, route, profile, tier, status, reason. The rows with status
export, export-again-settings-differ and export-again-settings-unknown go into the plan. Rows with
status held or negative stay out. INVENTORY.TSV (default ledger/inventory.tsv) adds the planned IGES
pairs with profile iges.solids. The plugin.combined IGES cases wait for the item 7 result, so they stay out.

A row with an empty profile is refused with exit 2. batch.py writes a timeout row only for pairs
whose profile it knows.
"""
import csv
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXPORT = ("export", "export-again-settings-differ", "export-again-settings-unknown")
ORDER = ["dxf", "dwg", "stl", "obj", "fbx", "gltf", "ifc", "sat", "pdf", "3ds", "iges", "png", "vwx", "parasolid",
         "step"]
EXT = {"parasolid": "x_t", "iges": "igs"}
DRIVER = {"stl": "scripted"}
STAGE3 = ("png", "3ds", "fbx", "gltf", "iges")
STAGE1 = os.path.join(ROOT, "driver", "batch", "stage1.tsv")
COLUMNS = ["step", "driver", "format", "profile", "cases", "options", "expect", "ext"]


def pairs(covering, inventory):
    with open(covering) as f:
        for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
            if r["status"] in EXPORT:
                yield r["route"], r["profile"], r["case"]
    with open(inventory) as f:
        for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
            if r["kind"] == "pair" and r["status"] == "planned" and r["name"].startswith("iges: "):
                case = r["name"][len("iges: "):]
                if not case.startswith("plugin.combined."):
                    yield "iges", "iges.solids", case


def plan(covering, inventory):
    groups = {}
    for route, profile, case in pairs(covering, inventory):
        if not profile:
            raise SystemExit("refused: %s %s has no profile" % (route, case))
        if route not in ORDER:
            raise SystemExit("refused: route %s has no place in the stage-2 order" % route)
        cases = groups.setdefault((route, profile), [])
        if case not in cases:
            cases.append(case)
    rows = []
    for (route, profile), cases in sorted(groups.items(), key=lambda g: (ORDER.index(g[0][0]), g[0][1])):
        rows.append({"step": profile, "driver": DRIVER.get(route, "ui"), "format": route, "profile": profile,
                     "cases": ",".join(sorted(cases)), "options": "" if route in DRIVER else "--unlisted", "expect": "install",
                     "ext": EXT.get(route, route)})
    return rows


def item7_rows():
    with open(STAGE1) as f:
        return [r for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE)
                if r["step"].startswith("item7-") and "--active-layer" in r["options"]]


def main(argv):
    mode = "stage2"
    if argv[:1] in (["--scripted"], ["--stage3"]):
        mode, argv = argv[0][2:], argv[1:]
    if len(argv) not in (1, 2):
        raise SystemExit(__doc__)
    rows = plan(argv[0], argv[1] if len(argv) == 2 else os.path.join(ROOT, "ledger", "inventory.tsv"))
    if mode == "scripted":
        rows = [r for r in rows if r["driver"] == "scripted"]
    else:
        rows = [r for r in rows if r["driver"] == "ui" and (r["format"] in STAGE3) == (mode == "stage3")]
    if mode == "stage3":
        rows += item7_rows()
    sys.stdout.write("\t".join(COLUMNS) + "\n")
    for row in rows:
        sys.stdout.write("\t".join(row[c] for c in COLUMNS) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit as e:
        if isinstance(e.code, str) and e.code.startswith("refused:"):
            print(e.code, file=sys.stderr)
            sys.exit(2)
        raise
