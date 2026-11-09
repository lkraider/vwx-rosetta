#!/usr/bin/env python3
import importlib.util
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "driver/inventory/make-pict.py"
FIXTURE = ROOT / "driver/inventory/fixtures/pict-asym.pict"


def bmp_rows(path):
    data = path.read_bytes()
    offset, = struct.unpack("<I", data[10:14])
    width, height, _, bits = struct.unpack("<iiHH", data[18:30])
    assert bits == 24 and height < 0, (bits, height)
    stride = (width * 3 + 3) // 4 * 4
    return [[data[offset + y * stride + x * 3] < 128 for x in range(width)] for y in range(-height)]


class MakePict(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name) / "out.pict"
        subprocess.run([sys.executable, "-I", str(TOOL), str(self.out)], check=True)
        spec = importlib.util.spec_from_file_location("make_pict", TOOL)
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)

    def tearDown(self):
        self.tmp.cleanup()

    def test_stored_fixture_matches_the_tool(self):
        self.assertEqual(self.out.read_bytes(), FIXTURE.read_bytes())

    def test_header_size_frame_and_end(self):
        data = self.out.read_bytes()
        self.assertEqual(data[:512], bytes(512))
        size, top, left, bottom, right = struct.unpack(">H4h", data[512:522])
        self.assertEqual(size, len(data) - 512)
        self.assertEqual((top, left, bottom, right), (0, 0, self.m.HEIGHT, self.m.WIDTH))
        self.assertEqual(data[522:526], b"\x00\x11\x02\xff")
        self.assertEqual(data[-2:], b"\x00\xff")
        self.assertEqual(data.count(b"\x00\x9a\x00\x00\x00\xff"), 1)

    @unittest.skipUnless(shutil.which("sips"), "sips decodes PICT on macOS only")
    def test_imageio_draws_the_bitmap(self):
        bmp = Path(self.tmp.name) / "out.bmp"
        subprocess.run(["sips", "-s", "format", "bmp", str(self.out), "--out", str(bmp)], check=True, capture_output=True)
        expected = [[self.m.black(x, y) for x in range(self.m.WIDTH)] for y in range(self.m.HEIGHT)]
        self.assertEqual(bmp_rows(bmp), expected)


if __name__ == "__main__":
    unittest.main()
