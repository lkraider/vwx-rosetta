#!/usr/bin/env python3
import hashlib
import itertools
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "driver/inventory/combined-sources.py"
sys.path.insert(0, str(ROOT / "driver"))
import recipe_intent

CALLS = ("CreateCustomObject", "CreateCustomObjectN", "CreateCustomObjectPath")


class Combined(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        rows = ["plugin\tcall\tpath\tstatus\ttype\twidth\theight\treason"]
        for n in range(62):
            path = ("open", "closed")[n % 2] if CALLS[n % 3] == "CreateCustomObjectPath" else ""
            rows.append("P%02d\t%s\t%s\tcreated\t86\t%d\t%d\t" % (n, CALLS[n % 3], path, 100 + (61 - n) * 40, 60))
        rows.append("Missing\tCreateCustomObject\t\tnot_created\t\t\t\tno module")
        (self.root / "probe.tsv").write_text("\n".join(rows) + "\n")
        self.out = self.root / "out"

    def tearDown(self):
        self.tmp.cleanup()

    def run_tool(self, *args):
        return subprocess.run([sys.executable, "-I", str(TOOL), *args], capture_output=True, text=True, check=True)

    def test_make_splits_evenly_and_skips_failures(self):
        self.run_tool("make", str(self.root / "probe.tsv"), str(self.out))
        counts = [len(json.loads(p.read_text())["parameters"]["plugins"])
                  for p in sorted((self.out / "recipes").glob("*.json"))]
        self.assertEqual(counts, [21, 21, 20])
        names = {p["plugin"] for r in (self.out / "recipes").glob("*.json")
                 for p in json.loads(r.read_text())["parameters"]["plugins"]}
        self.assertNotIn("Missing", names)

    def test_script_matches_recipe_and_places_each_object_on_its_layer(self):
        self.run_tool("make", str(self.root / "probe.tsv"), str(self.out))
        recipe = self.out / "recipes/plugin.combined.01.json"
        script = self.out / "scripts/plugin.combined.01.py"
        self.assertIn("# recipe_sha256: " + hashlib.sha256(recipe.read_bytes()).hexdigest(), script.read_text())
        objects = [o for o in recipe_intent.run(str(script)).objects if o["type"] == "plug-in object"]
        self.assertEqual(len(objects), 21)
        self.assertTrue(all(o["layer"] == o["class"] == "pio-" + o["plugin"] for o in objects))
        parameters = json.loads(recipe.read_text())["parameters"]
        cell = parameters["cell_mm"]
        self.assertGreaterEqual(cell, 2 * max(max(p["width"], p["height"]) for p in parameters["plugins"]))
        points = [tuple(o["args"][1]) for o in objects if o["api"] != "vs.CreateCustomObjectPath"]
        for a, b in itertools.combinations(points, 2):
            self.assertGreaterEqual(max(abs(a[0] - b[0]), abs(a[1] - b[1])), cell)

    def test_documents_group_objects_by_extent(self):
        self.run_tool("make", str(self.root / "probe.tsv"), str(self.out))
        cells = [json.loads(p.read_text())["parameters"]["cell_mm"] for p in sorted((self.out / "recipes").glob("*.json"))]
        self.assertEqual(cells, sorted(cells))
        first = json.loads((self.out / "recipes/plugin.combined.01.json").read_text())["parameters"]["plugins"]
        self.assertEqual(first[0]["plugin"], "P61")

    def test_path_kind_follows_the_probe(self):
        self.run_tool("make", str(self.root / "probe.tsv"), str(self.out))
        seen = 0
        for recipe in (self.out / "recipes").glob("*.json"):
            ops = json.loads(recipe.read_text())["operations"]
            for n, o in enumerate(ops):
                if o.get("api") != "vs.CreateCustomObjectPath":
                    continue
                kind = ("open", "closed")[int(o["args"][0][1:]) % 2]
                begin = max(i for i in range(n) if ops[i].get("api") == "vs.BeginPoly")
                self.assertEqual(ops[begin - 1]["api"], {"open": "vs.OpenPoly", "closed": "vs.ClosePoly"}[kind])
                points = sum(1 for i in range(begin, n) if ops[i].get("api") == "vs.AddPoint")
                self.assertEqual(points, {"open": 3, "closed": 4}[kind])
                seen += 1
        self.assertEqual(seen, sum(1 for n in range(62) if n % 3 == 2))

    def test_missing_path_kind_stops(self):
        probe = self.root / "bad.tsv"
        probe.write_text("plugin\tcall\tpath\tstatus\ttype\twidth\theight\treason\n"
                         "Hardscape\tCreateCustomObjectPath\t\tcreated\t86\t10\t10\t\n")
        r = subprocess.run([sys.executable, "-I", str(TOOL), "make", str(probe), str(self.out)], capture_output=True, text=True)
        self.assertEqual((r.returncode, "Hardscape has path ''" in r.stderr), (1, True))

    def test_split_halves(self):
        self.run_tool("make", str(self.root / "probe.tsv"), str(self.out))
        self.run_tool("split", str(self.out / "recipes/plugin.combined.03.json"), str(self.out))
        a = json.loads((self.out / "recipes/plugin.combined.03a.json").read_text())["parameters"]["plugins"]
        b = json.loads((self.out / "recipes/plugin.combined.03b.json").read_text())["parameters"]["plugins"]
        whole = json.loads((self.out / "recipes/plugin.combined.03.json").read_text())["parameters"]["plugins"]
        self.assertEqual((len(a), len(b)), (10, 10))
        self.assertEqual(a + b, whole)


if __name__ == "__main__":
    unittest.main()
