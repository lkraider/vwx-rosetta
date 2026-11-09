#!/usr/bin/env python3
"""Measure the mesh topology of every 3DS, OBJ, FBX and glTF artifact under `files/`.

Each row gives the vertex records, the faces as stored, the triangles of a fan over each
face, the total area of those triangles, and the vertex count after welding equal positions.
FBX and glTF place each mesh under a node transform, so their positions pass through the
node hierarchy first. 3DS and OBJ store world positions. The weld rounds each coordinate to
a grid of WELD_GRID times the diagonal of the bounding box of the file. glTF stores float32
positions, and FBX transforms round in the last bits, so one corner shared by two meshes can
land on positions about 1e-8 of the diagonal apart. The weld counts of the store are the same
for every grid from 1e-7 to 1e-5. Each format keeps its own unit and axes, so areas compare
across the formats of one case only after a unit factor. glTF is in metres. OBJ writes each
triangle twice, once per winding.

Each OBJ and 3DS row of a case that holds an FBX file carries the faces and the total area of
that FBX, and its own area as a fraction of the FBX area, with the OBJ area halved. A face count
does not compare. FBX tessellates a curved surface finer, and `solid.cone.asym` holds 144 faces
in FBX and 40 in 3DS with the same area within 0.7%. Measured 2026-10-23, every file that holds
the whole model lies at 0.993 to 1.099 of the FBX area, and every file that holds part of it at
0.003 to 0.5. A file below PARTIAL_BELOW of the FBX area reads `partial`, and any other reads
`full`. A partial file does not fail the check.

Usage:
  mesh-topology.py --write     write ledger/mesh-topology.tsv
  mesh-topology.py --check     exit 1 when the table on disk differs, or a file holds 0 faces
                               and ZERO_FACES names no reason. Print each partial file.
  mesh-topology.py             print the table
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FILES = os.path.join(ROOT, "files")
OUT = os.path.join(ROOT, "ledger", "mesh-topology.tsv")
COLUMNS = ["case", "format", "path", "sha256", "meshes", "vertices", "faces", "triangles",
           "total_area", "welded_vertices", "fbx_faces", "fbx_total_area", "area_of_fbx", "against_fbx"]
EXTENSIONS = {".3ds": "3ds", ".obj": "obj", ".fbx": "fbx", ".gltf": "gltf"}
WELD_GRID = 1e-6
PARTIAL_BELOW = 0.95
# path: the reason the store keeps a mesh file with 0 faces
ZERO_FACES = {}

_spec = importlib.util.spec_from_file_location("inert_pairs", os.path.join(ROOT, "driver", "ui", "inert-pairs.py"))
inert_pairs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(inert_pairs)

IDENTITY = [[1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0], [0.0, 0.0, 0.0, 1.0]]


def matmul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def translate(t):
    return [[1.0, 0.0, 0.0, t[0]], [0.0, 1.0, 0.0, t[1]], [0.0, 0.0, 1.0, t[2]], [0.0, 0.0, 0.0, 1.0]]


def scale(s):
    return [[s[0], 0.0, 0.0, 0.0], [0.0, s[1], 0.0, 0.0], [0.0, 0.0, s[2], 0.0], [0.0, 0.0, 0.0, 1.0]]


def rotate_xyz(degrees):
    """FBX rotation order eEulerXYZ: X first, then Y, then Z."""
    x, y, z = (math.radians(d) for d in degrees)
    cx, sx, cy, sy, cz, sz = math.cos(x), math.sin(x), math.cos(y), math.sin(y), math.cos(z), math.sin(z)
    rx = [[1.0, 0.0, 0.0, 0.0], [0.0, cx, -sx, 0.0], [0.0, sx, cx, 0.0], [0.0, 0.0, 0.0, 1.0]]
    ry = [[cy, 0.0, sy, 0.0], [0.0, 1.0, 0.0, 0.0], [-sy, 0.0, cy, 0.0], [0.0, 0.0, 0.0, 1.0]]
    rz = [[cz, -sz, 0.0, 0.0], [sz, cz, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0], [0.0, 0.0, 0.0, 1.0]]
    return matmul(rz, matmul(ry, rx))


def transpose3(m):
    return [[m[j][i] for j in range(3)] + [0.0] for i in range(3)] + [[0.0, 0.0, 0.0, 1.0]]


def apply(m, v):
    return tuple(m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2] + m[i][3] for i in range(3))


FBX_ARRAYS = {"f": ("f", 4), "d": ("d", 8), "l": ("q", 8), "i": ("i", 4), "b": ("?", 1)}
FBX_SCALARS = {"Y": "h", "C": "?", "I": "i", "F": "f", "D": "d", "L": "q"}


def fbx_nodes(data):
    """Return the top-level nodes of a binary FBX as (name, properties, children) triples."""
    if not data.startswith(b"Kaydara FBX Binary  \0"):
        raise ValueError("not a binary FBX")
    version, = struct.unpack_from("<I", data, 23)
    head = "<QQQB" if version >= 7500 else "<IIIB"
    head_size = struct.calcsize(head)

    def prop(pos):
        kind = chr(data[pos])
        pos += 1
        if kind in FBX_SCALARS:
            fmt = "<" + FBX_SCALARS[kind]
            return struct.unpack_from(fmt, data, pos)[0], pos + struct.calcsize(fmt)
        if kind in FBX_ARRAYS:
            count, encoding, size = struct.unpack_from("<III", data, pos)
            raw = data[pos + 12:pos + 12 + size]
            if encoding == 1:
                raw = zlib.decompress(raw)
            fmt, width = FBX_ARRAYS[kind]
            return list(struct.unpack("<%d%s" % (count, fmt), raw[:count * width])), pos + 12 + size
        if kind in "SR":
            n, = struct.unpack_from("<I", data, pos)
            return data[pos + 4:pos + 4 + n], pos + 4 + n
        raise ValueError("FBX property type %r" % kind)

    def nodes(pos, end):
        out = []
        while pos < end:
            stop, nprops, _size, nlen = struct.unpack_from(head, data, pos)
            if stop == 0:
                break
            name = data[pos + head_size:pos + head_size + nlen].decode("latin-1")
            p = pos + head_size + nlen
            props = []
            for _ in range(nprops):
                value, p = prop(p)
                props.append(value)
            out.append((name, props, nodes(p, stop) if p < stop else []))
            pos = stop
        return out

    return nodes(27, len(data))


def fbx_local(p):
    zero = (0.0, 0.0, 0.0)

    def get(key, default=zero):
        return tuple(p.get(key, default))

    rp, sp = get("RotationPivot"), get("ScalingPivot")
    steps = [translate(get("Lcl Translation")), translate(get("RotationOffset")), translate(rp),
             rotate_xyz(get("PreRotation")), rotate_xyz(get("Lcl Rotation")),
             transpose3(rotate_xyz(get("PostRotation"))), translate(tuple(-x for x in rp)),
             translate(get("ScalingOffset")), translate(sp), scale(get("Lcl Scaling", (1.0, 1.0, 1.0))),
             translate(tuple(-x for x in sp))]
    m = IDENTITY
    for step in steps:
        m = matmul(m, step)
    geometric = matmul(translate(get("GeometricTranslation")),
                       matmul(rotate_xyz(get("GeometricRotation")), scale(get("GeometricScaling", (1.0, 1.0, 1.0)))))
    return m, geometric


def fbx_meshes(path):
    with open(path, "rb") as f:
        top = {n[0]: n for n in fbx_nodes(f.read())}
    models, geometries, parent = {}, {}, {}
    for name, props, kids in top["Objects"][2]:
        if name == "Geometry":
            child = {k[0]: k[1][0] for k in kids if k[1]}
            if "Vertices" in child:
                geometries[props[0]] = (child["Vertices"], child.get("PolygonVertexIndex", []))
        elif name == "Model":
            settings = {}
            for k in kids:
                if k[0] == "Properties70":
                    for entry in k[2]:
                        settings[entry[1][0].decode("latin-1")] = entry[1][4:]
            models[props[0]] = settings
    for name, props, _kids in top.get("Connections", ("", [], []))[2]:
        if name == "C" and props[0] == b"OO":
            parent.setdefault(props[1], props[2])

    def world(model):
        m, geometric = fbx_local(models[model])
        up = parent.get(model)
        while up in models:
            m = matmul(fbx_local(models[up])[0], m)
            up = parent.get(up)
        return matmul(m, geometric)

    meshes = []
    for gid, (flat, index) in geometries.items():
        model = parent.get(gid)
        m = world(model) if model in models else IDENTITY
        faces, face = [], []
        for i in index:
            # A negative index ends its polygon and stores the index as its bitwise complement.
            face.append(~i if i < 0 else i)
            if i < 0:
                faces.append(face)
                face = []
        meshes.append(([apply(m, flat[i:i + 3]) for i in range(0, len(flat), 3)], faces))
    return meshes


GLTF_COMPONENTS = {5120: "b", 5121: "B", 5122: "h", 5123: "H", 5125: "I", 5126: "f"}
GLTF_WIDTH = {"SCALAR": 1, "VEC3": 3}


def gltf_meshes(path):
    with open(path) as f:
        doc = json.load(f)
    buffers = []
    for b in doc.get("buffers", []):
        with open(os.path.join(os.path.dirname(path), b["uri"]), "rb") as f:
            buffers.append(f.read())

    def accessor(n):
        a = doc["accessors"][n]
        view = doc["bufferViews"][a["bufferView"]]
        fmt = GLTF_COMPONENTS[a["componentType"]]
        width = GLTF_WIDTH[a["type"]]
        size = struct.calcsize("<" + fmt)
        stride = view.get("byteStride") or size * width
        base = view.get("byteOffset", 0) + a.get("byteOffset", 0)
        data = buffers[view["buffer"]]
        return [struct.unpack_from("<%d%s" % (width, fmt), data, base + i * stride) for i in range(a["count"])]

    def node_matrix(node):
        if "matrix" in node:
            m = node["matrix"]
            return [[m[c * 4 + r] for c in range(4)] for r in range(4)]
        t = node.get("translation", [0.0, 0.0, 0.0])
        x, y, z, w = node.get("rotation", [0.0, 0.0, 0.0, 1.0])
        r = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w), 0.0],
             [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w), 0.0],
             [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y), 0.0],
             [0.0, 0.0, 0.0, 1.0]]
        return matmul(translate(t), matmul(r, scale(node.get("scale", [1.0, 1.0, 1.0]))))

    meshes = []

    def visit(n, above):
        node = doc["nodes"][n]
        m = matmul(above, node_matrix(node))
        if "mesh" in node:
            for prim in doc["meshes"][node["mesh"]]["primitives"]:
                if prim.get("mode", 4) != 4:
                    raise ValueError("primitive mode %s" % prim.get("mode"))
                verts = [apply(m, v) for v in accessor(prim["attributes"]["POSITION"])]
                index = [i[0] for i in accessor(prim["indices"])] if "indices" in prim else list(range(len(verts)))
                meshes.append((verts, [index[i:i + 3] for i in range(0, len(index), 3)]))
        for child in node.get("children", []):
            visit(child, m)

    for n in doc["scenes"][doc.get("scene", 0)]["nodes"]:
        visit(n, IDENTITY)
    return meshes


def three_ds_meshes(path):
    with open(path, "rb") as f:
        return inert_pairs.three_ds_objects(f.read())


def obj_meshes(path):
    return [inert_pairs.obj_mesh(path)]


READERS = {"3ds": three_ds_meshes, "obj": obj_meshes, "fbx": fbx_meshes, "gltf": gltf_meshes}


def measure(meshes):
    vertices = faces = triangles = 0
    area = 0.0
    points = [p for verts, _ in meshes for p in verts]
    if points:
        diagonal = math.dist([min(c) for c in zip(*points)], [max(c) for c in zip(*points)])
        step = (diagonal or 1.0) * WELD_GRID
        positions = {tuple(round(c / step) for c in p) for p in points}
    else:
        positions = set()
    for verts, polys in meshes:
        vertices += len(verts)
        for poly in polys:
            faces += 1
            for k in range(1, len(poly) - 1):
                triangles += 1
                area += inert_pairs.triangle_area(verts[poly[0]], verts[poly[k]], verts[poly[k + 1]])
    return [str(len(meshes)), str(vertices), str(faces), str(triangles), "%.6f" % area, str(len(positions))]


def rows():
    out = []
    for case in sorted(os.listdir(FILES)):
        folder = os.path.join(FILES, case)
        if not os.path.isdir(folder):
            continue
        for name in sorted(os.listdir(folder)):
            fmt = EXTENSIONS.get(os.path.splitext(name)[1].lower())
            if not fmt:
                continue
            path = os.path.join(folder, name)
            with open(path, "rb") as f:
                digest = hashlib.sha256(f.read()).hexdigest()
            out.append([case, fmt, os.path.relpath(path, ROOT), digest] + measure(READERS[fmt](path)))
    return against_fbx(out)


def against_fbx(table):
    faces, area = COLUMNS.index("faces"), COLUMNS.index("total_area")
    fbx = {r[0]: r for r in table if r[1] == "fbx" and os.path.basename(r[2]) == r[0] + ".fbx"}
    for r in table:
        ref = fbx.get(r[0])
        if r[1] not in ("obj", "3ds") or ref is None or float(ref[area]) <= 0:
            r += ["-", "-", "-", "-"]
            continue
        fraction = float(r[area]) / (2 if r[1] == "obj" else 1) / float(ref[area])
        r += [ref[faces], ref[area], "%.3f" % fraction, "partial" if fraction < PARTIAL_BELOW else "full"]
    return table


def partials(table):
    col = {c: COLUMNS.index(c) for c in ("faces", "total_area", "fbx_faces", "fbx_total_area", "area_of_fbx")}
    return ["%s: %s faces, area %s, and the FBX holds %s faces, area %s, so %s of the FBX area" % (
        r[2], r[col["faces"]], r[col["total_area"]], r[col["fbx_faces"]], r[col["fbx_total_area"]],
        r[col["area_of_fbx"]]) for r in table if r[-1] == "partial"]


def failures(table):
    out = []
    for row in table:
        path, empty = row[2], row[COLUMNS.index("faces")] == "0"
        if empty and path not in ZERO_FACES:
            out.append("%s: 0 faces" % path)
        if not empty and path in ZERO_FACES:
            out.append("%s: ZERO_FACES names a reason and the file holds faces" % path)
    for path in sorted(set(ZERO_FACES) - {r[2] for r in table}):
        out.append("%s: ZERO_FACES names a file that is not in files/" % path)
    return out


def render(table):
    return "".join("\t".join(r) + "\n" for r in [COLUMNS] + table)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    table = rows()
    text = render(table)
    if args.write:
        with open(OUT, "w") as f:
            f.write(text)
    elif args.check:
        failed = failures(table)
        for line in failed:
            print("failed " + line)
        for line in partials(table):
            print("partial " + line)
        with open(OUT) as f:
            if f.read() != text:
                print("ledger/mesh-topology.tsv differs from what the readers give")
                return 1
        if failed:
            return 1
        print("ledger/mesh-topology.tsv is current")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
