#!/usr/bin/env python3
import hashlib
import importlib.util
import os
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("verify_artifacts", ROOT / "driver/ui/verify-artifacts.py")
verify_artifacts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_artifacts)


class SharedDigests(unittest.TestCase):
    def problems(self, shared, pinned):
        problems = []
        verify_artifacts.check_shared(shared, pinned, problems)
        return [tag for tag, _detail in problems]

    def test_record_group_whose_files_left_files_is_kept(self):
        merged = verify_artifacts.merge_groups({"a" * 64: ["c1/c1.png", "c2/c2.png"]},
                                               {"a" * 64: ["c3 png.p png"], "b" * 64: ["c1 png.p png", "c4 png.p png"]})
        self.assertEqual(merged, {"a" * 64: ["c1/c1.png", "c2/c2.png", "c3 png.p png"],
                                  "b" * 64: ["c1 png.p png", "c4 png.p png"]})

    def test_pinned_group_passes(self):
        self.assertEqual(self.problems({"a" * 64: ["c1/c1.stl", "c2/c2.stl"]}, {"a" * 64: "c1/c1.stl, c2/c2.stl"}), [])

    def test_new_group_fails(self):
        self.assertEqual(self.problems({"a" * 64: ["c1/c1.stl", "c2/c2.stl"]}, {}), ["a" * 16])

    def test_changed_group_fails(self):
        self.assertEqual(self.problems({"a" * 64: ["c1/c1.stl", "c3/c3.stl"]}, {"a" * 64: "c1/c1.stl, c2/c2.stl"}), ["a" * 16])

    def test_stale_row_fails(self):
        self.assertEqual(self.problems({}, {"b" * 64: "c1/c1.stl, c2/c2.stl"}), ["b" * 16])

    def test_store_rows_name_a_full_digest_and_two_members(self):
        pinned = verify_artifacts.read_shared_digests()
        self.assertTrue(all(len(d) == 64 and ", " in m for d, m in pinned.items()))


class Unrecorded(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = tmp.name
        os.makedirs(os.path.join(self.root, "files", "c"))
        with open(os.path.join(self.root, "files", "c", "c.stl"), "wb") as f:
            f.write(b"solid")
        self.coverage = os.path.join(self.root, "coverage.tsv")
        with open(self.coverage, "w") as f:
            f.write("case\tprofile\tformat\tstate\tartifact\treason\nc\tstl.p\tstl\tartifact\tc.stl\t\n")
        self.listed = os.path.join(self.root, "unrecorded.tsv")
        for name, value in (("ROOT", self.root), ("COVERAGE", self.coverage), ("UNRECORDED", self.listed)):
            patch = unittest.mock.patch.object(verify_artifacts, name, value)
            patch.start()
            self.addCleanup(patch.stop)

    def problems(self, unrecorded, sha):
        with open(self.listed, "w") as f:
            f.write("case\tprofile\tformat\tsha256\treason\nc\tstl.p\tstl\t%s\tr\n" % sha)
        problems = []
        verify_artifacts.check_unrecorded(unrecorded, problems)
        return [detail.split(",")[0] for _tag, detail in problems]

    def test_listed_pair_passes(self):
        self.assertEqual(self.problems({("c", "stl.p", "stl")}, hashlib.sha256(b"solid").hexdigest()), [])

    def test_changed_file_fails(self):
        self.assertEqual(self.problems({("c", "stl.p", "stl")}, "0" * 64),
                         ["the file differs from the sha256 in ledger/unrecorded-pairs.tsv"])

    def test_new_pair_and_recorded_row_fail(self):
        found = self.problems({("d", "stl.p", "stl")}, hashlib.sha256(b"solid").hexdigest())
        self.assertEqual(len(found), 2)


if __name__ == "__main__":
    unittest.main()
