#!/usr/bin/env python3
import importlib.util
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "driver"))
import pause  # noqa: E402
import vw_memory  # noqa: E402


class Parse(unittest.TestCase):
    def test_footprint_units(self):
        self.assertEqual(vw_memory.parse_footprint("Vectorworks [52033]: 64-bit    Footprint: 11 GB (16384 bytes per page)"), 11264)
        self.assertEqual(vw_memory.parse_footprint("Vectorworks [62663]: 64-bit    Footprint: 3298 MB (16384 bytes per page)"), 3298)
        self.assertIsNone(vw_memory.parse_footprint("footprint: no process"))

    def test_swap_decimal_comma_and_point(self):
        pt = "vm.swapusage: total = 5120,00M  used = 3723,38M  free = 1396,62M  (encrypted)"
        en = "vm.swapusage: total = 5120.00M  used = 3723.38M  free = 1396.62M  (encrypted)"
        self.assertEqual(vw_memory.parse_swap(pt), (3723, 5120))
        self.assertEqual(vw_memory.parse_swap(en), (3723, 5120))


class Limits(unittest.TestCase):
    def test_limits(self):
        self.assertEqual((vw_memory.FOOTPRINT_LIMIT_MB, vw_memory.SWAP_USED_MB, vw_memory.SWAP_FOOTPRINT_MB),
                         (6144, 4608, 5120))
        self.assertIsNone(vw_memory.over_limit(3320, 4352, 5120))
        self.assertIsNone(vw_memory.over_limit(6144, 1000, 5120))
        self.assertIn("footprint", vw_memory.over_limit(6145, 1000, 5120))
        self.assertIsNone(vw_memory.over_limit(5120, 4609, 5120))
        self.assertIsNone(vw_memory.over_limit(5289, 4608, 5120))
        self.assertIn("swap", vw_memory.over_limit(5289, 4609, 5120))
        self.assertIsNone(vw_memory.over_limit(None, None, None))


class DefaultLimit(unittest.TestCase):
    def test_footprint_limit_is_6144_when_the_variable_is_unset(self):
        env = {k: v for k, v in os.environ.items() if k != "VW_FOOTPRINT_LIMIT_MB"}
        with mock.patch.dict(os.environ, env, clear=True):
            spec = importlib.util.spec_from_file_location("vw_memory_fresh", ROOT / "driver/vw_memory.py")
            fresh = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(fresh)
        self.assertEqual(fresh.FOOTPRINT_LIMIT_MB, 6144)


class Steps(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.log = os.path.join(self.tmp.name, "vw-memory.tsv")
        self.pause = os.path.join(self.tmp.name, "rosetta-pause")
        patches = [mock.patch.object(vw_memory, "LOG", self.log),
                   mock.patch.object(pause, "PAUSE", self.pause),
                   mock.patch.object(vw_memory, "live_pid", return_value="100"),
                   mock.patch.object(vw_memory, "FOOTPRINT_LIMIT_MB", 4608)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def tearDown(self):
        self.tmp.cleanup()

    def rows(self):
        return [line.split("\t") for line in Path(self.log).read_text().splitlines()[1:]]

    def test_under_limit_logs_a_check_and_keeps_the_process(self):
        with mock.patch.object(vw_memory, "measure", return_value=(3298, (1000, 3072))), \
                mock.patch.object(vw_memory, "restart") as restart:
            self.assertEqual(vw_memory.before_row(), "100")
        restart.assert_not_called()
        self.assertEqual(self.rows()[0][:5], [self.rows()[0][0], "check", "", "100", "3298"])

    def test_over_limit_restarts(self):
        with mock.patch.object(vw_memory, "measure", return_value=(11264, (1000, 3072))), \
                mock.patch.object(vw_memory, "restart", return_value="200") as restart:
            self.assertEqual(vw_memory.before_row(), "200")
        self.assertIn("footprint 11264 MB", restart.call_args[0][0])

    def test_end_of_batch_under_the_limit_closes_the_documents_and_keeps_the_process(self):
        close = mock.Mock()
        with mock.patch.object(vw_memory, "measure", return_value=(3298, (1000, 3072))), \
                mock.patch.object(vw_memory, "restart") as restart:
            self.assertEqual(vw_memory.end_of_batch(close=close), "100")
        restart.assert_not_called()
        close.assert_called_once_with("100")
        self.assertEqual(self.rows()[0][1], "check")

    def test_end_of_batch_over_the_limit_restarts(self):
        close = mock.Mock()
        with mock.patch.object(vw_memory, "measure", return_value=(6200, (1000, 3072))), \
                mock.patch.object(vw_memory, "restart", return_value="200") as restart:
            self.assertEqual(vw_memory.end_of_batch(close=close), "200")
        self.assertIn("footprint 6200 MB", restart.call_args[0][0])
        close.assert_not_called()

    def test_end_of_batch_with_no_process_starts_none(self):
        with mock.patch.object(vw_memory, "live_pid", return_value=None), \
                mock.patch.object(vw_memory, "restart") as restart:
            self.assertIsNone(vw_memory.end_of_batch(close=mock.Mock()))
        restart.assert_not_called()

    def test_restart_reads_the_pause_file_before_the_quit(self):
        Path(self.pause).write_text("2999-01-01T00:00:00Z\n")
        with mock.patch.object(vw_memory, "run") as run, mock.patch.object(vw_memory, "quit_app") as quit_app:
            with self.assertRaises(pause.Paused):
                vw_memory.restart("end of batch")
        run.assert_not_called()
        quit_app.assert_not_called()

    def under_pause_restart(self, fronts):
        Path(self.pause).write_text("2999-01-01T00:00:00Z\n")
        fronts = iter(fronts)
        pids = iter(["100", "200"])
        with mock.patch.dict(os.environ, {"ROSETTA_OPEN_UNDER_PAUSE": "1"}), \
                mock.patch.object(vw_memory, "measure", return_value=(3298, (0, 0))), \
                mock.patch.object(vw_memory, "live_pid", side_effect=lambda: next(pids)), \
                mock.patch.object(vw_memory, "quit_app", return_value="click"), \
                mock.patch.object(vw_memory.focus, "front", side_effect=lambda: next(fronts)), \
                mock.patch.object(vw_memory.focus, "return_front") as back, \
                mock.patch.object(vw_memory, "run", return_value=(0, "")) as run:
            try:
                return vw_memory.restart("fresh at batch start"), back, run
            except RuntimeError as exc:
                return exc, back, run

    def test_restart_under_the_pause_starts_in_the_background(self):
        pid, back, run = self.under_pause_restart([("9", "iTerm2"), ("9", "iTerm2")])
        self.assertEqual(pid, "200")
        self.assertEqual(run.call_args[0][0], ["sh", vw_memory.LAUNCH])
        back.assert_not_called()

    def test_restart_under_the_pause_gives_the_front_back_and_raises(self):
        exc, back, _run = self.under_pause_restart([("9", "iTerm2"), ("200", "Vectorworks")])
        self.assertIn("came to the front", str(exc))
        back.assert_called_once_with("9", "200")
        self.assertIn("front given to iTerm2", self.rows()[0][2])

    def test_restart_logs_before_and_after(self):
        measures = iter([(11264, (3700, 5120)), (3298, (2000, 3072))])
        pids = iter(["100", "200"])
        closed = []
        with mock.patch.object(vw_memory, "measure", side_effect=lambda pid: next(measures)), \
                mock.patch.object(vw_memory, "live_pid", side_effect=lambda: next(pids)), \
                mock.patch.object(vw_memory, "quit_app", return_value="click"), \
                mock.patch.object(vw_memory, "run", return_value=(0, "ready pid 200 after 10s")) as run:
            self.assertEqual(vw_memory.restart("manual", close=closed.append), "200")
        self.assertEqual(closed, ["100"])
        self.assertEqual(run.call_args[0][0], ["sh", vw_memory.LAUNCH])
        row = dict(zip(vw_memory.COLUMNS, self.rows()[0]))
        self.assertEqual((row["event"], row["quit"], row["footprint_mb"], row["pid_after"], row["footprint_after_mb"]),
                         ("restart", "click", "11264", "200", "3298"))

    def test_failed_quit_kills_through_vw_launch(self):
        with mock.patch.object(vw_memory, "measure", return_value=(3298, (0, 0))), \
                mock.patch.object(vw_memory, "quit_app", return_value=None), \
                mock.patch.object(vw_memory, "run", return_value=(0, "")) as run:
            vw_memory.restart("manual")
        self.assertEqual(run.call_args[0][0], ["sh", vw_memory.LAUNCH, "--restart"])

    def test_quit_event_timeout_counts_as_a_failed_quit(self):
        def run(cmd, timeout=60):
            if cmd[0] == "osascript":
                raise vw_memory.subprocess.TimeoutExpired("osascript", 1)
            return 0, ""
        with mock.patch.object(vw_memory, "run", side_effect=run), mock.patch.object(vw_memory.time, "sleep"):
            self.assertIsNone(vw_memory.quit_app("100", seconds=0.2))

    def test_quit_cancels_a_panel_then_clicks_before_the_quit_event(self):
        calls = []
        def run(cmd, timeout=60):
            calls.append(cmd)
            return (1, "") if cmd[0] == "kill" and len(calls) > 3 else (0, "0")
        with mock.patch.object(vw_memory, "run", side_effect=run), mock.patch.object(vw_memory.time, "sleep"):
            self.assertEqual(vw_memory.quit_app("100", seconds=60), "click")
        scripts = [c[2] for c in calls if c[0] == "osascript"]
        self.assertEqual(len(scripts), 3)
        self.assertIn('click button "Cancel"', scripts[0])
        self.assertIn("click menu item", scripts[1])
        self.assertIn('click button "Don\u2019t Save"', scripts[2])
        self.assertIn('click button "Don\'t Save"', scripts[2])

    def test_quit_step_names_the_presses(self):
        def run(cmd, timeout=60):
            if cmd[0] == "kill":
                return (1, "") if run.dead else (0, "")
            if "Don't Save" in cmd[2]:
                run.dead = True
            return 0, "1"
        run.dead = False
        with mock.patch.object(vw_memory, "run", side_effect=run), mock.patch.object(vw_memory.time, "sleep"):
            self.assertEqual(vw_memory.quit_app("100", seconds=60), "cancel+click+dont-save")

    def test_press_in_windows_counts_presses(self):
        with mock.patch.object(vw_memory, "run", return_value=(0, "2\n")):
            self.assertEqual(vw_memory.press_in_windows("Cancel"), 2)
        with mock.patch.object(vw_memory, "run", return_value=(1, "execution error")):
            self.assertEqual(vw_memory.press_in_windows("Cancel"), 0)

    def test_small_source_keeps_the_process(self):
        small = os.path.join(self.tmp.name, "small.vwx")
        Path(small).write_bytes(b"x" * 1024)
        with mock.patch.object(vw_memory, "restart") as restart:
            self.assertEqual(vw_memory.after_source(small), "100")
        restart.assert_not_called()

    def test_large_source_restarts(self):
        large = os.path.join(self.tmp.name, "large.vwx")
        Path(large).write_bytes(b"x" * 2048)
        with mock.patch.object(vw_memory, "LARGE_SOURCE_MB", 0), \
                mock.patch.object(vw_memory, "restart", return_value="200") as restart:
            self.assertEqual(vw_memory.after_source(large), "200")
        self.assertIn("large source large.vwx", restart.call_args[0][0])


spec = importlib.util.spec_from_file_location("sweep_ui", ROOT / "driver/ui/sweep-ui.py")
sweep_ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep_ui)


class NoDesktop(unittest.TestCase):
    """A sweep test fails when it reaches osascript or the vwx ui commands.

    A suite that runs during a batch otherwise reads and moves the front application of the batch."""

    def setUp(self):
        reached = AssertionError("the test reached the desktop")
        for p in (mock.patch.object(sweep_ui, "cli", side_effect=reached),
                  mock.patch.object(sweep_ui, "osa", side_effect=reached),
                  mock.patch.object(sweep_ui.focus, "osa", side_effect=reached),
                  mock.patch.object(sweep_ui.pause, "PAUSE", os.path.join(tempfile.mkdtemp(), "pause"))):
            p.start()
            self.addCleanup(p.stop)


class Sweep(NoDesktop):
    def run_sweep(self, before_row, pairs, sources):
        after_source = mock.Mock(return_value=None)
        with tempfile.TemporaryDirectory() as run_dir:
            os.makedirs(os.path.join(run_dir, "records"))
            with mock.patch.object(sweep_ui, "live_pid", return_value="100"), \
                    mock.patch.object(sweep_ui, "collect_row", return_value=({"status": "ok"}, True)), \
                    mock.patch.object(sweep_ui, "sha", return_value=""), \
                    mock.patch.object(sweep_ui, "dismiss_modals"), \
                    mock.patch.object(sweep_ui, "close_extra_documents"), \
                    mock.patch.object(sweep_ui, "clear_documents", return_value=None), \
                    mock.patch.object(sweep_ui, "hold_front"), \
                    mock.patch.object(sweep_ui, "switch_workspace") as switch, \
                    mock.patch.object(sweep_ui.vw_memory, "before_row", side_effect=before_row), \
                    mock.patch.object(sweep_ui.vw_memory, "after_source", after_source), \
                    mock.patch.object(sweep_ui.vw_memory, "end_of_batch"), \
                    mock.patch("sys.stdout"):
                sweep_ui.sweep(types.SimpleNamespace(format="gltf"), pairs, sources, "run", run_dir, [])
        return switch, after_source

    def test_restart_presses_the_workspace_again(self):
        switch, _after = self.run_sweep(["100", "200", "200"], [("a", "p1"), ("b", "p1"), ("c", "p1")],
                                        {"a": "a.vwx", "b": "b.vwx", "c": "c.vwx"})
        self.assertEqual(switch.call_args_list, [mock.call("Rosetta glTF", mock.ANY)])

    def test_after_source_runs_once_per_source(self):
        _switch, after = self.run_sweep(["100"] * 3, [("a", "p1"), ("a", "p2"), ("b", "p1")],
                                        {"a": "a.vwx", "b": "b.vwx"})
        self.assertEqual([c.args[0] for c in after.call_args_list], ["a.vwx", "b.vwx"])

    def run_failed_pair(self, rows, vw_pid):
        with tempfile.TemporaryDirectory() as run_dir:
            os.makedirs(os.path.join(run_dir, "records"))
            with mock.patch.object(sweep_ui, "live_pid", return_value="100"), \
                    mock.patch.object(sweep_ui, "collect_row", side_effect=rows) as collect, \
                    mock.patch.object(sweep_ui, "sha", return_value=""), \
                    mock.patch.object(sweep_ui, "dismiss_modals"), \
                    mock.patch.object(sweep_ui, "close_extra_documents"), \
                    mock.patch.object(sweep_ui, "clear_documents", return_value=None), \
                    mock.patch.object(sweep_ui, "hold_front"), \
                    mock.patch.object(sweep_ui, "switch_workspace"), \
                    mock.patch.object(sweep_ui.vw_memory, "live_pid", return_value=vw_pid), \
                    mock.patch.object(sweep_ui.vw_memory, "restart", return_value="200") as restart, \
                    mock.patch.object(sweep_ui.vw_memory, "before_row", return_value=None), \
                    mock.patch.object(sweep_ui.vw_memory, "after_source", return_value=None), \
                    mock.patch.object(sweep_ui.vw_memory, "end_of_batch"), \
                    mock.patch("sys.stdout"):
                sweep_ui.sweep(types.SimpleNamespace(format="gltf"), [("a", "p1"), ("b", "p1")],
                               {"a": "a.vwx", "b": "b.vwx"}, "run", run_dir, [])
            with open(os.path.join(run_dir, "records", "a.p1.json")) as f:
                return collect, restart, sweep_ui.json.load(f)

    def test_gone_process_restarts_and_retries_the_pair_once(self):
        rows = [({"status": "exception"}, False), ({"status": "ok"}, True), ({"status": "ok"}, True)]
        collect, restart, record = self.run_failed_pair(rows, None)
        self.assertEqual(collect.call_count, 3)
        self.assertEqual(restart.call_args[0][0], "gone after a p1")
        self.assertEqual(record["status"], "ok")
        self.assertEqual(record["first_try"], "exception, Vectorworks gone, restarted")

    def test_failed_pair_with_a_live_process_runs_once(self):
        collect, restart, record = self.run_failed_pair([({"status": "exception"}, False), ({"status": "ok"}, True)], "100")
        self.assertEqual(collect.call_count, 2)
        restart.assert_not_called()
        self.assertNotIn("first_try", record)

    def test_paused_pair_runs_once_and_ends_the_sweep(self):
        paused = sweep_ui.pause.Paused("paused until 04:00Z")
        collect, restart, record = self.run_failed_pair([paused, ({"status": "ok"}, True)], None)
        self.assertEqual(collect.call_count, 1)
        restart.assert_not_called()
        self.assertEqual(record["status"], "paused")

    def test_gone_process_restart_logs_swap_and_passes_the_cli(self):
        with mock.patch.object(pause, "PAUSE", os.path.join(tempfile.gettempdir(), "rosetta-pause-absent")), \
                mock.patch.object(vw_memory, "live_pid", side_effect=[None, "200"]), \
                mock.patch.object(vw_memory, "measure", return_value=(3300, (100, 3072))), \
                mock.patch.object(vw_memory, "write_log") as write_log, \
                mock.patch.object(vw_memory, "run", return_value=(0, "vm.swapusage: total = 3072.00M  used = 2304.00M")) as run:
            self.assertEqual(vw_memory.restart("gone after a p1"), "200")
        row = write_log.call_args[0][0]
        self.assertEqual((row["quit"], row["swap_used_mb"], row["swap_total_mb"]), ("gone", 2304, 3072))
        self.assertEqual(run.call_args[0][0], ["sh", vw_memory.LAUNCH])
        self.assertEqual(run.call_args[1]["env"]["VWX_CLI"], vw_memory.CLI)


class ClearDocuments(NoDesktop):
    def clear(self, titles, modal="false"):
        log = []
        with mock.patch.object(sweep_ui, "live_pid", return_value="100"), \
                mock.patch.object(sweep_ui, "dismiss_modals") as dismiss, \
                mock.patch.object(sweep_ui, "close_extra_documents") as close, \
                mock.patch.object(sweep_ui, "title", side_effect=titles), \
                mock.patch.object(sweep_ui, "modal_state", return_value=("", modal)), \
                mock.patch.object(sweep_ui.vw_memory, "restart", return_value="200") as restart:
            pid = sweep_ui.clear_documents(log)
        self.assertEqual(dismiss.call_args, mock.call("100", "row-start", log, cancel_save=True))
        close.assert_called_once_with("100", None, log)
        return pid, restart

    def test_no_document_left_keeps_vectorworks(self):
        pid, restart = self.clear([""])
        self.assertIsNone(pid)
        restart.assert_not_called()

    def test_a_document_left_open_restarts_before_the_row(self):
        pid, restart = self.clear(["building.door.free.vwx"])
        self.assertEqual(pid, "200")
        self.assertEqual(restart.call_args[0][0], "open before the row: building.door.free.vwx")

    def test_a_modal_left_up_restarts_before_the_row(self):
        pid, restart = self.clear([""], modal="true")
        self.assertEqual(pid, "200")
        self.assertEqual(restart.call_args[0][0], "open before the row: a modal")


class RowStart(NoDesktop):
    def test_a_restart_for_a_document_left_open_comes_before_the_row(self):
        order = []
        with mock.patch.object(sweep_ui, "live_pid", return_value="200"), \
                mock.patch.object(sweep_ui.vw_memory, "before_row", return_value=None), \
                mock.patch.object(sweep_ui, "clear_documents", side_effect=lambda log: order.append("clear") or "200"), \
                mock.patch.object(sweep_ui, "hold_front"), \
                mock.patch.object(sweep_ui, "switch_workspace") as switch, \
                mock.patch.object(sweep_ui, "sha", return_value=""), \
                mock.patch.object(sweep_ui, "dismiss_modals"), \
                mock.patch.object(sweep_ui, "close_extra_documents"), \
                mock.patch.object(sweep_ui, "collect_row",
                                  side_effect=lambda *a: order.append("row") or ({"status": "ok"}, True)):
            pid, _row, ok = sweep_ui.export_pair(types.SimpleNamespace(format="dxf"), "a", "p1", "a.vwx", "run",
                                                 [], "100", "Rosetta DXF")
        self.assertEqual((pid, ok, order), ("200", True, ["clear", "row"]))
        switch.assert_called_once_with("Rosetta DXF", [])


class PauseBetweenPairs(NoDesktop):
    def test_a_pause_stops_the_sweep_before_the_next_pair_opens(self):
        def collect(*a):
            Path(sweep_ui.pause.PAUSE).write_text("2099-01-01T00:00:00Z\n")
            return {"status": "ok"}, True

        with tempfile.TemporaryDirectory() as run_dir:
            os.makedirs(os.path.join(run_dir, "records"))
            with mock.patch.object(sweep_ui, "live_pid", return_value="100"), \
                    mock.patch.object(sweep_ui, "collect_row", side_effect=collect) as rows, \
                    mock.patch.object(sweep_ui, "sha", return_value=""), \
                    mock.patch.object(sweep_ui, "dismiss_modals"), \
                    mock.patch.object(sweep_ui, "close_extra_documents"), \
                    mock.patch.object(sweep_ui, "clear_documents", return_value=None), \
                    mock.patch.object(sweep_ui, "hold_front"), \
                    mock.patch.object(sweep_ui, "switch_workspace"), \
                    mock.patch.object(sweep_ui.vw_memory, "before_row", return_value=None) as before_row, \
                    mock.patch.object(sweep_ui.vw_memory, "after_source", return_value=None), \
                    mock.patch.object(sweep_ui.vw_memory, "end_of_batch"), \
                    mock.patch("sys.stdout"):
                sweep_ui.sweep(types.SimpleNamespace(format="dxf"), [("a", "p1"), ("b", "p1"), ("c", "p1")],
                               {"a": "a.vwx", "b": "b.vwx", "c": "c.vwx"}, "run", run_dir, [])
            records = sorted(os.listdir(os.path.join(run_dir, "records")))
            with open(os.path.join(run_dir, "records", "b.p1.json")) as f:
                status = sweep_ui.json.load(f)["status"]
        self.assertEqual((rows.call_count, before_row.call_count), (1, 1))
        self.assertEqual((records, status), (["a.p1.json", "b.p1.json", "run.json"], "paused"))


class SaveChangesPrompt(NoDesktop):
    def test_the_prompt_gets_dont_save(self):
        prompt = "Do you want to save the changes you made in the document building.door.free.vwx?"
        states = iter([(prompt, "true"), ("", "false")])
        buttons = ("Save", "Don't Save", "Cancel")
        with mock.patch.object(sweep_ui, "modal_state", side_effect=lambda pid_: next(states)), \
                mock.patch.object(sweep_ui, "is_replace_prompt", return_value=False), \
                mock.patch.object(sweep_ui, "is_save_panel", return_value=False), \
                mock.patch.object(sweep_ui, "title", return_value=""), \
                mock.patch.object(sweep_ui, "note"), \
                mock.patch.object(sweep_ui.time, "sleep"), \
                mock.patch.object(sweep_ui, "press_label",
                                  side_effect=lambda pid_, txt, label: (label in buttons, "")) as press:
            log = []
            sweep_ui.dismiss_modals("100", "end-of-row", log)
        self.assertEqual([c[0][2] for c in press.call_args_list], ["OK", "Don't Save"])
        self.assertEqual(log[0]["action"], "pressed Don't Save")


class RowCheck(NoDesktop):
    """The real before_row() runs. measure() and restart() are mocked, so no Vectorworks runs."""

    def setUp(self):
        super().setUp()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        patches = [mock.patch.object(vw_memory, "LOG", os.path.join(self.tmp.name, "vw-memory.tsv")),
                   mock.patch.object(pause, "PAUSE", os.path.join(self.tmp.name, "rosetta-pause")),
                   mock.patch.object(vw_memory, "FOOTPRINT_LIMIT_MB", 6144),
                   mock.patch.object(vw_memory, "live_pid", return_value="100"),
                   mock.patch.object(vw_memory, "run", side_effect=AssertionError("no process may start"))]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def sweep_one_row(self, footprint_mb):
        with tempfile.TemporaryDirectory() as run_dir:
            os.makedirs(os.path.join(run_dir, "records"))
            with mock.patch.object(sweep_ui, "live_pid", return_value="100"), \
                    mock.patch.object(sweep_ui, "collect_row", return_value=({"status": "ok"}, True)), \
                    mock.patch.object(sweep_ui, "sha", return_value=""), \
                    mock.patch.object(sweep_ui, "dismiss_modals"), \
                    mock.patch.object(sweep_ui, "close_extra_documents"), \
                    mock.patch.object(sweep_ui, "clear_documents", return_value=None), \
                    mock.patch.object(sweep_ui, "hold_front"), \
                    mock.patch.object(sweep_ui, "switch_workspace") as switch, \
                    mock.patch.object(vw_memory, "measure", return_value=(footprint_mb, (1000, 3072))), \
                    mock.patch.object(vw_memory, "restart", return_value="200") as restart, \
                    mock.patch.object(vw_memory, "after_source", return_value=None), \
                    mock.patch.object(vw_memory, "end_of_batch"), \
                    mock.patch("sys.stdout"):
                sweep_ui.sweep(types.SimpleNamespace(format="gltf"), [("a", "p1")], {"a": "a.vwx"}, "run", run_dir, [])
        return restart, switch

    def test_sweep_row_at_6145_mb_restarts_and_presses_the_workspace(self):
        restart, switch = self.sweep_one_row(6145)
        self.assertEqual(restart.call_args[0][0], "footprint 6145 MB > 6144 MB")
        self.assertEqual(switch.call_args_list, [mock.call("Rosetta glTF", mock.ANY)])

    def test_sweep_row_at_6144_mb_keeps_the_process(self):
        restart, switch = self.sweep_one_row(6144)
        restart.assert_not_called()
        switch.assert_not_called()

    def make_sources_two_cases(self, footprint_mb):
        spec = importlib.util.spec_from_file_location("make_sources", ROOT / "driver/ui/make-sources.py")
        make_sources = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(make_sources)
        with tempfile.TemporaryDirectory() as out:
            argv = ["make-sources.py", "--cases", "a,b", "--out-dir", out, "--programs-dir", out]
            with mock.patch.object(make_sources, "run_case", return_value={"status": "ok"}), \
                    mock.patch.object(make_sources.vw_lock, "LOCK", os.path.join(self.tmp.name, "lock")), \
                    mock.patch.object(make_sources.run_provenance, "require",
                                      return_value={"commit": "c", "branch": "b"}), \
                    mock.patch.object(vw_memory, "measure", return_value=(footprint_mb, (1000, 3072))), \
                    mock.patch.object(vw_memory, "restart", return_value="200") as restart, \
                    mock.patch.object(vw_memory, "end_of_batch"), \
                    mock.patch.object(sys, "argv", argv), \
                    mock.patch("sys.stdout"):
                self.assertEqual(make_sources.main(), 0)
        return restart

    def test_make_sources_case_at_6145_mb_restarts_with_the_document_close(self):
        restart = self.make_sources_two_cases(6145)
        self.assertEqual([c.args[0] for c in restart.call_args_list], ["footprint 6145 MB > 6144 MB"] * 2)
        self.assertEqual(restart.call_args.args[2].func.__name__, "close_document")

    def test_make_sources_case_at_6144_mb_keeps_the_process(self):
        self.make_sources_two_cases(6144).assert_not_called()


if __name__ == "__main__":
    unittest.main()
