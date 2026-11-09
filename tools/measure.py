#!/usr/bin/env python3
"""Print one content count per artifact, for the --measure option of tools/install-artifact.py.

Usage: measure.py PATH...

Each output line has the TSV columns path, format, count, ok, fact. ok is `yes` or `no`.
The count is the number below for each format.
- dwg, dxf: entities in the ENTITIES section, VIEWPORT excluded. dwg is read with `dwgread -O JSON`.
- obj: `f ` lines. The fact also gives the volume of the faces, with each vertex set counted once.
- fbx: PolygonVertexIndex nodes in a binary FBX.
- png: pixels that differ from the most common pixel value.
- 3ds: faces in the FACE_ARRAY chunks.
- stl: triangles, binary or ASCII.
- x_t: whitespace tokens after **END_OF_HEADER.
- sat: `face` records.
- gltf: triangles over every mesh primitive. A buffer file that is absent or short gives count 0.
- vwx: 1 when the preamble size field at 0x54 equals the file size, else 0.
- pdf: dark pixels on page 1, from driver/ui/pdf-ink.py. This needs PIL and qlmanage.
An absent or empty file, and a format absent from the list, give count 0 and ok `no`.
"""
import collections, json, os, re, struct, subprocess, sys, tempfile, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PDF_INK = os.environ.get("ROSETTA_PDF_INK", os.path.join(ROOT, "driver", "ui", "pdf-ink.py"))
KEYS = {"dwg": "entities", "dxf": "entities", "obj": "faces", "fbx": "PolygonVertexIndex",
        "png": "non_background_pixels", "3ds": "faces", "stl": "triangles", "x_t": "tokens", "sat": "face"}


def dxf_fact(path):
    with open(path, "rb") as fh:
        lines = fh.read().decode("latin-1").splitlines()
    pairs = [(lines[i].strip(), lines[i + 1].strip()) for i in range(0, len(lines) - 1, 2)]
    section = None
    counts = collections.Counter()
    expect_name = False
    for code, val in pairs:
        if code == "0" and val == "SECTION":
            expect_name = True
            continue
        if expect_name and code == "2":
            section = val
            expect_name = False
            continue
        if code == "0" and val == "ENDSEC":
            section = None
            continue
        if code == "0" and section in ("ENTITIES", "BLOCKS") and val not in ("BLOCK", "ENDBLK", "SEQEND", "VERTEX"):
            counts[(section, val)] += 1
    ent = sum(n for (s, v), n in counts.items() if s == "ENTITIES" and v != "VIEWPORT")
    blk = sum(n for (s, v), n in counts.items() if s == "BLOCKS")
    return "entities=%d block_entities=%d" % (ent, blk), ent > 0


DWG_SKIP = {"BLOCK", "ENDBLK", "SEQEND", "VERTEX_2D", "VERTEX_3D", "VIEWPORT"}


def dwg_fact(path):
    fd, tmp = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    try:
        r = subprocess.run(["dwgread", "-O", "JSON", "-o", tmp, path], capture_output=True)
        try:
            with open(tmp, "rb") as fh:
                doc = json.loads(fh.read().decode("utf-8", "replace"))
        except ValueError:
            return "dwgread-rc=%d json-unreadable" % r.returncode, False
    finally:
        os.unlink(tmp)
    with open(path, "rb") as fh:
        ver = fh.read(6).decode("latin-1")
    objs = doc.get("OBJECTS", [])
    ents = collections.Counter(o["entity"] for o in objs if o.get("entity"))
    n = sum(v for k, v in ents.items() if k not in DWG_SKIP)
    return "version=%s objects=%d entities=%d" % (ver, len(objs), n), n > 0


def obj_fact(path):
    f = v = 0
    with open(path, "rb") as fh:
        for line in fh:
            if line.startswith(b"f "):
                f += 1
            elif line.startswith(b"v "):
                v += 1
    return "vertices=%d faces=%d volume=%.4f" % (v, f, obj_volume(path)), f > 0


def obj_volume(path):
    # The Vectorworks OBJ exporter writes every triangle twice, once per winding. The first
    # copy of each vertex set is kept, and the absolute signed volume of those is reported.
    verts, vol, seen = [], 0.0, set()
    with open(path) as fh:
        for line in fh:
            if line.startswith("v "):
                verts.append(tuple(float(x) for x in line.split()[1:4]))
            elif line.startswith("f "):
                idx = [int(tok.split("/")[0]) for tok in line.split()[1:]]
                key = frozenset(idx)
                if key in seen:
                    continue
                seen.add(key)
                pts = [verts[i - 1] if i > 0 else verts[i] for i in idx]
                for k in range(1, len(pts) - 1):
                    (ax, ay, az), (bx, by, bz), (cx, cy, cz) = pts[0], pts[k], pts[k + 1]
                    vol += (ax * (by * cz - bz * cy) - ay * (bx * cz - bz * cx) + az * (bx * cy - by * cx)) / 6.0
    return abs(vol)


def fbx_fact(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if not data.startswith(b"Kaydara FBX Binary"):
        return "not-binary-fbx", False
    ver = struct.unpack_from("<I", data, 23)[0]
    wide = ver >= 7500
    hdr = 25 if wide else 13
    names = collections.Counter()

    def walk(off, end):
        while off < end:
            eo, _np, pl = struct.unpack_from("<QQQ" if wide else "<III", data, off)
            nl = data[off + hdr - 1]
            if eo == 0:
                return
            names[data[off + hdr:off + hdr + nl].decode("latin-1")] += 1
            child = off + hdr + nl + pl
            if child < eo:
                walk(child, eo)
            off = eo

    walk(27, len(data))
    geo = len(re.findall(rb"Geometry\x00\x01Mesh", data))
    pv = names.get("PolygonVertexIndex", 0)
    return "version=%d nodes=%d mesh_geometry=%d PolygonVertexIndex=%d" % (ver, sum(names.values()), geo, pv), pv > 0


def tds_fact(path):
    with open(path, "rb") as fh:
        data = fh.read()
    counts = collections.Counter()
    faces = [0]

    def walk(off, end):
        while off + 6 <= end:
            cid, ln = struct.unpack_from("<HI", data, off)
            if ln < 6 or off + ln > end:
                counts["bad"] += 1
                return
            counts[cid] += 1
            body = off + 6
            if cid == 0x4000:  # NAMED_OBJECT: the name string comes before the child chunks.
                walk(data.index(b"\x00", body) + 1, off + ln)
            elif cid == 0x4120:  # FACE_ARRAY
                faces[0] += struct.unpack_from("<H", data, body)[0]
            elif cid in (0x4D4D, 0x3D3D, 0x4100, 0xB000):
                walk(body, off + ln)
            off += ln

    if len(data) < 6 or struct.unpack_from("<H", data, 0)[0] != 0x4D4D:
        return "no-4D4D-main-chunk", False
    walk(0, len(data))
    chunks = sum(v for k, v in counts.items() if k != "bad")
    return "chunks=%d faces=%d" % (chunks, faces[0]) + (" bad_chunk" if counts["bad"] else ""), faces[0] > 0


def stl_fact(path):
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        head = fh.read(84)
    if size >= 84:
        n = struct.unpack_from("<I", head, 80)[0]
        if 84 + 50 * n == size:
            return "binary triangles=%d" % n, n > 0
    with open(path, "rb") as fh:
        n = sum(1 for line in fh if line.strip().startswith(b"facet "))
    return "ascii triangles=%d" % n, n > 0


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def png_fact(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return "bad-signature", False
    off = 8
    idat = []
    while off < len(data):
        ln, typ = struct.unpack_from(">I4s", data, off)
        body = data[off + 8:off + 8 + ln]
        if typ == b"IHDR":
            w, h, depth, ctype, _, _, inter = struct.unpack(">IIBBBBB", body)
        elif typ == b"IDAT":
            idat.append(body)
        off += 12 + ln
    if depth != 8 or inter != 0:
        return "%dx%d depth=%d interlace=%d unsupported" % (w, h, depth, inter), False
    chans = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(b"".join(idat))
    stride = w * chans
    prev = bytearray(stride)
    counts = collections.Counter()
    pos = 0
    for _ in range(h):
        ft = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        if ft == 1:
            for i in range(chans, stride):
                line[i] = (line[i] + line[i - chans]) & 255
        elif ft == 2:
            line = bytearray((x + y) & 255 for x, y in zip(line, prev))
        elif ft == 3:
            for i in range(stride):
                left = line[i - chans] if i >= chans else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 255
        elif ft == 4:
            for i in range(stride):
                left = line[i - chans] if i >= chans else 0
                ul = prev[i - chans] if i >= chans else 0
                line[i] = (line[i] + paeth(left, prev[i], ul)) & 255
        b = bytes(line)
        counts.update(b[i:i + chans] for i in range(0, stride, chans))
        prev = line
    other = w * h - counts.most_common(1)[0][1]
    return "%dx%d ctype=%d colors=%d non_background_pixels=%d" % (w, h, ctype, len(counts), other), other > 0


def x_t_fact(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if b"**PARASOLID" not in data[:200]:
        return "no-PARASOLID-header", False
    i = data.find(b"**END_OF_HEADER")
    if i < 0:
        return "no-END_OF_HEADER", False
    body = data[data.index(b"\n", i) + 1:]
    tokens = body.split()
    return "payload_bytes=%d tokens=%d" % (len(body), len(tokens)), len(tokens) > 50


def sat_fact(path):
    with open(path, "rb") as fh:
        text = fh.read().decode("latin-1")
    recs = re.findall(r"^-?\d+\s+([A-Za-z][\w-]*)", text, re.M)
    c = collections.Counter(recs)
    return "records=%d body=%d face=%d edge=%d" % (len(recs), c["body"], c["face"], c["edge"]), \
        c["face"] + c["edge"] > 0


def measure_gltf(path):
    with open(path) as fh:
        d = json.load(fh)
    acc = d.get("accessors", [])
    for b in d.get("buffers", []):
        uri = b.get("uri", "")
        if uri.startswith("data:"):
            continue
        bp = os.path.join(os.path.dirname(path), uri)
        if not os.path.isfile(bp) or os.path.getsize(bp) < b.get("byteLength", 0):
            return 0, False, "buffer %s absent or short" % uri
    tris = verts = prims = 0
    for m in d.get("meshes", []):
        for p in m.get("primitives", []):
            prims += 1
            pos = p.get("attributes", {}).get("POSITION")
            n = acc[pos]["count"] if pos is not None else 0
            verts += n
            tris += (acc[p["indices"]]["count"] if "indices" in p else n) // 3
    return tris, True, "triangles=%d vertices=%d primitives=%d nodes=%d" % (
        tris, verts, prims, len(d.get("nodes", [])))


def measure_vwx(path):
    if os.path.getsize(path) < 0x94:
        return 0, False, "shorter than the preamble"
    with open(path, "rb") as fh:
        head = fh.read(0x94)
    size_ok = int.from_bytes(head[0x54:0x58], "big") == os.path.getsize(path)
    tokens = " ".join(t.decode("latin-1") for t in head[0x0E:0x20].split(b"\0") if t)
    fact = "token=%s build=%d size_ok=%s" % (tokens, int.from_bytes(head[0x50:0x54], "big"), str(size_ok).lower())
    return int(size_ok), size_ok, fact


def measure_pdf(path):
    with tempfile.TemporaryDirectory() as out_dir:
        p = subprocess.run([sys.executable, "-I", PDF_INK, "--out-dir", out_dir, path],
                           capture_output=True, text=True)
    rows = p.stdout.splitlines()
    row = rows[-1].split("\t") if rows else []
    if len(row) < 9:
        last = (p.stderr.strip().splitlines() or ["no row"])[-1]
        return 0, False, "pdf-ink.py exit %d: %s" % (p.returncode, last[:200])
    dark = int(row[4]) if row[4].isdigit() else 0
    return dark, row[-1] == "ink", "dark_px=%s dark_frac=%s extent=%s verdict=%s" % (row[4], row[5], row[7], row[8])


READERS = {"dxf": dxf_fact, "dwg": dwg_fact, "obj": obj_fact, "fbx": fbx_fact, "3ds": tds_fact,
           "stl": stl_fact, "png": png_fact, "x_t": x_t_fact, "sat": sat_fact}
MEASURES = {"gltf": measure_gltf, "vwx": measure_vwx, "pdf": measure_pdf}


def measure(path):
    ext = path.rsplit(".", 1)[-1].lower()
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        return ext, 0, False, "absent or zero bytes"
    if ext in MEASURES:
        return (ext,) + MEASURES[ext](path)
    if ext not in READERS:
        return ext, 0, False, "no reader for .%s" % ext
    fact, ok = READERS[ext](path)
    m = re.search(r"\b%s=(\d+)" % KEYS[ext], fact)
    return ext, int(m.group(1)) if m else 0, bool(ok), fact


if __name__ == "__main__":
    for path in sys.argv[1:]:
        ext, count, ok, fact = measure(path)
        print("%s\t%s\t%d\t%s\t%s" % (path, ext, count, "yes" if ok else "no", fact))
