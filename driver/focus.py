#!/usr/bin/env python3
"""Bring Vectorworks to the front only for a named step, give the front back, and log every front change.

Each row of LOG is one front change.
  activate       in_front brought Vectorworks to the front for the step.
  self-activated Vectorworks took the front by itself during the step, and give_back returned it.
  front-lost     in_front asked for the front and Vectorworks did not get it.
  background-ok, background-failed
                 a front step first tried its events posted to the Vectorworks pid with
                 CGEventPostToPid and read the effect. On background-failed it takes the front.
The detail column says whether the previous application got the front back. The front goes
back only while Vectorworks still holds it, so a window the person chose in the meantime stays
in front.

Usage: focus.py --per-hour [LOG]    print the count of front changes per UTC hour and step
"""
import collections
import contextlib
import datetime
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pause  # noqa: E402

VOLUME = os.environ.get("ROSETTA_VOLUME", "/Volumes/volxxxx")
SCRATCH = os.environ.get("ROSETTA_TMP", VOLUME + "/Caches/tmp/rosetta-corpus")
LOG = os.environ.get("ROSETTA_FOCUS_LOG", os.path.join(SCRATCH, "activations.tsv"))
COLUMNS = ["utc", "step", "run_id", "case", "profile", "kind", "previous", "seconds", "detail"]
CONTEXT = {"run_id": "", "case": "", "profile": ""}


class FrontLost(RuntimeError):
    pass


def osa(script, timeout=20):
    done = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=timeout)
    return done.returncode, done.stdout + done.stderr


def front():
    """The unix id and name of the front application, or ("", "") when System Events does not answer."""
    code, out = osa('tell application "System Events" to tell (first process whose frontmost is true) '
                    'to return (unix id as text) & tab & name')
    pid, _tab, name = out.strip().partition("\t")
    return (pid, name) if code == 0 and pid.isdigit() else ("", "")


def write(step, kind, previous, seconds, detail):
    new = not os.path.exists(LOG)
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    row = [utc, step, CONTEXT["run_id"], CONTEXT["case"], CONTEXT["profile"], kind, previous,
           "%.1f" % seconds, detail]
    with open(LOG, "a") as handle:
        if new:
            handle.write("\t".join(COLUMNS) + "\n")
        handle.write("\t".join(str(v).replace("\t", " ").replace("\n", " ") for v in row) + "\n")


def return_front(previous_pid, vw_pid):
    """Give the front to previous_pid while Vectorworks holds it. True when the front moved."""
    if not previous_pid or previous_pid == str(vw_pid) or front()[1] != "Vectorworks":
        return False
    osa('tell application "System Events" to set frontmost of (first process whose unix id is %s) to true'
        % previous_pid)
    return True


@contextlib.contextmanager
def in_front(step, vw_pid):
    """Hold Vectorworks in front for the block, then give the front back at once.

    Only the steps that cannot work in the background use this. Each one names itself in step."""
    pause.check()
    previous_pid, previous_name = front()
    started = time.time()
    osa('tell application "System Events" to set frontmost of (first process whose unix id is %s) to true'
        % vw_pid)
    for _ in range(10):
        if front()[1] == "Vectorworks":
            break
        time.sleep(0.5)
    else:
        write(step, "front-lost", previous_name, time.time() - started, "")
        raise FrontLost("Vectorworks did not come to the front, so no key was sent")
    try:
        yield
    finally:
        gave = return_front(previous_pid, vw_pid)
        write(step, "activate", previous_name, time.time() - started, "given back" if gave else "kept")


def give_back(step, vw_pid, previous):
    """Return the front to previous, the (pid, name) read before the step, when Vectorworks took it.

    Opening a document can bring Vectorworks to the front even when `open -g` asked for the
    background. Returns True when the front moved."""
    previous_pid, previous_name = previous
    if previous_name == "Vectorworks" or front()[1] != "Vectorworks":
        return False
    if not previous_name:
        write(step, "self-activated", "", 0, "kept, no other application seen")
        return False
    gave = return_front(previous_pid, vw_pid)
    write(step, "self-activated", previous_name, 0, "given back" if gave else "kept")
    return gave


def tried(step, worked, seconds, detail=""):
    """Log the result of the background try of a front step."""
    write(step, "background-ok" if worked else "background-failed", "", seconds, detail)


def per_hour(path):
    counts = collections.Counter()
    with open(path) as handle:
        for line in handle.read().splitlines()[1:]:
            cells = line.split("\t")
            counts[(cells[0][:13], cells[1], cells[5])] += 1
    return counts


if __name__ == "__main__":
    if not sys.argv[1:] or sys.argv[1] != "--per-hour":
        raise SystemExit(__doc__)
    for (hour, step, kind), n in sorted(per_hour(sys.argv[2] if len(sys.argv) > 2 else LOG).items()):
        print("%s\t%s\t%s\t%d" % (hour, step, kind, n))
