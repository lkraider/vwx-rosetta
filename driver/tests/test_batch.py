import csv
import glob
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BATCH = ROOT / "driver" / "batch.py"
spec = importlib.util.spec_from_file_location("batch", BATCH)
batch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(batch)


def run(*args, env=None):
    return subprocess.run([sys.executable, "-B", str(BATCH), *args], capture_output=True, text=True,
                          env=dict(os.environ, **(env or {})))


class DryRun(unittest.TestCase):
    def test_stage1_rows(self):
        done = run("stage1", "--dry-run")
        self.assertEqual(done.returncode, 0, done.stderr)
        rows = {r["step"]: r for r in map(json.loads, done.stdout.splitlines())}
        self.assertEqual(rows["dxf"]["action"], "run")
        self.assertEqual(rows["dxf"]["pairs"], [["spatial.extrude.asym", "dxf.all-content", "planned"]])
        self.assertEqual(rows["png"]["action"], "follow-up")
        self.assertIn("no reader for .png", rows["png"]["reason"])
        self.assertEqual(rows["item7-3ds-hub"]["pairs"], [["plugin.combined.09", "3ds.mesh", "planned"]])


class Refusal(unittest.TestCase):
    def test_held_lock_exits_2(self):
        tmp = tempfile.mkdtemp()
        os.mkdir(os.path.join(tmp, "lock"))
        done = run("stage1", "--front", "--no-wake", env={"ROSETTA_TMP": tmp})
        self.assertEqual(done.returncode, 2, done.stderr)
        summary = list(Path(tmp, "batch").glob("*-stage1/summary.md"))
        self.assertEqual(len(summary), 1)
        self.assertIn("refused: another run holds", summary[0].read_text())


class HeldPause(unittest.TestCase):
    def test_active_pause_exits_2_and_stays(self):
        tmp = tempfile.mkdtemp()
        held = os.path.join(tmp, "pause")
        Path(held).write_text("2099-01-01T00:00:00Z\n")
        done = run("stage1", "--front", "--no-wake", env={"ROSETTA_TMP": tmp, "ROSETTA_PAUSE": held})
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertIn("refused: the pause file", done.stderr)
        self.assertEqual(Path(held).read_text(), "2099-01-01T00:00:00Z\n")


class Call(unittest.TestCase):
    def make(self):
        out = tempfile.mkdtemp()
        held, batch.pause.PAUSE = batch.pause.PAUSE, os.path.join(out, "no-pause")
        self.addCleanup(setattr, batch.pause, "PAUSE", held)
        return batch.Run("plan.tsv", "stage1", out, out)

    def test_timeout_kills_the_call(self):
        run_ = self.make()
        started = time.time()
        code, _lines, err = run_.call("slow", ["sleep", "30"], timeout=2)
        self.assertEqual(code, "timeout")
        self.assertLess(time.time() - started, 10)
        self.assertIn("killed after 2 s", err)

    def test_idle_call_is_killed(self):
        run_ = self.make()
        started = time.time()
        code, _lines, err = run_.call("quiet", [sys.executable, "-c", "print('x', flush=True)\nimport time\n"
                                                "time.sleep(30)"], timeout=60, idle=2)
        self.assertEqual(code, "timeout")
        self.assertLess(time.time() - started, 10)
        self.assertIn("killed after 2 s without output", err)

    def test_large_stderr_does_not_block(self):
        run_ = self.make()
        code, lines, err = run_.call("loud", [sys.executable, "-c",
                                              "import sys; sys.stderr.write('x' * 200000); print('{}')"],
                                     timeout=20)
        self.assertEqual((code, [l for _t, l in lines]), (0, ["{}"]))
        self.assertIn("x" * 1000, err)


FAKE_MEMORY = """import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
MARK = os.path.join(HERE, "started")
KEEP_VW = os.path.exists(os.path.join(HERE, "keep"))
def live_pid():
    return "4242" if os.path.exists(MARK) else None
def close_all_documents():
    open(os.path.join(HERE, "closed"), "w").close()
if __name__ == "__main__":
    if os.environ.get("FAKE_START") == "fail":
        raise RuntimeError("vw-launch.sh failed after a restart for test: the application did not start")
    open(MARK, "w").close()
    print("4242")
"""

TIME_TAIL = """Traceback (most recent call last):
  File "sweep-ui.py", line 723, in live_pid
RuntimeError: no running Vectorworks process
        0,76 real         0,40 user         0,26 sys
            31866880  maximum resident set size
            24249856  peak memory footprint
"""


class StartVectorworks(unittest.TestCase):
    def make(self, start=""):
        evidence = tempfile.mkdtemp()
        os.mkdir(os.path.join(evidence, "driver"))
        Path(evidence, "driver", "vw_memory.py").write_text(FAKE_MEMORY)
        run_ = batch.Run("plan.tsv", "stage1", tempfile.mkdtemp(), evidence)
        held, batch.pause.PAUSE = batch.pause.PAUSE, os.path.join(evidence, "no-pause")
        self.addCleanup(setattr, batch.pause, "PAUSE", held)
        run_.env["FAKE_START"] = start
        return run_, evidence

    def test_start_when_no_process_runs(self):
        run_, evidence = self.make()
        run_.start_vw("dxf")
        self.assertTrue(os.path.exists(os.path.join(evidence, "driver", "started")))
        self.assertEqual(run_.timing[-1]["name"], "dxf-vectorworks-start")
        self.assertEqual(run_.timing[-1]["exit"], 0)

    def test_no_call_when_a_process_runs(self):
        run_, evidence = self.make()
        Path(evidence, "driver", "started").touch()
        run_.start_vw("dxf")
        self.assertEqual(run_.timing, [])

    def test_fresh_start_restarts_a_running_process(self):
        run_, evidence = self.make()
        Path(evidence, "driver", "started").touch()
        run_.start_vw("batch start", fresh=True)
        self.assertEqual(run_.timing[-1]["name"], "batch start-vectorworks-start")

    def test_kept_process_closes_documents_and_skips_the_fresh_restart(self):
        run_, evidence = self.make()
        Path(evidence, "driver", "started").touch()
        Path(evidence, "driver", "keep").touch()
        run_.start_vw("batch start", fresh=True)
        self.assertEqual(run_.timing, [])
        self.assertTrue(os.path.exists(os.path.join(evidence, "driver", "closed")))

    def test_kept_vectorworks_starts_when_no_process_runs(self):
        run_, evidence = self.make()
        Path(evidence, "driver", "keep").touch()
        run_.start_vw("dxf")
        self.assertEqual(run_.timing[-1]["name"], "dxf-vectorworks-start")
        self.assertFalse(os.path.exists(os.path.join(evidence, "driver", "closed")))

    def test_failed_start_stops_with_the_reason(self):
        run_, _evidence = self.make(start="fail")
        with self.assertRaises(batch.Stop) as stop:
            run_.start_vw("batch start")
        self.assertIn("Vectorworks could not be started before batch start: exit 1", str(stop.exception))
        self.assertIn("the application did not start", str(stop.exception))

    def test_a_failed_start_stops_the_row_before_the_driver_call(self):
        run_, _evidence = self.make(start="fail")
        row = {"step": "dxf", "driver": "ui", "format": "dxf", "profile": "dxf.all-content", "cases": "a",
               "options": "", "expect": "pass", "ext": "dxf"}
        with self.assertRaises(batch.Stop):
            run_.do_row(row)
        self.assertEqual([t["name"] for t in run_.timing], ["dxf-vectorworks-start"])

    def test_reason_is_above_the_time_block(self):
        self.assertEqual(batch.last_error_line("$ python3 x\n" + TIME_TAIL),
                         "RuntimeError: no running Vectorworks process")


class Retry(unittest.TestCase):
    def test_a_failed_pair_runs_once_more(self):
        out = tempfile.mkdtemp()
        run_ = batch.Run("plan.tsv", "stage1", out, out)
        calls = []

        def export(row, cases, profile, retry=False):
            calls.append((cases, profile, retry))
            status = "ok" if retry else "save dialog absent"
            return [{"case": c, "profile": profile, "status": status, "file": "/x/%s.dxf" % c, "run_id": ""}
                    for c in cases]

        run_.export = export
        run_.check = lambda row, results: {"/x/a.dxf": {"verdict": "pass", "detail": "1 entities"}}
        row = {"step": "dxf", "driver": "ui", "format": "dxf", "profile": "dxf.all-content", "cases": "a",
               "options": "", "expect": "pass", "ext": "dxf"}
        run_.do_row(row)
        self.assertEqual(calls, [(["a"], "dxf.all-content", False), (["a"], "dxf.all-content", True)])
        self.assertEqual(run_.summary[0]["verdict"], "pass")
        self.assertEqual(run_.summary[0]["retried"], "yes")
        self.assertIn("first try: save dialog absent", run_.summary[0]["detail"])
        self.assertEqual(run_.exit_code(), 0)


class UiAlert(unittest.TestCase):
    ALERT = "Export IGES failed. There are no valid objects available for export."

    def run_row(self, dialogs, status="no file produced"):
        out = tempfile.mkdtemp()
        run_ = batch.Run("plan.tsv", "stage1", out, out)
        records = os.path.join(out, "runs", "r1-ui-iges", "records")
        os.makedirs(records)
        Path(records, "a.iges.solids.json").write_text(json.dumps({"status": status, "dialogs": dialogs}))
        self.calls = []

        def call(step, argv, timeout=None, idle=None, vectorworks=True):
            self.calls.append(step)
            row = {"case": "a", "profile": "iges.solids", "status": status}
            return 1, [(time.time(), json.dumps({"run_id": "r1-ui-iges", "rows": 1})), (time.time(), json.dumps(row))], ""

        run_.call = call
        run_.start_vw = lambda step, fresh=False: setattr(run_, "last_start", time.time())
        run_.keep_ledger_lines = lambda: None
        run_.check = lambda row, results: {}
        run_.do_row({"step": "iges", "driver": "ui", "format": "iges", "profile": "iges.solids", "cases": "a",
                     "options": "", "expect": "record", "ext": "igs"})
        return run_.summary[0]

    def test_the_no_objects_alert_of_a_ui_pair_gets_no_retry(self):
        row = self.run_row([{"where": "after-save", "action": "pressed OK", "text": self.ALERT}])
        self.assertEqual(self.calls, ["iges"])
        self.assertEqual(row["retried"], "")
        self.assertEqual(row["alerts"], self.ALERT)
        self.assertEqual(row["status"], "no file produced, exit 1; alert: " + self.ALERT)

    def test_a_ui_failure_with_another_dialog_still_retries(self):
        row = self.run_row([{"where": "after-save", "action": "pressed OK", "text": "Export IGES failed."}])
        self.assertEqual(self.calls, ["iges", "iges-retry"])
        self.assertEqual(row["retried"], "yes")

    def test_a_layer_that_is_not_set_gets_no_retry(self):
        row = self.run_row([], status="active_layer_not_set")
        self.assertEqual(self.calls, ["iges"])
        self.assertEqual(row["status"], "active_layer_not_set")

    def test_a_layer_that_is_not_set_with_a_dialog_gets_no_retry(self):
        row = self.run_row([{"where": "after-save", "action": "pressed OK", "text": "Layer"}],
                           status="active_layer_not_set")
        self.assertEqual(self.calls, ["iges"])
        self.assertEqual(row["status"], "active_layer_not_set, exit 1; alert: Layer")

    def test_a_dialog_with_no_text_gives_no_alert(self):
        row = self.run_row([{"where": "after-save", "action": "pressed OK", "text": ""}])
        self.assertEqual(row["alerts"], "")
        self.assertEqual(row["retried"], "yes")
        self.assertEqual(row["status"], "no file produced")

    def test_other_active_layer_failures_still_retry(self):
        for status in ("active_layer_no_result", "active_layer_script_refused"):
            self.run_row([], status=status)
            self.assertEqual(self.calls, ["iges", "iges-retry"], status)



class RowTimeout(unittest.TestCase):
    def test_only_pairs_with_no_record_get_the_row_timeout(self):
        out = tempfile.mkdtemp()
        run_ = batch.Run("plan.tsv", "stage1", out, out)
        self.calls = []

        def call(step, argv, timeout=None, idle=None, vectorworks=True):
            self.calls.append(step)
            if step == "dxf":
                records = os.path.join(out, "runs", "r1-ui-dxf", "records")
                os.makedirs(records)
                Path(records, "a.dxf.all-content.json").write_text(
                    json.dumps({"status": "ok", "path": "files/a/a.dxf", "dialogs": []}))
                run_.killed = "killed after 1800 s without output"
                return "timeout", [], ""
            records = os.path.join(out, "runs", "r2-ui-dxf", "records")
            os.makedirs(records)
            Path(records, "b.dxf.all-content.json").write_text(json.dumps({"status": "ok", "path": "files/b/b.dxf"}))
            row = {"case": "b", "profile": "dxf.all-content", "status": "ok"}
            return 0, [(time.time(), json.dumps({"run_id": "r2-ui-dxf", "rows": 1})), (time.time(), json.dumps(row))], ""

        run_.call = call
        run_.start_vw = lambda step, fresh=False: setattr(run_, "last_start", time.time() - 1)
        run_.keep_ledger_lines = lambda: None
        run_.check = lambda row, results: {}
        run_.do_row({"step": "dxf", "driver": "ui", "format": "dxf", "profile": "dxf.all-content", "cases": "a,b",
                     "options": "", "expect": "record", "ext": "dxf"})
        self.assertEqual(self.calls, ["dxf", "dxf-retry"])
        a, b = run_.summary
        self.assertEqual((a["case"], a["status"], a["retried"], a["file"]),
                         ("a", "ok", "", os.path.join(out, "files/a/a.dxf")))
        self.assertNotIn("first try", a["detail"])
        self.assertEqual((b["case"], b["status"], b["retried"]), ("b", "ok", "yes"))
        self.assertTrue(b["detail"].startswith("first try: row timeout: killed after 1800 s without output"))

class SweepCall(unittest.TestCase):
    def test_ui_call_goes_straight_to_the_front_save(self):
        out = tempfile.mkdtemp()
        run_ = batch.Run("plan.tsv", "stage1", out, out)
        calls = []
        run_.start_vw, run_.last_start = (lambda step: None), 0.0
        run_.call = lambda step, argv, timeout=None, idle=None, vectorworks=True: calls.append(argv) or (1, [], "")
        run_.export({"step": "dxf", "driver": "ui", "format": "dxf", "options": ""}, ["a"], "dxf.all-content")
        self.assertIn("--front", calls[0])


class Wake(unittest.TestCase):
    def test_failed_wake_is_written_and_returns_false(self):
        out = tempfile.mkdtemp()
        body = os.path.join(out, "summary.md")
        Path(body).write_text("batch stage1 exit 0\n")
        bin_dir = os.path.join(out, "bin")
        os.mkdir(bin_dir)
        Path(bin_dir, "rig").write_text("#!/bin/sh\necho no daemon >&2\nexit 4\n")
        os.chmod(os.path.join(bin_dir, "rig"), 0o755)
        held = os.environ["PATH"]
        os.environ["PATH"] = bin_dir + ":" + held
        self.addCleanup(os.environ.__setitem__, "PATH", held)
        # Notification is optional (ROSETTA_NOTIFY, none by default); give it two destinations here.
        self.addCleanup(setattr, batch, "WAKE", batch.WAKE)
        batch.WAKE = ("a@example", "b@example")
        self.assertFalse(batch.wake(0, "stage1", body, True))
        self.assertIn("failed, exit 4: no daemon", Path(body).read_text())


class StopDuringRetry(unittest.TestCase):
    def test_finished_pairs_keep_their_summary_rows(self):
        out = tempfile.mkdtemp()
        run_ = batch.Run("plan.tsv", "stage2-block1", out, out)
        checked = []

        def export(row, cases, profile, retry=False):
            if retry:
                raise batch.Stop("a pause was written during the run: 2026-10-21T06:00:00Z")
            return [{"case": "a", "profile": profile, "status": "ok", "file": "/x/a.dxf", "run_id": "r"},
                    {"case": "b", "profile": profile, "status": "document_not_active", "file": "", "run_id": "r"}]

        run_.export = export
        run_.check = lambda row, results: checked.append([r["case"] for r in results]) or \
            {"/x/a.dxf": {"verdict": "pass", "detail": "1 entities"}}
        row = {"step": "dxf", "driver": "ui", "format": "dxf", "profile": "dxf.all-content", "cases": "a,b",
               "options": "", "expect": "record", "ext": "dxf"}
        with self.assertRaises(batch.Stop):
            run_.do_row(row)
        self.assertEqual(checked, [["a", "b"]])
        self.assertEqual([(r["case"], r["verdict"]) for r in run_.summary], [("a", "pass"), ("b", "")])

    def test_check_runs_under_a_pause(self):
        out = tempfile.mkdtemp()
        held, batch.pause.PAUSE = batch.pause.PAUSE, os.path.join(out, "pause")
        self.addCleanup(setattr, batch.pause, "PAUSE", held)
        Path(batch.pause.PAUSE).write_text("2099-01-01T00:00:00Z\n")
        run_ = batch.Run("plan.tsv", "stage1", out, out)
        code, lines, _err = run_.call("dxf-check", [sys.executable, "-c", "print('{}')"], timeout=20, vectorworks=False)
        self.assertEqual((code, [l for _t, l in lines]), (0, ["{}"]))
        with self.assertRaises(batch.Stop):
            run_.call("dxf", [sys.executable, "-c", "print('{}')"], timeout=20)


class PausedPair(unittest.TestCase):
    def test_a_paused_pair_stops_the_run_without_a_retry(self):
        out = tempfile.mkdtemp()
        run_ = batch.Run("plan.tsv", "stage2-block1", out, out)
        calls = []

        def export(row, cases, profile, retry=False):
            calls.append(retry)
            return [{"case": "a", "profile": profile, "status": "ok", "file": "/x/a.dxf", "run_id": "r"},
                    {"case": "b", "profile": profile, "status": "paused", "file": "", "run_id": "r"}]

        run_.export = export
        run_.check = lambda row, results: {"/x/a.dxf": {"verdict": "pass", "detail": "1 entities"}}
        row = {"step": "dxf", "driver": "ui", "format": "dxf", "profile": "dxf.all-content", "cases": "a,b,c",
               "options": "", "expect": "pass", "ext": "dxf"}
        with self.assertRaises(batch.Stop):
            run_.do_row(row)
        self.assertEqual((calls, run_.retries), ([False], 0))
        self.assertEqual([(r["case"], r["status"]) for r in run_.summary], [("a", "ok"), ("b", "paused")])
        self.assertEqual([(t["kind"], t["name"]) for t in run_.timing], [("pause", "in b dxf.all-content")])

    def test_the_output_check_runs_under_a_pause(self):
        out = tempfile.mkdtemp()
        run_ = batch.Run("plan.tsv", "stage1", out, out)
        run_.call = mock.Mock(side_effect=lambda *a, **k: run_.timing.append({"kind": "call"}) or (0, [], ""))
        run_.check({"step": "dxf"}, [{"file": "/x/a.dxf", "status": "ok", "record": ""}])
        self.assertIs(run_.call.call_args.kwargs["vectorworks"], False)

    def test_a_pause_before_a_call_goes_into_timing(self):
        out = tempfile.mkdtemp()
        held, batch.pause.PAUSE = batch.pause.PAUSE, os.path.join(out, "pause")
        self.addCleanup(setattr, batch.pause, "PAUSE", held)
        Path(batch.pause.PAUSE).write_text("2099-01-01T00:00:00Z\n")
        run_ = batch.Run("plan.tsv", "stage1", out, out)
        with self.assertRaises(batch.Stop):
            run_.call("dxf", [sys.executable, "-c", "print('{}')"], timeout=20)
        self.assertEqual([(t["kind"], t["name"], t["exit"]) for t in run_.timing],
                         [("pause", "before dxf", "2099-01-01T00:00:00Z")])


class Pause(unittest.TestCase):
    def test_earlier_text_comes_back(self):
        path = os.path.join(tempfile.mkdtemp(), "pause")
        Path(path).write_text("2099-01-01T00:00:00Z\n")
        before, mine = batch.take_pause(path)
        self.assertIsNone(batch.pause.paused_until(path))
        batch.give_pause_back(path, before, mine)
        self.assertEqual(Path(path).read_text(), "2099-01-01T00:00:00Z\n")

    def test_a_touch_during_the_run_pauses_it_and_stays(self):
        path = os.path.join(tempfile.mkdtemp(), "pause")
        old = time.time() - 86400
        Path(path).write_text(batch.utc(old) + "\n")
        os.utime(path, (old, old))
        before, mine = batch.take_pause(path)
        later = time.time() + 60
        os.utime(path, (later, later))
        self.assertIn("touched at", batch.pause.paused_until(path))
        batch.give_pause_back(path, before, mine)
        self.assertEqual(Path(path).read_text(), mine)

    def test_the_earlier_time_stamp_comes_back(self):
        path = os.path.join(tempfile.mkdtemp(), "pause")
        old = time.time() - 86400
        Path(path).write_text(batch.utc(old) + "\n")
        os.utime(path, (old, old))
        before, mine = batch.take_pause(path)
        batch.give_pause_back(path, before, mine)
        self.assertIsNone(batch.pause.paused_until(path))

    def test_a_pause_written_during_the_run_stays(self):
        path = os.path.join(tempfile.mkdtemp(), "pause")
        before, mine = batch.take_pause(path)
        Path(path).write_text("2099-01-01T00:00:00Z\n")
        batch.give_pause_back(path, before, mine)
        self.assertEqual(Path(path).read_text(), "2099-01-01T00:00:00Z\n")


class Report(unittest.TestCase):
    def make(self):
        out = tempfile.mkdtemp()
        run_ = batch.Run("plan.tsv", "stage1", out, out)
        row = {c: "" for c in batch.SUMMARY_COLUMNS}
        run_.summary = [dict(row, step="dxf", verdict="pass", expect="pass"),
                        dict(row, step="item7", verdict="partial", expect="record")]
        run_.follow_up = [{"step": "png", "driver": "ui", "format": "png", "profile": "png.top-plan",
                           "cases": "c", "options": "", "expect": "pass", "ext": "png",
                           "reason": "driver/output-check.py has no reader for .png"}]
        return out, run_

    def test_record_rows_do_not_fail_the_stage(self):
        out, run_ = self.make()
        self.assertEqual(run_.exit_code(), 0)
        run_.summary[0]["verdict"] = "unread"
        self.assertEqual(run_.exit_code(), 1)

    def test_follow_up_is_a_plan(self):
        out, run_ = self.make()
        text = run_.report(0)
        self.assertIn("png: driver/output-check.py has no reader for .png", text)
        rows = batch.read_plan(os.path.join(out, "follow-up.tsv"))
        self.assertEqual([r["step"] for r in rows], ["png"])
        self.assertTrue(os.path.exists(os.path.join(out, "summary.tsv")))

    def test_each_restart_is_a_timing_row_with_its_reason(self):
        out, run_ = self.make()
        head = ["utc", "event", "reason", "pid", "footprint_mb", "swap_used_mb", "swap_total_mb", "quit",
                "pid_after", "footprint_after_mb", "swap_used_after_mb", "seconds"]
        rows = [["2026-10-20T12:00:00Z", "restart", "fresh at batch start", "", "", "", "", "gone", "100", "", "", "40.1"],
                ["2026-10-20T12:01:00Z", "check", "", "100", "3000", "0", "0", "", "", "", "", ""],
                ["2026-10-20T12:05:00Z", "restart", "footprint 6200 MB", "100", "6200", "0", "0", "click", "200", "", "", "46"]]
        Path(out, "tmp", "vw-memory.tsv").write_text("\n".join("\t".join(r) for r in [head] + rows) + "\n")
        run_.report(0)
        with open(os.path.join(out, "timing.tsv")) as f:
            timing = list(csv.DictReader(f, delimiter="\t"))
        self.assertEqual([(t["kind"], t["name"], t["start"], t["end"], t["seconds"], t["exit"]) for t in timing],
                         [("restart", "fresh at batch start", "2026-10-20T12:00:00Z", "2026-10-20T12:00:40Z", "40.1", "gone"),
                          ("restart", "footprint 6200 MB", "2026-10-20T12:05:00Z", "2026-10-20T12:05:46Z", "46", "click")])


class Install(unittest.TestCase):
    def make(self, stdout, stderr, code=1):
        out = tempfile.mkdtemp()
        run_ = batch.Run("plan.tsv", "stage2", out, out)
        self.calls = []

        def call(step, argv, timeout=None, idle=None, vectorworks=True):
            self.calls.append(argv)
            self.assertFalse(vectorworks, "an install call runs under a pause")
            run_.timing.append({"kind": "call", "name": step})
            return code, [(0, l) for l in stdout], stderr

        run_.call = call
        return out, run_

    def ui_pair(self, out, case, profile="dxf.all-content"):
        records = os.path.join(out, "runs", "r1-ui-dxf", "records")
        os.makedirs(records, exist_ok=True)
        record = os.path.join(records, "%s.%s.json" % (case, profile))
        Path(record).write_text(json.dumps({"case": case, "profile": profile, "run_id": "r1-ui-dxf",
                                            "path": "files/%s/%s.dxf" % (case, case)}))
        return {"case": case, "profile": profile, "status": "ok", "record": record,
                "file": os.path.join(out, "files", case, case + ".dxf")}

    def test_actions_from_install_artifact(self):
        out, run_ = self.make(["a dxf.all-content\tinstall\told=0\tnew=12\t12 entities",
                               "b dxf.all-content\tkeep\told=12\tnew=12\t12 entities",
                               "e dxf.all-content\tkeep\told=0\tnew=0\t0 entities"],
                              "refused c dxf.all-content: output check fail: no object held\n"
                              "refused d dxf.all-content: record status ok, file /x\n")
        pairs = [self.ui_pair(out, c) for c in "abcde"]
        checked = {p["file"]: {"reader": "parsed", "objects": "0/1", "detail": "0 entities"} for p in pairs}
        run_.install({"step": "dxf.all-content", "driver": "ui", "format": "dxf"}, pairs, checked)
        self.assertEqual([p["install"] for p in pairs], ["install", "keep", "negative", "refused", "refused"])
        self.assertEqual(pairs[0]["counts"], "old=0 new=12")
        self.assertEqual(pairs[2]["install_reason"], "output check fail: no object held")
        self.assertEqual(pairs[3]["install_reason"], "record status ok, file /x")
        self.assertEqual(pairs[4]["install_reason"], "output check passed, measure counted 0: 0 entities")
        argv = self.calls[0]
        self.assertEqual(argv[:2], [batch.READER_PYTHON, os.path.join(batch.ROOT, "tools", "install-artifact.py")])
        self.assertEqual(argv[argv.index("--check-python") + 1], batch.READER_PYTHON)
        self.assertIn("--apply", argv)
        self.assertEqual(json.loads(Path(pairs[0]["record"]).read_text())["path"], pairs[0]["file"])

    def test_check_fail_without_a_reader_is_refused(self):
        out, run_ = self.make([], "refused a dxf.all-content: output check fail: reader failed: OSError\n")
        pairs = [self.ui_pair(out, "a")]
        run_.install({"step": "s", "driver": "ui", "format": "dxf"}, pairs, {pairs[0]["file"]: {"reader": "exception"}})
        self.assertEqual(pairs[0]["install"], "refused")

    def test_read_empty(self):
        tmp = tempfile.mkdtemp()
        whole, cut = os.path.join(tmp, "whole.3ds"), os.path.join(tmp, "cut.3ds")
        Path(whole).write_bytes(b"\x4d\x4d" + (16).to_bytes(4, "little") + bytes(10))
        Path(cut).write_bytes(b"\x4d\x4d" + (32).to_bytes(4, "little") + bytes(10))
        none = {"reader": "none", "objects": "0/1", "detail": "0 points"}
        cases = [("a.sat", {"reader": "parsed", "objects": "0/1", "detail": "0 entities"}, True),
                 ("a.dxf", {"reader": "warnings", "objects": "0/2", "missing": "p1,p2"}, True),
                 ("a.obj", {"reader": "none", "objects": "0/1", "detail": "0 points"}, True),
                 (whole, none, True),
                 (cut, none, False),
                 ("a.sat", {"reader": "rejected", "objects": "", "detail": "IndexError"}, False),
                 ("a.dxf", {"reader": "exception", "objects": ""}, False),
                 ("a.stl", {"reader": "none", "objects": "", "detail": "object reader failed: error: unpack"}, False),
                 ("a.dxf", {"reader": "parsed", "objects": "1/2"}, False),
                 ("a.dxf", {}, False)]
        for path, check, want in cases:
            self.assertEqual(batch.read_empty(path, check), want, (path, check))

    def test_a_crash_refuses_every_pair(self):
        out, run_ = self.make([], "Traceback (most recent call last):\nKeyError: 'path'\n")
        pairs = [self.ui_pair(out, "a")]
        run_.install({"step": "s", "driver": "ui", "format": "dxf"}, pairs, {})
        self.assertEqual(pairs[0]["install"], "refused")
        self.assertIn("install-artifact.py exit 1: KeyError: 'path'", pairs[0]["install_reason"])

    def test_scripted_record_gets_the_sweep_ui_form(self):
        out, run_ = self.make([], "")
        records = os.path.join(out, "runs", "r2-scripted", "records")
        os.makedirs(records)
        record = os.path.join(records, "a.json")
        found = {"format": "stl", "path": "files/a/a.stl", "bytes": 84}
        Path(record).write_text(json.dumps({"case": "a", "run_id": "r2-scripted", "source": "s.vwx",
                                            "source_sha256": "f00", "collected": [found], "errors": [],
                                            "work_copy": "/w"}))
        result = {"case": "a", "profile": "stl.binary.high-all", "record": record, "found": found,
                  "file": os.path.join(out, "files", "a", "a.stl")}
        path = run_.install_record({"driver": "scripted", "format": "stl"}, result)
        self.assertEqual(path, os.path.join(records, "a.stl.binary.high-all.json"))
        rec = json.loads(Path(path).read_text())
        self.assertEqual({k: rec[k] for k in ("case", "profile", "format", "status", "run_id", "source_sha256",
                                              "sidecars", "scripted_record", "path", "bytes")},
                         {"case": "a", "profile": "stl.binary.high-all", "format": "stl", "status": "ok",
                          "run_id": "r2-scripted", "source_sha256": "f00", "sidecars": [],
                          "scripted_record": record, "path": result["file"], "bytes": 84})
        self.assertFalse({"collected", "errors", "work_copy"} & set(rec))

    def test_unresolved_install_fails_the_stage(self):
        out, run_ = self.make([], "")
        row = {c: "" for c in batch.SUMMARY_COLUMNS}
        run_.summary = [dict(row, step="s", expect="install", install="negative", verdict="fail")]
        self.assertEqual(run_.exit_code(), 0)
        run_.summary.append(dict(row, step="s", expect="install", install="refused", verdict="pass"))
        self.assertEqual(run_.exit_code(), 1)


class Stage2Plan(unittest.TestCase):
    BUILD = ROOT / "driver" / "batch" / "build-stage2.py"
    INVENTORY = ("kind\tname\tstatus\treason_or_slot\tevidence\n"
                 "pair\tiges: b\tplanned\t\t\npair\tiges: plugin.combined.01\tplanned\t\t\n"
                 "pair\tiges: c\tdone\t\t\n")

    def build(self, covering, *flags):
        tmp = tempfile.mkdtemp()
        Path(tmp, "c.tsv").write_text("case\troute\tprofile\ttier\tstatus\treason\n" + covering)
        Path(tmp, "i.tsv").write_text(self.INVENTORY)
        return subprocess.run([sys.executable, "-B", str(self.BUILD), *flags, os.path.join(tmp, "c.tsv"),
                               os.path.join(tmp, "i.tsv")], capture_output=True, text=True)

    def rows(self, done):
        self.assertEqual(done.returncode, 0, done.stderr)
        tsv = Path(tempfile.mkdtemp(), "p.tsv")
        tsv.write_text(done.stdout)
        return batch.read_plan(str(tsv))

    def test_rows_follow_the_route_order(self):
        done = self.build("z\tpdf\tpdf.vector\tA\texport\t\na\tdxf\tdxf.top-plan\tA\texport-again-settings-unknown\t\n"
                          "b\tdxf\tdxf.top-plan\tA\texport-again-settings-differ\t\nc\tdwg\tdwg.all-content\tA\theld\t\n"
                          "d\tstl\tstl.binary.high-all\tA\texport\t\n")
        rows = self.rows(done)
        self.assertEqual([(r["step"], r["driver"], r["cases"], r["options"], r["expect"]) for r in rows],
                         [("dxf.top-plan", "ui", "a,b", "--unlisted", "install"),
                          ("pdf.vector", "ui", "z", "--unlisted", "install")])

    def test_stage3_takes_its_formats_and_the_item7_rows(self):
        done = self.build("a\tdxf\tdxf.top-plan\tA\texport\t\nb\tpng\tpng.top-plan\tA\texport\t\n")
        rows = self.rows(self.build("a\tdxf\tdxf.top-plan\tA\texport\t\nb\tpng\tpng.top-plan\tA\texport\t\n",
                                    "--stage3"))
        self.assertEqual([r["step"] for r in self.rows(done)], ["dxf.top-plan"])
        self.assertEqual([r["step"] for r in rows if not r["step"].startswith("item7-")],
                         ["iges.solids", "png.top-plan"])
        self.assertEqual(rows[0]["ext"], "igs")
        item7 = [r["step"] for r in rows if r["step"].startswith("item7-")]
        self.assertIn("item7-3ds-hub", item7)
        self.assertTrue(all("--active-layer" in r["options"] for r in rows if r["step"].startswith("item7-")))

    def test_scripted_rows_go_to_their_own_plan(self):
        covering = "a\tdxf\tdxf.top-plan\tA\texport\t\nd\tstl\tstl.binary.high-all\tA\texport\t\n"
        self.assertEqual([(r["step"], r["driver"], r["cases"], r["options"])
                          for r in self.rows(self.build(covering, "--scripted"))],
                         [("stl.binary.high-all", "scripted", "d", "")])
        self.assertEqual({r["driver"] for r in self.rows(self.build(covering))}, {"ui"})

    def test_empty_profile_is_refused(self):
        done = self.build("a\tdxf\t\tA\texport\t\n")
        self.assertEqual(done.returncode, 2)
        self.assertIn("refused: dxf a has no profile", done.stderr)

    def test_batch_refuses_an_install_row_without_profile(self):
        tsv = Path(tempfile.mkdtemp(), "p.tsv")
        tsv.write_text("s\tui\tdxf\t\ta\t\tinstall\tdxf\n")
        with self.assertRaises(SystemExit) as stop:
            batch.read_plan(str(tsv))
        self.assertIn("installs and names no profile", str(stop.exception))


class StagePlans(unittest.TestCase):
    def test_stage2_holds_no_stage3_format(self):
        formats = {r["format"] for r in batch.read_plan(batch.PLANS["stage2"])}
        self.assertFalse(formats & {"png", "3ds", "fbx", "gltf", "iges"}, formats)
        self.assertEqual({r["format"] for r in batch.read_plan(batch.PLANS["stage3"])} - {"png", "3ds", "fbx", "gltf",
                                                                                          "iges"}, set())

    def test_stage3_holds_every_item7_layer_row_of_stage1(self):
        item7 = [r for r in batch.read_plan(batch.PLANS["stage1"])
                 if r["step"].startswith("item7-") and "--active-layer" in r["options"]]
        self.assertTrue(item7)
        self.assertEqual([r for r in batch.read_plan(batch.PLANS["stage3"]) if r["step"].startswith("item7-")], item7)

    def test_blocks_together_equal_stage2(self):
        def pairs(path):
            return [(c, r["step"], r["driver"], r["format"], r["profile"], r["options"], r["expect"], r["ext"])
                    for r in batch.read_plan(path) for c in r["cases"].split(",")]
        blocks = sorted(glob.glob(os.path.join(ROOT, "driver", "batch", "stage2-block*.tsv")))
        self.assertTrue(blocks)
        joined = [p for b in blocks for p in pairs(b)]
        self.assertEqual(len(joined), len(set(joined)))
        self.assertEqual(sorted(joined), sorted(pairs(batch.PLANS["stage2"])))
        build = batch.load("build_blocks", str(ROOT / "driver" / "batch" / "build-blocks.py"))
        self.assertTrue(all(len(pairs(b)) <= build.BLOCK_SECONDS // build.PAIR_SECONDS for b in blocks))

    def test_blocks_match_build_blocks(self):
        tmp = Path(tempfile.mkdtemp(), "stage2.tsv")
        tmp.write_text((ROOT / "driver" / "batch" / "stage2.tsv").read_text())
        done = subprocess.run([sys.executable, "-B", str(ROOT / "driver" / "batch" / "build-blocks.py"), str(tmp)],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        made = sorted(p.name for p in tmp.parent.glob("stage2-block*.tsv"))
        kept = sorted(p.name for p in (ROOT / "driver" / "batch").glob("stage2-block*.tsv"))
        self.assertEqual(made, kept)
        for name in made:
            self.assertEqual(Path(tmp.parent, name).read_text(), (ROOT / "driver" / "batch" / name).read_text(), name)

    def test_each_stage_plan_holds_one_driver(self):
        for stage in ("stage1", "stage2"):
            self.assertEqual({r["driver"] for r in batch.read_plan(batch.PLANS[stage])}, {"ui"}, stage)
            self.assertEqual({r["driver"] for r in batch.read_plan(batch.PLANS[stage + "-scripted"])},
                             {"scripted"}, stage)

    def test_no_pair_is_in_both_plans_of_a_stage(self):
        def pairs(name):
            return {(c, r["profile"], r["format"]) for r in batch.read_plan(batch.PLANS[name])
                    for c in r["cases"].split(",")}
        for stage in ("stage1", "stage2"):
            self.assertFalse(pairs(stage) & pairs(stage + "-scripted"), stage)

    def test_scripted_plan_passes_the_front_check_without_front(self):
        tmp = tempfile.mkdtemp()
        os.mkdir(os.path.join(tmp, "lock"))
        done = run("stage1-scripted", "--no-wake", env={"ROSETTA_TMP": tmp})
        self.assertEqual(done.returncode, 2, done.stderr)
        summary = Path(next(Path(tmp, "batch").glob("*-stage1-scripted")), "summary.md").read_text()
        self.assertIn("refused: another run holds", summary)

    def test_ui_plan_still_needs_front(self):
        tmp = tempfile.mkdtemp()
        done = run("stage1", "--no-wake", env={"ROSETTA_TMP": tmp})
        self.assertEqual(done.returncode, 2, done.stderr)
        summary = Path(next(Path(tmp, "batch").glob("*-stage1")), "summary.md").read_text()
        self.assertIn("Start it with --front", summary)


class ReaderPython(unittest.TestCase):
    def test_missing_pil_refuses_the_start(self):
        tmp = tempfile.mkdtemp()
        fake = os.path.join(tmp, "python")
        Path(fake).write_text("#!/bin/sh\necho PIL\n")
        os.chmod(fake, 0o755)
        done = run("stage2", "--front", "--no-wake", env={"ROSETTA_TMP": tmp, "ROSETTA_READER_PYTHON": fake,
                                                "ROSETTA_PAUSE": os.path.join(tmp, "pause")})
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertIn("cannot import PIL", done.stderr)


class ScriptedUnderPause(unittest.TestCase):
    def make(self, exit_code):
        evidence = tempfile.mkdtemp()
        os.makedirs(os.path.join(evidence, "driver", "scripted"))
        Path(evidence, "driver", "vw_memory.py").write_text(FAKE_MEMORY)
        Path(evidence, "driver", "started").touch()
        Path(evidence, "driver", "scripted", "sweep-scripted.sh").write_text(
            'echo "open=$ROSETTA_OPEN_UNDER_PAUSE"\necho "run x stopped during a: took_front"\nexit %d\n' % exit_code)
        held = os.path.join(evidence, "pause")
        Path(held).write_text("2099-01-01T00:00:00Z\n")
        saved, batch.pause.PAUSE = batch.pause.PAUSE, held
        self.addCleanup(setattr, batch.pause, "PAUSE", saved)
        return batch.Run("plan.tsv", "stl", tempfile.mkdtemp(), evidence, under_pause=True)

    def row(self):
        return {"step": "stl", "driver": "scripted", "format": "stl", "profile": "stl.binary.high-all",
                "cases": "a", "options": "", "expect": "record", "ext": "stl"}

    def test_the_call_runs_with_the_open_flag(self):
        run_ = self.make(0)
        code, lines, _err = run_.call("stl", ["bash", "driver/scripted/sweep-scripted.sh"])
        self.assertEqual(code, 0)
        self.assertEqual(lines[0][1], "open=1")

    def test_exit_3_stops_the_run_after_the_summary_rows(self):
        run_ = self.make(3)
        with self.assertRaises(batch.Stop) as stop:
            run_.do_row(self.row())
        self.assertIn("exit 3 under the pause during a: run x stopped during a: took_front", str(stop.exception))
        self.assertEqual([(r["case"], r["status"]) for r in run_.summary],
                         [("a", "stopped: run x stopped during a: took_front")])

    def test_a_refusal_on_stderr_reaches_the_summary(self):
        run_ = self.make(3)
        Path(run_.evidence, "driver", "scripted", "sweep-scripted.sh").write_text(
            'echo "refused to drive Vectorworks: uncommitted changes" >&2\nexit 3\n')
        with self.assertRaises(batch.Stop) as stop:
            run_.do_row(self.row())
        self.assertIn("during a: refused to drive Vectorworks: uncommitted changes", str(stop.exception))
        self.assertEqual(run_.summary[0]["detail"], "stopped: refused to drive Vectorworks: uncommitted changes")

    def test_a_stop_in_a_retry_ends_the_retries(self):
        run_ = self.make(0)
        Path(run_.evidence, "driver", "scripted", "sweep-scripted.sh").write_text(
            'echo "$4" >> calls\n[ "$(wc -l < calls)" -ge 3 ] && { echo "took_front"; exit 3; }\nexit 1\n')
        row = dict(self.row(), cases="a,b")
        with self.assertRaises(batch.Stop):
            run_.do_row(row)
        self.assertEqual(Path(run_.evidence, "calls").read_text().split(), ["a", "b", "a"])

    def test_each_case_restores_the_ledger_before_the_next_case(self):
        run_ = self.make(0)
        git = ["git", "-C", run_.evidence, "-c", "user.name=t", "-c", "user.email=t@t"]
        os.makedirs(os.path.join(run_.evidence, "ledger"))
        Path(run_.evidence, "ledger", "corpus-ledger.jsonl").write_text("")
        subprocess.run(git[:3] + ["init", "-q"], check=True)
        subprocess.run(git + ["add", "ledger"], check=True)
        subprocess.run(git + ["commit", "-qm", "ledger"], check=True)
        Path(run_.evidence, "driver", "scripted", "sweep-scripted.sh").write_text(
            'git diff --quiet -- ledger || { echo "refused: uncommitted changes" >&2; exit 3; }\n'
            'echo "{\\"case\\": \\"$4\\"}" >> ledger/corpus-ledger.jsonl\n')
        results = run_.export(self.row(), ["a", "b"], "stl.binary.high-all")
        self.assertEqual(run_.stop, "")
        self.assertEqual([r["case"] for r in results], ["a", "b"])
        self.assertEqual(Path(run_.out, "ledger-lines.jsonl").read_text(), '{"case": "a"}\n{"case": "b"}\n')

    def scripted_record(self, error, alert):
        Path(self.run_.evidence, "driver", "scripted", "sweep-scripted.sh").write_text(
            'echo "$4" >> calls\n'
            'd="runs/$(wc -l < calls | tr -d " ")-scripted/records"; mkdir -p "$d"\n'
            "printf '%%s' '%s' > \"$d/$4.json\"\n" % json.dumps(
                {"collected": [], "errors": [{"format": "stl", "detail": error}], "alerts": [alert] if alert else []}))

    def test_the_stl_no_objects_alert_gets_no_retry_and_reaches_the_summary(self):
        self.run_ = self.make(0)
        alert = "Export STL failed. There are no valid objects available for export."
        self.scripted_record("api returned False, file size 0", alert)
        self.run_.do_row(self.row())
        self.assertEqual(Path(self.run_.evidence, "calls").read_text().split(), ["a"])
        row = self.run_.summary[0]
        self.assertEqual(row["retried"], "")
        self.assertEqual(row["alerts"], alert)
        self.assertTrue(row["status"].startswith("exit 0, no file: "))
        self.assertTrue(row["status"].endswith("; alert: " + alert))

    def test_a_failure_with_no_alert_still_retries(self):
        self.run_ = self.make(0)
        self.scripted_record("api returned False, file size 0", None)
        self.run_.do_row(self.row())
        self.assertEqual(Path(self.run_.evidence, "calls").read_text().split(), ["a", "a"])
        self.assertEqual(self.run_.summary[0]["retried"], "yes")

    def test_a_run_outside_the_pause_stops_at_the_pause(self):
        run_ = self.make(0)
        run_.under_pause = False
        with self.assertRaises(batch.Stop):
            run_.call("stl", ["true"])



class ForeignDocuments(unittest.TestCase):
    def found(self, stdout, code=0):
        done = subprocess.CompletedProcess([], code, stdout, "not allowed" if code else "")
        with mock.patch.object(batch.subprocess, "run", return_value=done):
            return batch.foreign_documents()

    def test_batch_work_copies_and_palettes_pass(self):
        self.assertEqual(self.found(
            "a.vwx\tfile:///Volumes/volxxxx/Caches/tmp/rosetta-corpus/batch/x/tmp/work-sources/a.vwx\ttrue\n"
            "\t\tfalse\nUntitled 1\t\tfalse\n"), [])

    def test_a_document_outside_the_cache_is_named(self):
        self.assertEqual(self.found("Plan B.vwx\tfile:///Users/someone/Documents/Plan%20B.vwx\tfalse\n"),
                         ["/Users/someone/Documents/Plan B.vwx"])

    def test_an_unsaved_window_without_a_file_is_named(self):
        self.assertEqual(self.found("Untitled 2\t\ttrue\n"), ["unsaved window 'Untitled 2'"])

    def test_a_failed_window_read_refuses(self):
        self.assertEqual(self.found("", 1), ["the window list of Vectorworks: osascript exit 1: not allowed"])



class BatchStarted(unittest.TestCase):
    def started(self, pid, lstart, rows):
        scratch = tempfile.mkdtemp()
        os.makedirs(os.path.join(scratch, "batch", "r", "tmp"))
        Path(scratch, "batch", "r", "tmp", "vw-memory.tsv").write_text(
            "utc\tevent\tpid_after\tseconds\n" + "".join("\t".join(r) + "\n" for r in rows))
        done = subprocess.CompletedProcess([], 0, lstart + "\n", "")
        with mock.patch.object(batch, "SCRATCH", scratch), mock.patch.object(batch.subprocess, "run", return_value=done), \
                mock.patch.dict(os.environ, {"TZ": "UTC"}):
            time.tzset()
            try:
                return batch.batch_started(pid)
            finally:
                time.tzset()

    def test_a_pid_started_by_a_batch_restart_passes(self):
        self.assertTrue(self.started("26284", "Tue Oct 20 07:47:45 2026",
                                     [("2026-10-20T07:47:33Z", "restart", "26284", "51")]))

    def test_a_reused_pid_is_refused(self):
        self.assertFalse(self.started("26284", "Tue Oct 20 09:00:00 2026",
                                      [("2026-10-20T07:47:33Z", "restart", "26284", "51")]))

    def test_a_malformed_row_is_skipped(self):
        self.assertTrue(self.started("26284", "Tue Oct 20 07:47:45 2026",
                                     [("garbage", "restart", "26284", "x"),
                                      ("2026-10-20T07:47:33Z", "restart", "26284", "51")]))

    def test_a_pid_with_no_batch_record_is_refused(self):
        self.assertFalse(self.started("500", "Tue Oct 20 07:47:45 2026",
                                      [("2026-10-20T07:47:33Z", "restart", "26284", "51")]))


class StartGuard(unittest.TestCase):
    def start(self, started, foreign):
        plan = os.path.join(tempfile.mkdtemp(), "plan.tsv")
        Path(plan).write_text("s\tscripted\tstl\tstl.binary.high-all\ta\t\trecord\tstl\n")
        scratch = tempfile.mkdtemp()
        with mock.patch.object(batch, "SCRATCH", scratch), \
                mock.patch.object(batch, "reader_missing", return_value=""), \
                mock.patch.object(batch.pause, "paused_until", return_value=None), \
                mock.patch.object(batch.run_provenance, "state", return_value={}), \
                mock.patch.object(batch.run_provenance, "refusal", return_value=None), \
                mock.patch.object(batch, "live_vectorworks", return_value="123"), \
                mock.patch.object(batch, "batch_started", return_value=started), \
                mock.patch.object(batch, "foreign_documents", return_value=foreign), \
                mock.patch.object(batch.subprocess, "run", side_effect=AssertionError("the start went past the guard")), \
                mock.patch.object(sys, "argv", ["batch.py", "--plan", plan, "--no-wake"]), \
                mock.patch("sys.stderr"):
            code = batch.main()
        summaries = glob.glob(os.path.join(scratch, "batch", "*", "summary.md"))
        return code, Path(summaries[0]).read_text() if summaries else ""

    def test_a_process_no_batch_started_refuses_the_start(self):
        code, summary = self.start(False, [])
        self.assertEqual(code, 2)
        self.assertIn("Vectorworks pid 123 runs, and no batch run started it", summary)

    def test_a_document_of_a_person_refuses_the_start(self):
        code, summary = self.start(True, ["/Users/someone/Plan.vwx"])
        self.assertEqual(code, 2)
        self.assertIn("quits Vectorworks: /Users/someone/Plan.vwx", summary)


class FrontOption(unittest.TestCase):
    def start(self, driver, *flags):
        plan = os.path.join(tempfile.mkdtemp(), "plan.tsv")
        Path(plan).write_text("s\t%s\tdxf\tdxf.r2018\ta\t\trecord\tdxf\n" % driver)
        with mock.patch.object(batch, "SCRATCH", tempfile.mkdtemp()), \
                mock.patch.object(batch, "reader_missing", return_value="ezdxf"), \
                mock.patch.object(sys, "argv", ["batch.py", "--plan", plan, "--no-wake"] + list(flags)), \
                mock.patch("sys.stderr") as err:
            code = batch.main()
        return code, "".join(c.args[0] for c in err.write.call_args_list)

    def test_a_ui_plan_without_front_is_refused(self):
        code, err = self.start("ui")
        self.assertEqual(code, 2)
        self.assertIn("the plan has ui rows", err)

    def test_front_lets_a_ui_plan_past_the_option_check(self):
        code, err = self.start("ui", "--front")
        self.assertEqual(code, 2)
        self.assertIn("cannot import ezdxf", err)

    def test_a_scripted_plan_needs_no_front(self):
        code, err = self.start("scripted")
        self.assertIn("cannot import ezdxf", err)


class ReaderAudit(unittest.TestCase):
    def make(self, install, code=0):
        out = tempfile.mkdtemp()
        run_ = batch.Run("plan.tsv", "stage1", out, out)
        run_.summary = [{"step": "s", "case": "c", "route": "dxf", "profile": "p", "verdict": "pass",
                         "missing": "", "detail": "", "expect": "install", "install": install}]
        run_.call = mock.Mock(return_value=(code, [], "Traceback\nOSError: dwgread missing\n"))
        run_.audit_readers()
        return run_, run_.report(0)

    def test_an_install_writes_the_reader_audit(self):
        run_, text = self.make("install")
        argv = run_.call.call_args.args[1]
        self.assertEqual(argv[1:], [os.path.join(batch.ROOT, "driver", "reader-audit.py"), "--write"])
        self.assertIs(run_.call.call_args.kwargs["vectorworks"], False)
        self.assertIn("reader audit: wrote ledger/reader-audit.tsv", text)

    def test_a_failed_reader_audit_gives_the_command(self):
        _run, text = self.make("install", code=1)
        self.assertIn("reader audit: exit 1: OSError: dwgread missing. Run this before the install commit: ", text)
        self.assertIn("reader-audit.py --write", text)

    def test_a_run_that_installed_nothing_has_no_reader_audit(self):
        run_, text = self.make("keep")
        run_.call.assert_not_called()
        self.assertNotIn("reader audit", text)


if __name__ == "__main__":
    unittest.main()
