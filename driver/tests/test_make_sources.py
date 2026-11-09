#!/usr/bin/env python3
import hashlib
import importlib.util
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("make_sources", ROOT / "driver/ui/make-sources.py")
make_sources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(make_sources)

SOURCES_HEADER = "source_file\tsha256\tbytes\tbatch\tcase_ids\tcurrent_sha256\tcurrent_bytes\n"
STORED_ROW = "case.a\tsources/case.a.vwx\t%s\t1\n"


class Record(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "sources").mkdir()
        (self.root / "driver").mkdir()
        self.out = self.root / "out"
        self.source_map = self.root / "driver/source-map.tsv"
        self.sources = self.root / "sources/SOURCES.tsv"
        self.sources.write_text(SOURCES_HEADER)
        lock = mock.patch.object(make_sources.vw_lock, "LOCK", str(self.root / "lock"))
        lock.start()
        self.addCleanup(lock.stop)

    def tearDown(self):
        self.tmp.cleanup()

    def run_main(self, case, generated, keep=False, pid="1", restart=None):
        def run_case(name, out_dir, programs_dir, scripts_dir=None):
            path = os.path.join(out_dir, name + ".vwx")
            Path(path).write_bytes(generated)
            return {"case": name, "status": "ok", "path": path, "bytes": len(generated),
                    "sha256": hashlib.sha256(generated).hexdigest()}

        argv = ["make-sources.py", "--cases", case, "--record", "--batch", "b8", "--out-dir", str(self.out),
                "--programs-dir", str(self.root / "programs")]
        with mock.patch.object(make_sources, "ROOT", str(self.root)), \
                mock.patch.object(make_sources, "SOURCE_MAP", str(self.source_map)), \
                mock.patch.object(make_sources, "run_case", run_case), \
                mock.patch.object(make_sources.run_provenance, "require",
                                  return_value={"commit": "c", "branch": "b"}), \
                mock.patch.object(make_sources.vw_memory, "live_pid", return_value=pid), \
                mock.patch.object(make_sources.vw_memory, "before_row"), \
                mock.patch.object(make_sources.vw_memory, "KEEP_VW", keep), \
                mock.patch.object(make_sources.vw_memory, "close_all_documents") as self.close_all, \
                mock.patch.object(make_sources.vw_memory, "restart", restart or mock.Mock()), \
                mock.patch.object(make_sources.vw_memory, "end_of_batch"), \
                mock.patch.object(sys, "argv", argv), \
                mock.patch("sys.stdout"):
            return make_sources.main()

    def test_new_source_is_copied_and_mapped_to_its_store_path(self):
        self.source_map.write_text("")
        self.assertEqual(self.run_main("case.b", b"new"), 0)
        self.assertEqual((self.root / "sources/case.b.vwx").read_bytes(), b"new")
        self.assertEqual(self.source_map.read_text(),
                         "case.b\tsources/case.b.vwx\t%s\t1\n" % hashlib.sha256(b"new").hexdigest())
        digest = hashlib.sha256(b"new").hexdigest()
        self.assertEqual(self.sources.read_text(),
                         SOURCES_HEADER + "case.b.vwx\t%s\t3\tb8\tcase.b\t%s\t3\n" % (digest, digest))

    def test_vectorworks_starts_when_no_process_runs(self):
        self.source_map.write_text("")
        restart = mock.Mock()
        self.assertEqual(self.run_main("case.b", b"new", pid=None, restart=restart), 0)
        self.assertEqual(restart.call_args.args[0], "not running before case.b")

    def test_stored_source_with_other_bytes_fails_and_stays(self):
        row = STORED_ROW % hashlib.sha256(b"stored").hexdigest()
        (self.root / "sources/case.a.vwx").write_bytes(b"stored")
        self.source_map.write_text(row)
        self.assertEqual(self.run_main("case.a", b"other"), 1)
        self.assertEqual((self.root / "sources/case.a.vwx").read_bytes(), b"stored")
        self.assertEqual(self.source_map.read_text(), row)
        self.assertEqual(self.sources.read_text(), SOURCES_HEADER)


    def test_kept_vectorworks_closes_every_document_before_each_case(self):
        self.source_map.write_text("")
        self.assertEqual(self.run_main("case.b,case.c", b"new", keep=True), 0)
        self.assertEqual(self.close_all.call_count, 2)

    def test_a_restarting_vectorworks_closes_no_document_first(self):
        self.source_map.write_text("")
        self.run_main("case.b", b"new")
        self.close_all.assert_not_called()


class Program(unittest.TestCase):
    def test_script_with_a_checkpoint_runs_to_its_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            body = Path(tmp, "case.c.py")
            body.write_text('rosetta_checkpoint("before-boolean")\nrosetta_save_reopen()\n')
            out = os.path.join(tmp, "case.c.vwx")
            program = make_sources.write_program("case.c", str(body), out, tmp)
            with mock.patch.dict(sys.modules, {"vs": types.ModuleType("vs")}):
                exec(compile(Path(program).read_text(), program, "exec"), {})
            self.assertTrue(os.path.exists(out + ".ran"))


class Close(unittest.TestCase):
    def test_close_document_cancels_a_panel_first(self):
        log = []
        with mock.patch.object(make_sources.vw_memory, "press_in_windows", return_value=1) as press, \
                mock.patch.object(make_sources, "modal", return_value={"modal": "false", "title": ""}), \
                mock.patch.object(make_sources.time, "sleep"):
            self.assertTrue(make_sources.close_document("100", log))
        press.assert_called_once_with("Cancel")
        self.assertEqual(log, [("discard", "pressed Cancel on a panel")])


class RunScript(unittest.TestCase):
    def route(self, transport, out=None):
        log, clicks = [], []
        with mock.patch.object(make_sources, "run", return_value=(2, out or "transport\t%s\n" % transport)), \
                mock.patch.object(make_sources, "modal", return_value={"modal": "false", "title": "", "message": ""}), \
                mock.patch.object(make_sources, "osa", side_effect=lambda s: clicks.append(s) or (0, "")), \
                mock.patch.object(make_sources, "wait_for", return_value=None):
            try:
                make_sources.run_script("100", "/p/a.py", log, panel_tries=1)
            except RuntimeError:
                pass
        return clicks

    def test_an_acknowledged_send_opens_no_panel(self):
        self.assertEqual(self.route("acknowledged"), [])

    def test_an_unknown_timeout_opens_no_panel(self):
        self.assertEqual(self.route("unknown_timeout"), [])

    def test_a_subprocess_timeout_opens_no_panel(self):
        with mock.patch.object(make_sources, "run", side_effect=make_sources.subprocess.TimeoutExpired("vwx", 30)), \
                mock.patch.object(make_sources, "osa") as osa:
            make_sources.run_script("100", "/p/a.py", [])
        osa.assert_not_called()

    def test_a_failed_send_opens_the_run_script_panel(self):
        self.assertIn("Run Script...", self.route("failed")[0])

    def test_a_refusal_before_the_send_opens_the_run_script_panel(self):
        self.assertIn("Run Script...", self.route(None, "status\trefused_policy\n")[0])


if __name__ == "__main__":
    unittest.main()
