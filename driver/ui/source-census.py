#!/usr/bin/env python3
"""Record the objects of Vectorworks documents and compare two records.

  source-census.py --out-dir DIR LABEL=PATH...
      Copies each document to DIR/work/LABEL.vwx, opens it in the running application, sends a
      program with `vwx native-script-send` that walks the layers, the groups and the symbol
      definitions, and writes DIR/LABEL.json. The copy is closed without a save.
  source-census.py --compare A B
      Prints `reproduces`, or `differs: ` and each difference. A and B are census files, or a case
      id that reads its record from driver/source-census.json.
  source-census.py --collect DIR
      Updates driver/source-census.json from DIR/CASE.stored.json for each case in
      driver/source-map.tsv, and from DIR/CASE.rerun.json for each other case. The entries of
      cases with no record in DIR stay as they are.
  source-census.py --check-hidden
      Exits 1 when a layer or a class that the script of a case hides reads visible in
      driver/source-census.json. A hidden layer or class with no census entry or no visibility
      value is listed, and fails once its case has an export in files/. The rows of
      driver/census-visibility-pinned.tsv are listed and pass until they gain a value. A pinned
      row with a value fails, so the file only shrinks. A case with no census entry passes when
      every layer and class its script hides is pinned.
"""
import argparse, collections, functools, importlib.util, json, os, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "driver"))
import vw_lock  # noqa: E402
TABLE = os.path.join(ROOT, "driver", "source-census.json")
SOURCE_MAP = os.path.join(ROOT, "driver", "source-map.tsv")
PINNED = os.path.join(ROOT, "driver", "census-visibility-pinned.tsv")

PROGRAM = r'''import json, os, vs
OUT = %(out)r
res = {'layers': [], 'objects': [], 'symdefs': [], 'names': [], 'classes': [], 'errors': []}

def t(label, fn):
    try:
        return fn()
    except Exception as e:
        res['errors'].append('%%s: %%r' %% (label, e))
        return None

def r(v):
    return [r(x) for x in v] if isinstance(v, (list, tuple)) else round(v, 6) if isinstance(v, float) else v

def row(h, layer, depth, container):
    typ = vs.GetTypeN(h)
    d = {'type': typ, 'name': vs.GetName(h), 'class': vs.GetClass(h), 'layer': layer,
         'depth': depth, 'container': container}
    d['bbox'] = t('GetBBox', lambda: r(vs.GetBBox(h)))
    d['3dinfo'] = t('Get3DInfo', lambda: r(vs.Get3DInfo(h)))
    if typ == 15:
        d['symbol'] = t('GetSymName', lambda: vs.GetSymName(h))
    if typ == 86:
        d['plugin'] = t('GetParametricRecord', lambda: vs.GetName(vs.GetParametricRecord(h)))
    return d

def walk(first, layer, depth, container, out):
    h = first
    while h:
        out.append(row(h, layer, depth, container))
        if vs.GetTypeN(h) == 11:
            walk(vs.FInGroup(h), layer, depth + 1, vs.GetName(h) or 'group', out)
        h = vs.NextObj(h)

res['fname'] = t('GetFName', vs.GetFName)
lay = vs.FLayer()
while lay:
    lname = vs.GetLName(lay)
    res['layers'].append({'name': lname, 'type': t('layer type', lambda: vs.GetObjectVariableInt(lay, 154)),
                          'elevation': t('GetLayerElevation', lambda: r(vs.GetLayerElevation(lay))),
                          'visibility': t('GetLVis', lambda: vs.GetLVis(lay))})
    walk(vs.FInLayer(lay), lname, 0, None, res['objects'])
    lay = vs.NextLayer(lay)
names = []
for i in range(1, int(vs.NameNum()) + 1):
    name = vs.NameList(i)
    if name:
        h = vs.GetObject(name)
        names.append([name, vs.GetTypeN(h) if h else None])
res['names'] = sorted(names)
res['classes'] = sorted(vs.ClassList(i) for i in range(1, int(vs.ClassNum()) + 1))
res['class_visibility'] = {c: t('GetCVis', lambda: vs.GetCVis(c)) for c in res['classes']}
sd = vs.FSymDef()
while sd:
    contents = []
    walk(vs.FInSymDef(sd), None, 1, vs.GetName(sd), contents)
    res['symdefs'].append({'name': vs.GetName(sd), 'type': vs.GetTypeN(sd), 'contents': contents})
    sd = vs.NextSymDef(sd)
tmp = OUT + '.tmp'
with open(tmp, 'w') as f:
    json.dump(res, f, indent=1, sort_keys=True)
os.replace(tmp, OUT)
'''


def make_sources():
    spec = importlib.util.spec_from_file_location("make_sources", os.path.join(ROOT, "driver", "ui", "make-sources.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def census(ms, pid, label, path, out_dir, log):
    work = os.path.join(out_dir, "work")
    os.makedirs(work, exist_ok=True)
    copy = os.path.join(work, label + ".vwx")
    shutil.copyfile(path, copy)
    os.chmod(copy, 0o644)
    result = os.path.join(out_dir, label + ".json")
    if os.path.exists(result):
        os.unlink(result)
    if not ms.close_document(pid, log):
        return "close failed"
    if ms.pause.paused_until():
        return "paused"
    subprocess.run(["open", "-g", "-a", ms.APP, copy], timeout=90)
    if not ms.wait_for(lambda: ms.modal(pid)["title"] == os.path.basename(copy) or None, tries=60):
        ms.settle(pid, log)
        if ms.modal(pid)["title"] != os.path.basename(copy):
            return "open failed: %s" % ms.modal(pid)
    program = os.path.join(work, label + ".census.py")
    with open(program, "w") as handle:
        handle.write(PROGRAM % {"out": result})
    code, out = ms.cli("native-script-send", "--pid", pid, "--expected-executable", ms.EXE,
                       "--program", program, "--operator-authorized", "--timeout-ms", "5000")
    done = ms.wait_for(lambda: os.path.exists(result), tries=60)
    ms.close_document(pid, log)
    return "ok" if done else "no census: %s" % out.strip().replace("\n", " ")[:200]


TOL = 1e-4


def objects(doc):
    rows = list(doc["objects"])
    for sd in doc["symdefs"]:
        rows += sd["contents"]
    return rows


def key(o):
    return (o["layer"], o["container"], o["depth"], o["type"], o.get("symbol"), o.get("plugin"))


def flat(v):
    if isinstance(v, list):
        for x in v:
            yield from flat(x)
    elif isinstance(v, (int, float)) and v is not None:
        yield float(v)


def delta(a, b):
    fa, fb = list(flat(a)), list(flat(b))
    if len(fa) != len(fb):
        return float("inf")
    return max((abs(x - y) for x, y in zip(fa, fb)), default=0.0)


def compare(a, b):
    out = []
    la = [(l["name"], l["type"], l["elevation"]) for l in a["layers"]]
    lb = [(l["name"], l["type"], l["elevation"]) for l in b["layers"]]
    if la != lb:
        out.append("layers %s -> %s" % ([l[0] for l in la], [l[0] for l in lb]))
    sa = sorted(s["name"] for s in a["symdefs"])
    sb = sorted(s["name"] for s in b["symdefs"])
    if sa != sb:
        out.append("symbol definitions %s -> %s" % (sa, sb))
    na = collections.Counter(tuple(n) for n in a["names"])
    nb = collections.Counter(tuple(n) for n in b["names"])
    if na != nb:
        out.append("names %s -> %s" % (sorted((na - nb).elements(), key=repr), sorted((nb - na).elements(), key=repr)))
    if a["classes"] != b["classes"]:
        out.append("classes %s -> %s" % (a["classes"], b["classes"]))
    ta = collections.Counter(o["type"] for o in objects(a))
    tb = collections.Counter(o["type"] for o in objects(b))
    if ta != tb:
        changed = sorted(set(ta) | set(tb))
        out.append("type counts " + ", ".join("type %d %d -> %d" % (t, ta[t], tb[t]) for t in changed if ta[t] != tb[t]))
        return out
    ga, gb = collections.defaultdict(list), collections.defaultdict(list)
    for o in objects(a):
        ga[key(o)].append(o)
    for o in objects(b):
        gb[key(o)].append(o)
    if set(ga) != set(gb) or any(len(ga[k]) != len(gb[k]) for k in ga):
        out.append("object placement differs (layer, container or depth)")
        return out
    names = classes = 0
    worst = (0.0, None)
    for k in ga:
        for x, y in zip(ga[k], gb[k]):
            names += x["name"] != y["name"]
            classes += x["class"] != y["class"]
            for field in ("bbox", "3dinfo"):
                d = delta(x[field], y[field])
                if d > worst[0]:
                    worst = (d, "%s of type %d %r" % (field, x["type"], x["name"]))
    if names:
        out.append("%d object names" % names)
    if classes:
        out.append("%d object classes" % classes)
    if worst[0] > TOL:
        out.append("%s by %g" % (worst[1], worst[0]))
    return out


def load(ref):
    if os.path.exists(ref):
        with open(ref) as handle:
            return json.load(handle)
    with open(TABLE) as handle:
        return json.load(handle)[ref]


def intended_hidden(case):
    """The layers and the classes that the script of the case hides, or None for a case with no script."""
    sys.path.insert(0, os.path.join(ROOT, "driver"))
    import recipe_intent
    script = recipe_intent.script_for(ROOT, case)
    if not os.path.exists(script):
        return None
    rec = recipe_intent.run(script)
    return ({l["name"] for l in rec.layers if l.get("hidden")},
            {name for name, c in rec.classes.items() if c.get("hidden")})


def scripted_cases():
    base = os.path.join(ROOT, "driver", "inventory", "scripts")
    return {name[:-len(".py")] for name in os.listdir(base) if name.endswith(".py")}


def exported(case):
    folder = os.path.join(ROOT, "files", case)
    return os.path.isdir(folder) and bool(os.listdir(folder))


def pinned_items(path=PINNED):
    with open(path, encoding="utf-8") as handle:
        rows = [line.rstrip("\n").split("\t") for line in handle if line.strip()]
    return {"%s: %s %s" % tuple(r[:3]) for r in rows[1:]}


def hidden_problems(table, intended, cases, exported=exported, pinned=frozenset()):
    """GetLVis and GetCVis read -1 for a hidden layer or class. A hidden layer or class with no
    census value is a problem once its case has an export in files/, unless it is pinned."""
    problems, unread = [], []
    for case in sorted(set(table) | set(cases)):
        hidden = intended(case)
        if hidden is None or not any(hidden):
            continue
        entry = table.get(case)
        items = ["%s: %s %s" % (case, kind, name) for kind, names in zip(("layer", "class"), hidden)
                 for name in sorted(names)]
        if entry is None and all(item in pinned for item in items):
            unread += [item + " pinned, no census entry" for item in items]
            continue
        if entry is None:
            if exported(case):
                problems.append("%s: no census entry, and an export in files/" % case)
            else:
                unread.append("%s: no census entry" % case)
            continue
        read = {"layer": {l["name"]: l.get("visibility") for l in entry["layers"]},
                "class": entry.get("class_visibility", {})}
        for kind, names in zip(("layer", "class"), hidden):
            for name in sorted(names):
                item = "%s: %s %s" % (case, kind, name)
                value = read[kind].get(name)
                if value is not None and item in pinned:
                    problems.append(item + " reads %r and is still pinned" % value)
                elif value is None and item in pinned:
                    unread.append(item + " pinned")
                elif value is None:
                    if exported(case):
                        problems.append(item + " has no visibility in the census, and an export in files/")
                    else:
                        unread.append(item + " has no visibility in the census")
                elif value != -1:
                    problems.append(item + " reads %r" % value)
    return problems, unread


def collect(directory, path=TABLE):
    """A case with no stored source takes the census of DIR/CASE.rerun.json, a make-sources.py
    document that is not in sources/."""
    with open(path) as handle:
        table = json.load(handle)
    updated = 0
    with open(SOURCE_MAP) as handle:
        stored = dict(line.rstrip("\n").split("\t")[:2] for line in handle if line.strip())
    for name in sorted(os.listdir(directory)):
        case, _, kind = name[:-len(".json")].rpartition(".")
        if not name.endswith(".json") or kind not in ("stored", "rerun"):
            continue
        if (kind == "stored") != (case in stored):
            continue
        with open(os.path.join(directory, name)) as record:
            found = json.load(record)
        found.pop("fname", None)
        found["document"] = stored[case] if kind == "stored" else "make-sources.py rerun, not stored"
        table[case] = found
        updated += 1
    with open(path, "w") as handle:
        json.dump(table, handle, indent=1, sort_keys=True)
        handle.write("\n")
    print("wrote %s: %d cases, %d updated" % (os.path.relpath(path, ROOT), len(table), updated))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir")
    parser.add_argument("--compare", nargs=2, metavar=("A", "B"))
    parser.add_argument("--collect", metavar="DIR")
    parser.add_argument("--check-hidden", action="store_true")
    parser.add_argument("documents", nargs="*", help="LABEL=PATH")
    args = parser.parse_args()
    if args.compare:
        diff = compare(*(load(ref) for ref in args.compare))
        print("differs: " + "; ".join(diff) if diff else "reproduces")
        return 0
    if args.collect:
        collect(args.collect)
        return 0
    if args.check_hidden:
        with open(TABLE) as handle:
            problems, unread = hidden_problems(json.load(handle), intended_hidden, scripted_cases(),
                                             pinned=pinned_items())
        for problem in problems:
            print("hidden in the script: " + problem)
        for item in unread:
            print("unread: " + item)
        print("%d problems, %d unread" % (len(problems), len(unread)))
        return 1 if problems else 0
    if not args.out_dir or not args.documents:
        parser.error("a census needs --out-dir and at least one LABEL=PATH")
    with vw_lock.held("source-census.py --out-dir " + args.out_dir):
        return run_census(args)


def run_census(args):
    ms = make_sources()
    driver = ms.run_provenance.require(ROOT, binaries=sorted({ms.CLI, ms.vw_memory.CLI}))
    os.makedirs(args.out_dir, exist_ok=True)
    with open(os.path.join(args.out_dir, "provenance.json"), "w") as handle:
        json.dump(driver, handle, indent=1, sort_keys=True)
    print("driver\t%s\t%s" % (driver["commit"], driver["branch"]))
    pid = ms.live_pid()
    failed = 0
    close = functools.partial(ms.close_document, log=[])
    for item in args.documents:
        label, path = item.split("=", 1)
        try:
            pid = ms.vw_memory.before_row(None, close) or pid
            status = census(ms, pid, label, path, args.out_dir, [])
            pid = ms.vw_memory.after_source(path, None, close) or pid
        except (ms.pause.Paused, RuntimeError) as exc:
            status = "vw_memory: %s" % exc
        print("%s	%s" % (label, status))
        sys.stdout.flush()
        failed += status != "ok"
    try:
        ms.vw_memory.end_of_batch(None, close)
    except (ms.pause.Paused, RuntimeError) as exc:
        print("vw_memory end of batch: %s" % exc)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
