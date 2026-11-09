#!/usr/bin/env python3
"""Count the face surface types and the edge curve types of each 3DSOLID in DXF files.

`reader-audit.py` calls `sat_types` to count the same types in a SAT file.

Usage: <venv>/bin/python -I driver/acis-types.py FILE.dxf...
Prints one line per 3DSOLID: file, space, handle, entity type, verdict, face types, edge curve types.
The space is `Model` or the name of the block that holds the entity.
An intcurve-curve is named by its subtype, for example intcurve:exact_int_cur. A `ref N`
subtype names the Nth subtype definition of the same SAB stream.
The verdict is `spline-only` when every face is plane-surface or spline-surface:exact_spl_sur and every
edge curve is straight-curve or intcurve:exact_int_cur.
"""
import collections, sys
import ezdxf
from ezdxf.acis import sab, sat

FACES_OK = {"plane-surface", "spline-surface:exact_spl_sur"}
CURVES_OK = {"straight-curve", "intcurve:exact_int_cur"}


def subtypes(records):
    defs = []
    for r in records:
        toks = r.data
        for i, t in enumerate(toks):
            if t.tag == 15 and i + 1 < len(toks) and toks[i + 1].tag == 13 and toks[i + 1].value != "ref":
                defs.append(toks[i + 1].value)
    return defs


def kind(record, defs):
    toks = record.data
    for i, t in enumerate(toks):
        if t.tag == 13:
            if t.value == "ref":
                n = toks[i + 1].value
                return defs[n] if n < len(defs) else "ref?%s" % n
            return t.value
    return "?"


def sat_subtypes(records):
    defs = []
    for r in records:
        toks = [t for t in r.data if isinstance(t, str)]
        for i, t in enumerate(toks):
            if t == "{" and i + 1 < len(toks) and toks[i + 1] != "ref":
                defs.append(toks[i + 1])
    return defs


def sat_kind(record, defs):
    toks = [t for t in record.data if isinstance(t, str)]
    for i, t in enumerate(toks):
        if t == "{" and i + 1 < len(toks):
            if toks[i + 1] == "ref":
                n = int(toks[i + 2])
                return defs[n] if n < len(defs) else "ref?%s" % n
            return toks[i + 1]
    return "?"


def body_types(data):
    records = sab.parse_sab(data).entities
    return count_types(records, subtypes(records), kind)


def sat_types(text):
    """Return the SAT header, the bodies, and the face and curve type counters of a SAT file."""
    doc = sat.parse_sat(text)
    faces, curves = count_types(doc.entities, sat_subtypes(doc.entities), sat_kind)
    return doc.header, len(doc.bodies), faces, curves


def count_types(records, defs, kind):
    faces, curves = collections.Counter(), collections.Counter()
    for r in records:
        if r.name == "spline-surface":
            faces["spline-surface:" + kind(r, defs)] += 1
        elif r.name.endswith("-surface"):
            faces[r.name] += 1
        elif r.name == "intcurve-curve":
            curves["intcurve:" + kind(r, defs)] += 1
        elif r.name.endswith("-curve"):
            curves[r.name] += 1
    return faces, curves


def main():
    for path in sys.argv[1:]:
        doc = ezdxf.readfile(path)
        spaces = [doc.modelspace()] + [b for b in doc.blocks if not b.name.lower().startswith("*paper_space")
                                       and b.name.lower() != "*model_space"]
        for space in spaces:
            for e in space.query("3DSOLID BODY REGION SURFACE"):
                data = e.sab
                if not data:
                    print("%s\t%s\t%s\t%s\tno-sab" % (path, space.name, e.dxf.handle, e.dxftype()))
                    continue
                faces, curves = body_types(data)
                ok = set(faces) <= FACES_OK and set(curves) <= CURVES_OK and faces
                print("%s\t%s\t%s\t%s\t%s\t%s\t%s" % (path, space.name, e.dxf.handle, e.dxftype(),
                                                    "spline-only" if ok else "other",
                                                    dict(sorted(faces.items())), dict(sorted(curves.items()))))


if __name__ == "__main__":
    main()
