#!/usr/bin/env python3
import datetime
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
import pause  # noqa: E402


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


sweep_ui = load("sweep_ui", "driver/ui/sweep-ui.py")
make_sources = load("make_sources", "driver/ui/make-sources.py")
source_census = load("source_census", "driver/ui/source-census.py")
NOW = datetime.datetime(2026, 10, 18, 22, 0, tzinfo=datetime.timezone.utc)


class PausedUntil(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "rosetta-pause")

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, text):
        Path(self.path).write_text(text)

    def test_missing_file_holds_no_pause(self):
        self.assertIsNone(pause.paused_until(self.path, NOW))

    def test_future_end_holds(self):
        self.write("2026-10-18T23:00:00Z\n")
        self.assertEqual(pause.paused_until(self.path, NOW), "2026-10-18T23:00:00Z")

    def stamp(self, utc):
        t = datetime.datetime.fromisoformat(utc).timestamp()
        os.utime(self.path, (t, t))

    def test_past_end_holds_no_pause(self):
        self.write("2026-10-18T21:00:00Z\n")
        self.stamp("2026-10-18T20:00:00+00:00")
        self.assertIsNone(pause.paused_until(self.path, NOW))

    def test_a_touch_after_the_past_end_holds(self):
        self.write("2026-10-18T21:00:00Z\n")
        self.stamp("2026-10-18T21:30:00+00:00")
        self.assertEqual(pause.paused_until(self.path, NOW), "2026-10-18T21:00:00Z, touched at 2026-10-18T21:30:00Z")

    def test_the_write_of_the_past_end_itself_holds_no_pause(self):
        self.write("2026-10-18T21:00:00Z\n")
        self.stamp("2026-10-18T21:00:01+00:00")
        self.assertIsNone(pause.paused_until(self.path, NOW))

    def test_unreadable_time_holds(self):
        self.write("tomorrow\n")
        self.assertEqual(pause.paused_until(self.path, NOW), "tomorrow")

    def test_undecodable_file_holds(self):
        Path(self.path).write_bytes(b"\xff\xfe\x00")
        self.assertEqual(pause.paused_until(self.path, NOW), "unreadable")

    def test_directory_holds(self):
        os.mkdir(self.path)
        self.assertEqual(pause.paused_until(self.path, NOW), "unreadable")

    def test_cli_exit_code(self):
        self.write("2999-01-01T00:00:00Z\n")
        env = dict(os.environ, ROSETTA_PAUSE=self.path)
        run = subprocess.run([sys.executable, str(ROOT / "driver/pause.py"), "--active"],
                             env=env, capture_output=True, text=True)
        self.assertEqual((run.returncode, run.stdout.strip()), (0, "2999-01-01T00:00:00Z"))
        os.unlink(self.path)
        run = subprocess.run([sys.executable, str(ROOT / "driver/pause.py"), "--active"],
                             env=env, capture_output=True, text=True)
        self.assertEqual(run.returncode, 1)


class FocusSteps(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(pause, "paused_until", return_value="2999-01-01T00:00:00Z")
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_in_front_sends_nothing_while_paused(self):
        with mock.patch.object(sweep_ui.focus, "osa") as osa:
            with self.assertRaises(pause.Paused):
                with sweep_ui.focus.in_front("test", 100):
                    pass
        osa.assert_not_called()

    def test_front_keys_sends_nothing_while_paused(self):
        with mock.patch.object(make_sources, "osa") as osa:
            with self.assertRaises(pause.Paused):
                make_sources.front_keys("key code 36")
        osa.assert_not_called()

    def test_census_opens_nothing_while_paused(self):
        with tempfile.TemporaryDirectory() as tmp:
            doc = os.path.join(tmp, "doc.vwx")
            Path(doc).write_bytes(b"x")
            with mock.patch.object(make_sources, "close_document", return_value=True), \
                    mock.patch.object(source_census.subprocess, "run") as run:
                status = source_census.census(make_sources, "1", "doc", doc, tmp, [])
        self.assertEqual(status, "paused")
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
