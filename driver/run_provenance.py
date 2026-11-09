"""The commit a Vectorworks run starts from, and the refusal of a worktree that does not hold it.

A run drives Vectorworks only from a worktree with no uncommitted code whose HEAD is the local
`main` tip, or the tip of one branch on top of that `main` tip whose commit a reviewer listed in
REVIEWED. REVIEWED holds one row per reviewed commit with the full commit id in the first
tab-separated field. Every vwx binary the run calls must have a sha256 that driver/bin/BUILD.tsv
lists at HEAD. driver/bin is outside git, so git status does not see a changed binary. A run writes into `runs/` and `files/`, so changes there do not count as
uncommitted code. Each run record stores the result of `state()`.

Usage: run_provenance.py ROOT [--binary PATH]... [OUTPUT...]
       print the state as JSON, or exit 3 with the refusal
"""
import hashlib
import json
import os
import subprocess
import sys

# batch.py sets ROSETTA_BASE to the commit its evidence worktree started from, so a merge to main
# during the run does not refuse the later calls.
BASE = os.environ.get("ROSETTA_BASE", "main")
OUTPUT_PATHS = (":(exclude)runs", ":(exclude)files", ":(exclude)AGENTS.md")
VOLUME = os.environ.get("ROSETTA_VOLUME", "/Volumes/volxxxx")
REVIEWED = os.environ.get("ROSETTA_REVIEWED", VOLUME + "/Caches/tmp/rosetta-reviewed.tsv")


def git(root, *args):
    return subprocess.run(["git", "-C", root] + list(args), capture_output=True, text=True)


def reviewed_commits(path):
    try:
        with open(path) as handle:
            return {line.split("\t", 1)[0].strip() for line in handle if line.strip()}
    except FileNotFoundError:
        return set()


def sha256(path):
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
    except OSError:
        return ""
    return digest.hexdigest()


def built_binaries(root):
    """The sha256 column of driver/bin/BUILD.tsv at HEAD."""
    text = git(root, "show", "HEAD:driver/bin/BUILD.tsv").stdout
    rows = [line.split("\t") for line in text.splitlines()[1:]]
    return {row[1] for row in rows if len(row) > 1}


def state(root, base=BASE, outputs=(), reviewed=None, binaries=()):
    """outputs names more paths the program writes, which then do not count as uncommitted."""
    excluded = OUTPUT_PATHS + tuple(":(exclude)" + path for path in outputs)
    status = git(root, "status", "--porcelain", "-z", "--untracked-files=all", "--", ".", *excluded)
    entries = [e for e in status.stdout.split("\0") if len(e) > 3]
    ahead = git(root, "rev-list", "--count", base + "..HEAD").stdout.strip()
    commit = git(root, "rev-parse", "HEAD").stdout.strip()
    base_commit = git(root, "rev-parse", base).stdout.strip()
    reviewed = reviewed or REVIEWED
    tips = git(root, "for-each-ref", "--points-at", "HEAD", "--format=%(refname:short)", "refs/heads").stdout.split()
    return {
        "commit": commit,
        "branch": git(root, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip(),
        "base": base,
        "base_commit": base_commit,
        "contains_base": bool(base_commit) and git(root, "merge-base", "HEAD", base).stdout.strip() == base_commit,
        "ahead_of_base": int(ahead) if ahead.isdigit() else None,
        "branch_tips": sorted(tip for tip in tips if tip != base),
        "reviewed_list": reviewed,
        "reviewed": bool(commit) and commit in reviewed_commits(reviewed),
        "binaries": [{"path": os.path.abspath(path), "sha256": sha256(path)} for path in binaries],
        "built_binaries": sorted(built_binaries(root)),
        "dirty": bool(entries) or status.returncode != 0,
        "uncommitted": sorted(e[3:] for e in entries)[:20],
    }


def refusal(st):
    """The reason a run must not start from st, or None."""
    if not st["commit"]:
        return "the worktree has no commit"
    if not st["contains_base"]:
        return "HEAD %s does not contain %s %s" % (st["commit"][:7], st["base"], st["base_commit"][:7])
    if st["dirty"]:
        return "uncommitted changes: " + ", ".join(st["uncommitted"]) if st["uncommitted"] else "git status failed"
    unlisted = [b["path"] for b in st["binaries"] if not b["sha256"] or b["sha256"] not in st["built_binaries"]]
    if unlisted:
        return "binary not in driver/bin/BUILD.tsv at HEAD: " + ", ".join(unlisted)
    if st["commit"] == st["base_commit"]:
        return None
    if len(st["branch_tips"]) != 1:
        return "HEAD %s is the tip of %d branches, and a run needs exactly one" % (st["commit"][:7], len(st["branch_tips"]))
    if not st["reviewed"]:
        return "HEAD %s of branch %s is not in the reviewed list %s" % (st["commit"][:7], st["branch_tips"][0], st["reviewed_list"])
    return None


def require(root, base=BASE, outputs=(), reviewed=None, binaries=()):
    """Return the state of root, or stop the program when a run must not start from it."""
    st = state(root, base, outputs, reviewed, binaries)
    reason = refusal(st)
    if reason:
        raise SystemExit("refused to drive Vectorworks from %s: %s" % (root, reason))
    return st


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    args, binaries, outputs = sys.argv[2:], [], []
    while args:
        if args[0] == "--binary" and len(args) > 1:
            binaries.append(args[1])
            args = args[2:]
        else:
            outputs.append(args.pop(0))
    st = state(sys.argv[1], outputs=tuple(outputs), binaries=binaries)
    reason = refusal(st)
    if reason:
        print("refused to drive Vectorworks from %s: %s" % (sys.argv[1], reason), file=sys.stderr)
        sys.exit(3)
    print(json.dumps(st, sort_keys=True))
