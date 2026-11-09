#!/usr/bin/env python3
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("sweep_ui", ROOT / "driver/ui/sweep-ui.py")
sweep_ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep_ui)


class Clock:
    """time.time and time.sleep for the module, where a sleep moves the clock."""

    def __init__(self):
        self.now = 100.0
        self.sleeps = []

    def time(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


class WaitState(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.log = os.path.join(self.tmp.name, "dialog-log-sweep.tsv")
        self.clock = Clock()
        for patch in (mock.patch.object(sweep_ui, "DIALOG_LOG", self.log),
                      mock.patch.dict(sweep_ui.CURRENT, {"run_id": "r1", "case": "c1", "profile": "p1"}),
                      mock.patch.object(sweep_ui.time, "time", self.clock.time),
                      mock.patch.object(sweep_ui.time, "sleep", self.clock.sleep)):
            patch.start()
            self.addCleanup(patch.stop)

    def tearDown(self):
        self.tmp.cleanup()

    def rows(self):
        return [line.rstrip("\n").split("\t") for line in Path(self.log).read_text().splitlines()]

    def test_state_ends_the_wait_and_returns_the_value(self):
        answers = iter([None, None, "found"])
        got = sweep_ui.wait_state("panel", lambda: next(answers), timeout=2.0)
        self.assertEqual(got, "found")
        self.assertEqual(self.clock.sleeps, [0.25, 0.25])
        self.assertEqual(self.rows()[0][4:], ["wait panel", "state", "0.50 s of 2.0 s"])

    def test_timeout_returns_none_after_the_timeout(self):
        got = sweep_ui.wait_state("panel", lambda: False, timeout=1.0, interval=0.4)
        self.assertIsNone(got)
        self.assertEqual([round(s, 6) for s in self.clock.sleeps], [0.4, 0.4, 0.2])
        self.assertEqual(self.rows()[0][4:], ["wait panel", "timeout", "1.00 s of 1.0 s"])

    def test_minimum_runs_before_the_first_check(self):
        checked_at = []

        def check():
            checked_at.append(self.clock.now)
            return True

        sweep_ui.wait_state("redraw", check, timeout=1.0, minimum=0.5)
        self.assertEqual(checked_at, [100.5])
        self.assertEqual(self.clock.sleeps, [0.5])
        self.assertEqual(self.rows()[0][5:], ["state", "0.50 s of 1.0 s"])

    def test_log_row_names_the_run_case_and_profile(self):
        sweep_ui.wait_state("ifc add enabled", lambda: True, timeout=0.5)
        row = self.rows()[0]
        self.assertEqual(row[1:5], ["r1", "c1", "p1", "wait ifc add enabled"])
        self.assertEqual(len(row), 7)

    def test_each_wait_writes_one_row(self):
        sweep_ui.wait_state("a", lambda: True, timeout=0.5)
        sweep_ui.wait_state("b", lambda: False, timeout=0.5)
        self.assertEqual([r[4:6] for r in self.rows()], [["wait a", "state"], ["wait b", "timeout"]])


class SetPopupRead(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        for patch in (mock.patch.object(sweep_ui, "note", lambda fields: None),
                      mock.patch.object(sweep_ui.time, "time", self.clock.time),
                      mock.patch.object(sweep_ui.time, "sleep", self.clock.sleep)):
            patch.start()
            self.addCleanup(patch.stop)

    def test_read_during_the_redraw_is_read_again(self):
        reports = iter(["control\tnot found\n", "value\tDXF 2018\n"])
        with mock.patch.object(sweep_ui, "cli", lambda *a, **k: (0, next(reports))):
            ok, why = sweep_ui.set_popup("1", "Export", "format", "DXF 2018")
        self.assertEqual((ok, why), (True, "already DXF 2018"))
        self.assertEqual(self.clock.sleeps, [1.0])

    def test_empty_value_counts_as_a_read(self):
        with mock.patch.object(sweep_ui, "cli", lambda *a, **k: (0, "value\t\n")):
            ok, why = sweep_ui.set_popup("1", "Export", "format", "")
        self.assertEqual((ok, why), (True, "already "))

    def test_no_value_after_the_timeout_fails_with_the_reasons(self):
        with mock.patch.object(sweep_ui, "cli", return_value=(0, "refused\tno window\n")) as cli:
            ok, why = sweep_ui.set_popup("1", "Export", "format", "DXF 2018")
        self.assertEqual(cli.call_count, 3)
        self.assertFalse(ok)
        self.assertEqual(why, "no value in the control report: refused\tno window")
        self.assertEqual(self.clock.sleeps, [1.0, 1.0])


if __name__ == "__main__":
    unittest.main()
