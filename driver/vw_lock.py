#!/usr/bin/env python3
"""Let one process drive Vectorworks at a time.

The lock is the directory $ROSETTA_TMP/lock. Its owner.tsv names the pid, the start time
and the command of the holder. batch.py takes it for a whole run and starts each driver with
ROSETTA_LOCK set to the lock path and ROSETTA_LOCK_OWNER set to its pid. A driver whose
ROSETTA_LOCK_OWNER matches the pid in owner.tsv runs under that lock. A driver started by hand
takes the lock itself and removes it when it ends. When another process holds the lock, the
driver prints the holder and exits 2. A process that dies by SIGKILL leaves the lock behind.
Remove it by hand after checking that its pid no longer runs.

Usage: vw_lock.py --mine           exit 0 when this process runs under the lock of ROSETTA_LOCK_OWNER
       vw_lock.py COMMAND [ARGS]   run COMMAND under the lock, or exit 2 when another process holds it
"""
import contextlib
import datetime
import os
import subprocess
import sys

VOLUME = os.environ.get("ROSETTA_VOLUME", "/Volumes/volxxxx")
LOCK = os.environ.get("ROSETTA_LOCK") or os.path.join(
    os.environ.get("ROSETTA_TMP", VOLUME + "/Caches/tmp/rosetta-corpus"), "lock")


class Held(RuntimeError):
    pass


def owner(path=None):
    """The (pid, started, command) row of owner.tsv, or None."""
    try:
        with open(os.path.join(path or LOCK, "owner.tsv")) as handle:
            rows = handle.read().splitlines()[1:]
    except OSError:
        return None
    return tuple((rows[0].split("\t") + ["", ""])[:3]) if rows else None


def mine(path=None):
    holder = owner(path)
    return bool(holder and holder[0] == os.environ.get("ROSETTA_LOCK_OWNER"))


def take(command, path=None):
    path = path or LOCK
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        os.mkdir(path)
    except FileExistsError:
        holder = owner(path)
        if holder:
            raise Held("another process holds %s: pid %s, %s, started %s" % (path, holder[0], holder[2], holder[1]))
        raise Held("another process holds %s, which has no owner.tsv" % path)
    started = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(os.path.join(path, "owner.tsv"), "w") as handle:
        handle.write("pid\tstarted\tcommand\n%d\t%s\t%s\n" % (os.getpid(), started, command))


def release(path=None):
    path = path or LOCK
    try:
        os.remove(os.path.join(path, "owner.tsv"))
    except OSError:
        pass
    os.rmdir(path)


@contextlib.contextmanager
def held(command, path=None):
    """Run the block under the lock. Exits 2 when another process holds it."""
    if mine(path):
        yield
        return
    try:
        take(command, path)
    except Held as exc:
        words = command.split()
        name = next((os.path.basename(w) for w in words if w.endswith((".py", ".sh"))), words[0])
        print("%s: refused: %s" % (name, exc), file=sys.stderr)
        raise SystemExit(2)
    try:
        yield
    finally:
        release(path)


def main(argv):
    if argv == ["--mine"]:
        return 0 if mine() else 1
    if not argv or argv[0].startswith("-"):
        raise SystemExit(__doc__)
    with held(" ".join(argv)):
        return subprocess.call(argv, env=dict(os.environ, ROSETTA_LOCK=LOCK, ROSETTA_LOCK_OWNER=owner()[0]))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
