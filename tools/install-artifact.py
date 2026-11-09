"""Install one re-exported artifact into files/<case>/ when it has strictly more content than the store file.

Usage: install-artifact.py --measure MEASURE --replaced TSV [--retire-dir DIR] [--store ROOT] [--source-changed]
       [--install-held CASE:PROFILE,...] [--apply] RECORD...

RECORD is a run record that an evidence copy of driver/ui/sweep-ui.py wrote outside the store,
at <evidence>/runs/<run_id>/records/<case>.<profile>.json, with status ok. Its `path` names the
exported file, absolute or relative to the store, and its `sidecars` name files beside it. A record
whose `path` names the store file itself is refused.

MEASURE is a program that takes file paths and prints one line per path with the columns path,
format, count, ok, fact. tools/measure.py is that program. The store file and the new file are
measured with it. An .ifc file is measured here, and its count is the number of element entities. An .igs
file is measured here, and its count is the number of surface and solid entities.

The action is `install` when the new count is above 0 and above the store count. An absent store
file counts 0. The action is `keep` otherwise. With --source-changed, a record whose source_sha256 differs from
the newest ledger line of the pair is exported from a regenerated source. Its action is `install` when the new
count is above 0 and at least the store count, and `hold` when it is below the store count. A held pair is
left for a person to judge. --install-held installs the held pairs it names, each as CASE:PROFILE, after that
person agrees. A record whose profile_revision is above the revision of the newest ledger line of the pair, and
whose source_sha256 equals that line, comes from changed profile settings. Its action is `install` when the new count is above 0, and the store file moves into
--retire-dir, which such an install requires. A ledger line with no profile_revision counts as revision 1. The action is `refuse` when the store file exists
and the newest ledger line of the pair disagrees with it on path, bytes or sha256, when the record
status is other than ok, or when the evidence file is absent.

With --apply an install does the steps below.
- Copies the file and its sidecars into STORE/files/<case>/ through a staged file and os.replace.
- Moves sidecars named by the newest ledger line of the pair and absent from the new record into
  --retire-dir.
- Copies the evidence run's pre/ programs and driver/ copy into STORE/runs/<run_id>/.
- Writes STORE/runs/<run_id>/records/<case>.<profile>.json with the store paths. Its `path` is
  relative to STORE.
- Appends one line to STORE/ledger/corpus-ledger.jsonl. The newest line of a pair is the one
  that counts. Its `path` is relative to STORE. It carries the profile_revision of the record and, after a
  profile revision install, the previous_profile_revision.
- Appends one row to TSV with old and new count, bytes and sha256.
Every record and line carries a `provenance` note with the evidence record and the old values.

Before the count, driver/output-check.py of the store checks the new file under --check-python, which
needs ezdxf, dwgread and qpdf. Default: $ROSETTA_READER_PYTHON, else this Python. The action is `refuse`
when its verdict is fail or unread. Fail means the file is empty, its reader rejects it or raises, or it holds
no source object. Unread means output-check.py has no reader for the format, for example PNG, VWX and STEP. A
partial verdict installs with `content` partial and the `missing` plug-ins in the record and the ledger
line. The record keeps `status` ok, because verify-artifacts.py counts a record with any other status as
a failed run. The record and the ledger line carry the `output_check` row.

The ledger lines of backfill-20261015 carry an empty profile. A pair with no line under its profile
uses the newest line of its case and format with an empty profile.

Exit status 1 when any record is refused.
"""
import argparse, hashlib, json, os, re, shutil, subprocess, sys, tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "driver"))
from store_path import relative, resolve  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--measure", required=True)
ap.add_argument("--replaced", required=True)
ap.add_argument("--retire-dir")
ap.add_argument("--store", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ap.add_argument("--source-changed", action="store_true")
ap.add_argument("--install-held", default="", metavar="CASE:PROFILE,...")
ap.add_argument("--apply", action="store_true")
ap.add_argument("--check-python", default=os.environ.get("ROSETTA_READER_PYTHON", sys.executable))
ap.add_argument("records", nargs="+")
args = ap.parse_args()
held_approved = {tuple(p.split(":", 1)) for p in args.install_held.split(",") if p}
STORE = args.store
LEDGER = os.path.join(STORE, "ledger", "corpus-ledger.jsonl")
HEADER = ("case\tprofile\tformat\tstore_path\tnew_source\told_count\tnew_count\told_bytes\tnew_bytes"
          "\told_sha256\tnew_sha256\trun_id\taction\tnew_fact\n")


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


IFC_ENTITY = re.compile(r"^#\d+= *(IFC[A-Z]+)\('[0-9A-Za-z_$]{22}',#\d+,", re.M)
IFC_NOT_ELEMENT = re.compile(
    r"^IFC(REL|ACTOR|PROPERTYSET|ELEMENTQUANTITY|PROJECT$|SITE|BUILDING$|BUILDINGSTOREY|OPENINGELEMENT)|(TYPE|STYLE|PROPERTIES)$")


def measure_ifc(path):
    """The count is the number of element entities: rooted entities other than the project, the site, the
    building, the storeys, the relations, the property sets, the actors, the types and the openings."""
    with open(path, errors="replace") as f:
        text = f.read()
    kinds = {}
    for kind in IFC_ENTITY.findall(text):
        if not IFC_NOT_ELEMENT.search(kind):
            kinds[kind] = kinds.get(kind, 0) + 1
    schema = re.search(r"FILE_SCHEMA\(\('([^']*)'", text)
    count = sum(kinds.values())
    return count, "elements=%d schema=%s %s" % (count, schema.group(1) if schema else "unknown",
                                                " ".join("%s=%d" % kv for kv in sorted(kinds.items())))


IGES_SURFACES_AND_SOLIDS = {108, 114, 118, 120, 122, 128, 140, 143, 144, 150, 152, 154, 156, 158, 160, 162,
                            164, 168, 180, 184, 186, 190, 192, 194, 196, 198, 510, 514}


def iges_types(path):
    """Entity type of each directory entry. Each entry is two lines with D in column 73, and the type is in
    columns 1-8 of the first line. A first line with no number there is skipped, as facts_iges in
    driver/ui/audit-corpus.py skips it."""
    with open(path, errors="replace") as f:
        lines = [line for line in f if line[72:73] == "D"]
    return [int(line[:8]) for line in lines[::2] if line[:8].strip().isdigit()]


def measure_iges(path):
    """The count is the number of surface and solid entities, the types in IGES_SURFACES_AND_SOLIDS. Vectorworks
    can write a NURBS surface as type 128 or 144 with no type 510 face."""
    kinds = {}
    for kind in iges_types(path):
        kinds[kind] = kinds.get(kind, 0) + 1
    count = sum(n for kind, n in kinds.items() if kind in IGES_SURFACES_AND_SOLIDS)
    return count, "surfaces_and_solids=%d faces=%d solids=%d entities=%d %s" % (
        count, kinds.get(510, 0), kinds.get(186, 0), sum(kinds.values()),
        " ".join("%d=%d" % kv for kv in sorted(kinds.items())))


IN_PROCESS = {".ifc": measure_ifc, ".igs": measure_iges}


def measure(paths):
    got = {p: IN_PROCESS[os.path.splitext(p)[1].lower()](p) for p in paths
           if os.path.splitext(p)[1].lower() in IN_PROCESS}
    paths = [p for p in paths if p not in got]
    if not paths:
        return got
    out = subprocess.run([sys.executable, "-I", args.measure] + paths, capture_output=True, text=True, check=True)
    for line in out.stdout.splitlines():
        p, _fmt, count, _ok, fact = line.split("\t", 4)
        got[p] = (int(count), fact)
    return got


def output_check(path, record):
    out = subprocess.run([args.check_python, "-I", os.path.join(STORE, "driver", "output-check.py"),
                          "%s=%s" % (path, os.path.abspath(record))], capture_output=True, text=True)
    lines = out.stdout.splitlines()
    if len(lines) != 2:
        return {"verdict": "fail", "detail": "output-check.py exit %d: %s" % (out.returncode, out.stderr.strip()[-200:])}
    return dict(zip(lines[0].split("\t"), lines[1].split("\t")))


def newest_line(case, profile, fmt):
    found = backfill = None
    with open(LEDGER) as f:
        for line in f:
            if line.strip():
                r = json.loads(line)
                if (r.get("case"), r.get("profile"), r.get("format")) == (case, profile, fmt):
                    found = r
                elif (r.get("case"), r.get("profile"), r.get("format")) == (case, "", fmt):
                    backfill = r
    return found or backfill


def revision(value):
    return int(value) if value else 1


def stage_copy(src, dest):
    fd, staged = tempfile.mkstemp(dir=os.path.dirname(dest), prefix=".install-")
    os.close(fd)
    shutil.copyfile(src, staged)
    os.chmod(staged, 0o644)
    os.replace(staged, dest)


def write_atomic(path, text, mode=0o644):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".install-")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def store_path(p, ev_run, run_dir):
    """Map a path inside the evidence run directory to the same path inside the store run directory."""
    if isinstance(p, str) and p.startswith(ev_run + os.sep):
        return os.path.join(run_dir, os.path.relpath(p, ev_run))
    return p


if not os.path.exists(args.replaced):
    with open(args.replaced, "w") as f:
        f.write(HEADER)
refused = []
for rp in args.records:
    rec = json.load(open(rp))
    case, profile, fmt, run_id = rec.get("case"), rec.get("profile"), rec.get("format"), rec.get("run_id")
    tag = "%s %s" % (case, profile)
    # The evidence copy of sweep-ui.py sets its ROOT to the store, so a relative `path` or `source`
    # in its record is relative to the store.
    new = resolve(rec.get("path"), STORE) or ""
    if rec.get("status") != "ok" or not os.path.isfile(new):
        refused.append("%s: record status %s, file %s" % (tag, rec.get("status"), new))
        continue
    ev_run = os.path.dirname(os.path.dirname(os.path.abspath(rp)))
    if os.path.basename(ev_run) != run_id:
        refused.append("%s: record sits in %s, run_id is %s" % (tag, ev_run, run_id))
        continue
    dest_dir = os.path.join(STORE, "files", case)
    sp = os.path.join(dest_dir, os.path.basename(new))
    if os.path.abspath(new) == os.path.abspath(sp):
        refused.append("%s: record path %s is the store file" % (tag, new))
        continue
    line = newest_line(case, profile, fmt)
    old_bytes = old_sha = "-"
    if os.path.isfile(sp):
        old_bytes, old_sha = os.path.getsize(sp), sha(sp)
        if not line or (resolve(line.get("path"), STORE), line.get("bytes"), line.get("sha256")) != (sp, old_bytes, old_sha):
            refused.append("%s: newest ledger line disagrees with %s" % (tag, sp))
            continue
    checked = output_check(new, rp)
    if checked["verdict"] in ("fail", "unread"):
        refused.append("%s: output check %s: %s" % (tag, checked["verdict"], checked.get("detail")))
        continue
    checked = {k: checked.get(k, "") for k in ("verdict", "reader", "objects", "missing", "settings", "alerts", "detail")}
    partial = {"content": "partial", "missing": checked["missing"].split(",")} if checked["verdict"] == "partial" else {}
    m = measure([new] + ([sp] if os.path.isfile(sp) else []))
    new_count, new_fact = m[new]
    old_count = m[sp][0] if sp in m else 0
    action = "install" if new_count > 0 and new_count > old_count else "keep"
    if args.source_changed and line and line.get("source_sha256") != rec.get("source_sha256") and new_count > 0:
        approved = (case, profile) in held_approved
        action = "install" if new_count >= old_count or approved else "hold"
    old_rev = revision((line or {}).get("profile_revision"))
    new_rev = revision(rec.get("profile_revision"))
    revised = (bool(line) and new_rev > old_rev and new_count > 0
               and line.get("source_sha256") == rec.get("source_sha256"))
    if revised:
        action = "install"
        if not args.retire_dir:
            refused.append("%s: profile revision %d replaces %d and needs --retire-dir" % (tag, new_rev, old_rev))
            continue
    nsha, nbytes = sha(new), os.path.getsize(new)
    print("%s\t%s\told=%s\tnew=%s\t%s" % (tag, action, old_count, new_count, new_fact))
    if not args.apply or action != "install":
        if args.apply:
            with open(args.replaced, "a") as f:
                f.write("\t".join(str(x) for x in (case, profile, fmt, sp, new, old_count, new_count, old_bytes,
                                                     nbytes, old_sha, nsha, run_id, action, new_fact)) + "\n")
        continue

    os.makedirs(dest_dir, exist_ok=True)
    retired_file = None
    if revised and os.path.isfile(sp):
        os.makedirs(os.path.join(args.retire_dir, case), exist_ok=True)
        retired_file = os.path.join(args.retire_dir, case, os.path.basename(sp))
        shutil.copyfile(sp, retired_file)
        assert sha(retired_file) == old_sha
    stage_copy(new, sp)
    assert sha(sp) == nsha
    sidecars = list(rec.get("sidecars") or [])
    for name in sidecars:
        stage_copy(os.path.join(os.path.dirname(new), name), os.path.join(dest_dir, name))
    retired = []
    for name in (line or {}).get("sidecars") or []:
        path = os.path.join(dest_dir, name)
        if name not in sidecars and os.path.basename(name) == name and os.path.isfile(path) and args.retire_dir:
            os.makedirs(os.path.join(args.retire_dir, case), exist_ok=True)
            shutil.move(path, os.path.join(args.retire_dir, case, name))
            retired.append(name)

    run_dir = os.path.join(STORE, "runs", run_id)
    os.makedirs(os.path.join(run_dir, "records"), exist_ok=True)
    for sub in ("pre", "driver"):
        src_dir = os.path.join(ev_run, sub)
        if os.path.isdir(src_dir):
            os.makedirs(os.path.join(run_dir, sub), exist_ok=True)
            for name in sorted(os.listdir(src_dir)):
                if os.path.isfile(os.path.join(src_dir, name)):
                    shutil.copyfile(os.path.join(src_dir, name), os.path.join(run_dir, sub, name))
    pre = rec.get("pre_export")
    if pre:
        pre = dict(pre)
        tmpl = os.path.join(run_dir, "pre", case + ".template.py")
        shutil.copyfile(pre["template"], tmpl)
        pre.update(template=tmpl, program=store_path(pre["program"], ev_run, run_dir),
                   result=store_path(pre["result"], ev_run, run_dir))
    ext = os.path.splitext(new)[1].lower()
    measurer = "%s in tools/install-artifact.py" % IN_PROCESS[ext].__name__ if ext in IN_PROCESS else args.measure
    text = ("installed with tools/install-artifact.py from %s, measured by %s: %s. Previous count %s bytes %s"
            " sha256 %s" % (rp, measurer, new_fact, old_count, old_bytes, old_sha))
    if revised:
        text += ". Profile revision %d replaces %d" % (new_rev, old_rev)
        if retired_file:
            text += ", previous file kept at %s" % retired_file
    if line and line.get("provenance"):
        text += ". Previous provenance: " + line["provenance"]
    source = relative(resolve(rec["source"], STORE), STORE) if rec.get("source") else rec.get("source")
    rec.update(path=relative(sp, STORE), source=source, origin_path=new, retired_sidecars=retired, provenance=text,
               output_check=checked, **partial)
    if pre:
        rec["pre_export"] = pre
    write_atomic(os.path.join(run_dir, "records", "%s.%s.json" % (case, profile)), json.dumps(rec, indent=1))

    entry = None
    ev_ledger = os.path.join(os.path.dirname(os.path.dirname(ev_run)), "out", "ledger-lines.jsonl")
    if os.path.isfile(ev_ledger):
        for raw in open(ev_ledger):
            if raw.strip():
                r = json.loads(raw)
                if (r.get("run_id"), r.get("case"), r.get("profile")) == (run_id, case, profile):
                    entry = r
    if entry is None:
        entry = {"ts": rec.get("ts"), "run_id": run_id, "case": case, "format": fmt, "profile": profile}
    entry.update(path=relative(sp, STORE), bytes=nbytes, sha256=nsha, sidecars=sidecars, origin_path=new,
                 source=source, source_sha256=rec.get("source_sha256"), provenance=text, output_check=checked,
                 **partial)
    if rec.get("profile_revision"):
        entry["profile_revision"] = rec["profile_revision"]
    if revised:
        entry["previous_profile_revision"] = str(old_rev)
    if pre:
        entry["pre_export"] = pre
    body = open(LEDGER).read()
    if body and not body.endswith("\n"):
        body += "\n"
    write_atomic(LEDGER, body + json.dumps(entry) + "\n", os.stat(LEDGER).st_mode & 0o7777)
    with open(args.replaced, "a") as f:
        f.write("\t".join(str(x) for x in (case, profile, fmt, sp, new, old_count, new_count, old_bytes,
                                             nbytes, old_sha, nsha, run_id, action, new_fact)) + "\n")
for r in refused:
    print("refused " + r, file=sys.stderr)
sys.exit(1 if refused else 0)
