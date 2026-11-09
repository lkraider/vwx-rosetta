#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("sweep_ui", ROOT / "driver/ui/sweep-ui.py")
sweep_ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep_ui)

WINDOWS = 'Exporting "landscape.plant.single.vwx", spatial.light.point.vwx'


class ExportWindow(unittest.TestCase):
    def test_window_of_the_document_counts(self):
        self.assertTrue(sweep_ui.exporting(WINDOWS, "landscape.plant.single.vwx"))

    def test_window_of_another_document_does_not_count(self):
        self.assertFalse(sweep_ui.exporting(WINDOWS, "spatial.light.point.vwx"))


class DestinationFolder(unittest.TestCase):
    def test_dxf_folder_takes_the_document_stem(self):
        spec = {"navigate": "parent", "ext": "dxf"}
        self.assertEqual(sweep_ui.destination_folder("plan-f2 v2027.vwx", spec),
                         os.path.join(sweep_ui.PANEL, "plan-f2 v2027-dxf"))

    def test_other_exporters_write_into_the_panel_folder(self):
        self.assertEqual(sweep_ui.destination_folder("plan.vwx", {"ext": "obj"}), sweep_ui.PANEL)


class WaitForFile(unittest.TestCase):
    def wait(self, finds, windows, refused=False):
        finds, windows = iter(finds), iter(windows)
        with mock.patch.object(sweep_ui.time, "sleep"), \
                mock.patch.object(sweep_ui, "wait_state", lambda _label, check, **_kw: check()):
            return sweep_ui.wait_for_file(lambda: next(finds), lambda: next(windows), lambda: refused)

    def test_late_file_with_no_window_is_found(self):
        self.assertEqual(self.wait([None] * 5 + ["out.dxf"], [False] * 5), "out.dxf")

    def test_closed_window_ends_the_wait(self):
        self.assertIsNone(self.wait([None, None, None], [True, False]))

    def test_refused_save_ends_the_wait(self):
        self.assertIsNone(self.wait([None], [False], refused=True))

    def test_no_file_and_no_window_ends_at_the_limit(self):
        clock = iter(range(0, 1000, 100))
        with mock.patch.object(sweep_ui.time, "time", lambda: next(clock)):
            self.assertIsNone(self.wait([None] * 10, [False] * 10))


class Settled(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "out.dwg")
        Path(self.path).write_bytes(b"part")

    def tearDown(self):
        self.tmp.cleanup()

    def test_file_that_holds_still_under_the_window_waits_for_the_window(self):
        states = [True] * 5
        calls = []

        def running():
            calls.append(None)
            return bool(states) and states.pop()

        with mock.patch.object(sweep_ui.time, "sleep"), \
                mock.patch.object(sweep_ui.time, "time", side_effect=range(1000)):
            self.assertTrue(sweep_ui.settled(self.path, running))
        self.assertEqual(len(calls), 7)

    def test_window_that_stays_up_ends_in_false(self):
        with mock.patch.object(sweep_ui.time, "sleep"), \
                mock.patch.object(sweep_ui.time, "time", side_effect=range(1000)):
            self.assertFalse(sweep_ui.settled(self.path, lambda: True, limit=10))


class FailureOnStderr(unittest.TestCase):
    def test_each_failed_pair_and_the_exit_go_to_stderr(self):
        rows = {"a": ({"status": "ok"}, True),
                "b": ({"status": "no file produced", "observed_title": "Export to DXF Folder",
                       "dialogs": [{"where": "after-save", "text": "Favorites Applications"}]}, False)}

        def export_pair(args, case, profile, src, run_id, log, pid, workspace):
            row, ok = rows[case]
            return pid, dict(row, case=case, profile=profile), ok

        args = mock.Mock(format="dxf")
        err = io.StringIO()
        with tempfile.TemporaryDirectory() as run_dir, \
                mock.patch.object(sweep_ui, "export_pair", export_pair), \
                mock.patch.object(sweep_ui, "live_pid", return_value="1"), \
                mock.patch.object(sweep_ui, "hold_front"), \
                mock.patch.object(sweep_ui, "memory_step", return_value="1"), \
                mock.patch.object(sweep_ui, "keep_workspace", return_value="1"), \
                mock.patch.object(sweep_ui.vw_memory, "live_pid", return_value="1"), \
                contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            os.mkdir(os.path.join(run_dir, "records"))
            code = sweep_ui.sweep(args, [("a", "p"), ("b", "p"), ("c", "p")], {"a": "/s/a", "b": "/s/b"},
                                  "r1", run_dir, [])
        self.assertEqual(code, 1)
        self.assertEqual(err.getvalue().splitlines(), [
            "sweep-ui: b p: no file produced; observed_title Export to DXF Folder; "
            "last dialog after-save: Favorites Applications",
            "sweep-ui: c p: no source document",
            "sweep-ui: exit 1, 2 of 3 pairs failed"])



class PairLineFlushed(unittest.TestCase):
    def test_each_pair_line_is_flushed_before_the_next_pair(self):
        class Pipe(io.StringIO):
            flushed = ""

            def flush(self):
                self.flushed = self.getvalue()

        out = Pipe()
        seen = []

        def export_pair(args, case, profile, src, run_id, log, pid, workspace):
            seen.append([line for line in out.flushed.splitlines() if '"case"' in line])
            return pid, {"case": case, "profile": profile, "status": "ok"}, True

        args = mock.Mock(format="dxf")
        with tempfile.TemporaryDirectory() as run_dir, \
                mock.patch.object(sweep_ui, "export_pair", export_pair), \
                mock.patch.object(sweep_ui, "live_pid", return_value="1"), \
                mock.patch.object(sweep_ui, "hold_front"), \
                mock.patch.object(sweep_ui, "memory_step", return_value="1"), \
                mock.patch.object(sweep_ui, "keep_workspace", return_value="1"), \
                contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(out):
            os.mkdir(os.path.join(run_dir, "records"))
            sweep_ui.sweep(args, [("a", "p"), ("b", "p"), ("c", "p")], {"a": "/s/a", "b": "/s/b", "c": "/s/c"},
                           "r1", run_dir, [])
        self.assertEqual([len(lines) for lines in seen], [0, 1, 2])

class DocumentUp(unittest.TestCase):
    def up(self, window, modal=("", "false")):
        log = []
        with mock.patch.object(sweep_ui, "title", return_value=window), \
                mock.patch.object(sweep_ui, "modal_state", return_value=modal), \
                mock.patch.object(sweep_ui, "press_label", return_value=(True, "")) as press:
            got = sweep_ui.document_up(1, "plan-tilt-r4", log)
        return got, log, press

    def test_plain_and_converted_titles_count(self):
        self.assertEqual(self.up("plan-tilt-r4.vwx")[0], "plan-tilt-r4.vwx")
        self.assertEqual(self.up("plan-tilt-r4 v2027.vwx")[0], "plan-tilt-r4 v2027.vwx")

    def test_conversion_alert_gets_ok(self):
        text = sweep_ui.CONVERSION_TEXT + " It will be converted and opened with the new name:"
        got, log, press = self.up("Vectorworks", (text, "true"))
        self.assertIsNone(got)
        press.assert_called_once_with(1, text, "OK")
        self.assertEqual(log[0]["action"], "pressed OK")

    def test_opening_progress_window_gets_no_answer(self):
        got, log, press = self.up("Vectorworks", ("Opening File: plan-tilt-r4.vwx", "true"))
        self.assertIsNone(got)
        press.assert_not_called()
        self.assertEqual(log, [])


if __name__ == "__main__":
    unittest.main()
