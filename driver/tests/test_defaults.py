#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


sweep_ui = load("sweep_ui", "driver/ui/sweep-ui.py")
compare = load("defaults_compare", "driver/defaults-compare.py")

TREE = "\n".join("\t".join(cells) for cells in [
    ["window_title", "Export PDF"],
    ["node", "0", "AXWindow", "AXDialog", "Export PDF", "", "", "null", "", "", "settable=null"],
    ["node", "3", "AXStaticText", "", "", "Format:", "", "true", "", "string", "settable=false"],
    ["node", "3", "AXPopUpButton", "", "", "PDF", "", "true", "", "string", "settable=false"],
    ["node", "3", "AXCheckBox", "", "Export classes as PDF layers", "0", "", "true", "", "number", "settable=false"],
    ["node", "4", "AXCheckBox", "", "Downsample higher resolution raster images to:", "0", "", "true", "", "number",
     "settable=false"],
    ["node", "4", "AXTextField", "", "", "300", "", "false", "", "string", "settable=false"],
    ["node", "1", "AXButton", "", "Export", "", "", "true", "", "", "settable=false"],
]) + "\n"

SAT = b"500 0 1 0\n@7 unknown 9 ACIS 32.0 NT 24 Mon Oct 19 10:00:00 2026\n-0 face $1 $2 $3 $-1 $4 forward single out #\n"


class ReadDialog(unittest.TestCase):
    def test_each_control_takes_its_title_or_the_label_before_it(self):
        with mock.patch.object(sweep_ui, "cli", return_value=(0, TREE)):
            controls, tree = sweep_ui.read_dialog("1", "Export PDF")
        self.assertEqual(tree, TREE)
        self.assertEqual(controls, [
            {"role": "AXPopUpButton", "label": "Format:", "value": "PDF", "enabled": "true"},
            {"role": "AXCheckBox", "label": "Export classes as PDF layers", "value": "0", "enabled": "true"},
            {"role": "AXCheckBox", "label": "Downsample higher resolution raster images to:", "value": "0",
             "enabled": "true"},
            {"role": "AXTextField", "label": "Format:", "value": "300", "enabled": "false"},
        ])


class Keeping(unittest.TestCase):
    def test_a_defaults_file_stays_in_its_run_folder(self):
        self.assertEqual(sweep_ui.keeping("c", "R", True), {
            "dest_dir": os.path.join(sweep_ui.ROOT, "runs", "R", "defaults", "c"), "ledger": False,
            "retire_sidecars": False, "rescue": False})

    def test_a_normal_file_goes_to_the_store(self):
        self.assertEqual(sweep_ui.keeping("c", "R", False), {
            "dest_dir": os.path.join(sweep_ui.ROOT, "files", "c"), "ledger": True,
            "retire_sidecars": True, "rescue": True})


class RoutePlan(unittest.TestCase):
    def test_defaults_reads_the_dialog_after_the_profile_controls(self):
        steps = sweep_ui.route_plan("3ds", "3ds.mesh.all-layers", defaults=True)
        read = steps.index("read every control of the options dialog, and no rescue step")
        self.assertEqual(steps[read - 1], "set radio/label/All Visible Objects in All Layers = 1")
        self.assertTrue(steps[-1].endswith("runs/<run_id>/defaults/<case>/"))

    def test_a_route_without_an_options_dialog_reads_none(self):
        steps = sweep_ui.route_plan("sat", "sat.solids", defaults=True)
        self.assertFalse([s for s in steps if s.startswith("read ")])


class Compare(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Path(self.tmp.name, "store")
        self.run = Path(self.tmp.name, "evidence", "runs", "R")
        (self.run / "records").mkdir(parents=True)
        (self.run / "defaults" / "c").mkdir(parents=True)
        (self.store / "files" / "c").mkdir(parents=True)
        (self.store / "files" / "c" / "c.sat").write_bytes(SAT)

    def tearDown(self):
        self.tmp.cleanup()

    def record(self, **fields):
        rec = {"case": "c", "profile": "sat.solids", "format": "sat", "defaults": True, "status": "ok",
               "path": "runs/R/defaults/c/c.sat", "dialog_read": []}
        rec.update(fields)
        (self.run / "records" / "c.sat.solids.json").write_text(json.dumps(rec))

    def compare(self):
        out = io.StringIO()
        with mock.patch.object(sys, "argv", ["defaults-compare.py", str(self.run), "--store", str(self.store)]), \
                contextlib.redirect_stdout(out):
            code = compare.main()
        return code, [line.split("\t") for line in out.getvalue().splitlines()[1:]]

    def test_an_equal_file_exits_0(self):
        (self.run / "defaults" / "c" / "c.sat").write_bytes(SAT)
        self.record(dialog_read=[{"role": "AXCheckBox", "label": "L", "value": "1", "enabled": "false"}])
        code, rows = self.compare()
        self.assertEqual(code, 0)
        self.assertIn(["c", "sat.solids", "sat", "version", "500", "500", "yes"], rows)
        self.assertIn(["c", "sat.solids", "sat", "faces", "single 1 double 0", "single 1 double 0", "yes"], rows)
        self.assertIn(["c", "sat.solids", "sat", "dialog: AXCheckBox L", "", "1 (disabled)", ""], rows)

    def test_a_different_value_exits_1(self):
        (self.run / "defaults" / "c" / "c.sat").write_bytes(SAT.replace(b"500", b"700", 1).replace(b"single", b"double"))
        self.record()
        code, rows = self.compare()
        self.assertEqual(code, 1)
        self.assertIn(["c", "sat.solids", "sat", "version", "500", "700", "no"], rows)

    def test_a_count_that_measure_cannot_read_differs(self):
        (self.run / "defaults" / "c" / "c.sat").write_bytes(SAT)
        self.record()
        out = "%s\tsat\t0\tno\tno reader\n" % (self.store / "files" / "c" / "c.sat")
        out += "%s\tsat\t0\tno\tno reader\n" % (self.run.parent.parent / "runs/R/defaults/c/c.sat")
        with mock.patch.object(compare.subprocess, "run", return_value=mock.Mock(stdout=out)):
            code, rows = self.compare()
        self.assertEqual(code, 1)
        self.assertIn(["c", "sat.solids", "sat", "count", "not measured: no reader", "not measured: no reader", "no"],
                      rows)

    def test_a_failed_export_exits_1(self):
        self.record(status="save_panel_missing")
        code, rows = self.compare()
        self.assertEqual(code, 1)
        self.assertEqual(rows, [["c", "sat.solids", "sat", "status", "", "save_panel_missing", "no"]])

    def test_an_absent_stored_file_differs(self):
        (self.store / "files" / "c" / "c.sat").unlink()
        self.record()
        code, rows = self.compare()
        self.assertEqual(code, 1)
        self.assertEqual(rows, [["c", "sat.solids", "sat", "stored file", "absent", "c.sat", "no"]])

    def test_a_run_with_no_record_exits_1(self):
        code, rows = self.compare()
        self.assertEqual((code, rows), (1, []))

    def test_pdf_layers_read_the_catalog(self):
        with mock.patch.object(compare, "qpdf", return_value=b"/OCProperties /Type /OCG /Type /OCG"):
            self.assertEqual(compare.pdf("x"), {"pdf layers": "on (2)", "images": "0"})
        with mock.patch.object(compare, "qpdf", return_value=b"/Subtype /Image"):
            self.assertEqual(compare.pdf("x"), {"pdf layers": "off", "images": "1"})

    def test_a_record_of_a_normal_run_differs(self):
        self.record(defaults=False)
        code, rows = self.compare()
        self.assertEqual(code, 1)
        self.assertEqual(rows, [["c", "sat.solids", "sat", "status", "", "ok without --defaults", "no"]])

    def test_a_failed_row_without_the_flag_keeps_its_status(self):
        self.record(defaults=False, status="exception")
        _code, rows = self.compare()
        self.assertEqual(rows, [["c", "sat.solids", "sat", "status", "", "exception", "no"]])


if __name__ == "__main__":
    unittest.main()
