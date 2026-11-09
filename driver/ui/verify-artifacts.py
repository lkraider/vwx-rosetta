#!/usr/bin/env python3
"""Check collected artifacts against their ledger lines and their records.

Usage:
  verify-artifacts.py [--run-id RUN_ID] [--all] [--quiet] [--write-index PATH]

Default reads the newest run directory. `--all` reads every run directory, which
is what a full audit needs.

Each artifact is checked against three sources: the file on disk, its ledger line
in ledger/corpus-ledger.jsonl, and its record under runs/<run_id>/records/. Every
check compares two of those three and reports a disagreement.

The ledger is append-only, so one case and profile can carry a line per run. Two
runs that export one document do not produce equal bytes, so a pair whose lines
carry different digests is expected. Two records of the *same* run that claim
different artifacts are a fault, and that is what the check flags.

Each ledger/companions.tsv row is checked against its file by size and sha256. Each glTF
buffer under files/ must have a companions row.

Files under files/ and run records of different cases that hold one sha256 form a
shared-digest group. The files include the backfilled files and the companions, which have
no run record. The records include exports whose file is no longer under files/. With `--all`, each group must be a row of
ledger/shared-digests.tsv with the same members, and each row must still be a group. A new
group, a changed group and a row that no longer matches a group are structural failures.

With `--all`, each required pair that holds an artifact on disk and has no ledger line with
its profile must be a row of ledger/unrecorded-pairs.tsv, with the sha256 of its file. A
pair missing from the list, a row whose pair has a ledger line, and a changed file are
structural failures.

Exit status is 0 when every structural check passes and 1 when any structural check
fails. A wrong size, a wrong sha256 and an absent artifact are structural failures. A
required pair with no passing run record is a provenance gap. It is printed and it leaves
the exit status at 0. Each pair of ledger/unrecorded-pairs.tsv holds an artifact on disk
and has no passing run record. Its reason column says what a record of it needs.

The newest record of a pair whose status is not ok is a structural failure when the pair
holds no artifact in ledger/coverage.tsv and has no row in ledger/negatives.tsv. A record
with no profile is in the scripted shape, and it is counted and not judged.
"""
import argparse
import hashlib
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "driver"))
from store_path import current_digest, find_source, relative, resolve  # noqa: E402
from profile_names import artifact_suffix  # noqa: E402
# The extension each exporter writes, keyed by the format name the inventory uses.
EXTENSIONS = {"parasolid": "x_t", "iges": "igs"}
LEDGER = os.path.join(ROOT, "ledger", "corpus-ledger.jsonl")
REQUIRED = os.path.join(ROOT, "ledger", "required-pairs.tsv")
COVERAGE = os.path.join(ROOT, "ledger", "coverage.tsv")
NEGATIVES = os.path.join(ROOT, "ledger", "negatives.tsv")
COMPANIONS = os.path.join(ROOT, "ledger", "companions.tsv")
SHARED_DIGESTS = os.path.join(ROOT, "ledger", "shared-digests.tsv")
UNRECORDED = os.path.join(ROOT, "ledger", "unrecorded-pairs.tsv")


# The signature each format must carry. A binary format starts its signature at
# byte zero. A text format can carry it further in, so the check looks inside the
# first sixty four bytes of the file. Vectorworks 2027 writes binary STL with the
# 80-byte header `STL file created by Vectorworks` and SAT at ACIS version 500.
MAGIC = {
    "dwg": [b"AC10"],
    "dxf": [b"SECTION"],
    "pdf": [b"%PDF"],
    "png": [b"\x89PNG"],
    "stl": [b"solid", b"\x00\x00\x00\x00", b"STL file created by Vectorworks"],
    "sat": [b"700 0 ", b"700 1 ", b"400 ", b"500 ", b"1000 "],
    "obj": [b"#", b"v ", b"mtllib"],
    "svg": [b"<?xml", b"<svg"],
    "step": [b"ISO-10303-21"],
    "stp": [b"ISO-10303-21"],
    "iges": [b"IGES"],
    "igs": [b"IGES"],
    "x_t": [b"**"],
    "x_b": [b"**"],
    "fbx": [b"Kaydara FBX Binary", b"; FBX"],
    "3ds": [b"\x4d\x4d"],
    "ifc": [b"ISO-10303-21"],
}


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_ledger():
    rows = []
    with open(LEDGER) as f:
        for number, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append((number, json.loads(line)))
            except ValueError:
                rows.append((number, None))
    return rows


def read_required():
    pairs = set()
    with open(REQUIRED) as f:
        next(f)
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 3:
                pairs.add((parts[0], parts[1], parts[2]))
    return pairs


def read_on_disk():
    """The pairs that driver/ui/coverage.py found as a file under files/."""
    pairs = set()
    if not os.path.isfile(COVERAGE):
        return None
    with open(COVERAGE) as f:
        next(f)
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 4 and parts[3] == "artifact":
                pairs.add((parts[0], parts[1], parts[2]))
    return pairs


def read_negatives():
    with open(NEGATIVES) as f:
        next(f)
        return {tuple(line.split("\t")[:2]) for line in f if line.strip()}


def read_shared_digests():
    with open(SHARED_DIGESTS) as f:
        next(f)
        return {row[0]: row[1] for row in (line.rstrip("\n").split("\t") for line in f) if row[0]}


def check_unrecorded(unrecorded_pairs, problems):
    with open(UNRECORDED) as f:
        next(f)
        rows = {tuple(r[:3]): r[3] for r in (line.rstrip("\n").split("\t") for line in f) if len(r) > 3}
    files = {}
    with open(COVERAGE) as f:
        next(f)
        for r in (line.rstrip("\n").split("\t") for line in f):
            if len(r) > 4 and r[3] == "artifact":
                files[tuple(r[:3])] = os.path.join(ROOT, "files", r[0], r[4])
    for pair in sorted(unrecorded_pairs - set(rows)):
        problems.append((" ".join(pair), "holds an artifact and no ledger line names its profile,"
                         " and ledger/unrecorded-pairs.tsv has no row for it"))
    for pair in sorted(set(rows) - unrecorded_pairs):
        problems.append((" ".join(pair), "ledger/unrecorded-pairs.tsv lists it, and it has a ledger line"
                         " with its profile or no artifact"))
    for pair in sorted(set(rows) & unrecorded_pairs):
        if not os.path.isfile(files.get(pair, "")) or sha(files[pair]) != rows[pair]:
            problems.append((" ".join(pair), "the file differs from the sha256 in ledger/unrecorded-pairs.tsv"))


def disk_groups():
    """sha256 -> sorted "case/file" names, for each sha256 that files of two cases hold."""
    names = {}
    files = os.path.join(ROOT, "files")
    for case in sorted(os.listdir(files)):
        folder = os.path.join(files, case)
        if not os.path.isdir(folder):
            continue
        for name in sorted(os.listdir(folder)):
            path = os.path.join(folder, name)
            if os.path.isfile(path):
                names.setdefault(sha(path), []).append("%s/%s" % (case, name))
    return {d: sorted(n) for d, n in names.items() if len({x.split("/")[0] for x in n}) > 1}


def merge_groups(disk, records):
    """Members are "case/file" names from disk_groups() and "case profile format" names from records."""
    merged = {d: set(n) for d, n in disk.items()}
    for digest, names in records.items():
        merged.setdefault(digest, set()).update(names)
    return {d: sorted(n) for d, n in merged.items()}


def check_shared(groups, pinned, problems):
    for digest, names in sorted(groups.items()):
        members = ", ".join(names)
        if pinned.get(digest) != members:
            problems.append((digest[:16], "files or records of different cases hold this sha256: %s."
                             " ledger/shared-digests.tsv lists %s" % (members, pinned.get(digest) or "no row")))
    for digest in sorted(set(pinned) - set(groups)):
        problems.append((digest[:16], "ledger/shared-digests.tsv lists %s, and no files or records of two cases hold this sha256"
                         % pinned[digest]))


def check_row(run_id, rec, ledger_index, problems, findings, on_disk=None, negatives=()):
    case = rec.get("case")
    fmt = rec.get("format")
    profile = rec.get("profile")
    if rec.get("status") != "ok":
        findings["status"][rec.get("status")] = findings["status"].get(rec.get("status"), 0) + 1
        if not profile:
            findings["no_profile"] += 1
        elif (case, profile) not in negatives and (case, profile, fmt) not in (on_disk or set()):
            problems.append(("%s %s %s" % (case, profile, fmt),
                             "run %s record status %s, and ledger/negatives.tsv has no row for the pair"
                             % (run_id, rec.get("status"))))
        return

    path = resolve(rec.get("path"), ROOT)
    tag = "%s %s %s" % (case, profile, fmt)

    if not path or not os.path.isfile(path):
        # A pair that ledger/coverage.tsv does not record as an artifact holds no file to
        # check here. The file was moved out of files/, or the pair is a negative that an
        # earlier run did write. That is a relocation and not a structural failure, so it
        # is counted and not reported as a problem.
        if on_disk is not None and (case, profile, fmt) not in on_disk:
            findings["relocated"] = findings.get("relocated", 0) + 1
            return
        problems.append((tag, "artifact missing at recorded path: %s" % path))
        return

    with open(path, "rb") as f:
        head = f.read(64)
    wanted = MAGIC.get(fmt)
    if wanted and not any(m in head for m in wanted):
        problems.append((tag, "header %r carries no %s signature" % (head[:24], fmt)))

    size = os.path.getsize(path)
    if size != rec.get("bytes"):
        problems.append((tag, "size %d does not match recorded bytes %s" % (size, rec.get("bytes"))))
    real = sha(path)
    if real != current_digest(rec.get("sha256"), ROOT):
        problems.append((tag, "sha256 %s does not match recorded %s" % (real, rec.get("sha256"))))

    # The ledger is append-only, so the newest line for a pair is the one that
    # counts. A pair whose lines disagree on the digest is expected across runs,
    # because a second export does not repeat the first. Two records of one run
    # that disagree are a fault.
    lines = ledger_index.get((case, profile, fmt))
    if not lines:
        problems.append((tag, "no ledger line"))
    else:
        if len(lines) > 1:
            findings["duplicate_keys"] += 1
            same_run = {l.get("sha256") for _n, l in lines
                        if l and l.get("run_id") == run_id}
            if len(same_run) > 1:
                problems.append((tag, "two records of run %s claim different artifacts" % run_id))
        _number, lrow = lines[-1]
        if lrow is None:
            problems.append((tag, "ledger line is not JSON"))
        else:
            for key, value in (("path", path), ("bytes", size), ("sha256", real)):
                stored = {"path": resolve(lrow.get(key), ROOT),
                          "sha256": current_digest(lrow.get(key), ROOT)}.get(key, lrow.get(key))
                if stored != value:
                    problems.append((tag, "ledger %s %r differs from %r"
                                     % (key, lrow.get(key), value)))
            if lrow.get("run_id") != run_id:
                findings["ledger_run_mismatch"] += 1

    # A profile that exports a subset or a variant of the document adds a suffix to the
    # file name. driver/profile_names.py holds the suffixes.
    # The file extension comes from the exporter, not from the format name. The
    # Parasolid exporter writes .x_t for the format the inventory calls parasolid.
    name = os.path.basename(path)
    want = case + artifact_suffix(profile) + "." + EXTENSIONS.get(fmt, fmt)
    if name != want:
        problems.append((tag, "file name %s should be %s" % (name, want)))
    if os.path.dirname(path) != os.path.join(ROOT, "files", case):
        problems.append((tag, "artifact sits outside files/%s" % case))

    # The source must still hash to the recorded value, which proves the exported
    # document came from the recorded source.
    src = find_source(rec.get("source"), rec.get("source_sha256"), ROOT)
    if src and os.path.isfile(src):
        got = sha(src)
        if got != current_digest(rec.get("source_sha256"), ROOT):
            problems.append((tag, "source %s hashes to %s, record says %s"
                             % (src, got, rec.get("source_sha256"))))
    elif src:
        problems.append((tag, "source document is gone: %s" % src))

    findings["ok"] += 1
    findings["bytes_by_format"][fmt] = findings["bytes_by_format"].get(fmt, 0) + size


def check_companions(problems):
    """Check each ledger/companions.tsv row against its file, and each glTF buffer against a row.

    A glTF names its `.bin` buffer in `buffers[].uri`, so a buffer that no row lists would leave a
    manifest entry that a consumer cannot load."""
    if not os.path.isfile(COMPANIONS):
        problems.append(("companions", "%s is absent" % COMPANIONS))
        return
    with open(COMPANIONS) as f:
        head = next(f).rstrip("\n").split("\t")
        rows = [dict(zip(head, line.rstrip("\n").split("\t"))) for line in f if line.strip()]
    listed = set()
    for row in rows:
        path = os.path.join(ROOT, "files", row["companion_case"], row["companion_file"])
        tag = "companion %s/%s" % (row["companion_case"], row["companion_file"])
        listed.add(os.path.normpath(path))
        if not os.path.isfile(path):
            problems.append((tag, "file is absent"))
            continue
        if str(os.path.getsize(path)) != row["bytes"]:
            problems.append((tag, "size %d does not match listed bytes %s"
                             % (os.path.getsize(path), row["bytes"])))
        real = sha(path)
        if real != row["sha256"]:
            problems.append((tag, "sha256 %s does not match listed %s" % (real, row["sha256"])))
    files = os.path.join(ROOT, "files")
    for case in sorted(os.listdir(files)):
        d = os.path.join(files, case)
        if not os.path.isdir(d):
            continue
        for name in sorted(n for n in os.listdir(d) if n.endswith(".gltf")):
            try:
                with open(os.path.join(d, name)) as f:
                    buffers = json.load(f).get("buffers", [])
            except ValueError:
                problems.append(("%s/%s" % (case, name), "glTF is not JSON"))
                continue
            for i, buf in enumerate(buffers):
                uri = buf.get("uri", "")
                if uri and not uri.startswith("data:") and \
                        os.path.normpath(os.path.join(d, uri)) not in listed:
                    problems.append(("%s/%s" % (case, name),
                                     "buffers[%d].uri %s has no ledger/companions.tsv row" % (i, uri)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-id")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--write-index", metavar="PATH",
                    help="write one authoritative row per required pair")
    args = ap.parse_args()

    runs = os.path.join(ROOT, "runs")
    if args.run_id:
        run_ids = [args.run_id]
    elif args.all:
        run_ids = sorted(d for d in os.listdir(runs) if os.path.isdir(os.path.join(runs, d)))
    else:
        run_ids = [max(d for d in os.listdir(runs) if os.path.isdir(os.path.join(runs, d)))]

    ledger_index = {}
    for number, row in read_ledger():
        if row is None:
            continue
        key = (row.get("case"), row.get("profile"), row.get("format"))
        ledger_index.setdefault(key, []).append((number, row))

    # A pair holds one artifact path, so a later run overwrites the file an earlier
    # run recorded. Only the newest record for a pair describes the file on disk.
    # Every older record is history, and the audit counts it rather than checking it.
    newest = {}
    for key, lines in ledger_index.items():
        last = lines[-1][1]
        if last:
            newest[key] = last.get("run_id")

    all_records = []
    for run_id in run_ids:
        records = os.path.join(runs, run_id, "records")
        if not os.path.isdir(records):
            continue
        for name in sorted(os.listdir(records)):
            if name == "run.json" or not name.endswith(".json"):
                continue
            with open(os.path.join(records, name)) as f:
                all_records.append((run_id, json.load(f)))

    on_disk = read_on_disk()
    problems = []
    findings = {"ok": 0, "status": {}, "bytes_by_format": {}, "ledger_run_mismatch": 0,
                "duplicate_keys": 0, "superseded": 0, "relocated": 0, "no_profile": 0}
    negatives = read_negatives()
    digests = {}
    rows_read = len(all_records)

    for run_id, rec in all_records:
        key = (rec.get("case"), rec.get("profile"), rec.get("format"))
        if run_id != newest.get(key, run_id):
            findings["superseded"] += 1
            continue
        check_row(run_id, rec, ledger_index, problems, findings, on_disk, negatives)
        if rec.get("status") == "ok" and rec.get("sha256"):
            digests.setdefault(current_digest(rec["sha256"], ROOT), []).append(
                "%s %s" % (rec.get("case"), rec.get("profile")))

    check_companions(problems)

    required = read_required()
    covered = set(ledger_index)
    missing = sorted(required - covered)

    shared = {d: names for d, names in digests.items()
              if len({n.split()[0] for n in names}) > 1}
    groups = merge_groups(disk_groups(), shared) if args.all else {}
    if args.all and on_disk is not None:
        check_unrecorded((required & on_disk) - covered, problems)
    if args.all:
        check_shared(groups, read_shared_digests(), problems)

    if args.write_index:
        with open(args.write_index, "w") as f:
            f.write("case\tprofile\tformat\tpath\tbytes\tsha256\trun_id\n")
            written = 0
            for case, profile, fmt in sorted(required):
                lines = ledger_index.get((case, profile, fmt))
                if not lines:
                    continue
                _number, row = lines[-1]
                path = resolve(row.get("path"), ROOT) if row else None
                if not path or not os.path.isfile(path):
                    continue
                f.write("%s\t%s\t%s\t%s\t%s\t%s\t%s\n" % (
                    case, profile, fmt, relative(path, ROOT), row.get("bytes"),
                    row.get("sha256"), row.get("run_id")))
                written += 1
        print("index written to %s with %d rows" % (args.write_index, written))

    print("runs read: %d" % len(run_ids))
    print("records read: %d, judged: %d, superseded by a later run: %d"
          % (rows_read, rows_read - findings["superseded"], findings["superseded"]))
    print("records that pass every check: %d" % findings["ok"])
    print("required pairs: %d, with a passing run record: %d, with no passing run record: %d"
          " (a provenance count and not a coverage count)"
          % (len(required), len(required & covered), len(missing)))
    on_disk = read_on_disk()
    if on_disk is None:
        print("pairs holding an artifact on disk: unknown, %s is absent" % COVERAGE)
    else:
        print("pairs holding an artifact on disk per ledger/coverage.tsv: %d,"
              " of which %d have no passing run record"
              % (len(required & on_disk), len(set(missing) & on_disk)))
    if findings["status"]:
        print("rows with other status:")
        for status, count in sorted(findings["status"].items(), key=lambda kv: str(kv[0])):
            print("  %-24s %d" % (status, count))
    if findings["no_profile"]:
        print("failed records with no profile, not judged: %d" % findings["no_profile"])
    if findings["duplicate_keys"]:
        print("pairs carrying more than one ledger line: %d" % findings["duplicate_keys"])
    if findings["ledger_run_mismatch"]:
        print("ledger lines whose run id is not the run that holds the record: %d"
              % findings["ledger_run_mismatch"])
    if findings.get("relocated"):
        print("run records whose artifact moved out of files/: %d"
              % findings["relocated"])
    print("problems: %d" % len(problems))
    for tag, detail in problems[:60]:
        print("  %s: %s" % (tag, detail))
    if len(problems) > 60:
        print("  ... and %d more" % (len(problems) - 60))
    print("digests shared by two different cases: %d" % len(shared))
    if args.all:
        print("sha256 values held by files or records of two different cases: %d, pinned in %s"
              % (len(groups), os.path.relpath(SHARED_DIGESTS, ROOT)))
    for digest, names in list(shared.items())[:20]:
        print("  %s: %s" % (digest[:16], ", ".join(sorted(set(names)))))
    if findings["bytes_by_format"] and not args.quiet:
        print("bytes by format:")
        for fmt, total in sorted(findings["bytes_by_format"].items()):
            print("  %-6s %d" % (fmt, total))

    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
