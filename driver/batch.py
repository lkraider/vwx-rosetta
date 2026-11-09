#!/usr/bin/env python3
"""Run one batch stage unattended: every export, output check, retry and memory restart, then one queue wake.

Usage: batch.py stage1|stage2|stage3|stage1-scripted|stage2-scripted [--front] [--dry-run] [--no-wake]
       batch.py --plan PLAN.tsv [--front] [--dry-run] [--no-wake]

--front lets the ui rows bring Vectorworks to the front for the steps that cannot run in the background.
A plan with a ui row refuses to start without it. The pause file still stops every front step.

stage1 runs driver/batch/stage1.tsv. stage2 and stage3 run driver/batch/stage2.tsv and stage3.tsv, which
driver/batch/build-stage2.py writes. driver/batch/build-blocks.py splits stage2.tsv into the block plans
stage2-blockN.tsv, which run with --plan. These plans hold the ui rows. stage1-scripted and stage2-scripted run the scripted rows of each stage
from driver/batch/STAGE-scripted.tsv. They need no --front and start under a pause, so they run outside the
front window. The batch lock lets one run hold Vectorworks at a time. driver/vw_lock.py lets each
driver it starts run under that lock. Each plan row is one driver call:
  step      the row name in the summary
  driver    ui (driver/ui/sweep-ui.py) or scripted (driver/scripted/sweep-scripted.sh)
  format    the sweep-ui format key, or the scripted format
  profile   the profile, or empty for every listed profile of the cases
  cases     comma-separated case names
  options   more sweep-ui options, in shell quoting
  expect    pass: each pair must get the output-check verdict pass. record: the result is reported only.
            install: each pair goes through tools/install-artifact.py into this checkout. The row needs a
            profile.
  ext       the file extension the output check reads

The exports run in an evidence worktree, a detached checkout of the main commit at the start, under
/Volumes/volxxxx/Caches/tmp/rosetta-worktrees/evidence-<stamp>. The drivers write files/, runs/ and
ledger/ there. Each driver call gets ROSETTA_BASE set to that commit, so a merge to main during the run
does not refuse later calls. Nothing goes into the store, because only tools/install-artifact.py installs. After each
call the script copies the new ledger lines into the output folder and restores the evidence ledger, so
driver/run_provenance.py accepts the next call.

An install row passes its exported pairs to one tools/install-artifact.py --apply call with --store set to
this checkout, MEASURE tools/measure.py and the reader Python. Its records first get the absolute evidence
path, because install-artifact.py reads a relative path as a store path. A scripted pair gets a record in the
sweep-ui form beside its scripted record. Each pair then has the install column install, keep, negative
(read_empty: the output check read the whole file and found no object), refused, or empty when no file was
exported.
A keep with a count of 0 is refused, because the output check passed that file.
install-artifact.py writes replaced.tsv in the output folder and moves retired files into retired/.
After the last row, a run that installed a file runs driver/reader-audit.py --write with the reader Python, so
ledger/reader-audit.tsv has rows for the new files. summary.md gives the result. When it fails, summary.md
gives the command to run before the install commit.

A row whose format the driver lacks, or whose ext has no reader in driver/output-check.py, does not run.
It goes into follow-up.tsv in the output folder. `batch.py --plan follow-up.tsv` runs it later.

The start quits a running Vectorworks and starts a new one, so no run reuses the state of an earlier run.
Before each driver call the script starts Vectorworks through driver/vw_memory.py when no process runs.
vw_memory.py starts it in the background with driver/ui/vw-launch.sh and waits until the File menu reads.
When it does not start, the run stops with exit 2.

The start writes the current UTC time into the pause file and restores the earlier text at the end.
A plan of scripted rows starts under a pause and leaves the pause file as it is. Its calls get
ROSETTA_OPEN_UNDER_PAUSE=1, so sweep-scripted.sh opens documents and ends with exit 3 when Vectorworks
comes to the front. Exit 3 then stops the run after the summary rows of that plan row.
The stopped case gets the status `stopped: <last line of the call>`.
A pause that a person writes during the run stops the run before its next Vectorworks call. sweep-ui reads
the pause before each pair and ends its call after a paused pair. That pair gets the status paused and no retry,
and timing.tsv gets a row of kind pause. The pairs
that finished before the stop still get their output check, install and summary rows. A call that runs past
its timeout, or a sweep-ui call that prints no line for IDLE_TIMEOUT seconds, is killed with its
process group. A pair with a record that the killed call wrote keeps the status of that record. The
other pairs get the status `row timeout: killed after N s`.

Output folder: $ROSETTA_TMP/batch/<stamp>-<plan>/ with summary.tsv, summary.md, timing.tsv,
activations.tsv, ledger-lines.jsonl, follow-up.tsv and logs/<step>.stderr.
timing.tsv has one row of kind restart for each restart in tmp/vw-memory.tsv, named by its reason.
Its start is the utc of that row, written before the quit. Its end is start plus seconds.

Exit 0 when every pass row has the verdict pass and every install pair is install, keep or negative.
Exit 1 when a pass row has another verdict, an install pair has another result, or when any
call timed out or raised, or when a wake failed. Exit 2 when the start is refused or the run stops. The start is refused while
the pause file holds a pause and the plan has a ui row, and when the reader Python cannot import PIL and ezdxf.
The start is also refused when a Vectorworks process runs that no batch run started: its pid is not the
pid_after of a vw-memory.tsv row under $ROSETTA_TMP/batch, at that row's time. For a batch-started process,
the start is refused when it shows a document outside /Volumes/volxxxx/Caches/tmp,
or a window with no file and unsaved edits, because the batch start quits Vectorworks. The refusal names them.
The end sends summary.md to each destination of ROSETTA_NOTIFY (comma-separated; none by default).
"""
import argparse
import calendar
import collections
import csv
import datetime
import glob
import importlib.util
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "driver"))
import pause  # noqa: E402
import run_provenance  # noqa: E402
import vw_lock  # noqa: E402

VOLUME = os.environ.get("ROSETTA_VOLUME", "/Volumes/volxxxx")
SCRATCH = os.environ.get("ROSETTA_TMP", VOLUME + "/Caches/tmp/rosetta-corpus")
WORKTREES = os.environ.get("ROSETTA_WORKTREES", VOLUME + "/Caches/tmp/rosetta-worktrees")
CACHE = VOLUME + "/Caches/tmp"
READERS_VENV = VOLUME + "/Caches/tmp/rosetta-readers-315/bin/python"
READER_PYTHON = os.environ.get("ROSETTA_READER_PYTHON") or (READERS_VENV if os.path.exists(READERS_VENV) else sys.executable)
WAKE = tuple(x for x in os.environ.get("ROSETTA_NOTIFY", "").split(",") if x)
SOURCE = os.environ.get("ROSETTA_NOTIFY_SOURCE", "rosetta-runner")
PLANS = {s: os.path.join(ROOT, "driver", "batch", s + ".tsv")
         for s in ("stage1", "stage2", "stage3", "stage1-scripted", "stage2-scripted")}
PLAN_COLUMNS = ["step", "driver", "format", "profile", "cases", "options", "expect", "ext"]
SUMMARY_COLUMNS = ["step", "case", "route", "profile", "file", "verdict", "missing", "alerts", "activations",
                   "expect", "status", "retried", "install", "counts", "detail"]
# The alert of an STL or IGES export for a source with no object the format takes. A second try gives
# the same alert, so the pair gets no retry.
NO_VALID_OBJECTS = "There are no valid objects available for export"
# sweep-ui gives active_layer_not_set when its script ran and the active layer read back differs from
# the plan's layer. A second try runs the same script on the same source.
NO_RETRY_STATUS = {"active_layer_not_set"}
TIMING_COLUMNS = ["kind", "name", "start", "end", "seconds", "exit", "retries", "peak_rss_mb", "vw_footprint_mb"]
CHECK_TIMEOUT = 600
PAIR_TIMEOUT = 900
CALL_TIMEOUT = 600
IDLE_TIMEOUT = 1800
CHECK_WARN = 480
START_TIMEOUT = 900
SECONDS_PER_FILE = 120
TIME_BLOCK = re.compile(r"^\s*[\d.,]+ real\s")
SLOW_FRONT_STEP = 20.0


class Stop(Exception):
    pass


def utc(t=None):
    return datetime.datetime.fromtimestamp(t or time.time(), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_plan(path):
    with open(path) as f:
        rows = [dict(zip(PLAN_COLUMNS, line.rstrip("\n").split("\t"))) for line in f
                if line.strip() and not line.startswith(("#", "step\t"))]
    for row in rows:
        missing = [c for c in PLAN_COLUMNS if c not in row]
        if missing or row["driver"] not in ("ui", "scripted") or row["expect"] not in ("pass", "record", "install"):
            raise SystemExit("plan row %s is malformed" % row.get("step"))
        if row["expect"] == "install" and not row["profile"]:
            raise SystemExit("plan row %s installs and names no profile" % row["step"])
    return rows


def write_tsv(path, columns, rows, header=True):
    with open(path, "w") as f:
        if header:
            f.write("\t".join(columns) + "\n")
        for row in rows:
            f.write("\t".join(str(row.get(c, "")).replace("\t", " ").replace("\n", " ") for c in columns) + "\n")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def readable_exts(root):
    checker = load("output_check", os.path.join(root, "driver", "output-check.py"))
    return {e.lstrip(".") for e in checker.READ} | set(checker.presence.READERS)


def driver_formats(root, row):
    if row["driver"] == "scripted":
        return {"stl", "sat"}
    text = open(os.path.join(root, "driver", "ui", "sweep-ui.py")).read()
    block = text[text.index("FORMATS = {"):]
    block = block[:block.index("\n}\n")]
    return set(re.findall(r'^    "([a-z0-9_]+)": \{', block, re.M))


def skip_reason(root, row, exts):
    if row["format"] not in driver_formats(root, row):
        return "the %s driver has no format %s" % (row["driver"], row["format"])
    if row["ext"] not in exts:
        return "driver/output-check.py has no reader for .%s" % row["ext"]
    return None


def last_error_line(err):
    """The last line that the called program wrote, above the /usr/bin/time -l block."""
    lines = []
    for line in err.splitlines():
        if TIME_BLOCK.match(line):
            break
        if line.strip() and not line.startswith("$ "):
            lines.append(line.strip())
    return lines[-1] if lines else ""


def reader_missing():
    """The modules of PIL and ezdxf that READER_PYTHON cannot import, as text, or ""."""
    done = subprocess.run([READER_PYTHON, "-c", "import sys\nfor m in ('PIL', 'ezdxf'):\n try: __import__(m)\n"
                           " except ImportError: print(m)"], capture_output=True, text=True)
    return " ".join(done.stdout.split()) if done.returncode == 0 else "anything (exit %d)" % done.returncode


def read_empty(path, check):
    """True when the output check read the whole file and found no object in it.

    A file cut short by a kill also fails the check, with a rejected reader, an object reader exception
    or no row at all. The 3DS reader finds 0 points in a cut file too, so a 3DS file counts only when
    its 0x4D4D main chunk length equals the file size."""
    objects = check.get("objects", "")
    if check.get("reader") not in ("parsed", "warnings", "none") or not objects.startswith("0/"):
        return False
    if check.get("detail", "").startswith("object reader failed"):
        return False
    if path.lower().endswith(".3ds"):
        with open(path, "rb") as f:
            head = f.read(6)
        return len(head) == 6 and head[:2] == b"\x4d\x4d" and int.from_bytes(head[2:], "little") == os.path.getsize(path)
    return True


def take_pause(path):
    """Write the current UTC time into the pause file. Return the earlier text and time stamp, or None."""
    try:
        with open(path) as f:
            before = f.read(), os.stat(path).st_mtime
    except FileNotFoundError:
        before = None
    mine = utc() + "\n"
    with open(path, "w") as f:
        f.write(mine)
    return before, mine


def give_pause_back(path, before, mine):
    """Restore the earlier text and time stamp while the file still holds the line and time stamp of this run.

    The old time stamp keeps a past end time from reading as a touch."""
    try:
        with open(path) as f:
            if f.read() != mine or pause.paused_until(path):
                return
    except OSError:
        return
    if before is None:
        os.remove(path)
    else:
        with open(path, "w") as f:
            f.write(before[0])
        os.utime(path, (before[1], before[1]))


class Run:
    def __init__(self, plan_path, name, out, evidence, under_pause=False):
        self.plan_path, self.name, self.out, self.evidence = plan_path, name, out, evidence
        self.under_pause = under_pause
        self.summary, self.timing, self.follow_up, self.warnings = [], [], [], []
        self.stop = ""
        self.reader_audit = ""
        self.retries = 0
        self.started = time.time()
        self.env = dict(os.environ, ROSETTA_TMP=os.path.join(out, "tmp"),
                        PATH="/opt/homebrew/bin:" + os.environ.get("PATH", "/usr/bin:/bin"),
                        ROSETTA_FOCUS_LOG=os.path.join(out, "activations.tsv"),
                        ROSETTA_LOCK=os.path.join(SCRATCH, "lock"), ROSETTA_LOCK_OWNER=str(os.getpid()),
                        VW_FOOTPRINT_LIMIT_MB=os.environ.get("VW_FOOTPRINT_LIMIT_MB", "6144"),
                        VW_SWAP_FOOTPRINT_MB=os.environ.get("VW_SWAP_FOOTPRINT_MB", "5120"),
                        VWX_CLI=os.environ.get("VWX_CLI", os.path.join(ROOT, "driver", "bin", "vwx")),
                        VWX_SCRIPT_CLI=os.environ.get("VWX_SCRIPT_CLI", os.path.join(ROOT, "driver", "bin", "vwx")))
        if under_pause:
            self.env["ROSETTA_OPEN_UNDER_PAUSE"] = "1"
        self.env["ROSETTA_BASE"] = subprocess.run(["git", "-C", evidence, "rev-parse", "HEAD"],
                                                  capture_output=True, text=True).stdout.strip()
        os.makedirs(os.path.join(out, "logs"), exist_ok=True)
        os.makedirs(os.path.join(out, "tmp"), exist_ok=True)

    def vw_footprint(self):
        try:
            memory = load("vw_memory", os.path.join(self.evidence, "driver", "vw_memory.py"))
            pid = memory.live_pid()
            return memory.measure(pid)[0] if pid else ""
        except Exception:
            return ""

    def start_vw(self, step, fresh=False):
        """Start Vectorworks through driver/vw_memory.py when no process runs, or quit and start it when fresh.
        Raises Stop when it does not start."""
        memory = load("vw_memory", os.path.join(self.evidence, "driver", "vw_memory.py"))
        if memory.live_pid() and memory.KEEP_VW:
            memory.close_all_documents()
            return
        if memory.live_pid() and not fresh:
            return
        code, _lines, err = self.call(step + "-vectorworks-start", ["python3", "driver/vw_memory.py", "--restart",
                                                                     ("fresh at " if fresh else "not running before ") + step],
                                      timeout=START_TIMEOUT)
        if code != 0 or not memory.live_pid():
            raise Stop("Vectorworks could not be started before %s: exit %s: %s"
                       % (step, code, last_error_line(err) or "no process after the start"))

    def call(self, step, argv, timeout=None, idle=None, vectorworks=True):
        """Run argv under /usr/bin/time -l. Returns (exit, stamped stdout lines, stderr of this call).

        stderr goes to logs/<step>.stderr. A watcher kills the process group after timeout seconds, or
        after idle seconds with no stdout line. That closes stdout and ends the read loop. The exit is
        then "timeout". A call with vectorworks=False runs under a pause."""
        until = vectorworks and not self.under_pause and pause.paused_until()
        if until:
            self.timing.append({"kind": "pause", "name": "before " + step, "start": utc(), "end": "",
                                "seconds": "0", "exit": until})
            raise Stop("a pause was written during the run: " + until)
        log = os.path.join(self.out, "logs", step + ".stderr")
        with open(log, "a") as f:
            f.write("$ %s\n" % shlex.join(argv))
            offset = f.tell()
        start = self.last_start = time.time()
        killed, last = [], [start]
        with open(log, "a") as err_file:
            proc = subprocess.Popen(["/usr/bin/time", "-l"] + argv, cwd=self.evidence, env=self.env,
                                    stdout=subprocess.PIPE, stderr=err_file, text=True, start_new_session=True)

            done = threading.Event()

            def watch():
                while not done.wait(1):
                    now = time.time()
                    if timeout and now - start > timeout:
                        killed.append("killed after %d s" % timeout)
                    elif idle and now - last[0] > idle:
                        killed.append("killed after %d s without output" % idle)
                    else:
                        continue
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except OSError:
                        pass
                    return

            watcher = threading.Thread(target=watch, daemon=True)
            watcher.start()
            lines = []
            for line in proc.stdout:
                last[0] = time.time()
                lines.append((last[0], line.rstrip("\n")))
            proc.stdout.close()
            proc.wait()
            done.set()
        end = time.time()
        with open(log) as f:
            f.seek(offset)
            err = f.read()
        if killed:
            err += "\nbatch.py: %s\n" % killed[0]
            with open(log, "a") as f:
                f.write("batch.py: %s\n" % killed[0])
        self.killed = killed[0] if killed else ""
        code = "timeout" if killed else proc.returncode
        rss = re.search(r"(\d+)\s+maximum resident set size", err)
        self.timing.append({"kind": "call", "name": step, "start": utc(start), "end": utc(end),
                            "seconds": "%.1f" % (end - start), "exit": code,
                            "peak_rss_mb": "%d" % (int(rss.group(1)) // 1048576) if rss else "",
                            "vw_footprint_mb": self.vw_footprint()})
        return code, lines, err

    def keep_ledger_lines(self):
        ledger = os.path.join(self.evidence, "ledger", "corpus-ledger.jsonl")
        diff = subprocess.run(["git", "-C", self.evidence, "diff", "--no-color", "-U0", "--", ledger],
                              capture_output=True, text=True).stdout
        added = [l[1:] for l in diff.splitlines() if l.startswith("+") and not l.startswith("+++")]
        if added:
            with open(os.path.join(self.out, "ledger-lines.jsonl"), "a") as f:
                f.write("\n".join(added) + "\n")
        subprocess.run(["git", "-C", self.evidence, "checkout", "--", ledger], capture_output=True)

    def export(self, row, cases, profile, retry=False):
        """One driver call. Returns a list of pair results: case, profile, status, file, record."""
        step = row["step"] + ("-retry" if retry else "")
        options = shlex.split(row["options"])
        if row["driver"] == "scripted":
            results = []
            for case in cases:
                self.start_vw(step)
                before = set(glob.glob(os.path.join(self.evidence, "runs", "*-scripted")))
                code, lines, err = self.call(step, ["bash", "driver/scripted/sweep-scripted.sh",
                                                    "--formats", row["format"], "--only", case],
                                             timeout=CALL_TIMEOUT + PAIR_TIMEOUT)
                self.keep_ledger_lines()
                said = lines[-1][1] if lines else last_error_line(err) or "no output"
                if code == 3 and self.under_pause:
                    self.stop = "sweep-scripted.sh exit 3 under the pause during %s: %s" % (case, said)
                    results.append({"case": case, "profile": profile or row["profile"], "record": "",
                                    "found": None, "file": "", "run_id": "", "status": "stopped: " + said})
                    break
                new = sorted(set(glob.glob(os.path.join(self.evidence, "runs", "*-scripted"))) - before)
                record = os.path.join(new[-1], "records", case + ".json") if new else ""
                found, alerts = None, []
                if record and os.path.exists(record):
                    data = json.load(open(record))
                    alerts = data.get("alerts", [])
                    for item in data.get("collected", []):
                        if item.get("format") == row["format"]:
                            found = item
                missing = "exit %s, no file: %s" % (code, said[:200])
                if alerts:
                    missing += "; alert: " + "; ".join(alerts)
                results.append({"case": case, "profile": profile or row["profile"], "record": record, "found": found,
                                "alerts": alerts, "status": found.get("status", "ok") if found else missing,
                                "file": os.path.join(self.evidence, found["path"]) if found else "",
                                "run_id": os.path.basename(new[-1]) if new else ""})
            return results
        argv = ["python3", "driver/ui/sweep-ui.py", "--format", row["format"], "--only", ",".join(cases), "--front"]
        if profile:
            argv += ["--profile", profile]
        self.start_vw(step)
        code, lines, err = self.call(step, argv + options, timeout=CALL_TIMEOUT + PAIR_TIMEOUT * len(cases),
                                     idle=IDLE_TIMEOUT)
        self.keep_ledger_lines()
        run_id, results, previous = "", [], self.last_start
        call_start = previous
        for stamp, line in lines:
            try:
                data = json.loads(line)
            except ValueError:
                continue
            if "run_id" in data and "rows" in data:
                run_id = data["run_id"]
            elif data.get("case") and data.get("profile") and "status" in data and "steps" not in data:
                results.append({"case": data["case"], "profile": data["profile"], "status": data["status"]})
                self.timing.append({"kind": "pair", "name": "%s %s %s" % (row["format"], data["case"], data["profile"]),
                                    "start": utc(previous), "end": utc(stamp), "seconds": "%.1f" % (stamp - previous),
                                    "exit": "" if data["status"] == "ok" else data["status"],
                                    "retries": 1 if retry else 0})
                previous = stamp
            elif data.get("status") == "probed" and data.get("dump"):
                results.append({"case": data.get("case", ",".join(cases)), "profile": profile or "probe",
                                "status": "probed", "file": data["dump"]})
        if not run_id:
            run_dirs = sorted(glob.glob(os.path.join(self.evidence, "runs", "*-ui-" + row["format"])))
            run_id = os.path.basename(run_dirs[-1]) if run_dirs else ""
        for result in results:
            result["run_id"] = run_id
            record = os.path.join(self.evidence, "runs", run_id, "records",
                                  "%s.%s.json" % (result["case"], result["profile"]))
            if result["status"] == "probed":
                continue
            result["record"] = record
            try:
                data = json.load(open(record))
            except (OSError, ValueError):
                data = {}
            path = data.get("path", "")
            result["file"] = os.path.join(self.evidence, path) if path else ""
            if result["status"] != "ok":
                result["alerts"] = [d["text"] for d in data.get("dialogs", []) if d.get("text")]
                if result["alerts"]:
                    result["status"] += ", exit %s; alert: %s" % (code, "; ".join(result["alerts"]))
        if code == "timeout":
            done = {(r["case"], r["profile"]) for r in results}
            for c in cases:
                if not profile or (c, profile) in done:
                    continue
                record = os.path.join(self.evidence, "runs", run_id, "records", "%s.%s.json" % (c, profile))
                try:
                    data = json.load(open(record)) if os.path.getmtime(record) >= call_start else {}
                except (OSError, ValueError):
                    data = {}
                if not data.get("status"):
                    results.append({"case": c, "profile": profile, "file": "", "record": "",
                                    "status": "row timeout: %s" % self.killed})
                    continue
                path = data.get("path", "")
                alerts = [d["text"] for d in data.get("dialogs", []) if d.get("text")]
                results.append({"case": c, "profile": profile, "run_id": run_id, "record": record,
                                "file": os.path.join(self.evidence, path) if path else "",
                                "alerts": alerts, "status": data["status"]})
        if not results:
            results = [{"case": c, "profile": profile or row["profile"], "status": "exit %s, no row: %s"
                        % (code, last_error_line(err)[:200]), "file": "", "record": ""}
                       for c in cases]
        return results

    def check(self, row, results):
        """Run driver/output-check.py on every exported file. Returns {file: check row}."""
        files = [r for r in results if r.get("file") and r["status"] == "ok"]
        if not files:
            return {}
        listing = os.path.join(self.out, "tmp", row["step"] + ".check-list")
        with open(listing, "w") as f:
            f.writelines("%s\t%s\n" % (r["file"], r.get("record", "")) for r in files)
        out = os.path.join(self.out, "tmp", row["step"] + ".check.tsv")
        start = time.time()
        self.call(row["step"] + "-check", [READER_PYTHON, "driver/output-check.py", "--list", listing, "--out", out],
                  timeout=CHECK_TIMEOUT + SECONDS_PER_FILE * len(files), vectorworks=False)
        self.timing[-1]["kind"] = "check"
        if time.time() - start > CHECK_WARN:
            self.warnings.append("output check of %s took %.0f s, limit %d s" % (row["step"], time.time() - start,
                                                                               CHECK_TIMEOUT))
        try:
            with open(out) as f:
                return {r["path"]: r for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE)}
        except OSError:
            return {}

    def install_record(self, row, result):
        """The record that install-artifact.py reads for one exported pair, with an absolute path."""
        if row["driver"] == "scripted":
            with open(result["record"]) as f:
                base = json.load(f)
            rec = {k: v for k, v in base.items() if k not in ("collected", "errors", "work_copy")}
            rec.update(result["found"], case=result["case"], profile=result["profile"], format=row["format"],
                       status="ok", sidecars=[], scripted_record=result["record"])
            path = os.path.join(os.path.dirname(result["record"]),
                                "%s.%s.json" % (result["case"], result["profile"]))
        else:
            with open(result["record"]) as f:
                rec = json.load(f)
            path = result["record"]
        rec["path"] = result["file"]
        with open(path, "w") as f:
            json.dump(rec, f, indent=2)
        return path

    def install(self, row, results, checked):
        """Run tools/install-artifact.py --apply on the exported pairs. Sets install and counts on each result."""
        pairs = [r for r in results if r["status"] == "ok" and r.get("file") and r.get("record")]
        if not pairs:
            return
        records = [self.install_record(row, r) for r in pairs]
        code, lines, err = self.call(row["step"] + "-install",
                                     [READER_PYTHON, os.path.join(ROOT, "tools", "install-artifact.py"),
                                      "--measure", os.path.join(ROOT, "tools", "measure.py"),
                                      "--replaced", os.path.join(self.out, "replaced.tsv"),
                                      "--retire-dir", os.path.join(self.out, "retired"), "--store", ROOT,
                                      "--check-python", READER_PYTHON, "--apply"] + records,
                                     timeout=CHECK_TIMEOUT + SECONDS_PER_FILE * len(records), vectorworks=False)
        self.timing[-1]["kind"] = "install"
        done = {}
        for _stamp, line in lines:
            cells = line.split("\t")
            if len(cells) >= 4 and cells[1] in ("install", "keep", "hold"):
                done[cells[0]] = (cells[1], "%s %s" % (cells[2], cells[3]), cells[4] if len(cells) > 4 else "")
        refused = {}
        for line in err.splitlines():
            if line.startswith("refused "):
                tag, _sep, reason = line[len("refused "):].partition(": ")
                refused[tag] = reason
        for r in pairs:
            tag = "%s %s" % (r["case"], r["profile"])
            if tag in done and done[tag][0] == "keep" and done[tag][1].endswith(" new=0"):
                r["install"], r["counts"] = "refused", done[tag][1]
                r["install_reason"] = "output check passed, measure counted 0: %s" % done[tag][2]
            elif tag in done:
                r["install"], r["counts"] = done[tag][:2]
            elif refused.get(tag, "").startswith("output check fail") and read_empty(r["file"], checked.get(r["file"], {})):
                r["install"], r["install_reason"] = "negative", refused[tag]
            else:
                r["install"] = "refused"
                r["install_reason"] = refused.get(tag) or "install-artifact.py exit %s: %s" % (code, last_error_line(err))

    def audit_readers(self):
        """Write ledger/reader-audit.tsv of this checkout when the run installed a file."""
        if not any(r["install"] == "install" for r in self.summary):
            return
        argv = [READER_PYTHON, os.path.join(ROOT, "driver", "reader-audit.py"), "--write"]
        try:
            code, _lines, err = self.call("reader-audit", argv, timeout=CHECK_TIMEOUT, vectorworks=False)
        except Stop as e:
            code, err = "not run", str(e)
        if code == 0:
            self.reader_audit = "wrote ledger/reader-audit.tsv"
        else:
            self.reader_audit = "exit %s: %s. Run this before the install commit: PATH=/opt/homebrew/bin:$PATH %s" % (
                code, last_error_line(err), shlex.join(argv))
            self.warnings.append("reader audit " + self.reader_audit)

    def activations(self, run_id, case, profile):
        path = os.path.join(self.out, "activations.tsv")
        if not os.path.exists(path):
            return 0
        with open(path) as f:
            rows = list(csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE))
        return sum(1 for r in rows if (r.get("run_id"), r.get("case"), r.get("profile")) == (run_id, case, profile))

    def do_row(self, row):
        cases = [c for c in row["cases"].split(",") if c]
        results = self.export(row, cases, row["profile"])
        paused = [r for r in results if r["status"].startswith("paused")]
        if paused and not self.stop:
            self.stop = "a pause was written during the run, %s %s paused" % (paused[0]["case"], paused[0]["profile"])
            self.timing.append({"kind": "pause", "name": "in %s %s" % (paused[0]["case"], paused[0]["profile"]),
                                "start": utc(), "end": "", "seconds": "0", "exit": pause.paused_until() or ""})
        failed = [] if self.stop else [r for r in results if r["status"] not in ("ok", "probed")]
        retried = set()
        for r in failed:
            if self.stop:
                break
            if any(NO_VALID_OBJECTS in a for a in r.get("alerts", [])):
                continue
            if r["status"].split(",")[0] in NO_RETRY_STATUS:
                continue
            self.retries += 1
            try:
                again = self.export(row, [r["case"]], r["profile"] if r["profile"] != "probe" else row["profile"],
                                    retry=True)
            except Stop as e:
                self.stop = str(e)
                break
            for a in again:
                if a["case"] == r["case"] and (a["profile"] == r["profile"] or not r["profile"]):
                    a["first_try"] = r["status"]
                    results[results.index(r)] = a
                    retried.add((a["case"], a["profile"]))
        checked = self.check(row, results)
        if row["expect"] == "install":
            self.install(row, results, checked)
        for r in results:
            c = checked.get(r.get("file"), {})
            verdict = "probe" if r["status"] == "probed" else c.get("verdict", "" if r["status"] != "ok" else "fail")
            detail = c.get("detail", "") if r["status"] == "ok" else r["status"]
            if r.get("install_reason"):
                detail = ("%s. install: %s" % (detail, r["install_reason"])).strip(". ")
            if r.get("first_try"):
                detail = ("first try: %s. %s" % (r["first_try"], detail)).strip()
            self.summary.append({"step": row["step"], "case": r["case"], "route": row["format"],
                                 "profile": r["profile"], "file": r.get("file", ""), "verdict": verdict,
                                 "missing": c.get("missing", ""), "alerts": c.get("alerts", "") or "; ".join(r.get("alerts", [])),
                                 "activations": self.activations(r.get("run_id"), r["case"], r["profile"]),
                                 "expect": row["expect"], "status": r["status"],
                                 "retried": "yes" if (r["case"], r["profile"]) in retried else "",
                                 "install": r.get("install", ""), "counts": r.get("counts", ""),
                                 "detail": detail})
        if self.stop:
            raise Stop(self.stop)

    def front_steps(self):
        path = os.path.join(self.out, "activations.tsv")
        if not os.path.exists(path):
            return
        with open(path) as f:
            for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
                seconds = float(r.get("seconds") or 0)
                self.timing.append({"kind": "front", "name": "%s %s %s %s" % (r["step"], r["kind"], r["case"], r["profile"]),
                                    "end": r["utc"], "seconds": "%.1f" % seconds, "exit": r.get("detail", "")})
                if seconds > SLOW_FRONT_STEP:
                    self.warnings.append("front step %s took %.1f s on %s %s" % (r["step"], seconds, r["case"], r["profile"]))

    def memory_restarts(self):
        path = os.path.join(self.out, "tmp", "vw-memory.tsv")
        if not os.path.exists(path):
            return []
        with open(path) as f:
            return [r for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE) if r.get("event") == "restart"]

    def restart_steps(self):
        for r in self.memory_restarts():
            end = calendar.timegm(time.strptime(r["utc"], "%Y-%m-%dT%H:%M:%SZ")) + float(r["seconds"])
            self.timing.append({"kind": "restart", "name": r.get("reason", ""), "start": r["utc"], "end": utc(end),
                                "seconds": r.get("seconds", ""), "exit": r.get("quit", ""),
                                "vw_footprint_mb": r.get("footprint_mb", "")})

    def restarts(self):
        return [r for r in self.memory_restarts() if r.get("quit") != "gone"]

    def exit_code(self):
        bad = [r for r in self.summary if (r["expect"] == "pass" and r["verdict"] != "pass")
               or (r["expect"] == "install" and r["install"] not in ("install", "keep", "negative"))
               or "timeout" in r["status"] or r["status"] == "batch error"]
        return 1 if bad else 0

    def report(self, code, stopped=None):
        self.front_steps()
        self.restart_steps()
        write_tsv(os.path.join(self.out, "summary.tsv"), SUMMARY_COLUMNS, self.summary)
        write_tsv(os.path.join(self.out, "timing.tsv"), TIMING_COLUMNS, self.timing)
        if self.follow_up:
            write_tsv(os.path.join(self.out, "follow-up.tsv"), PLAN_COLUMNS, self.follow_up)
        hours = max(time.time() - self.started, 1) / 3600.0
        pairs = [r for r in self.summary if r["verdict"] != "probe"]
        restarts = self.restarts()
        lines = ["batch %s exit %d" % (self.name, code), "",
                 "plan: %s" % self.plan_path, "output: %s" % self.out,
                 "evidence worktree: %s at main commit %s" % (self.evidence, self.env["ROSETTA_BASE"]),
                 "started %s, ended %s, %.2f h" % (utc(self.started), utc(), hours)]
        if stopped:
            lines.append("stopped: %s" % stopped)
        installs = collections.Counter(r["install"] for r in self.summary if r["expect"] == "install")
        lines += ["pairs: %d, pass %d, rate %.1f pairs per hour" % (
            len(pairs), sum(r["verdict"] == "pass" for r in pairs), len(pairs) / hours)]
        if installs:
            lines.append("install: " + ", ".join("%s %d" % (k or "not exported", n) for k, n in sorted(installs.items())))
        if self.reader_audit:
            lines.append("reader audit: " + self.reader_audit)
        lines += [
            "retries: %d, memory restarts: %d" % (self.retries, len(restarts)), ""]
        failing = [r for r in self.summary if r["verdict"] != "pass"]
        if failing:
            lines.append("rows without pass:")
            lines += ["- %s %s %s %s: %s %s (expect %s) %s" % (r["step"], r["route"], r["case"], r["profile"],
                                                              r["verdict"] or "no verdict", r["missing"],
                                                              r["expect"], r["detail"][:160]) for r in failing]
            lines.append("")
        if self.follow_up:
            lines.append("skipped into follow-up.tsv:")
            lines += ["- %s: %s" % (r["step"], r["reason"]) for r in self.follow_up]
            lines.append("")
        slow = sorted((t for t in self.timing if t["kind"] != "front"), key=lambda t: -float(t["seconds"]))[:5]
        lines.append("slowest steps:")
        lines += ["- %s %s %s s" % (t["kind"], t["name"], t["seconds"]) for t in slow]
        lines += ["", "warnings:"] + (["- " + w for w in self.warnings] or ["- none"])
        lines += ["", "memory restarts:"] + (["- %s %s" % (r.get("utc"), r.get("reason")) for r in restarts]
                                             or ["- none"])
        text = "\n".join(lines) + "\n"
        with open(os.path.join(self.out, "summary.md"), "w") as f:
            f.write(text)
        return text


def wake(code, name, body, enabled):
    """Send body to each of WAKE. Returns False when a queue create failed."""
    if not enabled:
        return True
    sent = True
    for destination in WAKE:
        done = subprocess.run(["rig", "queue", "create", "--source", SOURCE, "--destination", destination,
                               "--summary", "batch %s exit %d" % (name, code), "--body-file", body],
                              capture_output=True, text=True)
        if done.returncode:
            sent = False
            note = "wake to %s failed, exit %d: %s" % (destination, done.returncode, done.stderr.strip()[-300:])
            print(note, file=sys.stderr)
            with open(body, "a") as f:
                f.write("\n" + note + "\n")
    return sent


DOCUMENTS = """tell application "System Events"
if not (exists (first process whose bundle identifier is "net.nemetschek.vectorworks")) then return ""
tell (first process whose bundle identifier is "net.nemetschek.vectorworks")
set out to ""
repeat with w in windows
set d to missing value
set e to missing value
try
set d to value of attribute "AXDocument" of w
end try
try
set e to value of attribute "AXEdited" of (value of attribute "AXCloseButton" of w)
end try
if d is missing value then set d to ""
if e is missing value then set e to false
set out to out & (name of w) & tab & d & tab & (e as text) & linefeed
end repeat
return out
end tell
end tell"""


def live_vectorworks():
    found = subprocess.run(["pgrep", "-f", "MacOS/Vectorworks$"], capture_output=True, text=True).stdout.split()
    return found[0] if found else None


def batch_started(pid):
    """True when the vw-memory.tsv of a batch run names pid as the process its restart started, and
    the process started during that restart. The start time rejects a pid that macOS gave out again."""
    lstart = subprocess.run(["ps", "-o", "lstart=", "-p", pid], capture_output=True, text=True,
                            env=dict(os.environ, LC_ALL="C")).stdout.strip()
    try:
        started = time.mktime(time.strptime(lstart, "%a %b %d %H:%M:%S %Y"))
    except ValueError:
        return False
    for path in glob.glob(os.path.join(SCRATCH, "batch", "*", "tmp", "vw-memory.tsv")):
        with open(path) as f:
            for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
                if r.get("pid_after") != pid:
                    continue
                try:
                    at = calendar.timegm(time.strptime(r["utc"] or "", "%Y-%m-%dT%H:%M:%SZ"))
                    end = at + float(r.get("seconds") or 0) + 60
                except ValueError:
                    continue
                if at - 5 <= started <= end:
                    return True
    return False


def foreign_documents():
    """The Vectorworks windows that a fresh start would close with a person's work in them: a
    document outside the cache folder, or a window with no file whose close button shows unsaved
    edits. The batch opens its work copies under the cache folder, and they show unsaved edits too."""
    try:
        p = subprocess.run(["osascript", "-e", DOCUMENTS], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return ["the window list of Vectorworks: osascript timed out after 60 s"]
    if p.returncode:
        return ["the window list of Vectorworks: osascript exit %d: %s" % (p.returncode, p.stderr.strip())]
    found = []
    for line in p.stdout.splitlines():
        title, _sep, rest = line.partition("\t")
        url, _sep, edited = rest.partition("\t")
        path = urllib.parse.unquote(urllib.parse.urlparse(url).path)
        if path and not path.startswith(CACHE + "/"):
            found.append(path)
        elif not path and edited == "true" and os.environ.get("ROSETTA_KEEP_VW") != "1":
            found.append("unsaved window %r" % title)
    return found


def refuse(out, name, reason, enabled):
    os.makedirs(out, exist_ok=True)
    body = os.path.join(out, "summary.md")
    with open(body, "w") as f:
        f.write("batch %s exit 2\n\nrefused: %s\n" % (name, reason))
    print("refused: " + reason, file=sys.stderr)
    wake(2, name, body, enabled)
    return 2


def dry_run(rows):
    exts = readable_exts(ROOT)
    for row in rows:
        reason = skip_reason(ROOT, row, exts)
        if reason:
            print(json.dumps({"step": row["step"], "action": "follow-up", "reason": reason}))
            continue
        if row["driver"] == "scripted":
            print(json.dumps({"step": row["step"], "action": "run", "cases": row["cases"]}))
            continue
        argv = [sys.executable, os.path.join(ROOT, "driver", "ui", "sweep-ui.py"), "--format", row["format"],
                "--only", row["cases"], "--dry-run"] + (["--profile", row["profile"]] if row["profile"] else [])
        options = [o for o in shlex.split(row["options"]) if o != "--probe"]
        done = subprocess.run(argv + options, capture_output=True, text=True)
        pairs = [json.loads(l) for l in done.stdout.splitlines() if l.startswith("{")]
        print(json.dumps({"step": row["step"], "action": "run" if done.returncode == 0 and pairs else "refused",
                          "pairs": [[p["case"], p["profile"], p["status"]] for p in pairs],
                          "error": done.stderr.strip()[-200:]}))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("stage", nargs="?", choices=sorted(PLANS))
    ap.add_argument("--plan")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-wake", action="store_true")
    ap.add_argument("--front", action="store_true")
    args = ap.parse_args()
    plan_path = args.plan or (PLANS[args.stage] if args.stage else None)
    if not plan_path:
        ap.error("name a stage or --plan")
    name = args.stage or os.path.splitext(os.path.basename(plan_path))[0]
    rows = read_plan(plan_path)
    if args.dry_run:
        return dry_run(rows)

    stamp = time.strftime("%Y%m%dT%H%M%S")
    out = os.path.join(SCRATCH, "batch", "%s-%s" % (stamp, name))
    if not args.front and any(r["driver"] == "ui" for r in rows):
        return refuse(out, name, "the plan has ui rows, and they bring Vectorworks to the front. "
                      "Start it with --front when the front may be taken.", not args.no_wake)
    lock = os.path.join(SCRATCH, "lock")
    try:
        vw_lock.take("batch.py %s" % name, lock)
    except vw_lock.Held:
        return refuse(out, name, "another run holds %s" % lock, not args.no_wake)
    try:
        missing = reader_missing()
        if missing:
            return refuse(out, name, "the reader Python %s cannot import %s" % (READER_PYTHON, missing), not args.no_wake)
        if any(r["expect"] == "install" for r in rows) and not os.path.exists(os.path.join(ROOT, "tools", "measure.py")):
            return refuse(out, name, "tools/measure.py is not on main", not args.no_wake)
        under_pause = bool(pause.paused_until()) and all(r["driver"] == "scripted" for r in rows)
        if pause.paused_until() and not under_pause:
            return refuse(out, name, "the pause file %s holds %s" % (pause.PAUSE, pause.paused_until()),
                          not args.no_wake)
        reason = run_provenance.refusal(run_provenance.state(ROOT))
        if reason:
            return refuse(out, name, reason, not args.no_wake)
        pid = live_vectorworks()
        if pid and not batch_started(pid):
            return refuse(out, name, "Vectorworks pid %s runs, and no batch run started it. The batch start "
                          "quits Vectorworks, so quit it by hand first." % pid, not args.no_wake)
        foreign = foreign_documents()
        if foreign:
            return refuse(out, name, "Vectorworks holds work the batch did not open, and the batch start "
                          "quits Vectorworks: " + "; ".join(foreign), not args.no_wake)
        if not os.path.exists(os.path.join(ROOT, "driver", "output-check.py")):
            return refuse(out, name, "driver/output-check.py is not on main", not args.no_wake)
        evidence = os.path.join(WORKTREES, "evidence-%s-%s" % (stamp, name))
        made = subprocess.run(["git", "-C", ROOT, "worktree", "add", "--detach", evidence, "main"],
                              capture_output=True, text=True)
        if made.returncode:
            return refuse(out, name, "git worktree add failed: " + made.stderr.strip(), not args.no_wake)
        before, mine = (None, None) if under_pause else take_pause(pause.PAUSE)
        run = Run(plan_path, name, out, evidence, under_pause)
        stopped = None
        try:
            run.start_vw("batch start", fresh=True)
            exts = readable_exts(evidence)
            for row in rows:
                reason = skip_reason(evidence, row, exts)
                if reason:
                    run.follow_up.append(dict(row, reason=reason))
                    continue
                try:
                    run.do_row(row)
                except Stop:
                    raise
                except Exception as e:
                    run.summary.append(dict({c: "" for c in SUMMARY_COLUMNS}, step=row["step"], case=row["cases"],
                                            route=row["format"], profile=row["profile"], expect=row["expect"],
                                            status="batch error", detail="%s: %s" % (type(e).__name__, e)))
        except Stop as e:
            stopped = str(e)
        except Exception as e:
            stopped = "%s: %s" % (type(e).__name__, e)
        finally:
            if not under_pause:
                give_pause_back(pause.PAUSE, before, mine)
        run.audit_readers()
        code = 2 if stopped else run.exit_code()
        print(run.report(code, stopped))
        if not wake(code, name, os.path.join(out, "summary.md"), not args.no_wake):
            return code or 1
        return code
    finally:
        vw_lock.release(lock)


if __name__ == "__main__":
    sys.exit(main())
