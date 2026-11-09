#!/bin/sh
# The rule: no recursive force-delete anywhere in this repository.
#
#     tools/no-rm-rf.sh          check the working tree, exit 1 on a finding
#
# Why a check and not a note in a document. A rule that is only written down is followed until the
# next person is in a hurry, and the failure is silent: the command works, on the machine where the
# path happened to be right. This repository already lost that bet once, when `vwtest.sh` deleted a
# document directory because a variable it had been given named that directory instead of the
# scratch copy it expected. The rule is therefore a gate, and the gate fails the build.
#
# What to write instead: `tools/discard.sh`. It moves a tree into the trash and deletes only a path it
# composes itself.
#
# The pattern is matched, not the intent, because intent is not checkable. Code is scanned, and a
# mention inside a comment is not a command - comments are dropped before matching.
#
# The WORKING TREE is scanned, not `git ls-files`. The first version of this check asked git, and a
# planted `rm -rf "$VW_RUN"` in an untracked file went straight past it - which is the wrong answer,
# because a script is dangerous from the moment it exists, not from the moment it is committed, and
# `tools/validate.sh` runs this before the commit that would have made it visible.
#
# Reports under tools/research/ are a separate matter and are listed rather than failed. A report
# records the commands that were actually run, and rewriting a record to match a later rule is how
# evidence turns into fiction. New code is held to the rule; old records are left as they are.
set -eu

# The tree to scan is an argument, defaulting to this file's own checkout. `tools/validate.sh` passes
# the tree UNDER TEST while running this file FROM ANOTHER CHECKOUT, for the same reason the visible-diff
# baseline comes from there: a branch that supplies its own gate can also delete it, and a branch that
# predates the policy still has to comply with it.
ROOT=${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
ROOT=$(CDPATH= cd -- "$ROOT" 2>/dev/null && pwd) || { printf 'no-rm-rf: no such tree\n' >&2; exit 2; }

# A recursive remove, in every form it can be written: `rm -rf`, `rm -fr`, `rm -Rf`, `rm -r -f`,
# `rm -f -r`, `rm -r --force`, `rm --recursive --force`, `rm --force --recursive`, `rm -r` on its
# own, and behind `xargs` or an absolute path.
#
# The flag has to sit in the FLAG POSITION, immediately after `rm` or after other flags, and a flag
# may be short (`-f`) or long (`--force`). Allowing arbitrary tokens in between matched `-ar` inside a
# path and reported `rm -f $W/tools/research/` and `.../compare-arc/*.txt` as recursive deletes. A
# detector that cries wolf gets switched off, which is worse than no detector, so the pattern is
# anchored to where flags actually are.
# Requiring -f as well was the first attempt and it missed `rm -r -f`, which is the same command; a
# recursive remove deletes a tree with or without -f, so recursion alone is what is matched. A word
# boundary before `rm` keeps `charm` and `alarm` out of it.
PATTERN='(^|[^a-zA-Z0-9_])rm([[:space:]]+--?[a-zA-Z]+)*[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)'

# Not ours to police, or not source: the vendored corpus, the sample documents, and build output.
PRUNE='( -name .git -o -name samples -o -name vendor -o -name zig-out -o -name .zig-cache -o -name zig-cache -o -name node_modules -o -name __pycache__ ) -prune'

# A gate that has never been shown to fail is not a gate, and the failure mode of this one is silent:
# a broken pattern reports "ok" over a tree full of the thing it was written to forbid. So the
# detector is tested against known cases on every run. It costs a few milliseconds and it is the
# difference between a check and the appearance of one.
selftest() {
    _st_fail=0
    while IFS= read -r _st_line; do
        if ! printf '%s\n' "$_st_line" | grep -qE "$PATTERN"; then
            printf '  FAIL  selftest: this should be caught and is not: %s\n' "$_st_line"
            _st_fail=1
        fi
    done <<'MUST_CATCH'
rm -rf "$D"
rm -fr "$D"
rm -Rf "$D"
rm -r -f "$D"
rm -f -r "$D"
rm -r --force "$D"
rm --recursive --force "$D"
rm --force --recursive "$D"
rm -r "$D"
xargs rm -rf "$D"
/bin/rm -rf "$D"
MUST_CATCH
    while IFS= read -r _st_line; do
        if printf '%s\n' "$_st_line" | grep -qE "$PATTERN"; then
            printf '  FAIL  selftest: this should be allowed and is flagged: %s\n' "$_st_line"
            _st_fail=1
        fi
    done <<'MUST_NOT_CATCH'
rm -f "$D"
rm "$D"
rmdir "$D"
charm -r "$D"
alarm -rf "$D"
rm -i -v "$D"
MUST_NOT_CATCH
    return "$_st_fail"
}

code_hits=0
doc_hits=0

# A mention inside a comment is not a command, so comment lines are dropped before matching. The
# pattern is banned where a shell would actually run it.
if ! selftest; then
    printf 'no-rm-rf: FAIL the detector itself is broken; the scan below cannot be trusted\n'
    exit 1
fi

find "$ROOT" $PRUNE -o -type f \
    \( -name '*.sh' -o -name '*.bash' -o -name '*.zsh' -o -name '*.py' -o -name '*.zig' \
       -o -name Makefile -o -name '*.mk' \) -print0 > /tmp/no-rm-rf.code.$$
# One grep over the whole list, then the report loop over the files it named. The report loop used to
# run a grep per file: 549 files, 549 processes, 17.8 s of a 341 s gate (measured 2026-10-03). The
# list is NUL-separated because a path may contain a space, and the candidate list is written to a file
# because a `while` in a pipeline runs in a subshell and would lose code_hits.
xargs -0 -n 64 grep -lE "$PATTERN" < /tmp/no-rm-rf.code.$$ 2>/dev/null > /tmp/no-rm-rf.cand.$$ || true
while IFS= read -r f; do
    # This file is the detector. Its selftest holds the forbidden strings as data - they are inputs to
    # a test, not commands that anything runs - so it cannot be scanned by itself.
    case "${f#$ROOT/}" in tools/no-rm-rf.sh) continue ;; esac
    hits=$(grep -nE "$PATTERN" -- "$f" 2>/dev/null | grep -vE ':[[:space:]]*#' || true)
    [ -n "$hits" ] || continue
    printf '  FAIL  %s\n' "${f#$ROOT/}"
    printf '%s\n' "$hits" | sed 's/^/          /'
    code_hits=$((code_hits + 1))
done < /tmp/no-rm-rf.cand.$$
scanned=$(tr '\0' '\n' < /tmp/no-rm-rf.code.$$ | grep -c . || true)
find "$ROOT" $PRUNE -o -type f \( -name '*.md' -o -name '*.txt' -o -name '*.rst' \) -print0 > /tmp/no-rm-rf.docs.$$
xargs -0 -n 64 grep -lE "$PATTERN" < /tmp/no-rm-rf.docs.$$ 2>/dev/null > /tmp/no-rm-rf.dcand.$$ || true
while IFS= read -r f; do
    hits=$(grep -nE "$PATTERN" -- "$f" 2>/dev/null || true)
    [ -n "$hits" ] || continue
    printf '  note  %s (a record of a command that was run; not rewritten)\n' "${f#$ROOT/}"
    printf '%s\n' "$hits" | sed 's/^/          /'
    doc_hits=$((doc_hits + 1))
done < /tmp/no-rm-rf.dcand.$$
rm -f /tmp/no-rm-rf.code.$$ /tmp/no-rm-rf.docs.$$ /tmp/no-rm-rf.cand.$$ /tmp/no-rm-rf.dcand.$$

if [ "$code_hits" -gt 0 ]; then
    printf 'no-rm-rf: FAIL %s code file(s) of %s scanned with a recursive force-delete\n' \
        "$code_hits" "$scanned"
    printf 'no-rm-rf: use tools/discard.sh, which moves the tree into the trash and deletes only a path it built\n'
    exit 1
fi

printf 'no-rm-rf: ok 0 of %s code file(s) with a recursive force-delete; %s record(s) quote the pattern\n' \
    "$scanned" "$doc_hits"
exit 0
