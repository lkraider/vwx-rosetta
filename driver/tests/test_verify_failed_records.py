#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("verify_artifacts", ROOT / "driver/ui/verify-artifacts.py")
verify_artifacts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_artifacts)


class FailedRecord(unittest.TestCase):
    RECORD = {"case": "c", "profile": "p", "format": "f", "status": "no file produced"}

    def check(self, record, on_disk=(), negatives=()):
        problems, findings = [], {"status": {}, "no_profile": 0}
        verify_artifacts.check_row("run1", record, {}, problems, findings, set(on_disk), set(negatives))
        return problems, findings

    def test_no_artifact_and_no_negatives_row_is_a_problem(self):
        problems, _ = self.check(self.RECORD)
        self.assertEqual([p[0] for p in problems], ["c p f"])

    def test_negatives_row_passes(self):
        self.assertEqual(self.check(self.RECORD, negatives=[("c", "p")])[0], [])

    def test_stored_artifact_passes(self):
        self.assertEqual(self.check(self.RECORD, on_disk=[("c", "p", "f")])[0], [])

    def test_record_with_no_profile_is_counted(self):
        problems, findings = self.check(dict(self.RECORD, profile=None))
        self.assertEqual((problems, findings["no_profile"]), ([], 1))


if __name__ == "__main__":
    unittest.main()
