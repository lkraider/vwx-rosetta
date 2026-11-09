#!/usr/bin/env python3
"""Hold the steps that bring Vectorworks to the front while the person uses the screen.

The operator writes PAUSE with one line, the end time in ISO 8601 UTC, and deletes it on
resume. A file changed more than TOUCH_SLACK seconds after the past time it holds counts as paused.
batch.py writes its start time there, so `touch PAUSE` during a run pauses it. A step that takes the front calls check() first, and sweep-ui calls it before each pair. Export rows that run in the
background do not read the file. A file that cannot be read, or whose time does not
parse, counts as paused.

Usage: pause.py --active    exit 0 and print the end time while a pause holds, else exit 1
"""
import datetime
import os
import sys

VOLUME = os.environ.get("ROSETTA_VOLUME", "/Volumes/volxxxx")
PAUSE = os.environ.get("ROSETTA_PAUSE", VOLUME + "/Caches/tmp/rosetta-pause")
TOUCH_SLACK = 2


class Paused(RuntimeError):
    pass


def paused_until(path=None, now=None):
    """The end time text while a pause holds, else None."""
    try:
        with open(path or PAUSE) as handle:
            text = handle.read().strip()
            touched = os.fstat(handle.fileno()).st_mtime
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError):
        return "unreadable"
    now = now or datetime.datetime.now(datetime.timezone.utc)
    try:
        end = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return text or "unreadable"
    if end.tzinfo is None:
        end = end.replace(tzinfo=datetime.timezone.utc)
    if end > now:
        return text
    if touched > end.timestamp() + TOUCH_SLACK:
        return "%s, touched at %s" % (text, datetime.datetime.fromtimestamp(
            touched, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    return None


def check():
    until = paused_until()
    if until:
        raise Paused("paused until " + until)


if __name__ == "__main__":
    if sys.argv[1:] != ["--active"]:
        raise SystemExit(__doc__)
    until = paused_until()
    if until:
        print(until)
    sys.exit(0 if until else 1)
