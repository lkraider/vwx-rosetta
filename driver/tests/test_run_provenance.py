import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "driver"))
import run_provenance  # noqa: E402


def git(repo, *args):
    subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True)


class RunProvenance(unittest.TestCase):
    def setUp(self):
        self.repo = tempfile.mkdtemp()
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "config", "user.name", "t")
        git(self.repo, "config", "user.email", "t@example.invalid")
        self.write("driver/a.py", "a = 1\n")
        self.write("driver/bin/BUILD.tsv", "binary\tsha256\nvwx\t%s\n" % run_provenance.sha256(__file__))
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "base")

    def write(self, rel, text):
        path = os.path.join(self.repo, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def test_clean_main_runs(self):
        st = run_provenance.require(self.repo)
        self.assertFalse(st["dirty"])
        self.assertEqual(st["ahead_of_base"], 0)

    def test_changed_code_is_refused(self):
        self.write("driver/a.py", "a = 2\n")
        with self.assertRaises(SystemExit) as caught:
            run_provenance.require(self.repo)
        self.assertIn("driver/a.py", str(caught.exception))

    def test_untracked_code_is_refused(self):
        self.write("driver/b.py", "b = 1\n")
        self.assertIn("driver/b.py", run_provenance.refusal(run_provenance.state(self.repo)))

    def test_run_output_is_not_code(self):
        self.write("runs/r1/records/x.json", "{}\n")
        self.write("files/case/case.dxf", "0\n")
        self.assertIsNone(run_provenance.refusal(run_provenance.state(self.repo)))

    def test_named_output_is_not_code(self):
        self.write("sources/c.vwx", "x")
        self.assertIsNotNone(run_provenance.refusal(run_provenance.state(self.repo)))
        self.assertIsNone(run_provenance.refusal(run_provenance.state(self.repo, outputs=("sources",))))

    def commit_on_branch(self, name):
        git(self.repo, "checkout", "-qb", name)
        self.write("driver/a.py", "a = 3\n")
        git(self.repo, "commit", "-qam", "work")
        return subprocess.run(["git", "-C", self.repo, "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip()

    def reviewed_list(self, *commits):
        path = os.path.join(self.repo, "..", os.path.basename(self.repo) + "-reviewed.tsv")
        with open(path, "w") as f:
            f.writelines("%s\treviewer\tpass\n" % c for c in commits)
        return path

    def test_reviewed_branch_on_main_runs(self):
        commit = self.commit_on_branch("work")
        st = run_provenance.require(self.repo, reviewed=self.reviewed_list(commit))
        self.assertEqual((st["branch"], st["ahead_of_base"], st["reviewed"]), ("work", 1, True))

    def test_unreviewed_branch_is_refused(self):
        self.commit_on_branch("work")
        reason = run_provenance.refusal(run_provenance.state(self.repo, reviewed=self.reviewed_list("0" * 40)))
        self.assertIn("is not in the reviewed list", reason)

    def test_missing_reviewed_list_refuses_a_branch(self):
        self.commit_on_branch("work")
        reason = run_provenance.refusal(run_provenance.state(self.repo, reviewed=os.path.join(self.repo, "absent.tsv")))
        self.assertIn("is not in the reviewed list", reason)

    def test_commit_on_two_branches_is_refused(self):
        commit = self.commit_on_branch("work")
        git(self.repo, "branch", "copy")
        reason = run_provenance.refusal(run_provenance.state(self.repo, reviewed=self.reviewed_list(commit)))
        self.assertIn("tip of 2 branches", reason)

    def test_worktree_behind_main_is_refused(self):
        git(self.repo, "checkout", "-qb", "old")
        git(self.repo, "checkout", "-q", "main")
        self.write("driver/a.py", "a = 4\n")
        git(self.repo, "commit", "-qam", "newer main")
        git(self.repo, "checkout", "-q", "old")
        reason = run_provenance.refusal(run_provenance.state(self.repo))
        self.assertIn("does not contain main", reason)

    def test_pinned_base_survives_a_merge_to_main(self):
        start = subprocess.run(["git", "-C", self.repo, "rev-parse", "HEAD"], capture_output=True,
                               text=True).stdout.strip()
        git(self.repo, "checkout", "-q", "--detach")
        git(self.repo, "checkout", "-q", "-b", "later")
        self.write("driver/a.py", "a = 5\n")
        git(self.repo, "commit", "-qam", "merged during the run")
        git(self.repo, "branch", "-f", "main", "later")
        git(self.repo, "checkout", "-q", "--detach", start)
        self.assertIn("does not contain main", run_provenance.refusal(run_provenance.state(self.repo)))
        self.assertIsNone(run_provenance.refusal(run_provenance.state(self.repo, base=start)))
        done = subprocess.run([sys.executable, "-B", str(ROOT / "driver" / "run_provenance.py"), self.repo],
                              capture_output=True, text=True, env=dict(os.environ, ROSETTA_BASE=start))
        self.assertEqual(done.returncode, 0, done.stderr)


class Binaries(RunProvenance):
    def test_listed_binary_runs(self):
        st = run_provenance.require(self.repo, binaries=(__file__,))
        self.assertEqual(st["binaries"][0]["sha256"], run_provenance.sha256(__file__))

    def test_unlisted_binary_is_refused(self):
        other = os.path.join(self.repo, "..", os.path.basename(self.repo) + "-vwx")
        with open(other, "w") as f:
            f.write("another build")
        reason = run_provenance.refusal(run_provenance.state(self.repo, binaries=(other,)))
        self.assertIn("binary not in driver/bin/BUILD.tsv", reason)

    def test_missing_binary_is_refused(self):
        reason = run_provenance.refusal(run_provenance.state(self.repo, binaries=("/nonexistent/vwx",)))
        self.assertIn("/nonexistent/vwx", reason)


if __name__ == "__main__":
    unittest.main()
