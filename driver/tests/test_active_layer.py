#!/usr/bin/env python3
import glob
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("sweep_ui", ROOT / "driver/ui/sweep-ui.py")
sweep_ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep_ui)

DESIGN, SHEET = 1, 2


def fake_vs(layers, classes, active):
    """A vs module with one document. GetObject finds a class before a layer of the same name."""
    names = [n for n, _ in layers]
    kinds = dict(layers)
    state = {"active": active}

    def get_object(name):
        if name in classes:
            return ("class", name)
        return ("layer", name) if name in kinds else None

    def layer(name):
        if name not in kinds:
            names.append(name)
            kinds[name] = DESIGN
        state["active"] = name

    def next_layer(handle):
        i = names.index(handle[1]) + 1
        return ("layer", names[i]) if i < len(names) else None

    vs = types.ModuleType("vs")
    vs.GetObject = get_object
    vs.GetTypeN = lambda h: 31 if h[0] == "layer" else 94
    vs.FLayer = lambda: ("layer", names[0]) if names else None
    vs.NextLayer = next_layer
    vs.GetLName = lambda h: h[1]
    vs.GetObjectVariableInt = lambda h, i: kinds[h[1]] if i == 154 else 0
    vs.ActLayer = lambda: ("layer", state["active"])
    vs.Layer = layer
    return vs, names


class ActiveLayerProgram(unittest.TestCase):
    def run_program(self, name, layers, classes=()):
        vs, names = fake_vs(layers, set(classes), layers[0][0])
        with tempfile.TemporaryDirectory() as tmp:
            out = str(Path(tmp) / "result.json")
            with mock.patch.dict(sys.modules, {"vs": vs}):
                exec(sweep_ui.ACTIVE_LAYER_PROGRAM % {"out": out, "name": name}, {})
            return json.load(open(out)), names

    def test_layer_with_a_class_of_the_same_name_is_set(self):
        result, _ = self.run_program("pio-Hub - 3D", [("pio-Wide Flange", DESIGN), ("pio-Hub - 3D", DESIGN)],
                                     classes=["pio-Hub - 3D"])
        self.assertEqual((result["found"], result["got"]), (True, "pio-Hub - 3D"))

    def test_missing_layer_is_not_created(self):
        result, names = self.run_program("absent", [("L1", DESIGN)])
        self.assertEqual((result["found"], result["got"], names), (False, "L1", ["L1"]))

    def test_sheet_layer_is_set(self):
        result, names = self.run_program("S", [("L1", DESIGN), ("S", SHEET)])
        self.assertEqual((result["found"], result["got"], result["layer_type"], names), (True, "S", "sheet", ["L1", "S"]))

    def test_layer_of_another_type_is_not_set(self):
        result, _ = self.run_program("X", [("L1", DESIGN), ("X", 3)])
        self.assertEqual((result["found"], result["got"]), (False, "L1"))


class SourceOption(unittest.TestCase):
    SWEEP = os.path.join(ROOT, "driver", "ui", "sweep-ui.py")

    def dry_run(self, *source):
        return subprocess.run([sys.executable, "-B", self.SWEEP, "--format", "dxf", "--profile", "dxf.top-plan",
                               "--only", "h1-control", "--unlisted", "--dry-run", *source],
                              capture_output=True, text=True)

    def test_a_source_option_names_a_case_outside_the_map(self):
        done = self.dry_run("--source", "h1-control=/tmp/h1-control.vwx")
        self.assertEqual(done.returncode, 0, done.stderr)
        row = json.loads(done.stdout.splitlines()[0])
        self.assertEqual((row["source"], row["status"]), ("/tmp/h1-control.vwx", "planned"))

    def test_a_source_option_refuses_a_mapped_case(self):
        done = self.dry_run("--source", "annotation.viewport.sheet=/tmp/x.vwx")
        self.assertEqual(done.returncode, 1)
        self.assertIn("source-map.tsv does not name", done.stderr)

    def test_a_source_option_refuses_an_empty_case(self):
        done = self.dry_run("--source", "=/tmp/x.vwx")
        self.assertEqual(done.returncode, 1)
        self.assertIn("give CASE=PATH", done.stderr)

    def test_a_relative_source_path_is_made_absolute(self):
        done = self.dry_run("--source", "h1-control=h1-control.vwx")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(json.loads(done.stdout.splitlines()[0])["source"], os.path.join(os.getcwd(), "h1-control.vwx"))


class ProfileFileNames(unittest.TestCase):
    def test_each_planned_profile_of_a_format_has_its_own_file_name(self):
        sys.path.insert(0, os.path.join(ROOT, "driver"))
        import profile_names
        names = {}
        for plan in glob.glob(os.path.join(ROOT, "driver", "batch", "*.tsv")):
            with open(plan) as handle:
                for line in handle:
                    cols = line.rstrip("\n").split("\t")
                    if len(cols) > 3 and not line.startswith(("#", "step\t")):
                        names.setdefault((cols[2], profile_names.artifact_suffix(cols[3])), set()).add(cols[3])
        self.assertEqual({k: v for k, v in names.items() if len(v) > 1}, {})


class ProbeActiveLayer(unittest.TestCase):
    def probe(self, set_layer):
        args = types.SimpleNamespace(format="dxf", profile=None, only="annotation.viewport.sheet",
                                     active_layer="Rosetta-Sheet", pane=None, settings=None, hold=False)
        with tempfile.TemporaryDirectory() as run_dir, \
                mock.patch.object(sweep_ui, "live_pid", return_value="1"), \
                mock.patch.object(sweep_ui, "close_extra_documents"), \
                mock.patch.object(sweep_ui, "prepare_document", return_value=("w", "annotation.viewport.sheet.vwx")), \
                mock.patch.object(sweep_ui, "frame_document"), \
                mock.patch.object(sweep_ui, "set_active_layer", side_effect=set_layer), \
                mock.patch.object(sweep_ui, "title", return_value="annotation.viewport.sheet.vwx"), \
                mock.patch.object(sweep_ui, "press_menu", return_value=(0, "pressed")), \
                mock.patch.object(sweep_ui, "dump", return_value=({}, "")), \
                mock.patch.object(sweep_ui, "dismiss_modals"), \
                mock.patch.object(sweep_ui.time, "sleep"), \
                mock.patch("sys.stdout"):
            code = sweep_ui.probe(args, [], {"annotation.viewport.sheet": "src"}, run_dir, [])
            path = os.path.join(run_dir, "probe-dxf.tsv")
            return code, Path(path).read_text() if os.path.exists(path) else None

    def test_probe_records_the_active_sheet_layer_before_the_dump(self):
        def set_layer(pid_, case, name, row, log):
            row["active_layer"] = {"asked": name, "got": name, "layer_type": "sheet"}
            return True
        _code, text = self.probe(set_layer)
        self.assertTrue(text.startswith('active_layer\tRosetta-Sheet\t{"asked"'))

    def test_probe_stops_when_the_layer_is_not_set(self):
        def set_layer(pid_, case, name, row, log):
            row["status"] = "active_layer_not_set"
            return False
        self.assertEqual(self.probe(set_layer), (1, None))


if __name__ == "__main__":
    unittest.main()
