#!/usr/bin/env python3
import re
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / "driver/scripted/sweep-scripted.sh").read_text()


def function(name):
    return re.search(r"^%s\(\) \{\n.*?^\}\n" % name, SCRIPT, re.M | re.S).group(0)


STL_ALERT = "Export STL failed. There are no valid objects available for export."

# A stand-in for vwx: ui-dialog prints the modal in $MODAL until a press, and a press ends the
# export script in $SENDER_PID.
FAKE_CLI = r'''#!/bin/bash
for a in "$@"; do [ "$a" = --press ] && { touch "$STATE/pressed"; kill "$(cat "$STATE/sender")"; exit 0; }; done
if [ -f "$STATE/pressed" ]; then printf 'modal\tfalse\n'; exit 0; fi
printf 'modal\ttrue\nmessage\t%s\nbutton\tOK\n' "$MODAL"
'''


class WatchExport(unittest.TestCase):
    def watch(self, modal, export_seconds):
        tmp = Path(tempfile.mkdtemp())
        (tmp / "records").mkdir()
        cli = tmp / "vwx"
        cli.write_text(FAKE_CLI)
        cli.chmod(0o755)
        program = "\n".join([
            "set -u", "RUN=%s; VWX_CLI=%s; PID=1; EXE=x; STATE=%s; MODAL=%s; export STATE MODAL" % (
                tmp, cli, tmp, subprocess.list2cmdline([modal])),
            re.search(r"^STL_NO_OBJECTS=.*$", SCRIPT, re.M).group(0),
            function("dismiss_modals"), function("watch_export"),
            "sleep %d & echo $! > $STATE/sender" % export_seconds,
            'watch_export "$(cat $STATE/sender)" a'])
        start = time.monotonic()
        subprocess.run(["bash", "-c", program], check=False, timeout=60)
        modals = tmp / "records" / "modals.tsv"
        return time.monotonic() - start, modals.read_text() if modals.exists() else ""

    def test_the_stl_alert_is_pressed_before_the_export_times_out(self):
        seconds, modals = self.watch(STL_ALERT, 40)
        self.assertLess(seconds, 10)
        self.assertEqual([line.split("\t")[1:] for line in modals.splitlines()], [["export-a", "OK,", STL_ALERT]])

    def test_another_alert_waits_for_the_export_to_end(self):
        seconds, modals = self.watch("Some other alert.", 3)
        self.assertGreaterEqual(seconds, 3)
        self.assertEqual(modals, "")


if __name__ == "__main__":
    unittest.main()
