"""Write combined source recipes for the plug-in objects that the plug-in probe created.

Usage:
  combined-sources.py make PROBE.tsv OUT [--per-doc N] [--first K]
  combined-sources.py split RECIPE.json OUT

make reads the rows of PROBE.tsv whose status is `created` and writes OUT/recipes/<case>.json and
OUT/scripts/<case>.py for documents of at most N objects each (default 30). The documents hold
equal shares of the objects. Cases are plugin.combined.01, plugin.combined.02 and so on. The
objects are sorted by their largest extent, so small objects share a document and a small grid cell.

split writes two recipes that each hold one half of the objects of RECIPE.json. Their case ids end
in `a` and `b`. Split a half again to narrow a failing export down to one object.

PROBE.tsv columns: plugin, call, path, status, type, width, height, reason. call is CreateCustomObject,
CreateCustomObjectN or CreateCustomObjectPath. path is `open` or `closed` for CreateCustomObjectPath, and
empty for the other calls. width and height are the extent of the probe object in mm.
"""
import argparse
import csv
import hashlib
import json
import math
import os
import sys

CALLS = ("CreateCustomObject", "CreateCustomObjectN", "CreateCustomObjectPath")
PATHS = ("open", "closed")
CHANNELS = ["recipe", "source_original", "source_reopened", "native_state", "native_objects", "native_measurements"]
MARGIN = 1000.0
FIRST_LINE = "# Rosetta fixture recipe written by driver/inventory/combined-sources.py from the plug-in probe."


def read_probe(path):
    with open(path, newline="") as f:
        rows = [r for r in csv.DictReader(f, delimiter="\t") if r["status"] == "created"]
    plugins = []
    for r in rows:
        if r["call"] not in CALLS:
            sys.exit("combined-sources.py: %s has call %r" % (r["plugin"], r["call"]))
        p = {"plugin": r["plugin"], "call": r["call"], "width": float(r["width"] or 0), "height": float(r["height"] or 0)}
        if r["call"] == "CreateCustomObjectPath":
            if r.get("path") not in PATHS:
                sys.exit("combined-sources.py: %s has path %r" % (r["plugin"], r.get("path")))
            p["path"] = r["path"]
        plugins.append(p)
    return sorted(plugins, key=lambda p: (max(p["width"], p["height"]), p["plugin"]))


def cell_size(plugins):
    """Each object sits at the centre of a square cell twice its largest extent, so no two objects overlap."""
    return 2 * max([max(p["width"], p["height"]) for p in plugins] + [MARGIN]) + MARGIN


def operations(plugins, cell):
    ops = []
    columns = math.ceil(math.sqrt(len(plugins)))
    for n, p in enumerate(plugins):
        x = (n % columns + 0.5) * cell
        y = -(n // columns + 0.5) * cell
        bind = "o%02d" % n
        ops.append({"op": "call", "api": "vs.Layer", "args": ["pio-" + p["plugin"]]})
        ops.append({"op": "call", "api": "vs.NameClass", "args": ["pio-" + p["plugin"]]})
        if p["call"] == "CreateCustomObjectPath":
            half = cell / 4
            corners = [[x - half, y - half], [x + half, y - half], [x + half, y + half]]
            if p["path"] == "closed":
                corners.append([x - half, y + half])
            ops.append({"op": "call", "api": "vs.ClosePoly" if p["path"] == "closed" else "vs.OpenPoly", "args": []})
            ops.append({"op": "call", "api": "vs.BeginPoly", "args": []})
            ops += [{"op": "call", "api": "vs.AddPoint", "args": [c]} for c in corners]
            ops += [{"op": "call", "api": "vs.EndPoly", "args": []},
                    {"op": "create", "api": "vs.LNewObj", "args": [], "bind": "p%02d" % n, "name": None, "result": "return"},
                    {"op": "create", "api": "vs.CreateCustomObjectPath", "args": [p["plugin"], "$p%02d" % n, None],
                     "bind": bind, "name": "obj-%02d" % n, "result": "return"}]
        elif p["call"] == "CreateCustomObjectN":
            ops.append({"op": "create", "api": "vs.CreateCustomObjectN", "args": [p["plugin"], [x, y], 0, False],
                        "bind": bind, "name": "obj-%02d" % n, "result": "return"})
        else:
            ops.append({"op": "create", "api": "vs.CreateCustomObject", "args": [p["plugin"], [x, y], 0],
                        "bind": bind, "name": "obj-%02d" % n, "result": "return"})
    ops.append({"op": "save_reopen"})
    return ops


def recipe(case, plugins):
    cell = cell_size(plugins)
    names = ", ".join(p["plugin"] for p in plugins)
    return {
        "schema": "vwx-rosetta-recipe/1", "case_id": case, "family_id": "plugin.combined", "recipe_revision": "1",
        "universe": "controlled", "title": "%d plug-in objects, each on its own layer and class" % len(plugins),
        "mechanism": None, "blank_control": "control.blank.mm",
        "parameters": {"cell_mm": cell, "plugins": plugins},
        "native_verification": "unexecuted", "required_channels": CHANNELS, "extra_tags": [],
        "dependencies": [{"dependency_id": "plugin." + p["plugin"], "kind": "plugin_object", "acquisition_state": "acquired",
                          "reason": "The plug-in probe created it with vs.%s." % p["call"]} for p in plugins],
        "operations": operations(plugins, cell),
        "objects": [{"object_id": "obj-%02d" % n, "bind": "o%02d" % n, "role": "primary"} for n in range(len(plugins))],
        "queries": [{"object_id": "obj-%02d" % n, "quantity": "bounds3", "api": "vs.GetBBox", "frame": "document_world"}
                    for n in range(len(plugins))],
        "expected_relationships": [], "exclude_profiles": [],
        "notes": ["Object obj-NN is plugins[NN] of parameters. Its layer and its class are named pio- and the plug-in name, so an "
                  "export entity on that layer or class comes from that object.",
                  "Each object sits at the centre of a grid cell of cell_mm. A path object follows the path kind of "
                  "its probe row: an open path of three points or a closed square, inside its cell.",
                  "Plug-ins: " + names + "."],
    }


def value(v):
    if isinstance(v, bool) or v is None:
        return repr(v)
    if isinstance(v, str):
        return "h_" + v[1:] if v.startswith("$") else json.dumps(v)
    if isinstance(v, list):
        return "(" + ", ".join(value(x) for x in v) + ")"
    return repr(v)


def script(r, sha):
    out = [FIRST_LINE,
           "# case_id: " + r["case_id"],
           "# family_id: " + r["family_id"],
           "# recipe_revision: " + r["recipe_revision"],
           "# recipe_path: recipes/%s.json" % r["case_id"],
           "# recipe_sha256: " + sha,
           "# native_verification: unexecuted",
           "# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.",
           "import vs"]
    for o in r["operations"]:
        if o["op"] == "save_reopen":
            out.append("rosetta_save_reopen()")
            continue
        call = "%s(%s)" % (o["api"], ", ".join(value(a) for a in o["args"]))
        if o["op"] == "call":
            out.append(call)
            continue
        out.append("h_%s = %s" % (o["bind"], call))
        if o["name"] is not None:
            out.append("vs.SetName(h_%s, %s)" % (o["bind"], json.dumps(o["name"])))
    return "\n".join(out) + "\n"


def write(out, r):
    for d in ("recipes", "scripts"):
        os.makedirs(os.path.join(out, d), exist_ok=True)
    text = json.dumps(r, indent=2, ensure_ascii=True) + "\n"
    with open(os.path.join(out, "recipes", r["case_id"] + ".json"), "w") as f:
        f.write(text)
    with open(os.path.join(out, "scripts", r["case_id"] + ".py"), "w") as f:
        f.write(script(r, hashlib.sha256(text.encode()).hexdigest()))
    print("%s\t%d objects" % (r["case_id"], len(r["parameters"]["plugins"])))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)
    mk = sub.add_parser("make")
    mk.add_argument("probe")
    mk.add_argument("out")
    mk.add_argument("--per-doc", type=int, default=30)
    mk.add_argument("--first", type=int, default=1, help="number of the first case")
    sp = sub.add_parser("split")
    sp.add_argument("recipe")
    sp.add_argument("out")
    a = ap.parse_args()
    if a.command == "make":
        plugins = read_probe(a.probe)
        docs = math.ceil(len(plugins) / a.per_doc)
        size = math.ceil(len(plugins) / docs) if docs else 0
        for n in range(docs):
            write(a.out, recipe("plugin.combined.%02d" % (a.first + n), plugins[n * size:(n + 1) * size]))
    else:
        with open(a.recipe) as f:
            r = json.load(f)
        plugins = r["parameters"]["plugins"]
        if len(plugins) < 2:
            sys.exit("combined-sources.py: %s holds one object" % r["case_id"])
        half = (len(plugins) + 1) // 2
        write(a.out, recipe(r["case_id"] + "a", plugins[:half]))
        write(a.out, recipe(r["case_id"] + "b", plugins[half:]))


if __name__ == "__main__":
    main()
