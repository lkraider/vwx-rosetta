#!/usr/bin/env python3
"""Create the source documents of the rosetta corpus that no file holds.

The inventory generator already wrote one Python script per case. Each script calls
`vs` and ends with `rosetta_save_reopen()`. The capture framework used to define that
name, and `rosetta/capture/packet/bridge.py` holds the definition. The save itself is
`vs.SaveActiveDocument(path)`.

A script goes first through `vwx native-script-send --program`, which needs no front.
From a sandboxed shell it returns `transport failed` with `apple_event_error -609`. The
script then goes through `Tools > Plug-ins > Run Script...`, whose `Choose Script File`
panel takes the path in its Go to field with Vectorworks in front.

When no Vectorworks process runs before a case, driver/vw_memory.py starts one.

Each case runs in a new blank document. The script builds its objects and saves the
document under the case name, so the window title proves the document identity. The
application raises the dialogs as sheets attached to the document window, and a sheet
reports an empty title. Every dialog is therefore read by its own text.

A case with a file `scripts/revisions/<case>.rev<N>.py` runs the file with the largest N.
`vwx rosetta-inventory` writes each recipe revision there, and that revision replaces the
recipe under `scripts/<case>.py`.

`--dry-run` writes each program and prints the `vs` calls it holds. It reads no process
and sends no keystroke.

`--record` copies each new document to `sources/<case>.vwx` and maps the case to that path in
`driver/source-map.tsv`. It appends a row for each copied document to `sources/SOURCES.tsv`, with the batch
name that `--batch` gives. A source already in `sources/` stays. When its digest differs from the
new document, the case fails and its row stays as it is.

Usage: make-sources.py --cases a,b,c [--record --batch NAME] [--out-dir DIR] [--dry-run]
"""
import argparse
import functools
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "driver"))
import focus  # noqa: E402
import pause  # noqa: E402
import run_provenance  # noqa: E402
import vw_lock  # noqa: E402
import vw_memory  # noqa: E402
VOLUME = os.environ.get("ROSETTA_VOLUME", "/Volumes/volxxxx")
SCRATCH = os.environ.get("ROSETTA_TMP", VOLUME + "/Caches/tmp/rosetta-corpus")
CLI = os.environ.get("VWX_CLI", os.path.join(ROOT, "driver", "bin", "vwx"))
SCRIPT_CLI = os.environ.get("VWX_SCRIPT_CLI", CLI)
APP = os.environ.get("VW_APP", "/Applications/Vectorworks 2027/Vectorworks 2027.app")
EXE = APP + "/Contents/MacOS/Vectorworks"
SOURCE_MAP = os.path.join(ROOT, "driver", "source-map.tsv")

INVENTORY = os.path.join(ROOT, "driver", "inventory")
DEPENDENCY = re.compile(r"^# dependency: (\S+) (\S+) sha256 ([0-9a-f]{64})$", re.M)

SCRIPT_ROOTS = [
    os.path.join(ROOT, "driver", "inventory", "scripts"),
]

PROGRAM_HEAD = '''import vs

OUT = %(out)r
DEPENDENCIES = %(dependencies)r


def rosetta_checkpoint(cid):
    pass


def rosetta_dependency(did):
    return DEPENDENCIES[did]


def rosetta_save_reopen():
    vs.SaveActiveDocument(OUT)


def rosetta_script_end():
    open(OUT + ".ran", "w").close()


def rosetta_menu(*path):
    with open(OUT + ".menu", "w") as handle:
        handle.write("\\n".join(path))

'''

# Vectorworks regenerates some plug-in objects only after the script ends. A Simple Stair
# or a Column2 reads a zero box until then, and a save inside the script stores it with
# zero size. Opening that file drops the object with "The object described has zero size".
# The final save therefore runs as a second script.
SAVE_PROGRAM = '''import vs
vs.SaveActiveDocument(%(out)r)
'''

# A dialog is answered by the text it carries. The label of the discard button holds a
# typographic apostrophe, and both spellings are tried.
PROMPTS = [
    ("Do you want to save the changes", ["Don\u2019t Save", "Don't Save"]),
    ("Create Document", ["OK"]),
]


def run(cmd, timeout=60):
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return proc.returncode, proc.stdout + proc.stderr


def cli(*args, timeout=60):
    return run([CLI] + list(args), timeout=timeout)


def osa(script, timeout=40):
    return run(["osascript", "-e", script], timeout=timeout)


def quote(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def live_pid():
    code, out = run(["pgrep", "-f", "MacOS/Vectorworks$"], timeout=20)
    pid = out.split()[0] if out.split() else ""
    if not pid:
        raise RuntimeError("no Vectorworks process is running")
    return pid


def modal(pid):
    """Read the focused window. A sheet attached to a document reports an empty title."""
    code, out = cli("ui-dialog", "--pid", pid, "--expected-executable", EXE, "--timeout-ms", "6000")
    info = {"modal": "", "title": "", "message": "", "buttons": []}
    for line in out.splitlines():
        field = line.split("\t")
        if len(field) < 2:
            continue
        if field[0] == "modal":
            info["modal"] = field[1]
        elif field[0] == "window_title":
            info["title"] = field[1]
        elif field[0] == "message":
            info["message"] = field[1]
        elif field[0] == "button" and field[1].strip():
            info["buttons"].append(field[1])
    return info


def press(pid, label, text):
    code, out = cli("ui-dialog", "--pid", pid, "--expected-executable", EXE,
                    "--expected-text", text, "--press", label, "--timeout-ms", "10000")
    return "status" in out and "pressed" in out


def answer(pid, info, log):
    """Press the button that a known dialog asks for. Return the label or None."""
    for needle, labels in PROMPTS:
        if needle not in info["message"]:
            continue
        for label in labels:
            if label in info["buttons"] and press(pid, label, info["message"]):
                log.append(("answer", "%s -> %s" % (needle, label)))
                time.sleep(2)
                return label
    return None


def wait_for(test, tries=40, pause=0.5):
    for _ in range(tries):
        value = test()
        if value:
            return value
        time.sleep(pause)
    return None


def latest_revision(directory, case):
    pattern = re.compile(re.escape(case) + r"\.rev([0-9]+)\.py$")
    found = []
    if os.path.isdir(directory):
        for name in os.listdir(directory):
            match = pattern.match(name)
            if match:
                found.append((int(match.group(1)), os.path.join(directory, name)))
    return max(found)[1] if found else None


def find_script(case, extra=None):
    roots = [extra] if extra else []
    for base in roots + SCRIPT_ROOTS:
        if not base:
            continue
        for directory in (os.path.join(base, "revisions"), base):
            path = latest_revision(directory, case)
            if path:
                return path
        path = os.path.join(base, case + ".py")
        if os.path.isfile(path):
            return path
    return None


VS_CALL = re.compile(r"\bvs\.[A-Za-z0-9_]+\(.*")


def dry_run_case(case, out_dir, programs_dir, scripts_dir=None):
    """Write the program of one case and list its vs calls."""
    body = find_script(case, scripts_dir)
    if body is None:
        return {"case": case, "status": "no generated script"}
    out_path = os.path.join(out_dir, case + ".vwx")
    try:
        program = write_program(case, body, out_path, programs_dir)
    except (OSError, ValueError) as exc:
        return {"case": case, "status": "dependency", "detail": str(exc)}
    with open(program) as handle:
        lines = handle.read().splitlines()
    # The head defines rosetta_save_reopen() with vs.SaveActiveDocument. The listing starts
    # at the recipe body.
    body_lines = lines[len(PROGRAM_HEAD.splitlines()):]
    calls = [m.group(0) for m in map(VS_CALL.search, body_lines) if m]
    return {"case": case, "status": "dry-run", "script": body, "program": program,
            "calls": calls}


def dependencies(body):
    """Map each dependency the script names to its file under driver/inventory."""
    found = {}
    for did, rel, digest in DEPENDENCY.findall(body):
        path = os.path.join(INVENTORY, rel)
        with open(path, "rb") as handle:
            actual = hashlib.sha256(handle.read()).hexdigest()
        if actual != digest:
            raise ValueError("%s has sha256 %s and the script names %s" % (path, actual, digest))
        found[did] = path
    return found


def write_program(case, body_path, out_path, programs_dir):
    with open(body_path) as handle:
        body = handle.read()
    found = dependencies(body)
    program = os.path.join(programs_dir, case + ".py")
    lines = body.rstrip().splitlines()
    if lines and lines[-1].strip() == "rosetta_save_reopen()":
        lines.pop()
    with open(program, "w") as handle:
        handle.write(PROGRAM_HEAD % {"out": out_path, "dependencies": found})
        handle.write("\n".join(lines) + "\nrosetta_script_end()\n")
    with open(save_program_path(program), "w") as handle:
        handle.write(SAVE_PROGRAM % {"out": out_path})
    return program


def save_program_path(program):
    return program[:-3] + ".save.py"


def settle(pid, log, tries=8):
    """Answer every dialog the application raises until none is left.

    A dialog with no matching rule is dismissed with Cancel where that button exists,
    because this runs while a document is being discarded."""
    for _ in range(tries):
        info = modal(pid)
        if info["modal"] != "true":
            return True
        if answer(pid, info, log):
            continue
        for label in ("Cancel", "OK"):
            if label in info["buttons"]:
                press(pid, label, info["message"])
                log.append(("discard", "%s -> %s" % (info["message"][:60], label)))
                time.sleep(2)
                break
        else:
            log.append(("unanswered", info["message"][:120]))
            return False
    return False


def close_document(pid, log):
    """Close the open document, discarding any unsaved change. An open or save panel that
    a failed case left up reports no Cancel button to ui-dialog, so System Events presses it."""
    if vw_memory.press_in_windows("Cancel"):
        log.append(("discard", "pressed Cancel on a panel"))
        time.sleep(2)
    info = modal(pid)
    if info["modal"] == "true":
        settle(pid, log)
    if not modal(pid)["title"]:
        return True
    cli("ui-menu", "--pid", pid, "--expected-executable", EXE, "--item", "File",
        "--materialize", "--timeout-ms", "15000")
    code, out = cli("ui-menu", "--pid", pid, "--expected-executable", EXE,
                    "--item", "File", "--item", "Close", "--press", "--timeout-ms", "15000")
    log.append(("close", out.strip().replace("\t", " ")[:100]))
    settle(pid, log)
    return wait_for(lambda: modal(pid)["title"] == "" or None, tries=30)


def new_document(pid, log):
    """Click File > New... through System Events and accept the Create Document dialog.
    vwx ui-menu --press refuses File > New...."""
    cli("ui-menu", "--pid", pid, "--expected-executable", EXE, "--item", "File",
        "--materialize", "--timeout-ms", "15000")
    code, out = osa('tell application "System Events" to tell process "Vectorworks" '
                    'to click menu item "New..." of menu 1 of menu bar item "File" of menu bar 1')
    log.append(("new-click", out.strip()[:90]))
    got = wait_for(lambda: "Create Document" in modal(pid)["message"] or None, tries=40)
    if not got:
        raise RuntimeError("the Create Document dialog did not appear")
    if not settle(pid, log):
        raise RuntimeError("the Create Document dialog would not close")
    got = wait_for(lambda: modal(pid)["title"].startswith("Untitled") or None, tries=40)
    if not got:
        raise RuntimeError("no blank document appeared")
    return got


def front_keys(*actions):
    """Send System Events keys, each one only while Vectorworks is the front application.

    System Events types into whatever application is in front, so the script reads the
    front before every key and stops at the first key Vectorworks would not receive."""
    pause.check()
    lines = ['tell application "System Events"']
    for action in actions:
        lines += ['if frontmost of process "Vectorworks" is false then error "front lost"',
                  action]
    code, out = osa("\n".join(lines + ["end tell"]), timeout=120)
    if code != 0:
        raise RuntimeError("a key was due while another application was in front: "
                           + out.strip()[:120])


def send_script(pid, program, log):
    """Run program through native-script-send. True when Vectorworks holds the event: the
    transport is acknowledged or unknown_timeout, or the CLI does not return in 30 s."""
    try:
        _code, out = run([SCRIPT_CLI, "native-script-send", "--pid", pid, "--expected-executable", EXE,
                          "--program", program, "--operator-authorized", "--timeout-ms", "15000"], timeout=30)
    except subprocess.TimeoutExpired:
        log.append(("script-send", "timeout after 30 s"))
        return True
    log.append(("script-send", out.strip().replace("\t", " ")[:100]))
    return "transport\tacknowledged" in out or "transport\tunknown_timeout" in out


def run_script(pid, program, log, panel_tries=40):
    """Run program through native-script-send, or else through Tools > Plug-ins > Run Script...

    After unknown_timeout or a subprocess timeout Vectorworks holds the event, and the script
    can still run. The panel route would run it a second time. It runs after `transport failed`
    and after a refusal before the send, such as `status refused_policy`."""
    if send_script(pid, program, log):
        return
    code, out = osa('tell application "System Events" to tell process "Vectorworks" '
                    'to click menu item "Run Script..." of menu 1 of menu item "Plug-ins" '
                    'of menu 1 of menu bar item "Tools" of menu bar 1')
    log.append(("run-click", out.strip()[:90]))
    got = wait_for(lambda: modal(pid)["title"] == "Choose Script File" or None, tries=panel_tries)
    if not got:
        raise RuntimeError("the Choose Script File panel did not appear")

    with focus.in_front("make-sources-run-script", pid):
        front_keys('keystroke "g" using {command down, shift down}')
        time.sleep(1.5)
        front_keys('keystroke "a" using command down')
        time.sleep(0.5)
        front_keys(*("keystroke " + quote(c) for c in program))
        time.sleep(2.0)
        front_keys("key code 36")
        time.sleep(3.0)
        front_keys("key code 36")
    log.append(("choice", program))
    got = wait_for(lambda: modal(pid)["modal"] != "true" or None, tries=60)
    if not got:
        raise RuntimeError("the Choose Script File panel stayed open")


def choose_menu(pid, path, log):
    """Choose the menu item a recipe names with rosetta_menu() and accept each dialog with OK.

    Some objects have a menu command and no script call. The site model is built by
    AEC > Terrain > Site Model from Source Data... from the selected 3D loci."""
    items = ['menu item %s of menu 1' % quote(name) for name in reversed(path[1:])]
    code, out = osa('tell application "System Events" to tell process "Vectorworks" to click '
                    + ' of '.join(items) + ' of menu bar item %s of menu bar 1' % quote(path[0]))
    log.append(("menu-click", out.strip()[:90]))
    if code != 0:
        raise RuntimeError("the menu item %s did not open" % " > ".join(path))
    quiet = 0
    for _ in range(30):
        time.sleep(2)
        info = modal(pid)
        if info["modal"] != "true":
            quiet += 1
            if quiet >= 3:
                return
            continue
        quiet = 0
        if "OK" not in info["buttons"]:
            raise RuntimeError("a dialog without OK followed the menu: " + info["message"][:100])
        press(pid, "OK", info["message"])
        log.append(("menu-accept", info["message"][:80]))
    raise RuntimeError("dialogs kept opening after the menu " + " > ".join(path))


def wait_for_file(pid, path, log, seconds=180):
    """Wait for the saved document and answer any dialog the recipe raises.

    A recipe that places a parametric object makes the application open that object's
    preferences. `vs.CreateCustomObject("Door", ...)` opens Door Preferences, and the
    script waits there until the dialog is answered. The default button carries the
    values the recipe implies, so a dialog with no matching rule is accepted."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        if os.path.exists(path):
            return True
        info = modal(pid)
        if info["modal"] == "true":
            if answer(pid, info, log):
                continue
            if "OK" in info["buttons"]:
                press(pid, "OK", info["message"])
                log.append(("accept", info["message"][:80]))
                time.sleep(2)
                continue
            log.append(("blocked", info["message"][:100]))
            return False
        time.sleep(1.0)
    return False


def run_case(case, out_dir, programs_dir, scripts_dir=None):
    body = find_script(case, scripts_dir)
    if body is None:
        return {"case": case, "status": "no generated script"}
    out_path = os.path.join(out_dir, case + ".vwx")
    if os.path.exists(out_path):
        os.remove(out_path)
    try:
        program = write_program(case, body, out_path, programs_dir)
    except (OSError, ValueError) as exc:
        return {"case": case, "status": "dependency", "detail": str(exc)}
    log = []
    pid = live_pid()
    try:
        close_document(pid, log)
        new_document(pid, log)
        run_script(pid, program, log)
        if not wait_for_file(pid, out_path + ".ran", log):
            return {"case": case, "status": "script did not end", "log": log, "program": program}
        os.remove(out_path + ".ran")
        if os.path.exists(out_path + ".menu"):
            with open(out_path + ".menu") as handle:
                path = handle.read().split("\n")
            os.remove(out_path + ".menu")
            choose_menu(pid, path, log)
        run_script(pid, save_program_path(program), log, panel_tries=240)
        if not wait_for_file(pid, out_path, log):
            return {"case": case, "status": "no file", "log": log, "program": program}
        size = os.path.getsize(out_path)
        if size == 0:
            return {"case": case, "status": "empty file", "log": log, "program": program}
        # The saved document is the evidence. The window keeps the name it held while it
        # was blank, so the title is recorded rather than tested. The format version
        # line proves the file is a Vectorworks document and not a partial write.
        settle(pid, log)
        title = modal(pid)["title"]
        code, out = cli("info", out_path, timeout=90)
        if "format version" not in out:
            return {"case": case, "status": "unreadable", "bytes": size, "title": title,
                    "log": log, "program": program}
        with open(out_path, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        return {"case": case, "status": "ok", "path": out_path, "bytes": size,
                "sha256": digest, "title": title, "program": program, "log": log}
    except pause.Paused as exc:
        return {"case": case, "status": "paused", "detail": str(exc), "log": log, "program": program}
    except Exception as exc:
        return {"case": case, "status": "error", "detail": str(exc)[:200], "log": log,
                "program": program}


def record(results, batch):
    with open(SOURCE_MAP) as handle:
        rows = [line for line in handle if line.strip()]
    for result in results:
        if result["status"] != "ok":
            continue
        stored = "sources/%s.vwx" % result["case"]
        dest = os.path.join(ROOT, stored)
        if os.path.exists(dest):
            with open(dest, "rb") as handle:
                if hashlib.sha256(handle.read()).hexdigest() != result["sha256"]:
                    result["status"] = "differs from %s" % stored
                    continue
        else:
            shutil.copyfile(result["path"], dest)
            with open(os.path.join(ROOT, "sources", "SOURCES.tsv"), "a") as handle:
                handle.write("\t".join([os.path.basename(stored), result["sha256"], str(result["bytes"]), batch,
                                        result["case"], result["sha256"], str(result["bytes"])]) + "\n")
        rows = [line for line in rows if line.split("\t")[0] != result["case"]]
        rows.append("%s\t%s\t%s\t1\n" % (result["case"], stored, result["sha256"]))
    with open(SOURCE_MAP, "w") as handle:
        handle.writelines(rows)
    print("source-map now holds %d rows" % len(rows))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases", required=True, help="comma separated case ids")
    parser.add_argument("--out-dir", default=SCRATCH + "/generated-sources")
    parser.add_argument("--programs-dir", default=SCRATCH + "/generated-programs")
    parser.add_argument("--scripts-dir", default=None,
                        help="search this directory for the generated script before the pack")
    parser.add_argument("--record", action="store_true",
                        help="copy each new document to sources/ and map it in driver/source-map.tsv")
    parser.add_argument("--batch", help="the batch column of the sources/SOURCES.tsv row --record writes")
    parser.add_argument("--dry-run", action="store_true",
                        help="write each program and print its vs calls without the application")
    args = parser.parse_args()
    if args.record and not args.batch:
        parser.error("--record needs --batch for the sources/SOURCES.tsv row")
    if args.dry_run and args.record:
        parser.error("--dry-run writes no source, so --record has nothing to record")

    os.makedirs(args.out_dir, exist_ok=True)
    os.makedirs(args.programs_dir, exist_ok=True)
    cases = [c.strip() for c in args.cases.split(",") if c.strip()]

    if args.dry_run:
        missing = 0
        for case in cases:
            result = dry_run_case(case, args.out_dir, args.programs_dir, args.scripts_dir)
            print("case\t%s\t%s" % (case, result["status"]))
            if result["status"] != "dry-run":
                missing += 1
                continue
            print("script\t%s" % result["script"])
            print("program\t%s" % result["program"])
            for call in result["calls"]:
                print("call\t%s" % call)
        return 0 if missing == 0 else 1

    with vw_lock.held("make-sources.py --cases " + args.cases):
        driver = run_provenance.require(ROOT, outputs=("sources", "driver/source-map.tsv"), binaries=sorted({CLI, vw_memory.CLI}))
        print("driver\t%s\t%s" % (driver["commit"], driver["branch"]))
        results = []
        memory_log = []
        close = functools.partial(close_document, log=memory_log)
        for case in cases:
            try:
                if vw_memory.live_pid():
                    if vw_memory.KEEP_VW:
                        vw_memory.close_all_documents()
                    vw_memory.before_row(memory_log, close)
                else:
                    vw_memory.restart("not running before " + case, memory_log, close)
            except (pause.Paused, RuntimeError) as exc:
                result = {"case": case, "status": "vw_memory", "detail": str(exc)}
            else:
                result = run_case(case, args.out_dir, args.programs_dir, args.scripts_dir)
            results.append(result)
            print("%-44s %-16s %s" % (case, result["status"],
                                      result.get("bytes") or result.get("detail") or ""))
            sys.stdout.flush()
        try:
            vw_memory.end_of_batch(memory_log, close)
        except (pause.Paused, RuntimeError) as exc:
            print("vw_memory end of batch: %s" % exc)

        if args.record:
            record(results, args.batch)

        failed = [r for r in results if r["status"] != "ok"]
        for result in failed:
            print()
            print("--- %s: %s" % (result["case"], result["status"]))
            for entry in (result.get("log") or [])[-10:]:
                print("    %s %s" % (entry[0], entry[1]))
            if result.get("program"):
                print("    program %s" % result["program"])
        return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
