import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MEASURE = 'import sys\nfor p in sys.argv[1:]:\n    print("%s\\tobj\\t%d\\tok\\tlines" % (p, len(open(p).readlines())))\n'


class InstallRunsTheOutputCheck(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.store = os.path.join(tmp.name, "store")
        for rel in ("driver/output-check.py", "driver/plugin-presence.py", "driver/reader-audit.py",
                    "driver/store_path.py"):
            os.makedirs(os.path.dirname(os.path.join(self.store, rel)), exist_ok=True)
            shutil.copy(ROOT / rel, os.path.join(self.store, rel))
        os.makedirs(os.path.join(self.store, "driver", "inventory", "recipes"))
        os.makedirs(os.path.join(self.store, "ledger"))
        Path(self.store, "ledger", "corpus-ledger.jsonl").write_text("")
        self.measure = os.path.join(tmp.name, "measure.py")
        Path(self.measure).write_text(MEASURE)
        self.run_dir = os.path.join(tmp.name, "ev", "runs", "r1")
        os.makedirs(os.path.join(self.run_dir, "records"))
        self.tmp = tmp.name

    def install(self, data, fmt="obj", profile="obj.mesh"):
        out = os.path.join(self.run_dir, "c.x." + fmt)
        Path(out).write_bytes(data.encode() if isinstance(data, str) else data)
        rec = os.path.join(self.run_dir, "records", "c.x.%s.json" % profile)
        Path(rec).write_text(json.dumps({"case": "c.x", "profile": profile, "format": fmt, "run_id": "r1",
                                         "status": "ok", "path": out}))
        return subprocess.run([sys.executable, str(ROOT / "tools/install-artifact.py"), "--measure", self.measure,
                               "--replaced", os.path.join(self.tmp, "replaced.tsv"), "--store", self.store,
                               "--check-python", sys.executable, "--apply", rec], capture_output=True, text=True)

    def test_file_with_no_geometry_is_refused(self):
        done = self.install("# no vertex\n")
        self.assertEqual(done.returncode, 1)
        self.assertIn("output check fail:", done.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.store, "files", "c.x", "c.x.obj")))

    def test_unread_file_is_refused(self):
        done = self.install(os.urandom(5000), "png", "png.top-plan")
        self.assertEqual(done.returncode, 1)
        self.assertIn("output check unread:", done.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.store, "files", "c.x", "c.x.png")))

    def test_ledger_line_carries_the_output_check(self):
        done = self.install("v 0 0 0\nv 1 0 0\n")
        self.assertEqual(done.returncode, 0, done.stderr)
        line = json.loads(Path(self.store, "ledger", "corpus-ledger.jsonl").read_text().splitlines()[-1])
        self.assertEqual((line["output_check"]["verdict"], line["output_check"]["settings"]), ("pass", "unknown"))


if __name__ == "__main__":
    unittest.main()
