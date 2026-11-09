#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "driver"))
import recipe_intent  # noqa: E402

spec = importlib.util.spec_from_file_location("source_census", ROOT / "driver/ui/source-census.py")
source_census = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source_census)

CASE = "container.layer.hidden_design"


def entry(layer_vis, class_vis=None):
    e = {"layers": [{"name": n, "visibility": v} for n, v in layer_vis.items()]}
    if class_vis is not None:
        e["class_visibility"] = class_vis
    return e


class HiddenLayer(unittest.TestCase):
    def test_hide_layer_marks_the_active_layer(self):
        layers = {r["name"]: r for r in recipe_intent.run(recipe_intent.script_for(str(ROOT), CASE)).layers}
        self.assertTrue(layers["Rosetta-Hidden-L"].get("hidden"))
        self.assertFalse(layers["Rosetta-Visible-L"].get("hidden"))

    def test_objects_on_the_hidden_layer_read_hidden(self):
        objects = {o["id"]: o for o in recipe_intent.case_record(str(ROOT), CASE)["objects"]}
        self.assertTrue(objects["rect-hidden-layer"]["hidden"])
        self.assertTrue(objects["extrude-hidden-layer"]["hidden"])
        self.assertFalse(objects["oval-visible-layer"]["hidden"])

    def test_script_hides_the_m1_layer(self):
        self.assertEqual(source_census.intended_hidden(CASE), ({"Rosetta-Hidden-L"}, set()))


class CheckHidden(unittest.TestCase):
    def check(self, table, layers=(), classes=(), exported=False):
        return source_census.hidden_problems(table, lambda case: (set(layers), set(classes)), [CASE],
                                             lambda case: exported)

    def test_hidden_layer_that_reads_hidden_passes(self):
        self.assertEqual(self.check({CASE: entry({"L": -1, "V": 0})}, layers=["L"]), ([], []))

    def test_hidden_layer_that_reads_visible_fails(self):
        self.assertEqual(self.check({CASE: entry({"L": 0})}, layers=["L"]),
                         (["%s: layer L reads 0" % CASE], []))

    def test_hidden_class_that_reads_visible_fails(self):
        self.assertEqual(self.check({CASE: entry({}, {"H": 0})}, classes=["H"]),
                         (["%s: class H reads 0" % CASE], []))

    def test_record_without_visibility_and_no_export_is_listed(self):
        self.assertEqual(self.check({CASE: {"layers": [{"name": "L"}], "classes": ["H"]}},
                                    layers=["L"], classes=["H"]),
                         ([], ["%s: layer L has no visibility in the census" % CASE,
                               "%s: class H has no visibility in the census" % CASE]))

    def test_record_without_visibility_and_an_export_fails(self):
        self.assertEqual(self.check({CASE: {"layers": [], "classes": ["H"]}}, classes=["H"], exported=True),
                         (["%s: class H has no visibility in the census, and an export in files/" % CASE], []))

    def pinned(self, entry):
        return source_census.hidden_problems({CASE: entry}, lambda c: (set(), {"H"}), [CASE], lambda c: True,
                                             {"%s: class H" % CASE})

    def test_pinned_class_without_visibility_is_listed(self):
        self.assertEqual(self.pinned({"layers": [], "classes": ["H"]}), ([], ["%s: class H pinned" % CASE]))

    def test_pinned_class_with_a_visibility_value_fails(self):
        self.assertEqual(self.pinned(entry({}, {"H": -1})), (["%s: class H reads -1 and is still pinned" % CASE], []))

    def test_pinned_case_with_no_census_entry_is_listed(self):
        self.assertEqual(source_census.hidden_problems(
            {}, lambda c: (set(), {"H"}), [CASE], lambda c: True, {"%s: class H" % CASE}),
            ([], ["%s: class H pinned, no census entry" % CASE]))

    def test_case_with_no_census_entry_and_one_unpinned_item_fails(self):
        self.assertEqual(source_census.hidden_problems(
            {}, lambda c: ({"L"}, {"H"}), [CASE], lambda c: True, {"%s: class H" % CASE}),
            (["%s: no census entry, and an export in files/" % CASE], []))

    def test_pin_file_names_the_cases_with_no_visibility_value(self):
        self.assertEqual(len(source_census.pinned_items()), 18)
        self.assertIn("container.layer.hidden_design: layer Rosetta-Hidden-L", source_census.pinned_items())
        self.assertIn("resource.class.visibility: class Rosetta-Class-\u00c41", source_census.pinned_items())

    def test_case_with_no_script_is_skipped(self):
        self.assertEqual(source_census.hidden_problems({CASE: entry({"L": 0})}, lambda case: None, [CASE]), ([], []))

    def test_scripted_case_with_no_census_entry_counts_as_unread(self):
        self.assertEqual(self.check({}, layers=["L"]), ([], ["%s: no census entry" % CASE]))

    def test_scripted_case_with_an_export_and_no_census_entry_fails(self):
        self.assertEqual(self.check({}, layers=["L"], exported=True),
                         (["%s: no census entry, and an export in files/" % CASE], []))

    def test_m1_to_m7_read_pinned_until_their_census_goes_in(self):
        self.assertEqual(source_census.hidden_problems({}, source_census.intended_hidden, [CASE],
                                                       pinned=source_census.pinned_items()),
                         ([], ["%s: layer Rosetta-Hidden-L pinned, no census entry" % CASE]))


class Collect(unittest.TestCase):
    def test_collect_updates_the_cases_in_dir_and_keeps_the_others(self):
        with tempfile.TemporaryDirectory() as tmp:
            table = Path(tmp, "census.json")
            table.write_text(json.dumps({"kept.case": {"layers": []}, "new.case": {"layers": [], "old": True}}))
            records = Path(tmp, "records")
            records.mkdir()
            Path(records, "new.case.rerun.json").write_text(json.dumps({"layers": [{"name": "L"}], "fname": "x"}))
            with contextlib.redirect_stdout(io.StringIO()):
                source_census.collect(str(records), str(table))
            result = json.loads(table.read_text())
        self.assertEqual(sorted(result), ["kept.case", "new.case"])
        self.assertEqual(result["kept.case"], {"layers": []})
        self.assertEqual(result["new.case"], {"layers": [{"name": "L"}],
                                              "document": "make-sources.py rerun, not stored"})


if __name__ == "__main__":
    unittest.main()
