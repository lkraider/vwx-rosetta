#!/usr/bin/env python3
import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("audit_corpus", ROOT / "driver/ui/audit-corpus.py")
audit_corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit_corpus)


class WriteNeedsMeasureTools(unittest.TestCase):
    def stop(self, modules, which):
        with mock.patch.dict(sys.modules, modules), \
                mock.patch.object(audit_corpus.shutil, "which", return_value=which), \
                mock.patch.object(sys, "argv", ["audit-corpus.py", "--write"]), \
                mock.patch.object(audit_corpus, "read_table", side_effect=AssertionError("read the store")):
            with self.assertRaises(SystemExit) as stop:
                audit_corpus.main()
        return str(stop.exception.code)

    def test_write_stops_before_reading_the_store_when_pil_is_missing(self):
        self.assertIn("--write needs PIL", self.stop({"PIL": None}, "/usr/local/bin/dwg2dxf"))

    def test_write_stops_before_reading_the_store_when_dwg2dxf_is_missing(self):
        self.assertIn("--write needs dwg2dxf", self.stop({"PIL": mock.MagicMock()}, None))


if __name__ == "__main__":
    unittest.main()
