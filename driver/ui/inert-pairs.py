#!/usr/bin/env python3
"""Name every pair whose artifact carries no geometry of the kind its format holds.

`ledger/coverage.tsv` records a pair as `artifact` when a file exists under `files/`. A file
that exists and carries no geometry still reads as coverage. Measured 2026-10-16, 28 of the
526 artifacts carry no geometry for their format.

This reads the per artifact facts that `driver/ui/audit-corpus.py` already computes and writes
`ledger/inert-pairs.tsv`. One row per pair that holds an artifact. The `inert` column is `yes`
when the artifact carries no geometry for its format, `no` when it carries some, and `unknown`
when the format offers no geometry measure.

Usage:
  inert-pairs.py --write     write ledger/inert-pairs.tsv
  inert-pairs.py --check     exit non-zero when the table on disk differs, or when an
                             inert artifact belongs to a case outside EMPTY_CASES, or when
                             driver/source-census.json lists an object, a symbol definition or
                             an error for a case of EMPTY_CASES, or when the source of such a
                             case no longer hashes to the sha256 its census run read
  inert-pairs.py             print the summary only
"""
import argparse
import json
import os
import hashlib
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "driver"))
from store_path import current_digest  # noqa: E402
AUDIT = os.path.join(ROOT, "ledger", "corpus-audit.json")
CENSUS = os.path.join(ROOT, "driver", "source-census.json")
OUT = os.path.join(ROOT, "ledger", "inert-pairs.tsv")

def drawing(facts):
    return (facts.get("geometry") or 0) + (facts.get("block_geometry") or 0) > 0


# Each rule names the facts keys it reads and a function over them. `measure` renders the
# numbers a reader needs to check the verdict. A format with no geometry measure is absent
# from this table and its rows read `unknown`. VWX has no rule. Its facts come from the
# 148-byte preamble, and no reader outside Vectorworks parses the objects of a VWX file.
RULES = {
    "ifc": ("the element count", lambda f: (f.get("elements") or 0) > 0,
            lambda f: "elements=%s entities=%s %s" % (f.get("elements"), f.get("entities"),
                                                      f.get("element_types"))),
    "fbx": ("the Vertices node", lambda f: bool(f.get("has_vertices")),
            lambda f: "has_vertices=%s has_polygon_vertex_index=%s" % (
                f.get("has_vertices"), f.get("has_polygon_vertex_index"))),
    "gltf": ("the triangle count", lambda f: (f.get("triangles") or 0) > 0,
             lambda f: "v=%s triangles=%s primitives=%s" % (f.get("vertices"), f.get("triangles"),
                                                           f.get("primitives"))),
    "stl": ("the triangle count", lambda f: (f.get("triangles") or 0) > 0,
            lambda f: "triangles=%s binary=%s" % (f.get("triangles"), f.get("binary"))),
    # A DXF of an empty drawing still holds one paper space VIEWPORT, so the DXF and DWG
    # rules count the records in model space and in block definitions that are not one.
    "dxf": ("the drawing entity count", drawing,
            lambda f: "geometry=%s block_geometry=%s entities=%s" % (
                f.get("geometry"), f.get("block_geometry"), f.get("entities"))),
    "pdf": ("the page count", lambda f: (f.get("pages") or 0) > 0,
            lambda f: "pages=%s" % f.get("pages")),
    "sat": ("the body record count", lambda f: (f.get("body_records") or 0) > 0,
            lambda f: "body_records=%s lines=%s" % (f.get("body_records"), f.get("lines"))),
    "iges": ("the entity count", lambda f: (f.get("entities") or 0) > 0,
             lambda f: "entities=%s solids=%s faces=%s" % (f.get("entities"), f.get("solids"), f.get("faces"))),
    "parasolid": ("the data line count", lambda f: (f.get("data_lines") or 0) > 0,
                  lambda f: "data_lines=%s header_lines=%s" % (f.get("data_lines"), f.get("header_lines"))),
    # The DWG measure converts the file with `dwg2dxf` and reads the converted DXF.
    "dwg": ("the drawing entity count", drawing,
            lambda f: "records=%s viewports=%s geometry=%s block_geometry=%s types=%s" % (
                f.get("records"), f.get("viewports"), f.get("geometry"),
                f.get("block_geometry"), f.get("types"))),
    # A rendered page is mostly white, so the count of pixels darker than 250 separates a
    # drawing from a blank page. Measured 2026-10-16, the lowest of the 72 PNG artifacts is
    # `annotation.viewport.sheet` at 10885 of 1920000 pixels, a fraction of 0.005669.
    "png": ("the ink pixel count", lambda f: (f.get("ink") or 0) > 0,
            lambda f: "ink=%s of %s pixels fraction=%s" % (f.get("ink"), f.get("pixels"),
                                                           f.get("ink_fraction"))),
}

FILES = os.path.join(ROOT, "files")


def triangle_area(a, b, c):
    u = [b[i] - a[i] for i in range(3)]
    w = [c[i] - a[i] for i in range(3)]
    cross = (u[1] * w[2] - u[2] * w[1],
             u[2] * w[0] - u[0] * w[2],
             u[0] * w[1] - u[1] * w[0])
    return 0.5 * sum(t * t for t in cross) ** 0.5


def obj_mesh(path):
    """Return (vertices, faces) of an OBJ file. Each face is a list of 0-based vertex indices."""
    verts = []
    faces = []
    with open(path, errors="ignore") as f:
        for line in f:
            if line.startswith("v "):
                parts = line.split()
                if len(parts) >= 4:
                    verts.append((float(parts[1]), float(parts[2]), float(parts[3])))
            elif line.startswith("f "):
                faces.append([int(t.split("/")[0]) - 1 for t in line.split()[1:]])
    return verts, faces


def obj_surface(path):
    """Return (vertices, faces, total face area) for an OBJ file, or None when unreadable.

    A vertex count above zero and a face count above zero do not prove the file holds a
    surface. Measured 2026-10-16, `nurbs.curve.cubic.obj` holds 44 vertices and 86 faces
    whose total area is 0. The vertices trace a space curve, so the faces are a degenerate
    ribbon and the file carries no surface."""
    try:
        verts, faces = obj_mesh(path)
    except (OSError, ValueError):
        return None
    total = 0.0
    for face in faces:
        if len(face) < 3:
            continue
        try:
            a, b, c = verts[face[0]], verts[face[1]], verts[face[2]]
        except IndexError:
            continue
        total += triangle_area(a, b, c)
    return len(verts), len(faces), total


def three_ds_objects(data):
    """Return one (vertices, faces) pair per named object of the 3DS bytes `data`."""
    objects = []

    def walk(start, end):
        while start + 6 <= end:
            cid, length = struct.unpack_from("<HI", data, start)
            if length < 6 or start + length > end:
                return
            body = start + 6
            if cid in (0x4D4D, 0x3D3D, 0x4100):
                walk(body, start + length)
            elif cid == 0x4000:
                name_end = data.index(b"\0", body)
                objects.append([[], []])
                walk(name_end + 1, start + length)
            elif cid == 0x4110 and objects:
                n, = struct.unpack_from("<H", data, body)
                objects[-1][0] = [struct.unpack_from("<3f", data, body + 2 + 12 * i) for i in range(n)]
            elif cid == 0x4120 and objects:
                n, = struct.unpack_from("<H", data, body)
                objects[-1][1] = [struct.unpack_from("<3H", data, body + 2 + 8 * i) for i in range(n)]
            start += length

    walk(0, len(data))
    return objects


def three_ds_surface(path):
    """Return (vertices, faces, objects, total face area) for a 3DS file, or None when unreadable.

    Measured 2026-10-18, object `1Obj` of `nurbs.curve.cubic.3ds` holds the curve as 43 faces
    of area 0, so the 3DS rule reads the total face area, as the OBJ rule does."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    try:
        objects = three_ds_objects(data)
        total = sum(triangle_area(v[a], v[b], v[c]) for v, faces in objects for a, b, c in faces)
    except (struct.error, ValueError, IndexError):
        return None
    return (sum(len(v) for v, _ in objects), sum(len(f) for _, f in objects), len(objects), total)


def rows_from_audit():
    with open(AUDIT) as f:
        audit = json.load(f)
    out = []
    for entry in audit["entries"]:
        if entry.get("state") != "artifact":
            continue
        fmt = entry["format"]
        facts = entry.get("facts") or {}
        path = os.path.join(FILES, entry["case"], entry.get("file") or "")
        if facts.get("tool") == "absent":
            # The DWG and PNG measures need `dwg2dxf` and PIL. Recording `unknown` is honest
            # and a verdict with no measure behind it is not.
            reason = "none"
            inert = "unknown"
            measure = "the measure needs a tool this machine does not have for %s" % fmt
        elif fmt == "obj":
            measured = obj_surface(path)
            if measured is None:
                inert, measure, reason = "unknown", "obj file not readable", "none"
            else:
                nv, nf, area = measured
                inert = "no" if (nv > 0 and nf > 0 and area > 0) else "yes"
                measure = "v=%d f=%d total_face_area=%.9f" % (nv, nf, area)
                reason = "the face count and the total face area"
        elif fmt == "3ds":
            measured = three_ds_surface(path)
            if measured is None:
                inert, measure, reason = "unknown", "3ds file not readable", "none"
            else:
                nv, nf, objects, area = measured
                inert = "no" if (nv > 0 and nf > 0 and area > 0) else "yes"
                measure = "v=%d f=%d objects=%d total_face_area=%.9f" % (nv, nf, objects, area)
                reason = "the face count and the total face area"
        else:
            rule = RULES.get(fmt)
            if rule is None:
                inert, measure, reason = "unknown", "no geometry measure for %s" % fmt, "none"
            else:
                carries, render = rule[1], rule[2]
                inert = "no" if carries(facts) else "yes"
                measure = render(facts)
                reason = rule[0]
        out.append({
            "case": entry["case"],
            "profile": entry["profile"],
            "format": fmt,
            "file": entry.get("file") or "",
            "bytes": entry.get("bytes"),
            "inert": inert,
            "measure": measure,
            "rule": reason,
        })
    out.sort(key=lambda r: (r["format"], r["case"], r["profile"]))
    return out, audit


COLUMNS = ["case", "profile", "format", "file", "bytes", "inert", "measure", "rule"]


# The cases whose intended content draws nothing. Only these may hold an inert artifact. An
# export of any other case that holds none of its content is a measured negative in
# `ledger/negatives.tsv`, with the file kept under `driver/cache-evidence/`. The resource
# cases that place no object are left out, because their exports are such negatives.
# driver/ui/source-census.py opened each stored source in Vectorworks and recorded its
# objects in driver/source-census.json. The census run is the one commit 9697852d records,
# "Rerun the 66 unexecuted recipes and record a census of each document", 2026-10-18. Each
# sha256 is the stored source that run read. A source that no longer hashes to it needs a
# new census.
CENSUS_RUN = "the census run of commit 9697852d, 2026-10-18"
EMPTY_CASES = {
    "control.blank.mm": ("an empty document in millimetres",
                         "f64dae33a9c9311103e3d2d056e7a39f75c070c8ec4249b5fffeaf0f7b9ca32d"),
    "control.blank.imperial": ("an empty document in inches",
                               "63c7485e45b02ff6b4653e56110c7b11f977e65722f391bb19b9a9cdeea78acf"),
    "document.georeference.epsg": ("sets the document georeference and places no object",
                                   "67c7968d9a425142d965b19d51e538000a1a558222957a8bd546d2f22bb18f88"),
}


def source_problems(census):
    out = []
    for case, (_what, measured) in sorted(EMPTY_CASES.items()):
        document = (census.get(case) or {}).get("document") or ""
        path = os.path.join(ROOT, document)
        if not document or not os.path.isfile(path):
            out.append("%s: the source %s is absent" % (case, document or "of the census entry"))
            continue
        with open(path, "rb") as f:
            got = hashlib.sha256(f.read()).hexdigest()
        if got != current_digest(measured, ROOT):
            out.append("%s: %s hashes to %s, and %s read %s" % (case, document, got, CENSUS_RUN, measured))
    return out


def census_problems(census):
    out = []
    for case in sorted(EMPTY_CASES):
        entry = census.get(case)
        if entry is None:
            out.append("%s: driver/source-census.json has no entry" % case)
            continue
        found = {k: len(entry.get(k) or []) for k in ("objects", "symdefs", "errors")}
        if any(found.values()):
            out.append("%s: driver/source-census.json lists %s" % (
                case, ", ".join("%d %s" % (n, k) for k, n in found.items() if n)))
    return out


def render_table(rows):
    lines = ["\t".join(COLUMNS)]
    for row in rows:
        lines.append("\t".join(str(row[c]) for c in COLUMNS))
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    if not os.path.isfile(AUDIT):
        sys.exit("%s is absent, run driver/ui/audit-corpus.py --write first" % AUDIT)
    rows, audit = rows_from_audit()
    text = render_table(rows)

    inert = [r for r in rows if r["inert"] == "yes"]
    unknown = [r for r in rows if r["inert"] == "unknown"]

    print("audit pairs: %s, artifact: %s, negative: %s"
          % (audit["pairs"], audit["artifact"], audit["negative"]))
    print("artifact rows in this table: %d" % len(rows))
    print("inert artifacts: %d" % len(inert))
    print("artifacts with no geometry measure: %d" % len(unknown))
    by_format = {}
    for r in rows:
        cell = by_format.setdefault(r["format"], [0, 0, 0])
        cell[0] += 1
        if r["inert"] == "yes":
            cell[1] += 1
        elif r["inert"] == "unknown":
            cell[2] += 1
    print("%-10s %8s %7s %9s" % ("format", "artifact", "inert", "unmeasured"))
    for fmt in sorted(by_format):
        a, i, u = by_format[fmt]
        print("%-10s %8d %7d %9d" % (fmt, a, i, u))
    if inert:
        print("inert rows:")
        for r in inert:
            print("  %-46s %-8s %-10s %s" % (r["case"], r["profile"], r["format"], r["measure"]))

    if args.check:
        status = 0
        with open(CENSUS) as f:
            census = json.load(f)
        for problem in census_problems(census):
            print("a case of EMPTY_CASES is not empty: %s" % problem)
            status = 1
        for problem in source_problems(census):
            print("a source of EMPTY_CASES changed after its census: %s" % problem)
            status = 1
        for case in sorted(EMPTY_CASES):
            if case in census:
                print("empty source: %s, %s sha256 %s, measured by %s"
                      % (case, census[case].get("document"), EMPTY_CASES[case][1][:16], CENSUS_RUN))
        for r in inert:
            if r["case"] not in EMPTY_CASES:
                print("inert artifact of a case outside EMPTY_CASES, record it as a negative: %s"
                      % os.path.join("files", r["case"], r["file"]))
                status = 1
        on_disk = open(OUT).read() if os.path.isfile(OUT) else ""
        if on_disk != text:
            print("ledger/inert-pairs.tsv is stale, %d rows on disk against %d computed"
                  % (max(0, on_disk.count("\n") - 1), len(rows)))
            return 1
        if status == 0:
            print("ledger/inert-pairs.tsv is current")
        return status
    if args.write:
        with open(OUT, "w") as f:
            f.write(text)
        print("wrote %s with %d rows" % (OUT, len(rows)))
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
