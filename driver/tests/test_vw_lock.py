#!/usr/bin/env python3
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "driver"))
import vw_lock  # noqa: E402

spec = importlib.util.spec_from_file_location("batch", ROOT / "driver" / "batch.py")
batch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(batch)


def run(argv, tmp, **env):
    clean = {k: v for k, v in os.environ.items() if k not in ("ROSETTA_LOCK", "ROSETTA_LOCK_OWNER")}
    return subprocess.run([sys.executable, "-B", *argv], capture_output=True, text=True,
                          env=dict(clean, ROSETTA_TMP=tmp, **env))


def hold(lock, pid):
    os.makedirs(lock)
    Path(lock, "owner.tsv").write_text("pid\tstarted\tcommand\n%s\t2026-10-20T00:00:00Z\tbatch.py stage1\n" % pid)


class Refusal(unittest.TestCase):
    def test_held_lock_makes_make_sources_exit_2(self):
        tmp = tempfile.mkdtemp()
        hold(os.path.join(tmp, "lock"), 999999)
        done = run([str(ROOT / "driver/ui/make-sources.py"), "--cases", "case.a"], tmp)
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertIn("make-sources.py: refused: another process holds", done.stderr)
        self.assertIn("pid 999999, batch.py stage1", done.stderr)
        self.assertTrue(Path(tmp, "lock", "owner.tsv").exists())

    def test_held_lock_makes_a_census_exit_2(self):
        tmp = tempfile.mkdtemp()
        hold(os.path.join(tmp, "lock"), 999999)
        done = run([str(ROOT / "driver/ui/source-census.py"), "--out-dir", os.path.join(tmp, "out"),
                    "a=" + os.path.join(tmp, "a.vwx")], tmp)
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertIn("source-census.py: refused: another process holds", done.stderr)
        self.assertFalse(Path(tmp, "out").exists())

    def test_check_hidden_runs_under_a_held_lock(self):
        tmp = tempfile.mkdtemp()
        hold(os.path.join(tmp, "lock"), 999999)
        done = run([str(ROOT / "driver/ui/source-census.py"), "--check-hidden"], tmp)
        self.assertNotIn("refused", done.stderr)
        self.assertIn("problems,", done.stdout)

    def test_lock_without_owner_refuses(self):
        tmp = tempfile.mkdtemp()
        os.mkdir(os.path.join(tmp, "lock"))
        done = run([str(ROOT / "driver/vw_lock.py"), "true"], tmp)
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertIn("has no owner.tsv", done.stderr)

    # A missing vwx binary and a pause that holds stop each driver before Vectorworks when the lock check fails.
    def refused(self, argv, name):
        tmp = tempfile.mkdtemp()
        hold(os.path.join(tmp, "lock"), 999999)
        pause = os.path.join(tmp, "pause")
        Path(pause).write_text("2099-01-01T00:00:00Z\n")
        missing = os.path.join(tmp, "no-vwx")
        clean = {k: v for k, v in os.environ.items()
                 if k not in ("ROSETTA_LOCK", "ROSETTA_LOCK_OWNER", "ROSETTA_OPEN_UNDER_PAUSE")}
        done = subprocess.run(argv, capture_output=True, text=True, timeout=60,
                              env=dict(clean, ROSETTA_TMP=tmp, ROSETTA_PAUSE=pause, VWX_CLI=missing,
                                       VWX_SCRIPT_CLI=missing))
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertIn(name + ": refused: another process holds", done.stderr)

    def test_held_lock_makes_a_live_ui_sweep_exit_2(self):
        self.refused([sys.executable, "-B", str(ROOT / "driver/ui/sweep-ui.py"), "--format", "dxf",
                      "--profile", "dxf.top-plan", "--only", "x", "--unlisted"], "sweep-ui.py")

    def test_held_lock_makes_a_restart_exit_2(self):
        self.refused([sys.executable, "-B", str(ROOT / "driver/vw_memory.py"), "--restart"], "vw_memory.py")

    def test_held_lock_makes_a_document_read_exit_2(self):
        self.refused([sys.executable, "-B", str(ROOT / "driver/ui/read-documents.py"), "--out-dir",
                      tempfile.mkdtemp(), "--reads", "h1"], "read-documents.py")

    def test_held_lock_makes_a_scripted_sweep_exit_2(self):
        self.refused(["bash", str(ROOT / "driver/scripted/sweep-scripted.sh")], "sweep-scripted.sh")


class Owner(unittest.TestCase):
    def test_owner_tsv_holds_the_pid_of_the_taker(self):
        lock = os.path.join(tempfile.mkdtemp(), "lock")
        vw_lock.take("sweep-ui.py", lock)
        self.assertEqual(vw_lock.owner(lock)[0], str(os.getpid()))

    def test_driver_of_batch_runs_under_its_lock(self):
        tmp = tempfile.mkdtemp()
        with mock.patch.object(batch, "SCRATCH", tmp):
            run_ = batch.Run("plan.tsv", "stage1", os.path.join(tmp, "out"), str(ROOT))
        lock = os.path.join(tmp, "lock")
        self.assertEqual(run_.env["ROSETTA_LOCK"], lock)
        vw_lock.take("batch.py stage1", lock)
        try:
            done = subprocess.run([sys.executable, "-B", str(ROOT / "driver/vw_lock.py"), "--mine"], env=run_.env)
        finally:
            vw_lock.release(lock)
        self.assertEqual(done.returncode, 0)

    def test_lock_of_the_parent_pid_is_accepted(self):
        lock = os.path.join(tempfile.mkdtemp(), "lock")
        hold(lock, 4242)
        ran = []
        with mock.patch.dict(os.environ, {"ROSETTA_LOCK_OWNER": "4242"}):
            with vw_lock.held("make-sources.py", lock):
                ran.append(True)
        self.assertEqual(ran, [True])
        self.assertEqual(vw_lock.owner(lock)[0], "4242")

    def test_child_runs_under_the_lock_of_the_wrapper(self):
        tmp = tempfile.mkdtemp()
        done = run([str(ROOT / "driver/vw_lock.py"), sys.executable, "-B", str(ROOT / "driver/vw_lock.py"), "--mine"],
                   tmp)
        self.assertEqual(done.returncode, 0, done.stderr)


class Release(unittest.TestCase):
    def test_lock_is_gone_after_a_run(self):
        tmp = tempfile.mkdtemp()
        done = run([str(ROOT / "driver/vw_lock.py"), "true"], tmp)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertFalse(os.path.exists(os.path.join(tmp, "lock")))

    def test_lock_is_gone_after_an_error(self):
        lock = os.path.join(tempfile.mkdtemp(), "lock")
        with mock.patch.dict(os.environ, {"ROSETTA_LOCK_OWNER": ""}):
            with self.assertRaises(ValueError):
                with vw_lock.held("sweep-ui.py", lock):
                    self.assertTrue(os.path.exists(os.path.join(lock, "owner.tsv")))
                    raise ValueError("stop")
        self.assertFalse(os.path.exists(lock))


if __name__ == "__main__":
    unittest.main()
