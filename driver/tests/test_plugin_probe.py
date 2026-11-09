#!/usr/bin/env python3
import ast
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("plugin_probe", ROOT / "driver/inventory/plugin-probe.py")
plugin_probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin_probe)


class Probe(unittest.TestCase):
    def test_scripts_hold_each_plugin_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            plugins = Path(tmp, "Plug-Ins")
            plugins.mkdir()
            for name in ("Door", "Window", "Stair", "Hardscape", "Bolt"):
                Path(plugins, name + ".vso").write_bytes(b"")
            Path(plugins, "Menu.vsm").write_bytes(b"")
            out = Path(tmp, "scripts")
            with mock.patch("sys.stdout"):
                plugin_probe.write_scripts(str(out), 2, str(plugins))
            scripts = sorted(out.iterdir())
            self.assertEqual([p.name for p in scripts],
                             ["probe.plugins.01.py", "probe.plugins.02.py", "probe.plugins.03.py"])
            held = []
            for script in scripts:
                tree = ast.parse(script.read_text())
                held += next(ast.literal_eval(n.value) for n in tree.body
                             if isinstance(n, ast.Assign) and n.targets[0].id == "PLUGINS")
            self.assertEqual(sorted(held), ["Bolt", "Door", "Hardscape", "Stair", "Window"])

    def test_join_takes_the_first_call_with_a_box_after_reopen(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "probe.plugins.01.probe.tsv").write_text(
                "Door\tCreateCustomObjectN\t\tprobe-000-0\thandle\t86\t\n"
                "Hardscape\tCreateCustomObjectN\t\tprobe-001-0\thandle\t86\t\n"
                "Hardscape\tCreateCustomObjectPath\tclosed\tprobe-001-1\thandle\t86\t\n"
                "Bolt\tCreateCustomObjectN\t\t\tno handle\t\t\n"
                "Bolt\tCreateCustomObject\t\tprobe-002-3\thandle\t86\t\n")
            census = Path(tmp, "census")
            census.mkdir()
            Path(census, "probe.plugins.01.json").write_text(json.dumps({"objects": [
                {"name": "probe-000-0", "type": 86, "bbox": [[0.0, 120.0], [900.0, 0.0]], "3dinfo": [0, 0, 0]},
                {"name": "probe-001-0", "type": 86, "bbox": [[0, 0], [0, 0]], "3dinfo": [0, 0, 0]},
                {"name": "probe-001-1", "type": 86, "bbox": [[0, 5000], [5000, 0]], "3dinfo": [0, 0, 0]},
                {"name": "probe-002-3", "type": 86, "bbox": [[0, 0], [0, 0]], "3dinfo": [0, 0, 0]}]}))
            probe = os.path.join(tmp, "PROBE.tsv")
            with mock.patch("sys.stdout"):
                plugin_probe.join(tmp, str(census), probe)
            lines = [l.split("\t") for l in Path(probe).read_text().splitlines()]
            self.assertEqual(lines[0][:8], ["plugin", "call", "path", "status", "type", "width", "height", "reason"])
            self.assertEqual(lines[1][:7], ["Door", "CreateCustomObjectN", "", "created", "86", "900.0", "120.0"])
            self.assertEqual(lines[2][:4], ["Hardscape", "CreateCustomObjectPath", "closed", "created"])
            self.assertEqual(lines[3][3], "not_created")
            self.assertEqual(lines[3][-1], "probe.plugins.01")

    def test_join_finds_an_object_the_plugin_renamed_on_its_layer(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "probe.plugins.09.probe.tsv").write_text(
                "Simple Stair\tCreateCustomObjectN\t\tprobe-329-0\thandle\t86\t\n")
            census = Path(tmp, "census")
            census.mkdir()
            Path(census, "probe.plugins.09.json").write_text(json.dumps({"objects": [
                {"name": "{BE175EC2}", "type": 86, "plugin": "Simple Stair", "layer": "pio-Simple Stair",
                 "bbox": [[9970.0, -10000.0], [14200.0, -10900.0]], "3dinfo": [0, 0, 0]}]}))
            probe = os.path.join(tmp, "PROBE.tsv")
            with mock.patch("sys.stdout"):
                plugin_probe.join(tmp, str(census), probe)
            lines = [l.split("\t") for l in Path(probe).read_text().splitlines()]
            self.assertEqual(lines[1][:7], ["Simple Stair", "CreateCustomObjectN", "", "created", "86", "4230.0", "900.0"])

    def test_join_writes_a_stopped_plugin_as_not_created(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "census").mkdir()
            stopped = Path(tmp, "stopped.tsv")
            stopped.write_text("plugin\tstatus\treason\tdocument\n"
                               "Roadway (Curved)\tnot_created\tthe script did not end\tprobe.plugins.28\n")
            probe = os.path.join(tmp, "PROBE.tsv")
            with mock.patch("sys.stdout"):
                plugin_probe.join(tmp, str(Path(tmp, "census")), probe, str(stopped))
            lines = [l.split("\t") for l in Path(probe).read_text().splitlines()]
            self.assertEqual(lines[1], ["Roadway (Curved)", "", "", "not_created", "", "", "", "the script did not end", "",
                                        "probe.plugins.28"])

if __name__ == "__main__":
    unittest.main()
