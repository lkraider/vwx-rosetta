#!/usr/bin/env python3
"""Audit every artifact in the reference store and report what an offline reader can check.

This reads the store and writes nothing. Use --write to publish ledger/corpus-audit.json
and ledger/companions.tsv.

The audit answers one question. Does the store hold enough for a reader that never runs
Vectorworks? It reports, per format, the structural facts of each file, the pairs with no
file, the groups of files that carry the same digest under different case names, the
artifacts whose geometry is empty, and the artifacts whose source document is not recorded.

Usage: audit-corpus.py [--write] [--verbose]
"""

import collections
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STORE = os.path.dirname(ROOT)
FILES = os.path.join(STORE, "files")
LEDGER = os.path.join(STORE, "ledger")
sys.path.insert(0, os.path.join(STORE, "driver"))
from store_path import resolve  # noqa: E402

# The extension each required format writes on disk.
EXTENSION = {
    "dwg": "dwg",
    "dxf": "dxf",
    "png": "png",
    "pdf": "pdf",
    "obj": "obj",
    "fbx": "fbx",
    "3ds": "3ds",
    "parasolid": "x_t",
    "stl": "stl",
    "sat": "sat",
    "ifc": "ifc",
    "gltf": "gltf",
    "svg": "svg",
    "csv": "csv",
    "xlsx": "xlsx",
    "vwx": "vwx",
}

# A companion file that belongs to a primary artifact. The ledger records the primary
# artifact alone, so the audit reports these separately instead of counting them missing.
COMPANION = {"mtl", "jpg", "jpeg", "png_tex", "tif"}

# The formats whose measure reads the file as well as its bytes. The DWG measure converts
# the file with `dwg2dxf`. The PNG measure decodes it with PIL. Every other measure reads
# the bytes alone.
PATH_FACTS = {"dwg", "png"}

# The MTL statements that name a texture file. The file name is the last field.
MTL_MAP = ("map_Kd", "map_Bump", "bump", "refl", "map_d")


def read_table(path):
    with open(path) as handle:
        head = next(handle).rstrip("\n").split("\t")
        return [dict(zip(head, line.rstrip("\n").split("\t"))) for line in handle if line.strip()]


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def companion_links():
    """Map each file that an OBJ, MTL or glTF file names to the primary artifact that reached it.

    An OBJ line that starts with mtllib names one or more MTL files. An MTL line that
    starts with a name in MTL_MAP names a texture. A glTF `buffers[].uri` names a buffer and
    an `images[].uri` names a texture. Each name resolves against the directory of the naming
    file. A texture inherits the primary artifact of its MTL."""
    links = {}
    for case in sorted(os.listdir(FILES)):
        d = os.path.join(FILES, case)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if name.endswith(".gltf"):
                with open(os.path.join(d, name)) as handle:
                    doc = json.load(handle)
                for key, kind in (("buffers", "buffer"), ("images", "texture")):
                    for i, item in enumerate(doc.get(key, [])):
                        uri = item.get("uri", "")
                        if uri and not uri.startswith("data:"):
                            links.setdefault(os.path.normpath(os.path.join(d, uri)),
                                             (kind, case, name, "%s: %s[%d].uri %s" % (name, key, i, uri)))
                continue
            if not name.endswith(".obj"):
                continue
            for line in open(os.path.join(d, name), encoding="latin-1"):
                line = line.strip()
                if line.startswith("mtllib"):
                    for lib in line.split()[1:]:
                        links.setdefault(os.path.normpath(os.path.join(d, lib)),
                                         ("mtl", case, name, name + ": " + line))
    for mtl, (_, case, primary, _) in list(links.items()):
        if not os.path.isfile(mtl):
            continue
        for line in open(mtl, encoding="latin-1"):
            line = line.strip()
            fields = line.split()
            if fields and fields[0] in MTL_MAP and len(fields) > 1:
                tex = os.path.normpath(os.path.join(os.path.dirname(mtl), fields[-1]))
                links.setdefault(tex, ("texture", case, primary,
                                       os.path.basename(mtl) + ": " + line))
    return links


def ledger_paths():
    named = set()
    with open(os.path.join(LEDGER, "corpus-ledger.jsonl")) as handle:
        for line in handle:
            if line.strip():
                named.add(os.path.normpath(resolve(json.loads(line)["path"], STORE)))
    return named


def facts_stl(data):
    out = {"binary": not data[:5].startswith(b"solid")}
    if out["binary"] and len(data) >= 84:
        count = struct.unpack_from("<I", data, 80)[0]
        out["triangles"] = count
        out["length_ok"] = len(data) == 84 + 50 * count
        lo = [1e30] * 3
        hi = [-1e30] * 3
        for i in range(count):
            off = 84 + 50 * i + 12
            for v in range(3):
                x, y, z = struct.unpack_from("<3f", data, off + 12 * v)
                for k, val in enumerate((x, y, z)):
                    lo[k] = min(lo[k], val)
                    hi[k] = max(hi[k], val)
        out["extent"] = [round(hi[k] - lo[k], 4) for k in range(3)]
    return out


def facts_sat(data):
    """Facts of an ACIS SAT file. Every body record line starts with a negative index."""
    text = data.decode("latin-1", "replace")
    lines = text.splitlines()
    out = {"head": lines[0].strip() if lines else ""}
    out["lines"] = len(lines)
    if lines:
        fields = lines[0].split()
        out["header"] = [int(f) for f in fields if f.lstrip("-").isdigit()]
    out["end_marker"] = any(line.strip() == "End-of-ACIS-data" for line in lines)
    body = [line for line in lines if re.match(r"^-\d+ ", line)]
    out["body_records"] = len(body)
    names = collections.Counter(line.split()[1] for line in body if len(line.split()) > 1)
    out["record_types"] = dict(names.most_common(6))
    return out


def facts_step(data):
    text = data.decode("latin-1", "replace")
    out = {"magic_ok": text.startswith("ISO-10303-21")}
    out["entities"] = text.count("=")
    out["length_unit"] = "LENGTH_UNIT" in text
    for name in ("METRE", "MILLI", "INCH", "FOOT"):
        if name + "(" in text.upper():
            out["unit"] = name
            break
    return out


def facts_iges(data):
    """Each entity has two directory lines, and the first holds the entity type in columns 1-8.
    Type 186 is a manifold solid B-rep object and type 510 is one of its faces. The start
    section is free text, so the check reads the section letter in column 73."""
    lines = data.decode("latin-1", "replace").splitlines()
    out = {}
    for tag in "SGDPT":
        out[tag.lower()] = sum(1 for line in lines if len(line) > 72 and line[72] == tag)
    out["magic_ok"] = bool(lines) and len(lines[0]) > 72 and lines[0][72] == "S"
    directory = [line for line in lines if len(line) > 72 and line[72] == "D"][::2]
    types = collections.Counter(int(line[:8]) for line in directory if line[:8].strip().isdigit())
    out["entities"] = len(directory)
    out["solids"] = types.get(186, 0)
    out["faces"] = types.get(510, 0)
    out["types"] = " ".join("%d=%d" % kv for kv in sorted(types.items()))
    return out


def facts_obj(data):
    text = data.decode("latin-1", "replace")
    out = {
        "vertices": sum(1 for line in text.splitlines() if line.startswith("v ")),
        "faces": sum(1 for line in text.splitlines() if line.startswith("f ")),
        "usemtl": sum(1 for line in text.splitlines() if line.startswith("usemtl")),
        "mtllib": sum(1 for line in text.splitlines() if line.startswith("mtllib")),
    }
    lo = [1e30] * 3
    hi = [-1e30] * 3
    for line in text.splitlines():
        if not line.startswith("v "):
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        try:
            xyz = [float(parts[1]), float(parts[2]), float(parts[3])]
        except ValueError:
            continue
        for k, val in enumerate(xyz):
            lo[k] = min(lo[k], val)
            hi[k] = max(hi[k], val)
    if out["vertices"]:
        out["extent"] = [round(hi[k] - lo[k], 4) for k in range(3)]
    return out


def facts_fbx(data):
    """Facts of an FBX file.

    This function does not parse the binary FBX node stream. It searches the bytes for
    the node names Vertices and PolygonVertexIndex. A hit shows that the name occurs in
    the file. A hit does not show that the node holds a non-empty array."""
    out = {"magic_ok": data.startswith(b"Kaydara FBX Binary")}
    if out["magic_ok"]:
        out["version"] = struct.unpack_from("<I", data, 23)[0]
    out["vertices_offset"] = data.find(b"Vertices")
    out["has_vertices"] = out["vertices_offset"] >= 0
    out["has_polygon_vertex_index"] = b"PolygonVertexIndex" in data
    return out


THREEDS_SIMPLE_CONTAINER = {0x4D4D, 0x3D3D, 0x4100, 0xAFFF}


def facts_3ds(data):
    """Facts of a 3D Studio file. Walk the chunk tree and count the mesh records.

    A chunk header is a uint16 id then a uint32 length that counts the whole chunk.
    Chunk 0x4110 holds a uint16 vertex count then that many XYZ float triples. Chunk
    0x4120 holds a uint16 face count, then that many four-uint16 records, then its own
    sub-chunks. Chunk 0x4000 is an object block whose payload opens with a NUL
    terminated object name, so a reader that skips the name reads the name bytes as a
    chunk header and stops. The length field is a uint32 and not a uint16."""
    out = {"bytes": len(data)}
    if len(data) < 6:
        out["short"] = True
        out["has_mesh"] = False
        return out
    first, declared = struct.unpack_from("<HI", data, 0)
    out["first_chunk"] = hex(first)
    out["declared_length"] = declared
    out["length_ok"] = declared == len(data)
    out["declared_ok"] = first == 0x4D4D and 6 <= declared <= len(data)

    counts = {"objects": 0, "vertex_chunks": 0, "vertices": 0,
              "face_chunks": 0, "faces": 0, "bad_chunks": 0}

    def walk(off, end, depth):
        while off + 6 <= end and depth <= 12:
            cid, length = struct.unpack_from("<HI", data, off)
            if length < 6 or off + length > end:
                counts["bad_chunks"] += 1
                return
            body = off + 6
            limit = off + length
            if cid == 0x4110:
                if body + 2 <= limit:
                    n = struct.unpack_from("<H", data, body)[0]
                    if body + 2 + 12 * n <= limit:
                        counts["vertex_chunks"] += 1
                        counts["vertices"] += n
            elif cid == 0x4120:
                if body + 2 <= limit:
                    n = struct.unpack_from("<H", data, body)[0]
                    after = body + 2 + 8 * n
                    if after <= limit:
                        counts["face_chunks"] += 1
                        counts["faces"] += n
                        walk(after, limit, depth + 1)
            elif cid == 0x4000:
                counts["objects"] += 1
                stop = data.find(b"\0", body, limit)
                walk(stop + 1 if stop >= 0 else body, limit, depth + 1)
            elif cid in THREEDS_SIMPLE_CONTAINER:
                walk(body, limit, depth + 1)
            off += length

    walk(0, len(data), 0)
    out.update(counts)
    out["has_mesh"] = counts["vertices"] > 0
    return out


def facts_xt(data):
    """Facts of a Parasolid transmit file. The header is text and the body is an opaque
    token stream, so the data line count is the measure of content."""
    text = data.decode("latin-1", "replace")
    lines = text.splitlines()
    out = {"lines": len(lines)}
    for tag in ("**PART1;", "**PART2;", "**PART3;"):
        out[tag.strip("*").strip(";").lower()] = tag in text
    end = next((i for i, line in enumerate(lines) if line.startswith("**END_OF_HEADER")), -1)
    out["header_lines"] = end + 1 if end >= 0 else 0
    out["data_lines"] = len(lines) - (end + 1) if end >= 0 else 0
    for key in ("APPL=", "SCH=", "GUISE="):
        hit = next((line for line in lines if line.startswith(key)), "")
        if hit:
            out[key.rstrip("=").lower()] = hit.split("=", 1)[1].strip()
    return out


def dwg_section_entities(path):
    """Convert the DWG with libredwg and count the entity records it holds.

    libredwg reads the AC1032 object stream, which no standard library reaches. The
    conversion writes a text DXF and this reads its ENTITIES section. A VIEWPORT record is
    a paper space window and not drawing geometry, so it is counted separately.

    Measured 2026-10-16. `building.door.free.dwg` carries 1 record, a VIEWPORT.
    `spatial.extrude.asym.dwg` carries 2, a 3DSOLID and a VIEWPORT, so the model holds one
    entity. `ix.mech.rational-surface-trim-hole-units.dwg` carries 1, a VIEWPORT, so its
    NURBS surface did not reach the DWG.

    Return None when `dwg2dxf` is absent, so the caller records `unknown` rather than a
    wrong verdict.
    """
    tool = shutil.which("dwg2dxf")
    if not tool:
        return None
    fd, tmp = tempfile.mkstemp(suffix=".dxf")
    os.close(fd)
    # `dwg2dxf` does not write over a file that already exists, and `mkstemp` creates one.
    # Removing it first is what makes the conversion write anything at all.
    os.unlink(tmp)
    try:
        subprocess.run([tool, "-o", tmp, path], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=120)
        # `dwg2dxf` exits 1 on a file it converted and warned about, so the output file is
        # the evidence and not the exit status.
        if not os.path.isfile(tmp) or os.path.getsize(tmp) == 0:
            return None
        with open(tmp, errors="replace") as f:
            lines = [line.rstrip("\r\n") for line in f]
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

    return dxf_drawing_entities(lines)


def dxf_drawing_entities(lines):
    """Count the entity records of a text DXF in model space and in block definitions.

    A VIEWPORT record is a paper space window and not drawing geometry, so it is counted
    separately. BLOCK and ENDBLK open and close a definition, so they are left out. Measured
    2026-10-18, the DXF of `control.blank.mm` holds one VIEWPORT and nothing else.
    """
    census = collections.Counter()
    blocks = collections.Counter()
    section = None
    pending_section = False
    for i in range(0, len(lines) - 1, 2):
        code, value = lines[i].strip(), lines[i + 1].strip()
        if code == "0" and value == "SECTION":
            pending_section = True
            continue
        if pending_section and code == "2":
            section = value
            pending_section = False
            continue
        if code == "0" and value == "ENDSEC":
            section = None
            continue
        if code == "0" and section == "ENTITIES":
            census[value] += 1
        elif code == "0" and section == "BLOCKS" and value not in ("BLOCK", "ENDBLK"):
            blocks[value] += 1

    viewports = census.get("VIEWPORT", 0)
    block_geometry = sum(n for k, n in blocks.items() if k != "VIEWPORT")
    return {"records": sum(census.values()),
            "viewports": viewports,
            "geometry": sum(census.values()) - viewports,
            "block_geometry": block_geometry,
            "types": dict(census.most_common(8))}


def facts_dwg(data, path=None):
    out = {"signature": data[:6].decode("latin-1", "replace")}
    out["magic_ok"] = out["signature"].startswith("AC10")
    if path:
        summary = dwg_section_entities(path)
        if summary is None:
            out["tool"] = "absent"
        else:
            out.update(summary)
    return out


def facts_dxf(data):
    text = data.decode("latin-1", "replace")
    out = {"text": not data.startswith(b"AutoCAD Binary DXF")}
    out["sections"] = text.count("\nSECTION")
    out["entities"] = text.count("\nAcDbEntity")
    census = collections.Counter()
    for line in text.splitlines():
        token = line.strip()
        if token.isupper() and token and token.isalpha() and len(token) > 3:
            census[token] += 1
    out["census"] = dict(census.most_common(8))
    drawing = dxf_drawing_entities(text.splitlines())
    out["geometry"] = drawing["geometry"]
    out["block_geometry"] = drawing["block_geometry"]
    return out


def facts_pdf(data):
    out = {"magic_ok": data.startswith(b"%PDF-")}
    out["trailer_ok"] = b"%%EOF" in data[-2048:]
    out["pages"] = len(re.findall(rb"/Type\s*/Page(?![A-Za-z])", data))
    return out


def facts_png(data, path=None):
    if len(data) < 24:
        return {"magic_ok": False}
    width, height = struct.unpack_from(">II", data, 16)
    out = {"magic_ok": data.startswith(b"\x89PNG\r\n\x1a\n"), "width": width, "height": height}
    if not path:
        return out
    # A rendered page is mostly white. The fraction of pixels darker than 250 separates a
    # drawing from a blank page. Measured 2026-10-16, the review found every PNG non-blank.
    try:
        from PIL import Image
    except ImportError:
        out["tool"] = "absent"
        return out
    with Image.open(path) as image:
        grey = image.convert("L")
        pixels = grey.tobytes()
    out["pixels"] = len(pixels)
    out["ink"] = sum(1 for value in pixels if value < 250)
    out["ink_fraction"] = round(out["ink"] / len(pixels), 6) if pixels else 0.0
    return out


def facts_gltf(data):
    """Count the vertices and triangles of every mesh primitive from the accessor counts.

    A primitive with indices has index count / 3 triangles, else POSITION count / 3."""
    doc = json.loads(data)
    accessors = doc.get("accessors", [])
    vertices = triangles = primitives = 0
    for mesh in doc.get("meshes", []):
        for primitive in mesh.get("primitives", []):
            primitives += 1
            position = primitive.get("attributes", {}).get("POSITION")
            count = accessors[position]["count"] if position is not None else 0
            vertices += count
            if "indices" in primitive:
                count = accessors[primitive["indices"]]["count"]
            triangles += count // 3
    return {"vertices": vertices, "triangles": triangles, "primitives": primitives,
            "buffers": [b.get("uri", "") for b in doc.get("buffers", [])]}


IFC_NOT_ELEMENTS = {"IFCPROJECT", "IFCSITE", "IFCBUILDING", "IFCBUILDINGSTOREY", "IFCOPENINGELEMENT",
                    "IFCPRODUCTDEFINITIONSHAPE"}


def facts_ifc(data):
    """`elements` counts the instances that reference an IfcProductDefinitionShape. The project,
    the site, the building, the storey and the openings hold a shape too and are left out."""
    text = data.decode("latin-1", "replace")
    instances = re.findall(r"^#(\d+)\s*=\s*([A-Z0-9_]+)\((.*?)\);\s*$", text, re.M | re.S)
    shapes = {n for n, kind, _args in instances if kind == "IFCPRODUCTDEFINITIONSHAPE"}
    elements = collections.Counter(kind for _n, kind, args in instances if kind not in IFC_NOT_ELEMENTS
                                   and shapes.intersection(re.findall(r"#(\d+)", args)))
    return {"magic_ok": text.startswith("ISO-10303-21"), "entities": text.count("="),
            "elements": sum(elements.values()),
            "element_types": " ".join("%s=%d" % kv for kv in sorted(elements.items()))}


def facts_vwx(data):
    """The fields of the 148-byte preamble that name the saved format and its writer.

    A document saved by its own version holds two tokens at 0x0E, for example
    `VW23.0.2 VW31.6.0`, and a `BUILD: ` string. A document that Vectorworks 2027
    exports as an older version holds one token, for example `VectorWorks 217`,
    and no `BUILD: ` string."""
    head = data[:0x94]
    marker = head.find(b"BUILD: ")
    return {
        "format_word": int.from_bytes(head[0:4], "big"),
        "version_tokens": [t.decode("latin-1") for t in head[0x0E:0x20].split(b"\0") if t],
        "build": int.from_bytes(head[0x50:0x54], "big"),
        "build_string": head[marker:].split(b"\0")[0].decode("latin-1") if marker >= 0 else None,
        "size_ok": int.from_bytes(head[0x54:0x58], "big") == len(data),
    }


FACTS = {
    "vwx": facts_vwx,
    "gltf": facts_gltf,
    "stl": facts_stl,
    "sat": facts_sat,
    "step": facts_step,
    "iges": facts_iges,
    "obj": facts_obj,
    "fbx": facts_fbx,
    "3ds": facts_3ds,
    "dwg": facts_dwg,
    "dxf": facts_dxf,
    "pdf": facts_pdf,
    "png": facts_png,
    "x_t": facts_xt,
    "ifc": facts_ifc,
}


def element_count(ext, facts, size):
    """A single number that says how much content the file carries, or None."""
    if ext == "stl":
        return facts.get("triangles")
    if ext == "obj":
        return facts.get("faces")
    if ext == "sat":
        return facts.get("body_records")
    if ext == "step" or ext == "ifc":
        return facts.get("entities")
    if ext == "iges":
        return facts.get("entities")
    if ext == "dxf":
        return facts.get("entities")
    if ext == "pdf":
        return facts.get("pages")
    if ext == "x_t":
        return facts.get("data_lines")
    if ext in ("dwg", "3ds", "fbx", "png"):
        return size
    return None


def require_measure_tools():
    try:
        import PIL  # noqa: F401
    except ImportError:
        sys.exit("audit-corpus.py: --write needs PIL for the PNG ink measure, run it with $ROSETTA_READER_PYTHON")
    if not shutil.which("dwg2dxf"):
        sys.exit("audit-corpus.py: --write needs dwg2dxf on PATH for the DWG measure, install LibreDWG")


def main():
    write = "--write" in sys.argv
    if write:
        require_measure_tools()
    verbose = "--verbose" in sys.argv

    coverage = read_table(os.path.join(LEDGER, "coverage.tsv"))
    source_map = {}
    smap_path = os.path.join(ROOT, "source-map.tsv")
    if os.path.exists(smap_path):
        for line in open(smap_path):
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3:
                source_map[parts[0]] = {"path": parts[1], "sha256": parts[2]}
    entries = []
    for row in coverage:
        case, profile, fmt = row["case"], row["profile"], row["format"]
        ext = EXTENSION.get(fmt, fmt)
        name = row.get("artifact") or ""
        path = os.path.join(FILES, case, name) if name else ""
        entry = {"case": case, "profile": profile, "format": fmt,
                 "state": row["state"], "file": name}
        if row["state"] != "artifact" or not os.path.isfile(path):
            entries.append(entry)
            continue
        data = open(path, "rb").read()
        entry["bytes"] = len(data)
        entry["sha256"] = digest(path)
        fn = FACTS.get(ext)
        if fn:
            try:
                # The DWG and PNG measures convert or decode the file, so they need its path
                # as well as its bytes. PATH_FACTS names them rather than passing the path to
                # every other measure, which reads its bytes only.
                entry["facts"] = fn(data, path) if ext in PATH_FACTS else fn(data)
            except Exception as exc:  # a malformed file must not stop the audit
                entry["facts"] = {"error": type(exc).__name__ + ":" + str(exc)[:60]}
        entry["elements"] = element_count(ext, entry.get("facts") or {}, len(data))
        src = source_map.get(case, {})
        entry["source_sha256"] = src.get("sha256", "")
        entries.append(entry)

    # companions: files in a case directory that no coverage.tsv row names. This set also
    # holds artifacts that corpus-ledger.jsonl names in a format outside coverage.tsv.
    named = {os.path.join(FILES, e["case"], e["file"]) for e in entries if e.get("file")}
    links = companion_links()
    in_ledger = ledger_paths()
    companions = []
    for case in sorted(os.listdir(FILES)):
        d = os.path.join(FILES, case)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            p = os.path.join(d, name)
            if not os.path.isfile(p) or p in named:
                continue
            ext = name.rsplit(".", 1)[-1].lower()
            item = {"case": case, "file": name,
                    "bytes": os.path.getsize(p), "sha256": digest(p),
                    "in_ledger": p in in_ledger}
            if p in links:
                kind, pcase, pfile, line = links[p]
                item.update(kind=kind, primary_case=pcase, primary_file=pfile, linked_by=line)
            elif ext in COMPANION:
                item.update(kind="mtl" if ext == "mtl" else "texture",
                            primary_case="", primary_file="", linked_by="unreferenced")
            else:
                item.update(kind="artifact", primary_case=case, primary_file=name,
                            linked_by="corpus-ledger.jsonl" if p in in_ledger else "unreferenced")
            companions.append(item)

    by_digest = collections.defaultdict(list)
    for e in entries:
        if e.get("sha256"):
            by_digest[e["sha256"]].append(e["case"] + "/" + e["file"])
    duplicates = {k: v for k, v in by_digest.items() if len({x.split("/")[0] for x in v}) > 1}

    empty = [e["case"] + "/" + e["file"] for e in entries
             if e.get("elements") == 0]
    tiny = [e["case"] + "/" + e["file"] for e in entries
            if e.get("bytes") is not None and e["bytes"] < 128]

    per_format = collections.OrderedDict()
    for fmt in sorted({e["format"] for e in entries}):
        group = [e for e in entries if e["format"] == fmt]
        done = [e for e in group if e["state"] == "artifact"]
        per_format[fmt] = {
            "pairs": len(group),
            "artifact": len(done),
            "negative": len(group) - len(done),
            "digests": len({e["sha256"] for e in done if e.get("sha256")}),
            "empty": sum(1 for e in done if e.get("elements") == 0),
            "with_source": sum(1 for e in done if e.get("source_sha256")),
            "min_bytes": min((e["bytes"] for e in done if e.get("bytes")), default=0),
            "max_bytes": max((e["bytes"] for e in done if e.get("bytes")), default=0),
        }

    report = {
        "pairs": len(coverage),
        "artifact": sum(1 for e in entries if e["state"] == "artifact"),
        "negative": sum(1 for e in entries if e["state"] != "artifact"),
        "per_format": per_format,
        "duplicate_digest_groups": duplicates,
        "empty_artifacts": sorted(empty),
        "tiny_artifacts": sorted(tiny),
        "companions": companions,
        "entries": entries,
    }

    print("pairs            %d" % report["pairs"])
    print("artifact         %d" % report["artifact"])
    print("negative         %d" % report["negative"])
    print("companion files  %d" % len(companions))
    print("duplicate digest groups %d" % len(duplicates))
    print("empty artifacts  %d" % len(empty))
    print("tiny artifacts   %d" % len(tiny))
    print()
    print("%-11s %5s %8s %8s %7s %7s %10s %10s %s"
          % ("format", "pairs", "artifact", "negative", "digests", "empty", "minsize", "maxsize", "withsrc"))
    for fmt, v in per_format.items():
        print("%-11s %5d %8d %8d %7d %7d %10d %10d %d"
              % (fmt, v["pairs"], v["artifact"], v["negative"], v["digests"],
                 v["empty"], v["min_bytes"], v["max_bytes"], v["with_source"]))

    if verbose:
        print("\nduplicate digest groups")
        for d, names in sorted(duplicates.items(), key=lambda x: -len(x[1])):
            print("  %s  %d files" % (d[:12], len(names)))
            for n in names:
                print("      " + n)
        print("\nempty artifacts")
        for n in sorted(empty):
            print("  " + n)
        print("\ncompanion files")
        for c in companions:
            print("  %s/%s %d" % (c["case"], c["file"], c["bytes"]))

    if write:
        out = os.path.join(LEDGER, "corpus-audit.json")
        with open(out, "w") as handle:
            json.dump(report, handle, indent=1, sort_keys=True)
        print("\nwrote " + out)
        out = os.path.join(LEDGER, "companions.tsv")
        head = ("primary_case", "primary_file", "companion_case", "companion_file",
                "bytes", "sha256", "kind", "linked_by")
        with open(out, "w") as handle:
            handle.write("\t".join(head) + "\n")
            for c in companions:
                if c["kind"] in ("mtl", "texture", "buffer"):
                    handle.write("\t".join(str(v) for v in (
                        c["primary_case"], c["primary_file"], c["case"], c["file"],
                        c["bytes"], c["sha256"], c["kind"], c["linked_by"])) + "\n")
        print("wrote " + out)


if __name__ == "__main__":
    main()
