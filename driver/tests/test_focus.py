import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import focus  # noqa: E402
import pause  # noqa: E402


class Desktop:
    """A front application that the osascript calls of focus read and set."""

    def __init__(self, front, take=True):
        self.front = front
        self.take = take
        self.names = {"100": "Vectorworks", "200": "Mail", "300": "Finder"}
        self.scripts = []

    def osa(self, script, timeout=20):
        self.scripts.append(script)
        if "frontmost is true" in script:
            return 0, "%s\t%s\n" % (self.front, self.names[self.front])
        pid = script.split("unix id is ")[1].split(")")[0]
        if pid != "100" or self.take:
            self.front = pid
        return 0, ""


class Focus(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.log = os.path.join(self.tmp.name, "activations.tsv")
        for p in (mock.patch.object(focus, "LOG", self.log),
                  mock.patch.object(pause, "PAUSE", os.path.join(self.tmp.name, "no-pause")),
                  mock.patch.object(focus.time, "sleep")):
            p.start()
            self.addCleanup(p.stop)
        focus.CONTEXT.update(run_id="r1", case="c1", profile="p1")

    def rows(self):
        return [line.split("\t") for line in Path(self.log).read_text().splitlines()[1:]]

    def test_in_front_gives_the_front_back_and_logs_the_step(self):
        desk = Desktop("200")
        with mock.patch.object(focus, "osa", desk.osa):
            with focus.in_front("save-go-to-folder", 100):
                self.assertEqual(desk.front, "100")
        self.assertEqual(desk.front, "200")
        row = self.rows()[0]
        self.assertEqual(row[1:7], ["save-go-to-folder", "r1", "c1", "p1", "activate", "Mail"])
        self.assertEqual(row[8], "given back")

    def test_in_front_keeps_a_window_the_person_chose_meanwhile(self):
        desk = Desktop("200")
        with mock.patch.object(focus, "osa", desk.osa):
            with focus.in_front("ifc-layer-click", 100):
                desk.front = "300"
        self.assertEqual(desk.front, "300")
        self.assertEqual(self.rows()[0][8], "kept")

    def test_front_lost_is_logged_and_raised(self):
        desk = Desktop("200", take=False)
        with mock.patch.object(focus, "osa", desk.osa):
            with self.assertRaises(focus.FrontLost):
                with focus.in_front("run-script-go-to-folder", 100):
                    self.fail("the block ran without the front")
        self.assertEqual(self.rows()[0][5], "front-lost")

    def test_give_back_after_vectorworks_took_the_front(self):
        desk = Desktop("100")
        with mock.patch.object(focus, "osa", desk.osa):
            self.assertTrue(focus.give_back("open", 100, ("200", "Mail")))
        self.assertEqual(desk.front, "200")
        self.assertEqual(self.rows()[0][5], "self-activated")

    def test_give_back_does_nothing_while_another_app_is_in_front(self):
        desk = Desktop("300")
        with mock.patch.object(focus, "osa", desk.osa):
            self.assertFalse(focus.give_back("open", 100, ("200", "Mail")))
        self.assertFalse(os.path.exists(self.log))

    def test_per_hour_counts_step_and_kind(self):
        desk = Desktop("200")
        with mock.patch.object(focus, "osa", desk.osa):
            for _ in range(3):
                with focus.in_front("save-go-to-folder", 100):
                    pass
        counts = focus.per_hour(self.log)
        self.assertEqual(list(counts.values()), [3])
        self.assertEqual(list(counts)[0][1:], ("save-go-to-folder", "activate"))


class HoldFront(unittest.TestCase):
    def setUp(self):
        import importlib.util
        root = Path(__file__).resolve().parents[2]
        spec = importlib.util.spec_from_file_location("sweep_ui_focus", root / "driver/ui/sweep-ui.py")
        self.sweep_ui = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.sweep_ui)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.log = os.path.join(tmp.name, "activations.tsv")
        for p in (mock.patch.object(focus, "LOG", self.log),
                  mock.patch.object(self.sweep_ui, "live_pid", return_value="100")):
            p.start()
            self.addCleanup(p.stop)

    def test_front_taken_before_the_row_goes_back_to_the_last_other_app(self):
        desk = Desktop("200")
        with mock.patch.object(self.sweep_ui.focus, "osa", desk.osa):
            self.assertFalse(self.sweep_ui.hold_front("sweep-start"))
            desk.front = "100"
            self.assertTrue(self.sweep_ui.hold_front("memory-restart"))
            self.assertEqual(desk.front, "200")
            desk.front = "100"
            self.assertTrue(self.sweep_ui.hold_front("start"))
        self.assertEqual(desk.front, "200")
        steps = [line.split("\t")[1] for line in Path(self.log).read_text().splitlines()[1:]]
        self.assertEqual(steps, ["memory-restart", "start"])



class BackgroundFirst(HoldFront):
    def try_save(self, sheets, where):
        ui = self.sweep_ui
        keys = []
        for p in (mock.patch.object(ui, "sheet_open", side_effect=sheets),
                  mock.patch.object(ui, "save_if_panel_in", return_value=where),
                  mock.patch.object(ui, "post_key", lambda *a, **k: keys.append(a)),
                  mock.patch.object(ui.time, "sleep")):
            p.start()
            self.addCleanup(p.stop)
        return ui.save_to_folder_by_pid("/p", "100"), keys

    def test_no_sheet_means_no_typed_keys(self):
        result, keys = self.try_save([False] * 7, "pressed")
        self.assertEqual(result, "Cmd+Shift+G opened no sheet")
        self.assertEqual(len(keys), 1)

    def test_save_is_pressed_only_in_the_folder(self):
        self.assertEqual(self.try_save([False, True, False], "pressed")[0], "pressed")
        self.assertEqual(self.try_save([False, True, False], "elsewhere")[0], "elsewhere")

    def test_sheet_that_stays_open_fails_the_try(self):
        result, keys = self.try_save([False, True] + [True] * 6, "pressed")
        self.assertEqual(result, "the sheet stayed open after Return")
        self.assertEqual(keys[-1], (36,))

    def test_vectorworks_in_front_with_no_other_app_seen_is_logged(self):
        desk = Desktop("100")
        with mock.patch.object(self.sweep_ui.focus, "osa", desk.osa):
            self.assertFalse(self.sweep_ui.hold_front("sweep-start"))
        row = Path(self.log).read_text().splitlines()[1].split("\t")
        self.assertEqual((row[1], row[5], row[8]), ("sweep-start", "self-activated", "kept, no other application seen"))


if __name__ == "__main__":
    unittest.main()
