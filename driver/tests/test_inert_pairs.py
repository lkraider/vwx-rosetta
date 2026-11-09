#!/usr/bin/env python3
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("inert_pairs", ROOT / "driver/ui/inert-pairs.py")
inert_pairs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inert_pairs)

audit_spec = importlib.util.spec_from_file_location("audit_corpus", ROOT / "driver/ui/audit-corpus.py")
audit_corpus = importlib.util.module_from_spec(audit_spec)
audit_spec.loader.exec_module(audit_corpus)

EMPTY = {"objects": [], "symdefs": [], "errors": []}


class Census(unittest.TestCase):
    def census(self, **changed):
        census = {case: dict(EMPTY) for case in inert_pairs.EMPTY_CASES}
        census.update(changed)
        return census

    def test_empty_census_passes(self):
        self.assertEqual(inert_pairs.census_problems(self.census()), [])

    def test_case_with_an_object_fails(self):
        problems = inert_pairs.census_problems(self.census(**{"control.blank.mm": dict(EMPTY, objects=[{}])}))
        self.assertEqual(problems, ["control.blank.mm: driver/source-census.json lists 1 objects"])

    def test_case_with_a_census_error_fails(self):
        problems = inert_pairs.census_problems(self.census(**{"control.blank.mm": dict(EMPTY, errors=["x"])}))
        self.assertEqual(problems, ["control.blank.mm: driver/source-census.json lists 1 errors"])

    def test_case_with_no_entry_fails(self):
        census = self.census()
        del census["control.blank.mm"]
        self.assertEqual(inert_pairs.census_problems(census),
                         ["control.blank.mm: driver/source-census.json has no entry"])

    def test_store_census_lists_each_empty_case_as_empty(self):
        with open(inert_pairs.CENSUS) as f:
            self.assertEqual(inert_pairs.census_problems(json.load(f)), [])

    def test_store_sources_hash_to_the_census_run(self):
        with open(inert_pairs.CENSUS) as f:
            self.assertEqual(inert_pairs.source_problems(json.load(f)), [])

    def test_changed_source_fails(self):
        with open(inert_pairs.CENSUS) as f:
            census = json.load(f)
        census["control.blank.mm"] = dict(census["control.blank.mm"], document="sources/control.blank.imperial.vwx")
        problems = inert_pairs.source_problems(census)
        self.assertEqual(len(problems), 1)
        self.assertTrue(problems[0].startswith("control.blank.mm: sources/control.blank.imperial.vwx hashes to "))


class IfcRule(unittest.TestCase):
    HEAD = "ISO-10303-21;\nDATA;\n#1= IFCSITE($,$,$,$,$,#9,#5,$,$,$,$,$,$,$);\n#5= IFCPRODUCTDEFINITIONSHAPE($,$,(#6));\n"

    def inert(self, body):
        facts = audit_corpus.facts_ifc((self.HEAD + body + "ENDSEC;\n").encode())
        return not inert_pairs.RULES["ifc"][1](facts)

    def test_site_and_opening_alone_are_inert(self):
        self.assertTrue(self.inert("#7= IFCOPENINGELEMENT($,$,$,$,$,#9,#5,$);\n"))

    def test_wall_with_a_shape_holds_an_element(self):
        self.assertFalse(self.inert("#8= IFCWALL('g',$,$,$,$,#9,\n#5,$);\n"))


if __name__ == "__main__":
    unittest.main()
