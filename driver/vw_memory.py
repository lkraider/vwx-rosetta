#!/usr/bin/env python3
"""Restart Vectorworks by measured memory.

On 2026-10-19 at 00:13Z the 8 GB Mac ran Vectorworks at an 11 GB footprint with swap nearly
full, and WindowServer hung. RSS stays low while macOS compresses memory, so the footprint
comes from `footprint <pid>`.

The drivers call before_row() before each row, after_source() after each source document,
and end_of_batch() after the last row. end_of_batch() restarts only at a limit, as before_row()
does. With no restart it calls close, when the caller passes one. make-sources.py and
source-census.py pass one. sweep-ui.py passes none, because export_pair closes the documents
of each pair. batch.py starts a fresh Vectorworks at batch start, and starts one
before a driver call when no process runs. A restart clicks Vectorworks > Quit Vectorworks
and starts it with driver/ui/vw-launch.sh. vw-launch.sh starts it with `open -g`. Whether
the start then stays in the background is not measured, so a restart reads the pause file first.
With ROSETTA_OPEN_UNDER_PAUSE=1 a restart runs while the pause file holds. When Vectorworks is
in front after the start, the front goes back to the application read before and the restart
raises RuntimeError. Each check and restart appends a row to
$ROSETTA_TMP/vw-memory.tsv.

Limits: VW_FOOTPRINT_LIMIT_MB (6144), VW_SWAP_USED_MB (4608) while the footprint is above
VW_SWAP_FOOTPRINT_MB (5120), VW_LARGE_SOURCE_MB (100). Swap use after a restart measured 1562 to
3743 MB on this Mac, so swap alone would restart before many rows. Idle Vectorworks 2027 with no document measured 3298 MB.

Usage: vw_memory.py                     print the footprint and swap of the running Vectorworks
       vw_memory.py --restart [REASON]  restart it now, or start it when it is gone, and log
                                        REASON (default "manual")
"""
import datetime
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import focus  # noqa: E402
import pause  # noqa: E402
import vw_lock  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAUNCH = os.path.join(ROOT, "driver", "ui", "vw-launch.sh")
CLI = os.environ.get("VWX_CLI", os.path.join(ROOT, "driver", "bin", "vwx"))
BUNDLE_ID = "net.nemetschek.vectorworks"
FOOTPRINT_LIMIT_MB = int(os.environ.get("VW_FOOTPRINT_LIMIT_MB", "6144"))
SWAP_USED_MB = int(os.environ.get("VW_SWAP_USED_MB", "4608"))
SWAP_FOOTPRINT_MB = int(os.environ.get("VW_SWAP_FOOTPRINT_MB", "5120"))
LARGE_SOURCE_MB = int(os.environ.get("VW_LARGE_SOURCE_MB", "100"))
# A trial licence is checked at launch only, so ROSETTA_KEEP_VW=1 keeps the running Vectorworks alive.
KEEP_VW = os.environ.get("ROSETTA_KEEP_VW") == "1"
VOLUME = os.environ.get("ROSETTA_VOLUME", "/Volumes/volxxxx")
SCRATCH = os.environ.get("ROSETTA_TMP", VOLUME + "/Caches/tmp/rosetta-run-" + time.strftime("%Y%m%d"))
LOG = os.path.join(SCRATCH, "vw-memory.tsv")
COLUMNS = ("utc", "event", "reason", "pid", "footprint_mb", "swap_used_mb", "swap_total_mb",
           "quit", "pid_after", "footprint_after_mb", "swap_used_after_mb", "seconds")
UNITS = {"KB": 1 / 1024, "MB": 1, "GB": 1024}


def run(cmd, timeout=60, env=None):
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
    return p.returncode, p.stdout + p.stderr


def live_pid():
    _code, out = run(["pgrep", "-f", "MacOS/Vectorworks$"])
    return out.split()[0] if out.strip() else None


def parse_footprint(text):
    """MB from the `Footprint:` line of footprint(1)."""
    m = re.search(r"Footprint:\s*([\d.,]+)\s*(KB|MB|GB)", text)
    if not m:
        return None
    return round(float(m.group(1).replace(",", ".")) * UNITS[m.group(2)])


def parse_swap(text):
    """(used MB, total MB) from `sysctl vm.swapusage`. A locale with a decimal comma prints one here."""
    values = {}
    for key in ("total", "used"):
        m = re.search(key + r"\s*=\s*([\d.,]+)M", text)
        if not m:
            return None
        values[key] = round(float(m.group(1).replace(",", ".")))
    return values["used"], values["total"]


def measure(pid):
    _code, out = run(["footprint", str(pid)])
    _code, swap = run(["sysctl", "vm.swapusage"])
    return parse_footprint(out), parse_swap(swap) or (None, None)


def over_limit(footprint_mb, swap_used_mb, swap_total_mb):
    if footprint_mb is not None and footprint_mb > FOOTPRINT_LIMIT_MB:
        return "footprint %d MB > %d MB" % (footprint_mb, FOOTPRINT_LIMIT_MB)
    if footprint_mb is None or footprint_mb <= SWAP_FOOTPRINT_MB:
        return None
    if swap_used_mb is not None and swap_used_mb > SWAP_USED_MB:
        return "swap %d of %s MB > %d MB at footprint %d MB" % (
            swap_used_mb, swap_total_mb, SWAP_USED_MB, footprint_mb)
    return None


def write_log(row):
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    new = not os.path.exists(LOG)
    with open(LOG, "a") as handle:
        if new:
            handle.write("\t".join(COLUMNS) + "\n")
        handle.write("\t".join("" if row.get(c) is None else str(row[c]) for c in COLUMNS) + "\n")


def press_in_windows(*labels):
    """Press the first of `labels` in each window and sheet of Vectorworks that has it.
    Returns the number of presses. An open or save panel left by a failed step is modal,
    and it blocks File > New... and the Quit menu item."""
    lines = ['tell application "System Events" to tell (first process whose bundle identifier is "%s")' % BUNDLE_ID,
             "set n to 0",
             "repeat with w in windows",
             "repeat with s in (sheets of w) & {w}"]
    for label in labels:
        lines += ['if exists button "%s" of s then' % label,
                  'click button "%s" of s' % label,
                  "set n to n + 1",
                  "else"]
    lines += ["end if"] * len(labels) + ["end repeat", "end repeat", "return n", "end tell"]
    try:
        code, out = run(["osascript", "-e", "\n".join(lines)], timeout=30)
    except subprocess.TimeoutExpired:
        return 0
    return int(out.strip()) if code == 0 and out.strip().isdigit() else 0


def close_all_documents(rounds=40):
    """Click File > Close All and press Don't Save until no prompt is left. A kept Vectorworks shows
    every open document as a tab of one window, and the drivers find a document by its window title.
    Returns the number of presses."""
    click = ('tell application "System Events" to tell (first process whose bundle identifier is "%s") '
             'to click menu item "Close All" of menu 1 of menu bar item "File" of menu bar 1' % BUNDLE_ID)
    run(["osascript", "-e", 'tell application id "%s" to activate' % BUNDLE_ID])
    presses = press_in_windows("Cancel")
    run(["osascript", "-e", click])
    idle = 0
    while rounds and idle < 3:
        time.sleep(0.5)
        n = press_in_windows("Don’t Save", "Don't Save")
        presses += n
        idle = 0 if n else idle + 1
        rounds -= 1
    return presses


def quit_app(pid, seconds=120):
    """Press Cancel on any open panel, click Vectorworks > Quit Vectorworks through System
    Events, then send the quit Apple Event. A save prompt gets Don't Save. Returns the step that
    ended the process, "click" or "event", with "cancel+" before it and "+dont-save" after it
    when those presses happened. Returns None when the process stays. An instance that
    vw-launch.sh starts through LaunchServices ignores the Apple Event and quits on the click.
    `vwx ui-menu --press` refuses the Quit item. An Apple Event to a stopped application starts
    it under the launchd locale, which crashes, so the event is sent only while the application
    runs."""
    if KEEP_VW:
        return None
    click = ('tell application "System Events" to tell (first process whose bundle identifier is "%s") '
             'to click menu item "Quit Vectorworks" of menu 1 of menu bar item 2 of menu bar 1' % BUNDLE_ID)
    event = 'if application id "%s" is running then tell application id "%s" to quit' % (BUNDLE_ID, BUNDLE_ID)
    before = "cancel+" if press_in_windows("Cancel") else ""
    after = ""
    for step, script in (("click", click), ("event", event)):
        try:
            run(["osascript", "-e", script], timeout=30)
        except subprocess.TimeoutExpired:
            pass
        deadline = time.time() + seconds / 2
        while time.time() < deadline:
            if run(["kill", "-0", str(pid)])[0] != 0:
                return before + step + after
            if press_in_windows("Don’t Save", "Don't Save"):
                after = "+dont-save"
            time.sleep(2)
    return None


def restart(reason, log=None, close=None):
    """Quit and start Vectorworks. Returns the new pid as text."""
    if KEEP_VW and live_pid():
        write_log({"utc": utc(), "event": "kept", "reason": reason, "pid": live_pid()})
        return live_pid()
    under_pause = os.environ.get("ROSETTA_OPEN_UNDER_PAUSE") == "1"
    if not under_pause:
        pause.check()
    before = focus.front() if under_pause else ("", "")
    t0 = time.time()
    pid = live_pid()
    row = {"utc": utc(), "event": "restart", "reason": reason, "pid": pid}
    if pid:
        fp, (used, total) = measure(pid)
        row.update(footprint_mb=fp, swap_used_mb=used, swap_total_mb=total)
        if close:
            close(pid)
        row["quit"] = quit_app(pid) or "killed"
    else:
        _code, swap = run(["sysctl", "vm.swapusage"])
        used, total = parse_swap(swap) or (None, None)
        row.update(swap_used_mb=used, swap_total_mb=total, quit="gone")
    args = ["sh", LAUNCH] + (["--restart"] if row.get("quit") == "killed" else [])
    code, out = run(args, timeout=600, env=dict(os.environ, VWX_CLI=CLI))
    after = live_pid()
    row["pid_after"] = after
    if after:
        fp, (used, _total) = measure(after)
        row.update(footprint_after_mb=fp, swap_used_after_mb=used)
    took_front = under_pause and before[1] != "Vectorworks" and focus.front()[1] == "Vectorworks"
    if took_front:
        focus.return_front(before[0], after)
        row["reason"] = "%s; Vectorworks came to the front under the pause, front given to %s" % (reason, before[1])
    row["seconds"] = round(time.time() - t0)
    write_log(row)
    if log is not None:
        log.append(row)
    if took_front:
        raise RuntimeError("Vectorworks came to the front after the start under the pause")
    if code != 0 or not after:
        raise RuntimeError("vw-launch.sh failed after a restart for %s: %s" % (reason, out.strip()[-300:]))
    return after


def before_row(log=None, close=None):
    """Measure the running Vectorworks and restart it when a limit is passed."""
    pid = live_pid()
    if not pid:
        return None
    fp, (used, total) = measure(pid)
    reason = over_limit(fp, used, total)
    write_log({"utc": utc(), "event": "check", "reason": reason or "", "pid": pid,
               "footprint_mb": fp, "swap_used_mb": used, "swap_total_mb": total})
    if reason:
        return restart(reason, log, close)
    return pid


def after_source(path, log=None, close=None):
    try:
        size_mb = os.path.getsize(path) / 1048576
    except OSError:
        return live_pid()
    if size_mb < LARGE_SOURCE_MB:
        return live_pid()
    return restart("large source %s %d MB" % (os.path.basename(path), size_mb), log, close)


def end_of_batch(log=None, close=None):
    pid = live_pid()
    after = before_row(log, close)
    if close and after and after == pid:
        close(pid)
    return after


def utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--restart"] and len(sys.argv) <= 3:
        with vw_lock.held("vw_memory.py --restart"):
            print(restart(sys.argv[2] if len(sys.argv) == 3 else "manual"))
    elif sys.argv[1:] == ["--close-all"]:
        print(close_all_documents())
    elif sys.argv[1:]:
        raise SystemExit(__doc__)
    else:
        pid = live_pid()
        if not pid:
            raise SystemExit("no running Vectorworks process")
        fp, (used, total) = measure(pid)
        print("pid\t%s\nfootprint_mb\t%s\nswap_used_mb\t%s\nswap_total_mb\t%s\nover_limit\t%s"
              % (pid, fp, used, total, over_limit(fp, used, total) or ""))
