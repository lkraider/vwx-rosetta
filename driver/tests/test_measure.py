#!/usr/bin/env python3
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MEASURE = ROOT / "tools/measure.py"

STL = """solid t
facet normal 0 0 1
 outer loop
  vertex 0 0 0
  vertex 1 0 0
  vertex 0 1 0
 endloop
endfacet
facet normal 0 0 1
 outer loop
  vertex 1 0 0
  vertex 1 1 0
  vertex 0 1 0
 endloop
endfacet
endsolid t
"""

# A unit tetrahedron. Each face is written twice, once per winding, as the Vectorworks exporter does.
OBJ = """v 0 0 0
v 1 0 0
v 0 1 0
v 0 0 1
f 1 3 2
f 1 2 4
f 1 4 3
f 2 3 4
f 1 2 3
f 1 4 2
f 1 3 4
f 2 4 3
"""

DXF = "\n".join(["0", "SECTION", "2", "ENTITIES", "0", "LINE", "8", "0", "0", "CIRCLE", "8", "0",
                 "0", "VIEWPORT", "0", "ENDSEC", "0", "EOF", ""])


def png(width, height, pixels):
    """pixels is a list of rows of RGB tuples. Every row uses filter type 0."""
    raw = b"".join(b"\x00" + b"".join(bytes(p) for p in row) for row in pixels)

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class Measure(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def run_measure(self, name, data, env=None):
        path = os.path.join(self.tmp.name, name)
        with open(path, "wb") as fh:
            fh.write(data if isinstance(data, bytes) else data.encode())
        out = subprocess.run([sys.executable, "-I", str(MEASURE), path], capture_output=True, text=True, check=True,
                             env=dict(os.environ, **(env or {})))
        cols = out.stdout.rstrip("\n").split("\t")
        self.assertEqual(len(cols), 5)
        self.assertEqual(cols[0], path)
        return cols[1:]

    def test_ascii_stl_counts_facets(self):
        self.assertEqual(self.run_measure("a.stl", STL), ["stl", "2", "yes", "ascii triangles=2"])

    def test_binary_stl_counts_triangles(self):
        data = b"\0" * 80 + struct.pack("<I", 3) + b"\0" * 150
        self.assertEqual(self.run_measure("b.stl", data), ["stl", "3", "yes", "binary triangles=3"])

    def test_obj_counts_faces_and_volume_of_one_winding(self):
        self.assertEqual(self.run_measure("t.obj", OBJ),
                         ["obj", "8", "yes", "vertices=4 faces=8 volume=%.4f" % (1 / 6)])

    def test_png_counts_pixels_other_than_the_most_common(self):
        white, black = (255, 255, 255), (0, 0, 0)
        rows = [[white, white, white], [white, black, white], [black, white, white]]
        self.assertEqual(self.run_measure("p.png", png(3, 3, rows)),
                         ["png", "2", "yes", "3x3 ctype=2 colors=2 non_background_pixels=2"])

    def test_dxf_counts_entities_without_viewport(self):
        self.assertEqual(self.run_measure("d.dxf", DXF), ["dxf", "2", "yes", "entities=2 block_entities=0"])

    def test_empty_file_counts_zero(self):
        self.assertEqual(self.run_measure("e.stl", b""), ["stl", "0", "no", "absent or zero bytes"])

    def test_unknown_format_counts_zero(self):
        self.assertEqual(self.run_measure("u.xyz", "data"), ["xyz", "0", "no", "no reader for .xyz"])

    def test_pdf_reader_failure_counts_zero(self):
        ink = os.path.join(self.tmp.name, "ink.py")
        Path(ink).write_text("import sys\nsys.exit(\"ModuleNotFoundError: No module named 'PIL'\")\n")
        self.assertEqual(self.run_measure("f.pdf", "%PDF-1.4\n", env={"ROSETTA_PDF_INK": ink}),
                         ["pdf", "0", "no", "pdf-ink.py exit 1: ModuleNotFoundError: No module named 'PIL'"])

    def test_pdf_row_with_exit_1_keeps_its_count(self):
        ink = os.path.join(self.tmp.name, "ink.py")
        Path(ink).write_text("import sys\nprint('\\t'.join(['f.pdf', '1', '2', '3', '309', '0.000304', '7', '0.826',"
                             " 'small']))\nsys.exit(1)\n")
        self.assertEqual(self.run_measure("s.pdf", "%PDF-1.4\n", env={"ROSETTA_PDF_INK": ink}),
                         ["pdf", "309", "no", "dark_px=309 dark_frac=0.000304 extent=0.826 verdict=small"])


if __name__ == "__main__":
    unittest.main()
