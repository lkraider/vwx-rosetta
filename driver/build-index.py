#!/usr/bin/env python3
"""Rewrite INDEX.md, ledger/intent.json and ledger/manifest.json from the store contents.

Usage: python3 driver/build-index.py [--check]

Every count in INDEX.md is read from a ledger file or from a directory walk at run time.
The descriptions of the files are fixed text in this program. ledger/manifest.json joins the
ledger tables into one entry per required pair. ledger/intent.json holds what the script of each
case draws. driver/MANIFEST.md describes both. With --check the program writes nothing and exits 1
when a file differs from the computed text.
"""
import argparse
import collections
import functools
import csv
import glob
import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INDEX = os.path.join(ROOT, "INDEX.md")
MANIFEST = os.path.join(ROOT, "ledger", "manifest.json")
INTENT = os.path.join(ROOT, "ledger", "intent.json")
sys.path.insert(0, os.path.join(ROOT, "driver"))
import recipe_intent  # noqa: E402
from store_path import current_digest, find_source, relative, resolve  # noqa: E402

# Directory walks skip the interpreter caches, because each Python run rewrites them.
SKIP_DIRS = {"__pycache__"}
# .gitignore leaves these out, so a clone holds neither. The walks skip them so a clone computes
# the same INDEX.md.
SKIP_PATHS = {"driver/bin", "driver/sdk"}

NEGATIVE_MEANING = {
    "format not offered by the application": "the Export Image File dialog lists 14 file types and SVG is not among them",
    "no ifc file produced by either route": "both routes resolve and neither writes a file",
    "no exportable objects": "the command appears and the application refuses it",
    "no source document": "no source document exists for the case, and the readiness tree holds a FAKEVWX stub",
    "no tessellatable geometry": "the 3DS options dialog disables its Export button, or the file it writes holds no vertex list",
    "no tessellatable objects": "the export function returns False and writes a 0 byte file",
    "no objects on the active layer": "the export function finds nothing to write",
    "no valid objects for export": "the object is selected, the route rejects it, and no file is written or the file it writes holds no geometry. Measured 2026-10-16, every route rejects the nurbs-surface-a object of ix.mech.rational-surface-trim-hole-units",
    "worksheet window required": "the menu item presses and no worksheet window exists",
    "2D locus draws no mark": "the case holds one 2D locus, and the PDF and PNG exporters draw no locus marker",
    "3D locus has no face or plan marker": "the case holds one 3D locus, the mesh exporters write no polygon for a point, and the top plan image draws no pixel",
    "light has no geometry": "the case holds one Light, and the export writes no entity, mesh or pixel for it",
    "NURBS curve has no face": "the case holds one NURBS curve, and the FBX exporter writes meshes only",
    "resource not placed, nothing written": "the case defines a resource and places no object that uses it, and the file equals the control.blank.mm file of the same profile except for handles and timestamps",
    "material not written": "the file holds the object that uses the material, and it holds no material name and no material data",
    "record not written": "the file holds the object that carries the record, and it holds no record name, field or value",
    "sheet-layer object has no design-layer entity": "the case puts its only object on a sheet layer, and the All Visible Design Layers scope writes an empty model space and one paper-space VIEWPORT",
    "trimmed NURBS surface has no drawable face": "vs.TrimNurbsSurface returns True, the trimmed surface draws nothing in Vectorworks 2027, and every export of it holds no geometry",
    "the ifc export writes no element": "the IFC export maps the design layer to a storey and writes the project, site, building and storey with no element entity",
}


# The empty-fixture repair of 2026-10-16 ran a program in the open document before the export and
# saved nothing. The sealed source under sources/ is the document that was opened. Each sentence
# names what the program in runs/<run_id>/pre/ did to it.
PRE_EXPORT_CHANGE = {
    "ix.mech.viewport-crop-annotation-visibility": "sets classes None and Dimension visible in viewport-b and updates the viewport",
}


def path(rel):
    return os.path.join(ROOT, rel)


def size(rel):
    return os.path.getsize(path(rel))


def read_tsv(rel):
    with open(path(rel), newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def tsv_rows(rel):
    return len(read_tsv(rel))


def walk(rel):
    """Return the file count and the byte total under a store directory."""
    count = 0
    total = 0
    for dirpath, dirnames, filenames in os.walk(path(rel)):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS
                       and os.path.relpath(os.path.join(dirpath, d), ROOT) not in SKIP_PATHS]
        for name in filenames:
            count += 1
            total += os.path.getsize(os.path.join(dirpath, name))
    return count, total


def mb(n):
    return "%.1f MB" % (n / 1e6)


def subdirs(rel):
    return sorted(d for d in os.listdir(path(rel)) if os.path.isdir(os.path.join(path(rel), d)))


def count_lines(rel, pattern):
    rx = re.compile(pattern)
    with open(path(rel)) as f:
        return sum(1 for line in f if rx.match(line))


def doc_table(rows):
    out = ["| path | bytes | what it holds |", "|---|---:|---|"]
    for rel, what in rows:
        out.append("| `%s` | %d | %s |" % (rel, size(rel), what))
    return out


def build(index_bytes):
    coverage = read_tsv("ledger/coverage.tsv")
    negatives = read_tsv("ledger/negatives.tsv")
    states = collections.Counter(r["state"] for r in coverage)
    cases = sorted({r["case"] for r in coverage})
    profiles = sorted({r["profile"] for r in coverage})
    formats = sorted({r["format"] for r in coverage})
    unaccounted = len(coverage) - states["artifact"] - states["negative"]
    files_n, files_b = walk("files")
    extras_n, _ = walk("extras")
    sources = read_tsv("sources/SOURCES.tsv")
    source_cases = set()
    for r in sources:
        source_cases.update(c for c in r["case_ids"].split(",") if c)
    source_docs = [n for n in os.listdir(path("sources")) if n.endswith(".vwx")]
    runs = subdirs("runs")
    lessons = count_lines("RETROSPECTIVE.md", r"## \d+\. ")
    with open(path("driver/source-map.tsv")) as f:
        smap = [line.rstrip("\n").split("\t") for line in f if line.strip()]
    review_files = len(json.load(open(path("ledger/artifact-review.json")))["files"])
    raw_n, _ = walk("ui-map/raw")

    L = []
    L += [
        "# Reference corpus index",
        "",
        "`driver/build-index.py` writes this page from the store contents. Every count on this",
        "page was read from the file or the directory named beside it.",
        "",
        "## 1. What this store is",
        "",
        "The store holds reference exports that Vectorworks 2027 wrote itself. One file covers each",
        "collected case, profile and format. The store also holds the drivers, the per run records,",
        "the accounting, the sealed source documents and the observed dialog trees.",
        "",
        "The store answers one question. What does Vectorworks 2027 write for a given case, profile",
        "and format. A reader that never runs Vectorworks can open any file under `files/` and",
        "compare its own writer against it.",
        "",
        "- Required pairs: %d, spread over %d case ids, %d profiles and %d format families. Source `ledger/coverage.tsv`."
        % (len(coverage), len(cases), len(profiles), len(formats)),
        "- Artifact on disk: %d. Source `ledger/coverage.tsv` state `artifact`." % states["artifact"],
        "- Recorded negative: %d. Source `ledger/coverage.tsv` state `negative`." % states["negative"],
        "- Unaccounted: %d. Source `ledger/coverage.tsv`, rows in neither state." % unaccounted,
        "- Files under `files/`: %d, total %s. Source a walk of `files/`." % (files_n, mb(files_b)),
        "- Files under `extras/`: %d. Source a walk of `extras/`." % extras_n,
        "- Source documents under `sources/`: %d, mapped to %d case ids. Source `sources/SOURCES.tsv`."
        % (len(source_docs), len(source_cases)),
        "- Run directories under `runs/`: %d. Source a listing of `runs/`." % len(runs),
        "",
        "`ledger/coverage.tsv` holds one row per required pair and names its state.",
        "`ledger/negatives.tsv` holds the evidence text for each negative pair.",
        "",
        "## 2. The documents",
        "",
        "The byte counts are file sizes read at generation time.",
        "",
    ]
    L += doc_table([
        ("CORPUS-COVERAGE.md", "what the corpus holds, what is left to collect and how to resume"),
        ("STATUS.md", "the measured details, the store checks, the known limits and the findings"),
        ("ROADMAP.md", "the open driver work and the decisions"),
        ("RETROSPECTIVE.md", "what could have been done better, %d lessons, counted from its numbered headings" % lessons),
        ("README-WORKFLOW.md", "the front door to the workflow stages"),
        ("design/REPLACED.md", "what the store does in place of each section of the imported design documents"),
        ("design/VECTORWORKS-LESSONS.md", "the driving lessons of the old repository that no other store document holds"),
    ])
    L.append("| `INDEX.md` | %d | this page |" % index_bytes)
    L += doc_table([
        ("driver/WORKFLOW.md", "the runbook for the four workflow stages and `driver/ui/run-all.sh`"),
        ("driver/FORMAT-ROUTES.md", "what each format needs and what was proven"),
        ("driver/GLTF-ROUTE.md", "the glTF route through a workspace copy that lists the command"),
        ("driver/MISSING-SOURCES.md", "the search for the cases with no source document"),
        ("driver/DRIVER-NOTES.md", "the driver notes, the locale crash diagnosis, the driver fault list and the launch script"),
        ("driver/PACKETS.md", "the dispatch register"),
        ("driver/MANIFEST.md", "the fields of `ledger/manifest.json` and `ledger/intent.json`"),
        ("driver/EXPORT-VARIANCE.md", "the DXF and DWG fields that change between two exports of one source"),
        ("driver/RECIPE-PROFILE-AUDIT.md", "the recipe against required profile audit"),
        ("driver/OBJ-FBX-SCOPE.md", "the Export OBJ Options and Export FBX Options probe"),
        ("driver/OBJECT-CENSUS.md", "the object census of the 12 documents with empty mesh pairs"),
        ("driver/ROUTE-DEFECTS.md", "the pairs the object census contradicts"),
        ("driver/INTERVIEW-NOTES.md", "the questions the corpus raises and their answers"),
        ("driver/MESH-APPLICABILITY.md", "the mesh profile applicability measurement and its three answers"),
        ("driver/EMPTY-DOCUMENTS.md", "the three fixtures that created no object, the cost and the refuted causes"),
        ("driver/RECORDS-2026-10-16.md", "the files that record the store of 2026-10-16"),
        ("driver/BLOCK0-ANSWERS.md", "the H1, O5, O8 and M1-M7 answers for a .vwx reader"),
        ("ledger/artifact-review.md", "the first batch artifact review in prose"),
        ("sources/SOURCES.tsv", "the sealed documents to case ids, %d rows" % len(sources)),
        ("extras/README.md", "the files that belong to no required pair"),
    ])[2:]
    L += [
        "",
        "Read `CORPUS-COVERAGE.md` first for what the corpus holds and what is left to collect. Read `STATUS.md`",
        "for the measured details. Read `RETROSPECTIVE.md` before running a second capture pass.",
        "",
        "## 3. The layout",
        "",
        "Each row is a walk of the directory. The walk skips `__pycache__` directories, `driver/bin/` and `driver/sdk/`.",
        "",
        "| path | files | bytes | what it holds |",
        "|---|---:|---:|---|",
    ]
    for rel, what in [
        ("files", "the artifacts, one directory per case id"),
        ("extras", "the export files that belong to no required pair"),
        ("sources", "the sealed source documents, `SOURCES.tsv`, and the older bytes of repaired fixtures under `superseded/`"),
        ("runs", "one directory per driver run, holding `records/` and a snapshot of the driver"),
        ("ledger", "the accounting, the run log and the machine readable audits"),
        ("driver", "the drivers, the route reports and the notes"),
        ("ui-map", "the observed Accessibility tree of every dialog used"),
        ("scripted", "the retained legacy scripted location"),
    ]:
        n, b = walk(rel)
        L.append("| `%s/` | %d | %s | %s |" % (rel, n, mb(b), what))

    L += [
        "",
        "## 4. Coverage by format",
        "",
        "Every count in this table is a row count of `ledger/coverage.tsv`.",
        "",
        "| format | pairs | artifact | negative | profiles |",
        "|---|---:|---:|---:|---|",
    ]
    by_fmt = collections.defaultdict(collections.Counter)
    fmt_profiles = collections.defaultdict(set)
    for r in coverage:
        by_fmt[r["format"]][r["state"]] += 1
        fmt_profiles[r["format"]].add(r["profile"])
    for fmt in formats:
        c = by_fmt[fmt]
        L.append("| %s | %d | %d | %d | %s |" % (
            fmt, sum(c.values()), c["artifact"], c["negative"],
            ", ".join("`%s`" % p for p in sorted(fmt_profiles[fmt]))))
    L.append("| **total** | **%d** | **%d** | **%d** | |" % (len(coverage), states["artifact"], states["negative"]))

    L += [
        "",
        "## 5. The negative states",
        "",
        "Every count in this table is a row count of `ledger/negatives.tsv` grouped by its `status` column.",
        "",
        "| state | pairs | what it means |",
        "|---|---:|---|",
    ]
    neg = collections.Counter(r["status"] for r in negatives)
    for state, n in sorted(neg.items(), key=lambda kv: (-kv[1], kv[0])):
        if state not in NEGATIVE_MEANING:
            sys.exit("build-index.py: ledger/negatives.tsv holds the state %r. Add its meaning to NEGATIVE_MEANING." % state)
        L.append("| `%s` | %d | %s |" % (state, n, NEGATIVE_MEANING[state]))
    L.append("| **total** | **%d** | |" % len(negatives))

    # Git keeps no empty directory, so a clone holds only the case directories that hold a file.
    case_dirs = {d for d in subdirs("files") if walk("files/" + d)[0]}
    stray = sorted(case_dirs - set(cases))
    extra_dirs = subdirs("extras")
    L += [
        "",
        "## 6. Case directory index",
        "",
        "A case holds a directory under `files/` when it produced at least one artifact. The table",
        "names the formats each case holds as artifacts and the number of required pairs the case",
        "records as negative. Both come from `ledger/coverage.tsv`.",
    ]
    if stray:
        L.append("These directories under `files/` belong to no required pair: %s." % ", ".join("`files/%s/`" % d for d in stray))
    else:
        L.append("A listing of `files/` finds %d directories that hold a file, and every one names a required case id." % len(case_dirs))
    L.append("`extras/` holds %s." % ", ".join(
        "`extras/%s/` with %d files" % (d, walk("extras/" + d)[0]) for d in extra_dirs))
    L += [
        "",
        "| case | formats held | negative pairs | profiles |",
        "|---|---|---:|---|",
    ]
    held_cases = 0
    for case in cases:
        rows = [r for r in coverage if r["case"] == case]
        held = collections.Counter(r["format"] for r in rows if r["state"] == "artifact")
        negs = sum(1 for r in rows if r["state"] == "negative")
        if held:
            held_cases += 1
        L.append("| `%s` | %s | %d | %s |" % (
            case,
            ", ".join("%s x%d" % (f, held[f]) for f in sorted(held)) or "none",
            negs,
            ", ".join(sorted({r["profile"] for r in rows}))))
    L += [
        "",
        "Cases that hold an artifact: %d. Cases that hold only negatives: %d. Source `ledger/coverage.tsv`."
        % (held_cases, len(cases) - held_cases),
        "",
        "## 7. The driver files",
        "",
        "The byte counts are file sizes read at generation time.",
        "",
    ]
    driver_rows = [
        ("driver/ui/validate-store.sh", "the single validation entry point"),
        ("driver/ui/run-all.sh", "runs the workflow stages in `driver/WORKFLOW.md`"),
        ("driver/ui/sweep-ui.py", "the user interface driver and the FORMATS route table"),
        ("driver/ui/coverage.py", "the pair accounting, writes `ledger/coverage.tsv`"),
        ("driver/ui/verify-artifacts.py", "the run record verifier"),
        ("driver/ui/audit-corpus.py", "the whole store audit, writes `ledger/corpus-audit.json`"),
        ("driver/ui/inert-pairs.py", "names every artifact that holds no geometry, writes `ledger/inert-pairs.tsv`"),
        ("driver/ui/mesh-topology.py", "measures the vertices, faces, area and welded vertices of each 3DS, OBJ, FBX and glTF file, writes `ledger/mesh-topology.tsv`"),
        ("driver/ui/make-sources.py", "writes a source document from a recipe"),
        ("driver/inventory/combined-sources.py", "writes combined plug-in source recipes from the plug-in probe TSV, and splits one in halves"),
        ("driver/ui/source-census.py", "records the layers, objects, symbols, names and classes of a source document with layer and class visibility, compares two records, and checks that hidden layers and classes read hidden"),
        ("driver/ui/export-queue.py", "writes `driver/ui/export-queue.jsonl`, the export steps of each required pair"),
        ("driver/ui/vw-launch.sh", "starts the application through LaunchServices with an English locale"),
        ("driver/vw_memory.py", "restarts the application when its footprint or the swap use passes a limit, logs each check to `vw-memory.tsv`"),
        ("driver/pause.py", "reads the pause file that holds the steps which bring the application to the front"),
        ("driver/vw_lock.py", "the lock that lets one process drive the application at a time"),
        ("driver/scripted/sweep-scripted.sh", "the scripted route driver"),
        ("driver/scripted/exporter.py", "the binding calls, one handler per format"),
        ("driver/scripted/routes.tsv", "the per format binding call and its arguments"),
        ("driver/scripted/probe.py", "the adapter that reports the open document"),
        ("driver/source-map.tsv", "%d case ids to %d source documents, with sha256" % (len(smap), len({r[1] for r in smap}))),
        ("driver/build-source-map.py", "builds `source-map.tsv` and rejects FAKEVWX stubs"),
        ("driver/source-census.json", "the census of the document of %d recipes" % len(json.load(open(path("driver/source-census.json"))))),
        ("driver/census-visibility-pinned.tsv", "hidden classes whose census predates the visibility reads, which `source-census.py --check-hidden` lists and passes"),
        ("driver/export-settings.py", "the export settings generator, writes `ledger/export-settings.tsv`"),
        ("driver/recipe-profile-audit.py", "the recipe audit generator, writes `ledger/recipe-profile-audit.tsv`"),
        ("driver/build-index.py", "this generator, writes `INDEX.md`, `ledger/intent.json` and `ledger/manifest.json`"),
        ("driver/recipe_intent.py", "reads the script of each case for `ledger/intent.json`"),
        ("driver/reader-audit.py", "reads every DXF, DWG, PDF, SAT and STEP file with a reader outside Vectorworks, writes `ledger/reader-audit.tsv`"),
        ("driver/dxf-diff.py", "compares two DXF files group by group, used for `driver/EXPORT-VARIANCE.md`"),
        ("driver/export-inventory.py", "the export inventory generator, writes `ledger/inventory.tsv` and `ledger/covering/`"),
        ("driver/export-inventory-input/", "the inputs of `export-inventory.py` and their origin"),
        ("driver/plugin-presence.py", "reads each stored export of each combined source, writes `ledger/plugin-presence.tsv`"),
    ]
    for rel in sorted(glob.glob(path("driver/*CENSUS*"))) + sorted(glob.glob(path("driver/object-census*"))):
        driver_rows.append((os.path.relpath(rel, ROOT), "the object census, one probe run per case"))
    L += doc_table(driver_rows)

    L += [
        "",
        "## 8. The ledger files",
        "",
        "The byte counts are file sizes. The row counts exclude the header line.",
        "",
    ]
    L += doc_table([
        ("ledger/manifest.json", "the consumer manifest, schema `rosetta-manifest/1`, %d pairs, described in `driver/MANIFEST.md`"
         % len(json.load(open(path("ledger/manifest.json")))["pairs"])),
        ("ledger/intent.json", "what the script of each case draws, schema `rosetta-intent/1`, %d cases, described in `driver/MANIFEST.md`"
         % len(json.load(open(path("ledger/intent.json")))["cases"])),
        ("ledger/required-pairs.tsv", "the required case, profile and format pairs, %d rows" % tsv_rows("ledger/required-pairs.tsv")),
        ("ledger/coverage.tsv", "one row per required pair, %d rows, with its state" % len(coverage)),
        ("ledger/negatives.tsv", "one row per negative pair, %d rows, with its state and its evidence text" % len(negatives)),
        ("ledger/corpus-audit.json", "the per artifact audit, written by `audit-corpus.py`"),
        ("ledger/corpus-ledger.jsonl", "the per artifact ledger line, written by the drivers"),
        ("ledger/corpus-index.tsv", "the case and profile index"),
        ("ledger/verification.tsv", "the earlier verification pass"),
        ("ledger/artifact-review.json", "the first batch review, %d files" % review_files),
        ("ledger/companions.tsv", "the material, texture and buffer companions, %d rows" % tsv_rows("ledger/companions.tsv")),
        ("ledger/inert-pairs.tsv", "the per artifact geometry measure and verdict, %d rows" % tsv_rows("ledger/inert-pairs.tsv")),
        ("ledger/mesh-topology.tsv", "the mesh topology of each 3DS, OBJ, FBX and glTF file, %d rows" % tsv_rows("ledger/mesh-topology.tsv")),
        ("ledger/reader-audit.tsv", "the ezdxf, dwgread, qpdf, ACIS SAT and STEP unit result per file, %d rows" % tsv_rows("ledger/reader-audit.tsv")),
        ("ledger/export-settings.tsv", "the settings that produced each artifact, %d rows" % tsv_rows("ledger/export-settings.tsv")),
        ("ledger/recipe-profile-audit.tsv", "the per case recipe and artifact audit, %d rows" % tsv_rows("ledger/recipe-profile-audit.tsv")),
        ("ledger/source-map-cache-paths.tsv", "the cache paths preserved as provenance, %d rows" % tsv_rows("ledger/source-map-cache-paths.tsv")),
        ("ledger/inventory.tsv", "each export command, export option, node type and plug-in with its status, %d rows" % tsv_rows("ledger/inventory.tsv")),
        ("ledger/plugin-presence.tsv", "for each plug-in of each combined source, whether each stored export holds it, %d rows" % tsv_rows("ledger/plugin-presence.tsv")),
        ("ledger/shared-digests.tsv", "the groups of different cases whose stored exports hold one sha256, %d rows" % tsv_rows("ledger/shared-digests.tsv")),
        ("ledger/unrecorded-pairs.tsv", "the required pairs whose stored export has no ledger line with its profile, %d rows" % tsv_rows("ledger/unrecorded-pairs.tsv")),
        ("ledger/covering/", "per route, the smallest case list that holds every object type the route carries, the pinned cases, and one case per option"),
    ])

    L += [
        "",
        "## 9. The ui-map files",
        "",
        "| path | what it holds |",
        "|---|---|",
    ]
    for name in sorted(os.listdir(path("ui-map"))):
        rel = "ui-map/" + name
        if os.path.isfile(path(rel)):
            L.append("| `%s` | %d bytes |" % (rel, size(rel)))
    L.append("| `ui-map/raw/` | %d native tree dumps and probe captures, counted by a walk of `ui-map/raw/` |" % raw_n)

    L += [
        "",
        "## 10. How to read the store without the application",
        "",
        "Run this command from the store root.",
        "",
        "- `sh driver/ui/validate-store.sh` runs `tools/no-rm-rf.sh`, `driver/ui/coverage.py`,",
        "  `driver/ui/verify-artifacts.py --all`, `driver/ui/audit-corpus.py`,",
        "  `driver/ui/inert-pairs.py --check` and `driver/ui/export-queue.py --check` in that order.",
        "  It writes nothing under the store.",
        "  It prints one line per step and exits 1 when any step exits non-zero.",
        "- `sh driver/ui/validate-store.sh --write` passes `--write` to `coverage.py` and",
        "  `audit-corpus.py`. Those steps replace `ledger/coverage.tsv`, `ledger/corpus-audit.json`",
        "  and `ledger/companions.tsv`.",
        "- `driver/ui/audit-corpus.py` measures DWG geometry with `dwg2dxf` from LibreDWG",
        "  (`brew install libredwg`) and PNG ink with Pillow (`python3 -m pip install Pillow`).",
        "  A DWG or PNG artifact reads `unknown` when its tool is absent.",
        "- `VWX_CLI` names the `vwx` binary and `ROSETTA_TMP`",
        "  the scratch root. The `vwx` default is `driver/bin/vwx`. `sh driver/native/build.sh`",
        "  builds it with Zig 0.16.0 and compares its SHA-256 with `driver/bin/BUILD.tsv`.",
        "- `sh driver/ui/run-all.sh verify` and `sh driver/ui/run-all.sh index` run stages 3 and 4 of",
        "  `driver/WORKFLOW.md`. `README-WORKFLOW.md` lists the four stages.",
        "",
    ]
    return "\n".join(L)


def sha256(rel):
    h = hashlib.sha256()
    with open(path(rel), "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


@functools.cache
def ledger_json():
    """Return the texts of ledger/intent.json and ledger/manifest.json."""
    def key(r):
        return (r["case"], r["profile"], r["format"])

    required = [key(r) for r in read_tsv("ledger/required-pairs.tsv")]
    coverage = {key(r): r for r in read_tsv("ledger/coverage.tsv")}
    negatives = {key(r): r for r in read_tsv("ledger/negatives.tsv")}
    inert = {key(r): r for r in read_tsv("ledger/inert-pairs.tsv")}
    readers = {r["path"]: r for r in read_tsv("ledger/reader-audit.tsv")}
    audit = {(e["case"], e["profile"], e["format"]): e
             for e in json.load(open(path("ledger/corpus-audit.json")))["entries"]}
    with open(path("driver/source-map.tsv")) as f:
        smap = {r[0]: (r[1], r[2]) for r in (line.rstrip("\n").split("\t") for line in f) if len(r) > 2}
    newest = {}
    with open(path("ledger/corpus-ledger.jsonl")) as f:
        for line in f:
            if line.strip():
                r = json.loads(line)
                newest[(r["case"], r["profile"], r["format"])] = r
    if set(required) != set(coverage) or len(set(required)) != len(required):
        sys.exit("build-index.py: ledger/coverage.tsv and ledger/required-pairs.tsv name different pairs")

    companions = collections.defaultdict(list)
    unlinked = []
    for r in read_tsv("ledger/companions.tsv"):
        item = {
            "path": "files/%s/%s" % (r["companion_case"], r["companion_file"]),
            "bytes": int(r["bytes"]),
            "sha256": r["sha256"],
            "kind": r["kind"],
            "linked_by": r["linked_by"],
        }
        if r["primary_file"]:
            companions[(r["primary_case"], r["primary_file"])].append(item)
        else:
            unlinked.append(dict(item, case=r["companion_case"]))

    records = {}
    for case, _profile, _fmt in required:
        if case not in records:
            records[case] = recipe_intent.case_record(ROOT, case)

    sources = {}
    entries = []
    for k in required:
        case, profile, fmt = k
        row = coverage[k]
        entry = {"case": case, "profile": profile, "format": fmt, "state": row["state"],
                 "source_path": None, "source_sha256": None,
                 "intent_path": "ledger/intent.json", "intent_sha256": recipe_intent.digest(records[case])}
        if case in smap:
            src_path, src_sha = smap[case]
            if case not in sources:
                rel = relative(find_source(src_path, src_sha, ROOT), ROOT)
                if sha256(rel) != src_sha:
                    sys.exit("build-index.py: %s does not hash to %s" % (rel, src_sha))
                sources[case] = rel
            entry["source_path"] = sources[case]
            entry["source_sha256"] = src_sha
        if row["state"] == "artifact":
            rel = "files/%s/%s" % (case, row["artifact"])
            digest = sha256(rel)
            if digest != audit[k]["sha256"] or audit[k]["source_sha256"] != entry["source_sha256"]:
                sys.exit("build-index.py: %s differs from ledger/corpus-audit.json" % rel)
            measure = inert[k]
            entry.update({
                "artifact_path": rel,
                "artifact_bytes": size(rel),
                "artifact_sha256": digest,
                "inert": measure["inert"],
                "inert_measure": measure["measure"],
                "inert_rule": measure["rule"],
                "companions": companions.pop((case, row["artifact"]), []),
                "working_copy": None,
                "reader": None,
            })
            if fmt in ("dxf", "dwg", "pdf", "sat"):
                read = readers.get(rel)
                if not read or current_digest(read["sha256"], ROOT) != digest:
                    sys.exit("build-index.py: ledger/reader-audit.tsv has no row for %s at its digest. "
                             "Run driver/reader-audit.py --write." % rel)
                entry["reader"] = {"name": read["reader"], "result": read["result"], "detail": read["detail"]}
            # The scripted route wrote its sat and stl records under other keys, so those pairs hold
            # no ledger line here. That route ran no pre-export program.
            line = newest.get(k, {})
            if line and current_digest(line.get("sha256"), ROOT) != digest:
                sys.exit("build-index.py: the newest ledger line of %s %s does not name %s" % (case, profile, rel))
            pre = line.get("pre_export")
            if pre:
                if current_digest(line["source_sha256"], ROOT) != entry["source_sha256"]:
                    sys.exit("build-index.py: the newest ledger line of %s %s names another source" % (case, profile))
                if case not in PRE_EXPORT_CHANGE:
                    sys.exit("build-index.py: %s ran a pre-export program. Add its change to PRE_EXPORT_CHANGE." % case)
                program = relative(resolve(pre["program"], ROOT), ROOT)
                entry["working_copy"] = {
                    "source_sha256": line["source_sha256"],
                    "change": PRE_EXPORT_CHANGE[case],
                    "program_path": program,
                    "program_sha256": sha256(program),
                }
        else:
            entry.update({
                "reason": negatives[k]["status"],
                "evidence": negatives[k]["evidence"],
            })
        entries.append(entry)
    if companions:
        sys.exit("build-index.py: ledger/companions.tsv names a primary file that no pair holds: %s"
                 % ", ".join(sorted(f for _c, f in companions)))
    intent = {"schema": "rosetta-intent/1", "cases": records,
              "entity_kinds": recipe_intent.entity_kinds(ROOT, records, entries)}
    doc = {"schema": "rosetta-manifest/1", "pairs": entries, "unlinked_companions": unlinked}
    return (json.dumps(intent, indent=1, ensure_ascii=False) + "\n",
            json.dumps(doc, indent=1, ensure_ascii=False) + "\n")


def intent():
    return ledger_json()[0]


def manifest():
    return ledger_json()[1]


def links_agree():
    """Compare the intent_sha256 of each manifest entry on disk with its record in ledger/intent.json."""
    if not (os.path.isfile(INTENT) and os.path.isfile(MANIFEST)):
        return True
    records = json.load(open(INTENT))["cases"]
    wrong = sorted({p["case"] for p in json.load(open(MANIFEST))["pairs"]
                    if p["case"] not in records or recipe_intent.digest(records[p["case"]]) != p.get("intent_sha256")})
    for case in wrong:
        print("ledger/manifest.json and ledger/intent.json disagree on %s" % case)
    return not wrong


def compute():
    # INDEX.md names its own size, so iterate until the size stops changing.
    n = 0
    for _ in range(10):
        text = build(n)
        m = len(text.encode())
        if m == n:
            return text
        n = m
    sys.exit("build-index.py: the INDEX.md size did not settle")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="exit 1 when INDEX.md, ledger/intent.json or ledger/manifest.json differs from the computed text")
    args = parser.parse_args()
    # INDEX.md names the sizes of both ledger files, so they are written first.
    outputs = [(INTENT, intent), (MANIFEST, manifest), (INDEX, compute)]
    failed = 0
    for target, make in outputs:
        if args.check and target == INDEX and not (os.path.isfile(MANIFEST) and os.path.isfile(INTENT)):
            print("INDEX.md not checked: it names the sizes of ledger/intent.json and ledger/manifest.json, and one is missing")
            continue
        text = make()
        name = os.path.relpath(target, ROOT)
        if args.check:
            current = open(target).read() if os.path.isfile(target) else None
            if current != text:
                print("%s differs from the computed text" % name)
                failed = 1
            else:
                print("%s matches the computed text" % name)
            continue
        with open(target, "w") as f:
            f.write(text)
        print("wrote %s, %d bytes" % (name, len(text.encode())))
    if args.check and not links_agree():
        failed = 1
    return failed


if __name__ == "__main__":
    sys.exit(main())
