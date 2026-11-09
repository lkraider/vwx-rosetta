#!/usr/bin/env python3
"""Write ledger/plugin-presence.tsv: for each plug-in object of each combined source, whether each stored
export of that source holds it.

driver/inventory/combined-sources.py puts plug-in NN of a combined source on the layer and class `pio-` plus
its name, at the centre of grid cell NN of parameters.cell_mm, in rows of ceil(sqrt(count)) cells. A reader
decides presence in one of two ways.
  layer  the file keeps layer and block names. The plug-in is held when an entity on its layer is drawing
         geometry, or when an insert of its block obj-NN holds geometry. A plug-in that sets its own class,
         such as Dimension, has its entities on that class's layer.
  cell   the file keeps world coordinates. The plug-in is held when a point of the file lies in its cell.
         A PDF page holds no scale, so its reader fits the grid to the drawing first.
A format with no reader gets `unread` on every row. PNG has no reader. A grid fit to the pixels of
plugin.combined.13 is wrong, because Drawing Border - Old fills a page-sized block at the origin.

Usage: plugin-presence.py            write the output
       plugin-presence.py --check    compare the output with the computed text, exit 1 on a difference
"""
import argparse
import base64
import bisect
import collections
import csv
import io
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RECIPES = os.path.join(ROOT, "driver", "inventory", "recipes")
LEDGER = os.path.join(ROOT, "ledger", "corpus-ledger.jsonl")
OUT = "ledger/plugin-presence.tsv"
HEADER = ["case", "plugin", "format", "profile", "file", "held", "method", "measure"]
NOT_GEOMETRY = {"VIEWPORT", "ATTRIB", "ATTDEF", "SEQEND", "BLOCK", "ENDBLK", "WIPEOUT"}


def dxf_pairs(lines):
    for i in range(0, len(lines) - 1, 2):
        yield lines[i].strip(), lines[i + 1].strip()


def held_layers(model, blocks):
    """Layer name to the count of its model entities that are drawing geometry or insert a block holding some.
    "block NAME" to the count of model inserts of block NAME when it holds geometry.

    model is a list of (kind, layer, inserted block) and blocks maps a block to a list of (kind, inserted block).
    """
    memo = {}

    def solid(name, seen=()):
        if name not in memo:
            memo[name] = name not in seen and any(
                kind not in NOT_GEOMETRY and (kind != "INSERT" or solid(ref, seen + (name,)))
                for kind, ref in blocks.get(name, []))
        return memo[name]

    held = collections.Counter()
    for kind, layer, ref in model:
        if kind not in NOT_GEOMETRY and (kind != "INSERT" or solid(ref)):
            held[layer] += 1
            if kind == "INSERT":
                held["block " + ref] += 1
    return held


def layers_dxf(path):
    with open(path, errors="replace") as f:
        lines = [line.rstrip("\r\n") for line in f]
    section = block = None
    pending = False
    records = []
    for code, value in dxf_pairs(lines):
        if code == "0" and value == "SECTION":
            pending = True
        elif pending and code == "2":
            section, pending = value, False
        elif code == "0":
            if value == "ENDSEC":
                section = None
            if value == "ENDBLK":
                block = None
            records.append({"section": section, "kind": value, "block": block})
        elif records and code == "8":
            records[-1].setdefault("layer", value)
        elif records and code == "2" and records[-1]["kind"] in ("BLOCK", "INSERT"):
            records[-1].setdefault("name", value)
            if records[-1]["kind"] == "BLOCK" and section == "BLOCKS":
                block = value
    model = [(r["kind"], r.get("layer", ""), r.get("name")) for r in records if r["section"] == "ENTITIES"]
    blocks = collections.defaultdict(list)
    for r in records:
        if r["section"] == "BLOCKS" and r["block"] and r["kind"] not in ("BLOCK", "ENDBLK"):
            blocks[r["block"]].append((r["kind"], r.get("name")))
    return held_layers(model, blocks)


def layers_dwg(path):
    """libredwg writes the DWG as JSON. Its DXF output drops the 3DSOLID records of block definitions, and its
    JSON keeps them. An entity belongs to the block header named by its owner handle. Return None when dwgread
    is absent. A model space entity has entmode 2 and no owner handle. A paper space entity has entmode 1, and
    counts with model space, as the ENTITIES section of a DXF holds both. A block entity is owned by its block
    header."""
    tool = shutil.which("dwgread")
    if not tool:
        return None
    work = tempfile.mkdtemp()
    tmp = os.path.join(work, "out.json")
    try:
        subprocess.run([tool, "-O", "JSON", "-o", tmp, path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=300)
        if not os.path.isfile(tmp) or os.path.getsize(tmp) == 0:
            return None
        with open(tmp, errors="replace") as f:
            objects = json.load(f)["OBJECTS"]
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
        os.rmdir(work)
    layer_names = {o["handle"][-1]: o.get("name", "") for o in objects if o.get("object") == "LAYER"}
    headers = {o["handle"][-1]: o.get("name", "") for o in objects if o.get("object") == "BLOCK_HEADER"}
    model, blocks = [], collections.defaultdict(list)
    for o in objects:
        kind = o.get("entity")
        if not kind:
            continue
        ref = headers.get(o["block_header"][-1]) if kind == "INSERT" and "block_header" in o else None
        if o.get("entmode") in (1, 2):
            model.append((kind, layer_names.get(o.get("layer", [None])[-1], ""), ref))
        elif "ownerhandle" in o and o["ownerhandle"][-1] in headers:
            blocks[headers[o["ownerhandle"][-1]]].append((kind, ref))
    return held_layers(model, blocks)


def points_stl(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:5].startswith(b"solid"):
        for line in data.decode("latin-1").splitlines():
            parts = line.split()
            if parts[:1] == ["vertex"]:
                yield float(parts[1]), float(parts[2])
        return
    for i in range(struct.unpack_from("<I", data, 80)[0]):
        for v in range(3):
            x, y, _z = struct.unpack_from("<3f", data, 84 + 50 * i + 12 + 12 * v)
            yield x, y


def points_obj(path):
    with open(path, errors="replace") as f:
        for line in f:
            if line.startswith("v "):
                parts = line.split()
                yield float(parts[1]), float(parts[2])


def _mat_mul(a, b):
    """Product of two 4x4 row-major matrices."""
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def _mat_apply(m, x, y, z):
    return (m[0][0] * x + m[0][1] * y + m[0][2] * z + m[0][3],
            m[1][0] * x + m[1][1] * y + m[1][2] * z + m[1][3],
            m[2][0] * x + m[2][1] * y + m[2][2] * z + m[2][3])


_IDENTITY = [[1.0 if i == j else 0.0 for j in range(4)] for i in range(4)]


def points_3ds(path):
    """3DS stores world coordinates in millimetres with Z up.

    Chunk 0x4110 holds a uint16 vertex count then XYZ float triples. Chunk 0x4000 opens with a NUL
    terminated object name. Chunk 0x4160 holds the local axes of a mesh. The 0x4110 vertices are already
    in world coordinates, so the reader ignores 0x4160.
    """
    with open(path, "rb") as f:
        data = f.read()
    containers = {0x4D4D, 0x3D3D, 0x4100}

    def walk(off, end):
        while off + 6 <= end:
            cid, length = struct.unpack_from("<HI", data, off)
            if length < 6 or off + length > end:
                return
            body = off + 6
            if cid == 0x4110:
                n = struct.unpack_from("<H", data, body)[0]
                for i in range(n):
                    x, y, _z = struct.unpack_from("<3f", data, body + 2 + 12 * i)
                    yield x, y
            elif cid == 0x4000:
                stop = data.find(b"\0", body, off + length)
                yield from walk(stop + 1 if stop >= 0 else body, off + length)
            elif cid in containers:
                yield from walk(body, off + length)
            off += length

    yield from walk(0, len(data))


def points_gltf(path):
    """glTF stores metres with Y up. Plan x is X and plan y is -Z.

    A node carries either a column-major 4x4 matrix or translation, rotation (quaternion x y z w) and
    scale. The world matrix of a node is the product of the matrices from the scene root down to it.
    """
    with open(path, "rb") as f:
        doc = json.load(f)
    base = os.path.dirname(path)
    blobs = []
    for b in doc.get("buffers", []):
        uri = b.get("uri", "")
        if uri.startswith("data:"):
            blobs.append(base64.b64decode(uri.split(",", 1)[1]))
        else:
            with open(os.path.join(base, uri), "rb") as f:
                blobs.append(f.read())

    def local(node):
        if "matrix" in node:
            m = node["matrix"]
            return [[m[c * 4 + r] for c in range(4)] for r in range(4)]
        tx, ty, tz = node.get("translation", [0.0, 0.0, 0.0])
        qx, qy, qz, qw = node.get("rotation", [0.0, 0.0, 0.0, 1.0])
        sx, sy, sz = node.get("scale", [1.0, 1.0, 1.0])
        r = [[1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw)],
             [2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw)],
             [2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy)]]
        return [[r[0][0] * sx, r[0][1] * sy, r[0][2] * sz, tx],
                [r[1][0] * sx, r[1][1] * sy, r[1][2] * sz, ty],
                [r[2][0] * sx, r[2][1] * sy, r[2][2] * sz, tz],
                [0.0, 0.0, 0.0, 1.0]]

    sizes = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}

    def positions(index):
        acc = doc["accessors"][index]
        if "bufferView" not in acc:
            return
        view = doc["bufferViews"][acc["bufferView"]]
        blob = blobs[view["buffer"]]
        start = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
        stride = view.get("byteStride") or 4 * sizes[acc["type"]]
        for i in range(acc["count"]):
            yield struct.unpack_from("<3f", blob, start + i * stride)

    nodes = doc.get("nodes", [])
    scenes = doc.get("scenes", [])
    if scenes:
        roots = scenes[doc.get("scene", 0)].get("nodes", [])
    else:
        children = {c for n in nodes for c in n.get("children", [])}
        roots = [i for i in range(len(nodes)) if i not in children]
    stack = [(i, _IDENTITY) for i in roots]
    while stack:
        i, parent = stack.pop()
        node = nodes[i]
        world = _mat_mul(parent, local(node))
        if "mesh" in node:
            for prim in doc["meshes"][node["mesh"]].get("primitives", []):
                pos = prim.get("attributes", {}).get("POSITION")
                if pos is None:
                    continue
                for x, y, z in positions(pos):
                    wx, _wy, wz = _mat_apply(world, x, y, z)
                    yield wx * 1000.0, -wz * 1000.0
        stack.extend((c, world) for c in node.get("children", []))


def _fbx_nodes(data):
    """Parse a binary FBX file into a list of nodes (name, properties, children)."""
    version = struct.unpack_from("<I", data, 23)[0]
    wide = version >= 7500
    head = "<QQQ" if wide else "<III"
    head_len = 25 if wide else 13

    def prop(off):
        t = chr(data[off])
        off += 1
        scalar = {"Y": "<h", "C": "<?", "I": "<i", "F": "<f", "D": "<d", "L": "<q"}
        if t in scalar:
            v = struct.unpack_from(scalar[t], data, off)[0]
            return v, off + struct.calcsize(scalar[t])
        if t in "fdlib":
            count, enc, clen = struct.unpack_from("<III", data, off)
            off += 12
            raw = data[off:off + clen]
            if enc == 1:
                raw = zlib.decompress(raw)
            code = {"f": "f", "d": "d", "l": "q", "i": "i", "b": "?"}[t]
            return list(struct.unpack("<%d%s" % (count, code), raw)), off + clen
        if t in "SR":
            n = struct.unpack_from("<I", data, off)[0]
            off += 4
            raw = data[off:off + n]
            return (raw.decode("utf-8", "replace") if t == "S" else raw), off + n
        raise ValueError("FBX property type %r at %d" % (t, off - 1))

    def node(off):
        end, nprops, _plen = struct.unpack_from(head, data, off)
        if end == 0:
            return None, off + head_len
        nlen = data[off + head_len - 1]
        name = data[off + head_len:off + head_len + nlen].decode("latin-1")
        p = off + head_len + nlen
        props = []
        for _ in range(nprops):
            v, p = prop(p)
            props.append(v)
        children = []
        while p < end:
            child, p = node(p)
            if child is None:
                break
            children.append(child)
        return (name, props, children), end

    out = []
    off = 27
    while off < len(data):
        n, off = node(off)
        if n is None:
            break
        out.append(n)
    return out


def _fbx_euler(rx, ry, rz):
    """Rotation matrix of FBX Euler XYZ order in degrees: R = Rz * Ry * Rx."""
    a, b, c = (math.radians(v) for v in (rx, ry, rz))
    ca, sa, cb, sb, cc, sc = math.cos(a), math.sin(a), math.cos(b), math.sin(b), math.cos(c), math.sin(c)
    mx = [[1, 0, 0, 0], [0, ca, -sa, 0], [0, sa, ca, 0], [0, 0, 0, 1]]
    my = [[cb, 0, sb, 0], [0, 1, 0, 0], [-sb, 0, cb, 0], [0, 0, 0, 1]]
    mz = [[cc, -sc, 0, 0], [sc, cc, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
    return _mat_mul(mz, _mat_mul(my, mx))


def _fbx_translate(t):
    m = [row[:] for row in _IDENTITY]
    m[0][3], m[1][3], m[2][3] = t
    return m


def _fbx_scale(s):
    m = [row[:] for row in _IDENTITY]
    m[0][0], m[1][1], m[2][2] = s
    return m


def points_fbx(path):
    """Binary FBX. Vertices sit in Geometry nodes. A Geometry connects to a Model, and a Model connects to a
    parent Model or to the root (id 0).

    The local matrix of a Model is T * Roff * Rp * Rpre * R * Rpost^-1 * Rp^-1 * Soff * Sp * S * Sp^-1,
    then the geometric transform applies to the vertices. GlobalSettings UpAxis, FrontAxis and CoordAxis
    give the file axes, and UnitScaleFactor gives centimetres per file unit.
    """
    with open(path, "rb") as f:
        data = f.read()
    top = {n[0]: n for n in _fbx_nodes(data)}

    def props70(node):
        out = {}
        for child in node[2]:
            if child[0] == "Properties70":
                for p in child[2]:
                    if p[0] == "P":
                        out[p[1][0]] = p[1][4:]
        return out

    settings = {}
    for child in top.get("GlobalSettings", ("", [], []))[2]:
        if child[0] == "Properties70":
            settings = props70(("", [], [child]))
    unit_cm = settings.get("UnitScaleFactor", [1.0])[0]
    up = settings.get("UpAxis", [1])[0]
    up_sign = settings.get("UpAxisSign", [1])[0]
    front = settings.get("FrontAxis", [2])[0]
    front_sign = settings.get("FrontAxisSign", [1])[0]
    coord = settings.get("CoordAxis", [0])[0]
    coord_sign = settings.get("CoordAxisSign", [1])[0]

    geometries, models = {}, {}
    for obj in top.get("Objects", ("", [], []))[2]:
        if obj[0] == "Geometry":
            for child in obj[2]:
                if child[0] == "Vertices":
                    geometries[obj[1][0]] = child[1][0]
        elif obj[0] == "Model":
            models[obj[1][0]] = props70(obj)
    parent = {}
    for c in top.get("Connections", ("", [], []))[2]:
        if c[0] == "C" and c[1][0] == "OO":
            parent.setdefault(c[1][1], c[1][2])

    def vec(p, key, default):
        return tuple(p[key][-3:]) if key in p else default

    def local(p):
        zero, one = (0.0, 0.0, 0.0), (1.0, 1.0, 1.0)
        rp, sp = vec(p, "RotationPivot", zero), vec(p, "ScalingPivot", zero)
        neg = lambda v: tuple(-a for a in v)
        rpost = _fbx_euler(*vec(p, "PostRotation", zero))
        rpost_inv = [[rpost[j][i] for j in range(4)] for i in range(4)]
        for i in range(3):
            rpost_inv[i][3] = rpost_inv[3][i] = 0.0
        rpost_inv[3][3] = 1.0
        chain = [_fbx_translate(vec(p, "Lcl Translation", zero)),
                 _fbx_translate(vec(p, "RotationOffset", zero)), _fbx_translate(rp),
                 _fbx_euler(*vec(p, "PreRotation", zero)), _fbx_euler(*vec(p, "Lcl Rotation", zero)),
                 rpost_inv, _fbx_translate(neg(rp)),
                 _fbx_translate(vec(p, "ScalingOffset", zero)), _fbx_translate(sp),
                 _fbx_scale(vec(p, "Lcl Scaling", one)), _fbx_translate(neg(sp))]
        m = _IDENTITY
        for step in chain:
            m = _mat_mul(m, step)
        return m

    def geometric(p):
        zero, one = (0.0, 0.0, 0.0), (1.0, 1.0, 1.0)
        m = _mat_mul(_fbx_translate(vec(p, "GeometricTranslation", zero)),
                     _fbx_euler(*vec(p, "GeometricRotation", zero)))
        return _mat_mul(m, _fbx_scale(vec(p, "GeometricScaling", one)))

    def world(model_id):
        m = _IDENTITY
        seen = set()
        while model_id in models and model_id not in seen:
            seen.add(model_id)
            m = _mat_mul(local(models[model_id]), m)
            model_id = parent.get(model_id)
        return m

    mm_per_unit = unit_cm * 10.0
    for gid, flat in geometries.items():
        model_id = parent.get(gid)
        m = world(model_id)
        if model_id in models:
            m = _mat_mul(m, geometric(models[model_id]))
        for i in range(0, len(flat) - 2, 3):
            v = _mat_apply(m, flat[i], flat[i + 1], flat[i + 2])
            # Plan x is the coord axis. Plan y points away from the viewer, opposite the front axis.
            x = v[coord] * coord_sign
            y = -v[front] * front_sign
            yield x * mm_per_unit, y * mm_per_unit


def points_sat(path):
    """ACIS SAT text. The third header line opens with the millimetres per file unit.

    A record is a type name, then fields, then `#`. A `$N` field points to record N. A `point` record ends
    with its X Y Z. A `body` record points last to its `transform`, or holds $-1. A transform holds the
    images of the X, Y and Z axes, the translation, then the scale. The records reachable from a body,
    other bodies excepted, are the topology of that body.
    """
    with open(path, errors="replace") as f:
        lines = f.read().splitlines()
    unit_mm = float(lines[2].split()[0])
    records = []
    for chunk in " ".join(lines[3:]).split("#"):
        parts = chunk.split()
        if parts and parts[0].startswith("-") and parts[0][1:].isdigit():
            parts = parts[1:]
        if parts:
            records.append(parts)

    def refs(rec):
        return [int(t[1:]) for t in rec[1:] if t.startswith("$") and t[1:].lstrip("-").isdigit() and int(t[1:]) >= 0]

    def numbers(rec):
        out = []
        for t in rec[1:]:
            try:
                out.append(float(t))
            except ValueError:
                pass
        return out

    owner = {}
    for b, rec in enumerate(records):
        if rec[0] != "body":
            continue
        ptrs = [t for t in rec[1:] if t.startswith("$")]
        t_index = int(ptrs[-1][1:]) if ptrs else -1
        if t_index < 0 or t_index >= len(records) or records[t_index][0] != "transform":
            continue
        v = numbers(records[t_index])
        stack, seen = [b], {b}
        while stack:
            i = stack.pop()
            if records[i][0] == "point":
                owner[i] = v
            for j in refs(records[i]):
                if j < len(records) and j not in seen and records[j][0] != "body":
                    seen.add(j)
                    stack.append(j)
    for i, rec in enumerate(records):
        if rec[0] != "point":
            continue
        x, y, z = numbers(rec)[-3:]
        v = owner.get(i)
        if v:
            s = v[12] if len(v) > 12 else 1.0
            x, y = (s * (x * v[0] + y * v[3] + z * v[6]) + v[9], s * (x * v[1] + y * v[4] + z * v[7]) + v[10])
        yield x * unit_mm, y * unit_mm


def points_xt(path):
    """Parasolid text transmit file, in metres with Z up.

    The text after the header is one token stream wrapped at 80 columns, and a line break can split a
    token. A POINT node is type 29, an optional 255 on the first node of a type, then the index, node id,
    attributes, owner, next and previous, then the X Y Z vector.
    """
    with open(path, errors="replace") as f:
        text = f.read()
    stream = text.split("**END_OF_HEADER", 1)[1].split("\n", 1)[1].replace("\r", "").replace("\n", "")
    toks = stream.split()

    def num(t):
        try:
            return float(t)
        except ValueError:
            return None

    found = {}
    for i, t in enumerate(toks):
        if t.lstrip("?") != "29":
            continue
        j = i + 2 if i + 1 < len(toks) and toks[i + 1] == "255" else i + 1
        ints = toks[j:j + 6]
        xyz = [num(t) for t in toks[j + 6:j + 9]]
        if len(ints) == 6 and all(t.isdigit() for t in ints) and len(xyz) == 3 and None not in xyz:
            index, node_id, _attr, _owner, nxt, prev = (int(t) for t in ints)
            if index and node_id:
                found.setdefault(index, (nxt, prev, xyz))
    # Integer runs elsewhere in the stream can read as a POINT. The next and previous fields of a POINT
    # name other POINT nodes, 0, or another geometry node at the end of a run of POINT nodes. Keep a candidate
    # when every link lands on a candidate, or when a candidate names it back.
    def linked_back(index, nxt, prev):
        return (prev in found and found[prev][0] == index) or (nxt in found and found[nxt][1] == index)

    changed = True
    while changed:
        changed = False
        for index, (nxt, prev, _xyz) in list(found.items()):
            if ((nxt and nxt not in found) or (prev and prev not in found)) and not linked_back(index, nxt, prev):
                del found[index]
                changed = True
    # Two integer runs can name each other and read as a run of POINT nodes. Drop a run whose links leave it
    # at both ends for nodes that are no candidate.
    # A false pair with 0 as one outer link leaves the run at one end only, so it stays.
    for start in list(found):
        if start not in found:
            continue
        run, todo = set(), [start]
        while todo:
            index = todo.pop()
            if index not in run:
                run.add(index)
                todo += [k for k in found[index][:2] if k in found]
        if sum(1 for index in run for k in found[index][:2] if k and k not in found) > 1:
            for index in run:
                del found[index]
    for _nxt, _prev, (x, y, _z) in found.values():
        yield x * 1000.0, y * 1000.0
    for x, y in xt_centres(toks, num):
        yield x * 1000.0, y * 1000.0


# Node type to the offset of a unit vector after the centre: CIRCLE and ELLIPSE (normal), SPHERE (axis, after
# the radius), TORUS (axis).
XT_CENTRED = {"31": 3, "32": 3, "53": 4, "54": 3}


def xt_centres(toks, num):
    """The centre of each circle, ellipse, sphere and torus node. A body of curved faces only, such as a sphere
    or a swept circle, holds no POINT node. These nodes are type, an optional 255, then index, node id,
    attributes, owner, next, previous and geometric owner, then the sense (+ or -) joined to the first token of
    the centre vector."""
    for i, kind in enumerate(toks):
        kind = kind.lstrip("?")
        if kind not in XT_CENTRED:
            continue
        j = i + 2 if i + 1 < len(toks) and toks[i + 1] == "255" else i + 1
        ints = toks[j:j + 7]
        if len(ints) < 7 or not all(t.isdigit() for t in ints) or not int(ints[0]) or not int(ints[1]):
            continue
        rest = toks[j + 7:j + 18]
        if not rest or rest[0][:1] not in ("+", "-"):
            continue
        rest = ([rest[0][1:]] if rest[0][1:] else []) + rest[1:]
        values = [num(t) for t in rest[:10]]
        if len(values) < 10 or None in values:
            continue
        k = XT_CENTRED[kind]
        if abs(sum(v * v for v in values[k:k + 3]) - 1.0) > 1e-6:
            continue
        yield values[0], values[1]


def points_iges(path):
    """IGES. Global parameter 14 is the unit flag and 13 the model space scale. The directory entry of an
    entity points in field 7 to a type 124 matrix, which can itself point to another. Status use flag 05
    marks a curve in the parameter space of a surface, so the reader skips it.

    Points come from 116 points, 110 line ends, 100 arc centres and ends, 502 vertex lists and the
    control points of 126 curves and 128 surfaces.
    """
    with open(path, errors="replace") as f:
        lines = [line.rstrip("\r\n").ljust(80) for line in f]
    section = {"G": [], "D": [], "P": []}
    for line in lines:
        if line[72] in section:
            section[line[72]].append(line)
    g = "".join(line[:72] for line in section["G"])
    pdelim, rdelim = ",", ";"
    if g.startswith("1H"):
        pdelim = g[2]
        if g[3:5] == pdelim + "1H":
            rdelim = g[5]
    gparams = _iges_split(g, pdelim, rdelim)
    unit_mm = {1: 25.4, 2: 1.0, 4: 304.8, 5: 1609344.0, 6: 1000.0, 7: 1e6, 8: 0.0254, 9: 0.001, 10: 10.0,
               11: 2.54e-5}.get(int(float(gparams[13] or 1)), 1.0)
    scale = float(gparams[12] or 1.0)
    pdata = {}
    for line in section["P"]:
        de = int(line[64:72])
        pdata[de] = pdata.get(de, "") + line[:64]
    entries = {}
    d = section["D"]
    for k in range(0, len(d) - 1, 2):
        seq = k + 1
        etype = int(d[k][0:8])
        matrix = int(d[k][48:56] or 0)
        if d[k][64:72].replace(" ", "0")[4:6] == "05":
            continue
        params = [float(v.strip().replace("D", "E").replace("d", "e") or 0.0)
                  for v in _iges_split(pdata.get(seq, ""), pdelim, rdelim)[1:] if _is_num(v)]
        entries[seq] = (etype, matrix, params)

    def matrix_of(seq, depth=0):
        etype, parent, p = entries.get(seq, (0, 0, []))
        if etype != 124 or len(p) < 12 or depth > 50:
            return None
        m = [p[0:4], p[4:8], p[8:12]]
        outer = matrix_of(parent, depth + 1) if parent else None
        if outer:
            m = [[sum(outer[r][k] * m[k][c] for k in range(3)) + (outer[r][3] if c == 3 else 0.0)
                  for c in range(4)] for r in range(3)]
        return m

    for seq, (etype, mptr, p) in entries.items():
        pts = []
        if etype == 116 and len(p) >= 3:
            pts = [p[0:3]]
        elif etype == 110 and len(p) >= 6:
            pts = [p[0:3], p[3:6]]
        elif etype == 100 and len(p) >= 7:
            pts = [(p[1], p[2], p[0]), (p[3], p[4], p[0]), (p[5], p[6], p[0])]
        elif etype == 502 and p:
            n = int(p[0])
            pts = [p[1 + 3 * i:4 + 3 * i] for i in range(n) if len(p) >= 4 + 3 * i]
        elif etype == 126 and len(p) >= 6:
            k, m = int(p[0]), int(p[1])
            a = 6 + (k + m + 2) + (k + 1)
            pts = [p[a + 3 * i:a + 3 + 3 * i] for i in range(k + 1) if len(p) >= a + 3 + 3 * i]
        elif etype == 128 and len(p) >= 9:
            k1, k2, m1, m2 = (int(v) for v in p[0:4])
            count = (k1 + 1) * (k2 + 1)
            a = 9 + (k1 + m1 + 2) + (k2 + m2 + 2) + count
            pts = [p[a + 3 * i:a + 3 + 3 * i] for i in range(count) if len(p) >= a + 3 + 3 * i]
        m = matrix_of(mptr) if mptr else None
        for x, y, z in pts:
            if m:
                x, y = (m[0][0] * x + m[0][1] * y + m[0][2] * z + m[0][3],
                        m[1][0] * x + m[1][1] * y + m[1][2] * z + m[1][3])
            yield x / scale * unit_mm, y / scale * unit_mm


def _is_num(v):
    v = v.strip()
    if not v:
        return True
    try:
        float(v.replace("D", "E").replace("d", "e"))
        return True
    except ValueError:
        return False


def _iges_split(text, pdelim, rdelim):
    """Split IGES free-format parameters. A Hollerith string nH carries n characters that can hold a
    delimiter."""
    out, i, cur = [], 0, ""
    while i < len(text):
        c = text[i]
        if c == pdelim or c == rdelim:
            out.append(cur.strip())
            cur = ""
            if c == rdelim:
                break
            i += 1
            continue
        if c == "H" and cur.strip().isdigit():
            n = int(cur.strip())
            cur = text[i + 1:i + 1 + n]
            i += 1 + n
            continue
        cur += c
        i += 1
    return out


def _ifc_entities(text):
    """Entity id to (TYPE, argument text) for the DATA section of an IFC STEP file."""
    data = text[text.index("DATA;") + 5:]
    out = {}
    for m in re.finditer(r"#(\d+)\s*=\s*([A-Z0-9_]+)\s*\((.*?)\)\s*;\s*(?=#\d+\s*=|ENDSEC)", data, re.S):
        out[int(m.group(1))] = (m.group(2), m.group(3))
    return out


def _ifc_args(raw):
    """Argument text of one STEP entity as a list. A reference becomes an int, a list a list, a string a str,
    $ and * None, and a typed value such as IFCLABEL('x') its first argument."""
    raw = "(" + raw + ")"
    pos = 0

    def value():
        nonlocal pos
        while raw[pos] in " \r\n\t":
            pos += 1
        c = raw[pos]
        if c == "#":
            m = re.compile(r"#(\d+)").match(raw, pos)
            pos = m.end()
            return int(m.group(1))
        if c == "'":
            pos += 1
            buf = []
            while True:
                if raw[pos] == "'":
                    if raw[pos + 1:pos + 2] == "'":
                        buf.append("'")
                        pos += 2
                        continue
                    pos += 1
                    return "".join(buf)
                buf.append(raw[pos])
                pos += 1
        if c == "(":
            pos += 1
            items = []
            while True:
                while raw[pos] in " \r\n\t,":
                    pos += 1
                if raw[pos] == ")":
                    pos += 1
                    return items
                items.append(value())
        if c in "$*":
            pos += 1
            return None
        m = re.compile(r"[A-Z0-9_]+\(").match(raw, pos)
        if m:
            pos = m.end() - 1
            return value()[0]
        m = re.compile(r"[^,)]+").match(raw, pos)
        pos = m.end()
        token = m.group(0).strip()
        try:
            return float(token)
        except ValueError:
            return token

    return value()


def layers_ifc(path):
    """Layer name to the count of products on it whose representation reaches at least one IfcCartesianPoint.

    A product takes the names of the IfcPresentationLayerAssignment rows that list one of its shape
    representations or one of their items. Vectorworks writes the design layer pio-<plugin> there. Grid
    Bubble exports as an IfcGrid with an empty IfcGeometricCurveSet, which reaches no point.
    """
    with open(path, encoding="latin-1") as f:
        ents = _ifc_entities(f.read())
    layer_of = collections.defaultdict(set)
    for kind, raw in ents.values():
        if kind in ("IFCPRESENTATIONLAYERASSIGNMENT", "IFCPRESENTATIONLAYERWITHSTYLE"):
            a = _ifc_args(raw)
            for item in a[2] or []:
                layer_of[item].add(a[0])
    memo = {}

    def has_point(eid):
        if eid not in memo:
            memo[eid] = False
            kind, raw = ents.get(eid, ("", ""))
            if kind == "IFCCARTESIANPOINT":
                memo[eid] = True
            elif kind and not kind.startswith(("IFCSTYLED", "IFCPRESENTATIONSTYLE")) and not kind.endswith("CONTEXT"):
                stack = [_ifc_args(raw)]
                while stack and not memo[eid]:
                    v = stack.pop()
                    if isinstance(v, list):
                        stack.extend(v)
                    elif isinstance(v, int) and has_point(v):
                        memo[eid] = True
        return memo[eid]

    held = collections.Counter()
    for kind, raw in ents.values():
        if kind in ("IFCCARTESIANPOINT", "IFCPOLYLOOP", "IFCFACE", "IFCFACEOUTERBOUND"):
            continue
        a = _ifc_args(raw)
        if len(a) < 7 or not isinstance(a[6], int) or ents.get(a[6], ("",))[0] != "IFCPRODUCTDEFINITIONSHAPE":
            continue
        layers, solid = set(), False
        for rep in _ifc_args(ents[a[6]][1])[2] or []:
            layers |= layer_of.get(rep, set())
            for item in _ifc_args(ents[rep][1])[3] or []:
                layers |= layer_of.get(item, set())
                solid = solid or has_point(item)
        if solid:
            for layer in layers:
                held[layer] += 1
    return held


def _grid_recipe(path):
    """Plug-in count and cell_mm of the recipe of the case that path belongs to: <root>/files/<case>/<file>."""
    case = os.path.basename(os.path.dirname(path))
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(path))))
    with open(os.path.join(root, "driver", "inventory", "recipes", case + ".json")) as f:
        params = json.load(f)["parameters"]
    return len(params["plugins"]), params["cell_mm"]


def _grid_fit(points, count, cell):
    """Map drawing points (u right, v down, any unit) to plan millimetres (x right, y up).

    The export holds no scale. The fit finds the cell size s and the grid corner (ou, ov) in drawing units
    that keep the points furthest from cell edges. It assumes the drawing fills the first and last column and
    the first and last row, so s lies between extent/cells and extent/(cells - 1) on each axis. The 0.2% of
    points at each end of an axis are left out of that extent, because text and leader lines can stand past
    the grid. A point outside the grid costs more than a point on a cell edge.
    """
    cols = math.ceil(math.sqrt(count))
    rows = math.ceil(count / cols)
    us = sorted(p[0] for p in points)
    vs = sorted(p[1] for p in points)
    if not us:
        return []
    trim = lambda a: (a[int(0.002 * len(a))], a[min(len(a) - 1, int(0.998 * len(a)))])
    ul, uh = trim(us)
    vl, vh = trim(vs)
    bands = (0.01, 0.03, 0.1, 0.2, 0.3, 0.4)
    lo = 0.9 * max((uh - ul) / cols, (vh - vl) / rows)
    his = [(uh - ul) / (cols - 1) if cols > 1 else None, (vh - vl) / (rows - 1) if rows > 1 else None]
    hi = min([h for h in his if h] or [lo / 0.8])
    hi = max(hi, lo * 1.0001)

    def axis(vals, low, high, s, n):
        best = None
        for i in range(61):
            o = high - n * s + (low - high + n * s) * i / 60
            score = 2 * len(bands) * (bisect.bisect_left(vals, o) + len(vals) - bisect.bisect(vals, o + n * s))
            for j in range(n + 1):
                edge = o + j * s
                for w in bands:
                    score += bisect.bisect(vals, edge + w * s) - bisect.bisect_left(vals, edge - w * s)
            if best is None or score < best[0]:
                best = (score, o)
        return best

    best = None
    for i in range(81):
        s = lo + (hi - lo) * i / 80
        su, ou = axis(us, ul, uh, s, cols)
        sv, ov = axis(vs, vl, vh, s, rows)
        if best is None or su + sv < best[0]:
            best = (su + sv, s, ou, ov)
    _score, s, ou, ov = best
    return [((u - ou) / s * cell, -(v - ov) / s * cell) for u, v in points]


def _pdf_widths(objs, page):
    """Font resource name to (default width, {code: width}) in 1/1000 text space units. A Type0 font reads
    DW and W of its descendant CIDFont. A simple font reads FirstChar and Widths."""

    def deref(text):
        m = re.match(rb"\s*(\d+)\s+0\s+R", text)
        return objs.get(int(m.group(1)), b"") if m else text

    fonts = re.search(rb"/Font\s*(<<.*?>>|\d+\s+0\s+R)", page, re.S)
    out = {}
    if not fonts:
        return out
    for name, ref in re.findall(rb"/([^\s/<>\[\]()]+)\s*(\d+)\s+0\s+R", deref(fonts.group(1))):
        font = objs.get(int(ref), b"")
        widths = {}
        m = re.search(rb"/DescendantFonts\s*(\[[^\]]*\]|\d+\s+0\s+R)", font)
        if m:
            kids = deref(m.group(1))
            cid = objs.get(int(re.search(rb"(\d+)\s+0\s+R", kids).group(1)), b"")
            dw = float((re.search(rb"/DW\s*([\d.]+)", cid) or re.match(rb"()", b"")).group(1) or 1000)
            w = re.search(rb"/W\s*\[(.*)\]", cid, re.S)
            items = re.findall(rb"\[[^\]]*\]|[\d.]+", w.group(1) if w else b"")
            i = 0
            while i < len(items):
                first = int(float(items[i]))
                if items[i + 1].startswith(b"["):
                    for k, v in enumerate(re.findall(rb"[\d.]+", items[i + 1])):
                        widths[first + k] = float(v)
                    i += 2
                else:
                    for c in range(first, int(float(items[i + 1])) + 1):
                        widths[c] = float(items[i + 2])
                    i += 3
            out[name] = (dw, widths, 2)
        else:
            first = re.search(rb"/FirstChar\s*(\d+)", font)
            vals = re.search(rb"/Widths\s*(\[[^\]]*\]|\d+\s+0\s+R)", font)
            if first and vals:
                for k, v in enumerate(re.findall(rb"[\d.]+", deref(vals.group(1)))):
                    widths[int(first.group(1)) + k] = float(v)
            out[name] = (0.0, widths, 1)
    return out


def _pdf_page_points(path):
    """(u, v) of the painted path points and of the start, middle and end of the baseline of each shown
    string on the first page, in PDF points with v down. Clip paths end with n and are skipped.

    Vectorworks writes annotation text at paper size. At 1:330 one line spans more than a cell. Some plug-ins
    start their text at the object and others centre it there, so the start alone misses the centred ones."""
    with open(path, "rb") as f:
        data = f.read()
    objs = {int(m.group(1)): m.group(2) for m in re.finditer(rb"(\d+)\s+0\s+obj(.*?)endobj", data, re.S)}
    page = next(b for b in objs.values() if re.search(rb"/Type\s*/Page(?![s\w])", b))
    fonts = _pdf_widths(objs, page)
    refs = re.search(rb"/Contents\s*(\[[^\]]*\]|\d+\s+0\s+R)", page).group(1)
    content = b""
    for ref in re.findall(rb"(\d+)\s+0\s+R", refs):
        body = objs[int(ref)]
        start = re.search(rb"stream\r?\n", body).end()
        raw = body[start:body.rindex(b"endstream")]
        content += (zlib.decompress(raw) if b"FlateDecode" in body[:start] else raw) + b"\n"
    tokens = re.finditer(rb"\((?:\\.|[^\\)])*\)|<<|>>|<[0-9A-Fa-f\s]*>|/[^\s/\[\]()<>{}%]*|\[|\]"
                         rb"|[-+]?(?:\d+\.?\d*|\.\d+)|[A-Za-z'\"*]+[0-9]*\*?|%[^\r\n]*", content)

    def mul(m, n):
        a, b, c, d, e, f = m
        A, B, C, D, E, F = n
        return a * A + b * C, a * B + b * D, c * A + d * C, c * B + d * D, e * A + f * C + E, e * B + f * D + F

    def at(m, x, y):
        return m[0] * x + m[2] * y + m[4], -(m[1] * x + m[3] * y + m[5])

    def advance(operands):
        """Width in text space of the strings and TJ adjustments among the operands of a show operator."""
        dw, widths, size = fonts.get(font, (500.0, {}, 1))
        total = 0.0
        for tok in operands:
            if tok.startswith(b"<"):
                code = bytes.fromhex(re.sub(rb"\s", b"", tok[1:-1]).decode())
            elif tok.startswith(b"("):
                code = re.sub(rb"\\(.)", rb"\1", tok[1:-1])
            else:
                total -= float(tok) / 1000.0 * font_size
                continue
            for i in range(0, len(code) - size + 1, size):
                total += widths.get(int.from_bytes(code[i:i + size], "big"), dw) / 1000.0 * font_size
        return total

    unit = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    ctm, tm, lm, leading = unit, unit, unit, 0.0
    font, font_size = b"", 0.0
    stack, nums, operands, path_pts, out = [], [], [], [], []
    for t in tokens:
        tok = t.group(0)
        if tok[:1] in b"-+.0123456789":
            nums.append(float(tok))
            operands.append(tok)
            continue
        if tok[:1] in b"(/" or (tok[:1] == b"<" and tok != b"<<"):
            operands.append(tok)
            continue
        if not tok[:1].isalpha() and tok[:1] not in b"'\"":
            continue
        op = tok.decode("latin-1")
        if op == "q":
            stack.append((ctm, font, font_size))
        elif op == "Q" and stack:
            ctm, font, font_size = stack.pop()
        elif op == "cm" and len(nums) >= 6:
            ctm = mul(tuple(nums[-6:]), ctm)
        elif op in ("m", "l") and len(nums) >= 2:
            path_pts.append(at(ctm, *nums[-2:]))
        elif op == "c" and len(nums) >= 6:
            path_pts += [at(ctm, nums[i - 6], nums[i - 5]) for i in (0, 2, 4)]
        elif op in ("v", "y") and len(nums) >= 4:
            path_pts += [at(ctm, nums[i - 4], nums[i - 3]) for i in (0, 2)]
        elif op == "re" and len(nums) >= 4:
            x, y, w, h = nums[-4:]
            path_pts += [at(ctm, x, y), at(ctm, x + w, y), at(ctm, x, y + h), at(ctm, x + w, y + h)]
        elif op in ("S", "s", "f", "F", "f*", "B", "B*", "b", "b*"):
            out += path_pts
            path_pts = []
        elif op == "n":
            path_pts = []
        elif op == "Tf" and nums and operands[:1] and operands[0].startswith(b"/"):
            font, font_size = operands[0][1:], nums[-1]
        elif op == "BT":
            tm = lm = unit
        elif op == "Tm" and len(nums) >= 6:
            tm = lm = tuple(nums[-6:])
        elif op in ("Td", "TD") and len(nums) >= 2:
            if op == "TD":
                leading = -nums[-1]
            tm = lm = mul((1.0, 0.0, 0.0, 1.0, nums[-2], nums[-1]), lm)
        elif op == "TL" and nums:
            leading = nums[-1]
        if op in ("T*", "'", '"'):
            tm = lm = mul((1.0, 0.0, 0.0, 1.0, 0.0, -leading), lm)
        if op in ("Tj", "TJ", "'", '"'):
            shown = [o for o in operands if o[:1] in b"(<"] if op != "TJ" else [o for o in operands if o[:1] != b"/"]
            width = advance(shown)
            out += [at(mul(tm, ctm), width * f, 0.0) for f in (0.0, 0.5, 1.0)]
            tm = mul((1.0, 0.0, 0.0, 1.0, width, 0.0), tm)
        nums, operands = [], []
    return out


def points_pdf(path):
    """Plan points of a vector PDF export. The page-fit step of the export scales and moves the drawing to
    centre it on the page, so _grid_fit derives the mapping from the drawing."""
    count, cell = _grid_recipe(path)
    return _grid_fit(_pdf_page_points(path), count, cell)


READERS = {
    "dxf": ("layer", layers_dxf),
    "dwg": ("layer", layers_dwg),
    "stl": ("cell", points_stl),
    "obj": ("cell", points_obj),
    "3ds": ("cell", points_3ds),
    "gltf": ("cell", points_gltf),
    "fbx": ("cell", points_fbx),
    "sat": ("cell", points_sat),
    "x_t": ("cell", points_xt),
    "igs": ("cell", points_iges),
    "ifc": ("layer", layers_ifc),
    "pdf": ("cell", points_pdf),
}


def newest_files(case):
    found = {}
    with open(LEDGER) as f:
        for line in f:
            if line.strip():
                r = json.loads(line)
                if r.get("case") == case:
                    found[(r.get("profile", ""), r.get("format", ""))] = r
    out = []
    for (profile, fmt), r in sorted(found.items()):
        rel = os.path.relpath(r["path"], ROOT) if os.path.isabs(r["path"]) else r["path"]
        if os.path.isfile(os.path.join(ROOT, rel)):
            out.append((fmt, profile, rel))
    return out


def presence(recipe, fmt, rel):
    plugins = [p["plugin"] for p in recipe["parameters"]["plugins"]]
    ext = os.path.splitext(rel)[1].lower().lstrip(".")
    method, reader = READERS.get(ext, (None, None))
    if reader is None:
        return [(name, "unread", "", "no reader for .%s" % ext) for name in plugins]
    got = reader(os.path.join(ROOT, rel))
    if got is None:
        return [(name, "unread", method, "dwgread absent") for name in plugins]
    if method == "layer":
        out = []
        for n, name in enumerate(plugins):
            on_layer, inserts = got.get("pio-" + name, 0), got.get("block obj-%02d" % n, 0)
            out.append((name, "yes" if on_layer or inserts else "no", method,
                        "entities on layer pio-%s=%d, inserts of block obj-%02d=%d" % (name, on_layer, n, inserts)))
        return out
    cell = recipe["parameters"]["cell_mm"]
    columns = math.ceil(math.sqrt(len(plugins)))
    counts = collections.Counter()
    outside = 0
    for x, y in got:
        col, row = math.floor(x / cell), math.floor(-y / cell)
        n = row * columns + col
        if 0 <= col < columns and 0 <= n < len(plugins):
            counts[n] += 1
        else:
            outside += 1
    return [(name, "yes" if counts[n] else "no", method,
             "points in cell %d=%d, outside every cell=%d" % (n, counts[n], outside)) for n, name in enumerate(plugins)]


def rows():
    out = []
    for name in sorted(os.listdir(RECIPES)):
        if not name.startswith("plugin.combined.") or not name.endswith(".json"):
            continue
        with open(os.path.join(RECIPES, name)) as f:
            recipe = json.load(f)
        case = recipe["case_id"]
        for fmt, profile, rel in newest_files(case):
            for plugin, held, method, measure in presence(recipe, fmt, rel):
                out.append([case, plugin, fmt, profile, rel, held, method, measure])
    return out


def tsv_text(table):
    buf = io.StringIO()
    w = csv.writer(buf, delimiter="\t", lineterminator="\n")
    w.writerow(HEADER)
    w.writerows(table)
    return buf.getvalue()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    text = tsv_text(rows())
    target = os.path.join(ROOT, OUT)
    if args.check:
        same = os.path.exists(target) and open(target).read() == text
        print("%s %s" % (OUT, "matches" if same else "differs"))
        return 0 if same else 1
    with open(target, "w") as f:
        f.write(text)
    print("%s written" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
