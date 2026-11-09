#!/usr/bin/env python3
import importlib.util
import os
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HAS_EZDXF = importlib.util.find_spec("ezdxf") is not None
if HAS_EZDXF:
    spec = importlib.util.spec_from_file_location("reader_audit", ROOT / "driver/reader-audit.py")
    reader_audit = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reader_audit)


@unittest.skipUnless(HAS_EZDXF, "reader-audit.py imports ezdxf. driver/ui/validate-store.sh runs this test "
                                "under $ROSETTA_READER_PYTHON, a Python with ezdxf 1.4.5")
class RejectedPdf(unittest.TestCase):
    def test_detail_names_the_store_relative_path(self):
        with tempfile.TemporaryDirectory() as scratch:
            path = os.path.join(scratch, "broken.pdf")
            Path(path).write_bytes(b"%PDF-1.4\ngarbage\n")
            result, detail = reader_audit.read_pdf(path)
        self.assertEqual(result, "rejected")
        self.assertNotIn("qpdf: %s:" % path, detail)
        self.assertIn("qpdf: %s:" % os.path.relpath(path, reader_audit.ROOT), detail)


@unittest.skipUnless(HAS_EZDXF, "reader-audit.py imports ezdxf")
class Failures(unittest.TestCase):
    def row(self, path, fmt, result, detail=""):
        return ["c", path, "0" * 64, fmt, "r", result, detail]

    def test_unparsed_and_empty_sat_fail(self):
        table = [self.row("files/c/a.dxf", "dxf", "rejected", "DXFError: x"),
                 self.row("files/c/b.sat", "sat", "parsed", "version=500 bodies=0 faces={} curves={}"),
                 self.row("files/c/c.step", "step", "LENGTH_UNIT", "schema=X"),
                 self.row("files/c/d.pdf", "pdf", "warnings", "pages=1")]
        self.assertEqual([f.split(":")[0] for f in reader_audit.failures(table)],
                         ["files/c/a.dxf", "files/c/b.sat", "files/c/d.pdf"])

    def test_accepted_reason_must_match_a_failing_file(self):
        table = [self.row("files/c/a.dxf", "dxf", "rejected"), self.row("files/c/b.dxf", "dxf", "parsed")]
        accepted = {"files/c/a.dxf": "r", "files/c/b.dxf": "r", "files/c/gone.dxf": "r"}
        with unittest.mock.patch.dict(reader_audit.ACCEPTED, accepted):
            self.assertEqual([f.split(":")[0] for f in reader_audit.failures(table)],
                             ["files/c/b.dxf", "files/c/gone.dxf"])


if __name__ == "__main__":
    unittest.main()
