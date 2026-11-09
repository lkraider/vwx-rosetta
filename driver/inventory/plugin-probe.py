#!/usr/bin/env python3
"""Write the scripts of the plug-in probe and join their rows.

Usage:
  plugin-probe.py scripts DIR [--per-doc N] [--plugins-dir PATH]
  plugin-probe.py join OUT_DIR CENSUS_DIR PROBE.tsv [--stopped STOPPED.tsv]

scripts writes DIR/probe.plugins.NN.py for each group of N installed .vso files (default 40).
make-sources.py --scripts-dir DIR --cases probe.plugins.01,... runs them. Each script tries
each create call on each plug-in, on a layer and a class named pio- and the plug-in name.
It keeps every object a call returns, under the name probe-NNN-K, and appends one row per
call to <document>.probe.tsv beside the document it saves. The row is written before the
next call starts, so a script that stops keeps the rows of the calls before it.

Vectorworks regenerates a plug-in object after the script ends, so its box reads 0 inside
the script. source-census.py --out-dir CENSUS_DIR probe.plugins.NN=OUT_DIR/probe.plugins.NN.vwx
records the boxes of the saved document.

join writes PROBE.tsv. For each plug-in it takes the first call, in the order below, whose
object has a nonzero box or 3D extent in the census: CreateCustomObjectN without the
preferences dialog, CreateCustomObjectPath with a closed path, CreateCustomObjectPath with
an open path, CreateCustomObject. Some plug-ins replace the object name with a GUID.
A call whose name is absent takes the next object of that plug-in on its pio- layer whose name
does not start with probe-. PROBE.tsv has the columns that combined-sources.py reads:
plugin, call, path, status, type, width, height, reason, then tries and document.

A plug-in that stops the script or the save leaves no saved document. STOPPED.tsv lists each one
with the columns plugin, status, reason and document, and join writes that row. status is
not_created when the create call failed, and unmeasured when it returned an object that no
saved document holds.
"""
import argparse
import glob
import json
import os
import sys

VOLUME = os.environ.get("ROSETTA_VOLUME", "/Volumes/volxxxx")
PLUGINS = VOLUME + "/Applications/Vectorworks 2027/Plug-Ins"
COLUMNS = ("plugin", "call", "path", "status", "type", "width", "height", "reason", "tries", "document")

BODY = '''import os

PLUGINS = %(plugins)r
FIRST = %(first)d
TSV = OUT[:-4] + ".probe.tsv"
CELL = 10000.0


def path(x, y, closed):
    vs.ClosePoly() if closed else vs.OpenPoly()
    vs.BeginPoly()
    corners = [(x - 2500, y - 2500), (x + 2500, y - 2500), (x + 2500, y + 2500)]
    if closed:
        corners.append((x - 2500, y + 2500))
    for c in corners:
        vs.AddPoint(c)
    vs.EndPoly()
    return vs.LNewObj()


def on_path(name, x, y, closed):
    poly = path(x, y, closed)
    h = vs.CreateCustomObjectPath(name, poly, None)
    if not h:
        vs.DelObject(poly)
    return h


def attempts(name, x, y):
    yield "CreateCustomObjectN", "", lambda: vs.CreateCustomObjectN(name, (x, y), 0, False)
    yield "CreateCustomObjectPath", "closed", lambda: on_path(name, x, y, True)
    yield "CreateCustomObjectPath", "open", lambda: on_path(name, x, y, False)
    yield "CreateCustomObject", "", lambda: vs.CreateCustomObject(name, (x, y), 0)


def write(row):
    with open(TSV, "a") as handle:
        handle.write("\\t".join(c.replace("\\t", " ").replace("\\n", " ") for c in row) + "\\n")


for n, name in enumerate(PLUGINS):
    x, y = (n %% 8) * CELL, -(n // 8) * CELL
    vs.Layer("pio-" + name)
    vs.NameClass("pio-" + name)
    for k, (call, kind, create) in enumerate(attempts(name, x, y)):
        try:
            h = create()
        except Exception as exc:
            write([name, call, kind, "", "error", "", (str(exc).splitlines() or [type(exc).__name__])[0][:120]])
            continue
        if not h:
            write([name, call, kind, "", "no handle", "", ""])
            continue
        obj = "probe-%%03d-%%d" %% (FIRST + n, k)
        vs.SetName(h, obj)
        write([name, call, kind, obj, "handle", str(vs.GetTypeN(h)), ""])
rosetta_save_reopen()
'''


def installed(plugins_dir):
    return sorted(os.path.basename(p)[:-4] for p in glob.glob(os.path.join(plugins_dir, "*.vso")))


def write_scripts(out, per_doc, plugins_dir):
    names = installed(plugins_dir)
    if not names:
        sys.exit("plugin-probe.py: no .vso file in %s" % plugins_dir)
    os.makedirs(out, exist_ok=True)
    cases = []
    for start in range(0, len(names), per_doc):
        case = "probe.plugins.%02d" % (start // per_doc + 1)
        with open(os.path.join(out, case + ".py"), "w") as handle:
            handle.write(BODY % {"plugins": names[start:start + per_doc], "first": start})
        cases.append(case)
    print("%d plug-ins in %d scripts" % (len(names), len(cases)))
    print(",".join(cases))


def extent(o):
    (x1, y1), (x2, y2) = o.get("bbox") or ((0, 0), (0, 0))
    width, height = round(abs(x2 - x1), 1), round(abs(y1 - y2), 1)
    if not (width or height):
        info = o.get("3dinfo") or (0, 0, 0)
        width, height = round(abs(info[1]), 1), round(abs(info[2]), 1)
    return width, height


def join(out_dir, census_dir, probe_tsv, stopped=None):
    rows = []
    if stopped:
        with open(stopped) as handle:
            for line in handle:
                if line.strip() and not line.startswith("plugin\t"):
                    plugin, status, reason, document = line.rstrip("\n").split("\t")
                    if status not in ("not_created", "unmeasured"):
                        sys.exit("plugin-probe.py: %s has status %r" % (plugin, status))
                    rows.append([plugin, "", "", status, "", "", "", reason, "", document])
    for tsv in sorted(glob.glob(os.path.join(out_dir, "probe.plugins.*.probe.tsv"))):
        document = os.path.basename(tsv)[:-len(".probe.tsv")]
        census = os.path.join(census_dir, document + ".json")
        if not os.path.exists(census):
            sys.exit("plugin-probe.py: no census %s" % census)
        with open(census) as handle:
            objects = {o["name"]: o for o in json.load(handle)["objects"]}
        tries = {}
        with open(tsv) as handle:
            for line in handle:
                if line.strip():
                    plugin, call, kind, obj, result, typ, error = (line.rstrip("\n").split("\t") + [""] * 7)[:7]
                    tries.setdefault(plugin, []).append((call, kind, obj, result, typ, error))
        for plugin, attempts in tries.items():
            notes, chosen = [], None
            renamed = [o for o in objects.values() if o.get("layer") == "pio-" + plugin
                       and o.get("plugin") == plugin and not o["name"].startswith("probe-")]
            for call, kind, obj, result, typ, error in attempts:
                label = call + ("/" + kind if kind else "")
                if result != "handle":
                    notes.append("%s: %s" % (label, error or result))
                    continue
                if obj in objects:
                    found, how = objects[obj], ""
                elif renamed:
                    found, how = renamed.pop(0), ", renamed by the plug-in"
                else:
                    notes.append("%s: type %s, gone after reopen" % (label, typ))
                    continue
                width, height = extent(found)
                notes.append("%s: type %s box %sx%s%s" % (label, found["type"], width, height, how))
                if chosen is None and (width or height):
                    chosen = [plugin, call, kind, "created", str(found["type"]), str(width), str(height), ""]
            row = chosen or [plugin, "", "", "not_created", "", "", "", "no call gave an object with a nonzero box"]
            rows.append(row + ["; ".join(notes), document])
    seen = set()
    for row in rows:
        if row[0] in seen:
            sys.exit("plugin-probe.py: %s has two rows" % row[0])
        seen.add(row[0])
    with open(probe_tsv, "w") as handle:
        handle.write("\t".join(COLUMNS) + "\n")
        for row in rows:
            handle.write("\t".join(row) + "\n")
    counts = {status: sum(1 for r in rows if r[3] == status) for status in ("created", "not_created", "unmeasured")}
    print("%d rows, %d created, %d not created, %d unmeasured" % (len(rows), counts["created"], counts["not_created"],
                                                                  counts["unmeasured"]))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("scripts")
    s.add_argument("dir")
    s.add_argument("--per-doc", type=int, default=40)
    s.add_argument("--plugins-dir", default=PLUGINS)
    j = sub.add_parser("join")
    j.add_argument("out_dir")
    j.add_argument("census_dir")
    j.add_argument("probe_tsv")
    j.add_argument("--stopped")
    args = parser.parse_args()
    if args.command == "scripts":
        write_scripts(args.dir, args.per_doc, args.plugins_dir)
    else:
        join(args.out_dir, args.census_dir, args.probe_tsv, args.stopped)


if __name__ == "__main__":
    main()
