#!/bin/sh
# Run the rosetta corpus workflow stages in order.
#
# Usage: sh driver/ui/run-all.sh [all|sources|export|verify|index] [--dry-run] [--pid N]
#        sh driver/ui/run-all.sh --status
#
# Stages, in the order that `all` runs them:
#   sources  make-sources.py --record for each case that has a pending pair and no source document
#   export   sweep-ui.py per format, sweep-scripted.sh for stl and sat, pending pairs only
#   verify   verify-artifacts.py --all, then pdf-ink.py on every PDF under files/
#   index    coverage.py, audit-corpus.py, inert-pairs.py, mesh-topology.py, verify-artifacts.py
#            --write-index, reader-audit.py --write and build-index.py. The stage stops at
#            the first step that exits non-zero.
#
# audit-corpus.py and reader-audit.py run under $ROSETTA_READER_PYTHON, a Python with ezdxf 1.4.5
# and Pillow. reader-audit.py also needs LibreDWG dwgread and qpdf on PATH. driver/WORKFLOW.md "Inputs outside the store" says how to install them.
#
# A pending pair is a row of ledger/required-pairs.tsv whose state in coverage.py is
# `unaccounted`. The export stage exports pending pairs only, so it never replaces a
# file under files/. To export a held pair again, run sweep-ui.py by hand.
#
# sources and export need a running Vectorworks and an unsandboxed operator shell.
# With --dry-run they print the work list and start nothing. verify and index need no
# application, and --dry-run has no effect on them.
#
# Before sources or export drives the application, the script takes the lock directory
# $ROSETTA_TMP/lock and writes $ROSETTA_TMP/lock/owner.tsv. The columns are holder (the
# pid of this script), vw_pid, found (the pids that `pgrep -f "MacOS/Vectorworks$"`
# returns) and started (UTC). An EXIT trap removes the lock. --pid N names the Vectorworks
# process. Without --pid, the script uses vw_pid from a lock that an ancestor process
# holds. The drivers drive the first pgrep match, so the stage refuses unless pgrep
# returns exactly vw_pid. A lock held by any other process stops sources, export and all,
# with or without --dry-run. --status prints the lock owner and the digest check of the vwx
# binary against driver/bin/BUILD.tsv, and exits 0.
#
# verify prints two results. `artifacts` is the verify-artifacts.py exit code. `pages`
# counts the pdf-ink.py verdicts. The stage fails when verify-artifacts.py exits non-zero,
# or when a PDF of a pdf row in ledger/required-pairs.tsv reads `blank` or `error`.
#
# Scratch state goes under $ROSETTA_TMP, default
# /Volumes/volxxxx/Caches/tmp/rosetta-run-<YYYYMMDD>. TMPDIR is set to $ROSETTA_TMP/tmp.
# Each stage writes $ROSETTA_TMP/logs/<stage>.log and prints one line:
#   stage <name> PASS|FAIL exit <code> log <path>
# The script exits 0 when every selected stage passes, and 1 otherwise. Bad arguments
# and a refused scratch root exit 2. A lock held by another process exits 4. A stage
# that refuses to drive the application prints `stage <name> FAIL exit 4`.
set -u

STORE=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
UI="$STORE/driver/ui"
STAGE=all
DRY=0
STATUS=0
PID_ARG=
usage() {
    printf 'usage: run-all.sh [all|sources|export|verify|index] [--dry-run] [--pid N]\n' >&2
    printf '       run-all.sh --status\n' >&2
    exit 2
}
while [ $# -gt 0 ]; do
    case "$1" in
        all|sources|export|verify|index) STAGE=$1 ;;
        --dry-run) DRY=1 ;;
        --status) STATUS=1 ;;
        --pid)
            [ $# -ge 2 ] || usage
            PID_ARG=$2
            shift
            ;;
        *) usage ;;
    esac
    shift
done
case "$PID_ARG" in
    *[!0-9]*) usage ;;
esac

ROSETTA_TMP=${ROSETTA_TMP:-${ROSETTA_VOLUME:-/Volumes/volxxxx}/Caches/tmp/rosetta-run-$(date +%Y%m%d)}
case "$ROSETTA_TMP" in
    /*) ;;
    *) printf 'ROSETTA_TMP must be an absolute path: %s\n' "$ROSETTA_TMP" >&2; exit 2 ;;
esac
case "$ROSETTA_TMP/" in
    "$STORE"/*) printf 'ROSETTA_TMP is inside the store: %s\n' "$ROSETTA_TMP" >&2; exit 2 ;;
esac
READER_PYTHON=${ROSETTA_READER_PYTHON:-${ROSETTA_VOLUME:-/Volumes/volxxxx}/Caches/tmp/rosetta-readers/bin/python}
mkdir -p "$ROSETTA_TMP/tmp" "$ROSETTA_TMP/logs" || exit 2
if git -C "$ROSETTA_TMP" rev-parse --show-toplevel >/dev/null 2>&1; then
    printf 'ROSETTA_TMP is inside a git worktree: %s\n' "$ROSETTA_TMP" >&2
    exit 2
fi
mkdir -p "$ROSETTA_TMP/work-sources" "$ROSETTA_TMP/page-fit" "$ROSETTA_TMP/generated-sources" \
    "$ROSETTA_TMP/generated-programs" "$ROSETTA_TMP/pdf-ink" || exit 2

# The drivers read ROSETTA_TMP for their scratch root. Bytecode caches would land
# beside the drivers in the store, so Python writes none.
export ROSETTA_TMP
export TMPDIR="$ROSETTA_TMP/tmp"
export PYTHONDONTWRITEBYTECODE=1
PENDING="$ROSETTA_TMP/pending-pairs.tsv"
failed=0

say() {
    printf '%s\n' "$*"
}

# note prints to the stage log and to the terminal.
note() {
    printf '%s\n' "$*"
    printf '%s\n' "$*" >&3
}

LOCK="$ROSETTA_TMP/lock"
LOCK_TAKEN=0
LOCK_VW=

# Refusals go to the stage log on stdout and to the terminal on fd 3.
exec 3>&2
refuse() {
    printf '%s\n' "$*"
    printf '%s\n' "$*" >&3
}

alive() {
    [ -n "$1" ] && ps -p "$1" >/dev/null 2>&1
}

is_ancestor() {
    p=$$
    while [ -n "$p" ] && [ "$p" -gt 1 ]; do
        [ "$p" = "$1" ] && return 0
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    done
    return 1
}

lock_field() {
    awk -F '\t' -v c="$1" 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == c) k = i }
        NR == 2 && k { print $k }' "$LOCK/owner.tsv" 2>/dev/null
}

say_alive() {
    if alive "$1"; then printf 'alive'; else printf 'dead'; fi
}

print_status() {
    say "lock $LOCK"
    if [ ! -d "$LOCK" ]; then
        say "lock: none"
    else
        holder=$(lock_field holder)
        vw=$(lock_field vw_pid)
        say "holder ${holder:--} $(say_alive "$holder")"
        say "vw_pid ${vw:--} $(say_alive "$vw")"
        say "found $(lock_field found)"
        say "started $(lock_field started)"
    fi
    say "pgrep MacOS/Vectorworks\$: $(pgrep -f "MacOS/Vectorworks$" | paste -sd, -)"
    cli=${VWX_CLI:-$STORE/driver/bin/vwx}
    if [ ! -x "$cli" ]; then
        say "vwx $cli: absent. sh driver/native/build.sh builds it"
    else
        sha=$(shasum -a 256 "$cli" | cut -d' ' -f1)
        want=$(awk -F '\t' '$1 == "driver/bin/vwx" { print $2 }' "$STORE/driver/bin/BUILD.tsv")
        if [ "$sha" = "$want" ]; then match="matches driver/bin/BUILD.tsv"; else match="differs from driver/bin/BUILD.tsv"; fi
        say "vwx $cli sha256 $sha $match"
    fi
}

# A lock held by an ancestor names the process to drive. Any other lock stops the
# stages that drive the application.
check_lock() {
    [ -d "$LOCK" ] || return 0
    holder=$(lock_field holder)
    vw=$(lock_field vw_pid)
    started=$(lock_field started)
    if [ -n "$holder" ] && is_ancestor "$holder"; then
        if [ -n "$PID_ARG" ] && [ "$PID_ARG" != "$vw" ]; then
            refuse "refused: --pid $PID_ARG differs from vw_pid $vw in $LOCK/owner.tsv"
            return 4
        fi
        LOCK_VW=$vw
        return 0
    fi
    refuse "refused: lock $LOCK is held"
    refuse "holder ${holder:--} $(say_alive "$holder"), vw_pid ${vw:--} $(say_alive "$vw"), started ${started:--}"
    if ! alive "$holder"; then
        refuse "the holder is dead. Check that no session drives vw_pid ${vw:--}, then discard $LOCK"
    fi
    return 4
}

# Names the process, checks that the drivers will drive it, and takes the lock.
claim_app() {
    [ "$LOCK_TAKEN" -eq 1 ] && return 0
    pid=${PID_ARG:-$LOCK_VW}
    if [ -z "$pid" ]; then
        refuse "refused: no lock at $LOCK and no --pid. Name the Vectorworks process with --pid N"
        return 4
    fi
    found=$(pgrep -f "MacOS/Vectorworks$" | paste -sd, -)
    if [ -z "$found" ]; then
        refuse "no running Vectorworks process"
        return 3
    fi
    if [ "$found" != "$pid" ]; then
        refuse "refused: pgrep -f MacOS/Vectorworks\$ returns ${found}. The drivers drive the first match. The named pid is $pid"
        return 4
    fi
    [ -n "$LOCK_VW" ] && return 0
    if ! mkdir "$LOCK" 2>/dev/null; then
        refuse "refused: lock $LOCK appeared after the start check"
        return 4
    fi
    LOCK_TAKEN=1
    printf 'holder\tvw_pid\tfound\tstarted\n%s\t%s\t%s\t%s\n' "$$" "$pid" "$found" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$LOCK/owner.tsv"
    say "lock taken: holder $$ vw_pid $pid"
}

release_lock() {
    [ "$LOCK_TAKEN" -eq 1 ] || return 0
    [ "$(lock_field holder)" = "$$" ] || return 0
    rm -f "$LOCK/owner.tsv"
    rmdir "$LOCK"
    LOCK_TAKEN=0
}
trap release_lock EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# coverage.py without --write reads the store and writes only the pending list.
write_pending() {
    python3 "$UI/coverage.py" --pending "$PENDING"
}

stage_sources() {
    write_pending || return 1
    cases=$(cut -f1 "$PENDING" | sort -u | while read -r case; do
        grep -q "^$case	" "$STORE/driver/source-map.tsv" || printf '%s\n' "$case"
    done | paste -sd, -)
    say "cases without a source document: ${cases:-none}"
    [ -z "$cases" ] && return 0
    [ "$DRY" -eq 1 ] && return 0
    claim_app || return
    python3 "$UI/make-sources.py" --cases "$cases" --record --batch "run-all-$(date -u +%Y-%m-%d)" \
        --out-dir "$ROSETTA_TMP/generated-sources" \
        --programs-dir "$ROSETTA_TMP/generated-programs"
}

stage_export() {
    write_pending || return 1
    say "pending pairs: $(wc -l <"$PENDING" | tr -d ' ')"
    [ -s "$PENDING" ] || return 0
    if [ "$DRY" -eq 0 ]; then
        claim_app || return
    fi
    code=0
    for key in $(cut -f2,3 "$PENDING" | sort -u | tr '\t' '|'); do
        profile=${key%|*}
        fmt=${key#*|}
        cases=$(awk -F '\t' -v p="$profile" '$2 == p { print $1 }' "$PENDING" | paste -sd, -)
        case "$fmt" in
            dwg|dxf|png|pdf|obj|fbx|3ds|parasolid|iges|vwx)
                if [ "$DRY" -eq 1 ]; then
                    python3 "$UI/sweep-ui.py" --format "$fmt" --profile "$profile" --only "$cases" --dry-run || code=1
                else
                    say "sweep-ui.py --format $fmt --profile $profile --only $cases"
                    python3 "$UI/sweep-ui.py" --format "$fmt" --profile "$profile" --only "$cases" || code=1
                fi
                ;;
            stl|sat)
                for case in $(printf '%s' "$cases" | tr ',' ' '); do
                    say "sweep-scripted.sh --formats $fmt --only $case"
                    [ "$DRY" -eq 0 ] || continue
                    bash "$STORE/driver/scripted/sweep-scripted.sh" --formats "$fmt" --only "$case"
                    sc=$?
                    if [ "$sc" -eq 3 ]; then
                        say "Vectorworks gone during $case $profile: start it and try once more"
                        python3 "$STORE/driver/vw_memory.py" --restart "gone after $case $profile" || return 1
                        bash "$STORE/driver/scripted/sweep-scripted.sh" --formats "$fmt" --only "$case"
                        sc=$?
                    fi
                    [ "$sc" -eq 0 ] || code=1
                    if [ "$sc" -eq 3 ]; then
                        python3 "$STORE/driver/vw_memory.py" --restart "gone again after $case $profile" || return 1
                    fi
                done
                ;;
            *)
                say "no export route for format $fmt, profile $profile, cases $cases"
                code=1
                ;;
        esac
    done
    return $code
}

stage_verify() {
    code=0
    python3 "$UI/verify-artifacts.py" --all --quiet
    va=$?
    if [ "$va" -eq 0 ]; then
        note "artifacts: consistent, verify-artifacts.py exit 0"
    else
        note "artifacts: problems, verify-artifacts.py exit $va"
        code=1
    fi
    list="$ROSETTA_TMP/pdf-list.txt"
    find "$STORE/files" -type f -name '*.pdf' | sort >"$list"
    say "pdfs: $(wc -l <"$list" | tr -d ' ')"
    [ -s "$list" ] || { note "pages: no PDF under files/"; return $code; }
    # pdf-ink.py exits 1 when any page is not `ink`. The verdict column decides.
    tr '\n' '\0' <"$list" | xargs -0 python3 "$UI/pdf-ink.py" --out-dir "$ROSETTA_TMP/pdf-ink" \
        >"$ROSETTA_TMP/pdf-ink.tsv"
    say "pdf-ink.py exit $?, table $ROSETTA_TMP/pdf-ink.tsv"
    # A PDF is required when its case has a pdf row in ledger/required-pairs.tsv.
    awk -F '\t' -v files="$STORE/files/" '
        FNR == NR { if ($3 == "pdf") req[$1] = 1; next }
        FNR == 1 { next }
        {
            v = $NF
            sub(/ .*/, "", v)
            n[v]++
            rel = $1
            if (index(rel, files) == 1) rel = substr(rel, length(files) + 1)
            c = rel
            sub(/\/.*/, "", c)
            if ((v == "blank" || v == "error") && (c in req)) { bad++; print "required " v ": files/" rel }
        }
        END {
            printf "pages: readable %d, faint %d, blank %d, error %d, required blank or error %d\n",
                n["ink"], n["small"], n["blank"], n["error"], bad
            exit (bad > 0 ? 1 : 0)
        }' "$STORE/ledger/required-pairs.tsv" "$ROSETTA_TMP/pdf-ink.tsv" >"$ROSETTA_TMP/pages.txt"
    pages=$?
    cat "$ROSETTA_TMP/pages.txt"
    cat "$ROSETTA_TMP/pages.txt" >&3
    [ "$pages" -eq 0 ] || code=1
    return $code
}

# Each step reads what the steps before it wrote, so the stage stops at the first failed step.
stage_index() {
    for step in "coverage.py --write" "audit-corpus.py --write" "inert-pairs.py --write" "mesh-topology.py --write" \
        "verify-artifacts.py --all --quiet --write-index $STORE/ledger/corpus-index.tsv"; do
        # $step is split on spaces on purpose. No argument in the list holds a space.
        py=python3
        case $step in audit-corpus.py*) py=$READER_PYTHON ;; esac
        "$py" "$UI"/$step
        rc=$?
        say "$step exit $rc"
        [ "$rc" -eq 0 ] || return 1
    done
    "$READER_PYTHON" "$STORE/driver/reader-audit.py" --write
    rc=$?
    say "reader-audit.py --write exit $rc"
    [ "$rc" -eq 0 ] || return 1
    python3 "$STORE/driver/build-index.py" && python3 "$STORE/driver/build-index.py" --check
    rc=$?
    say "build-index.py exit $rc"
    [ "$rc" -eq 0 ] || return 1
}

run_stage() {
    name=$1
    log="$ROSETTA_TMP/logs/$name.log"
    "stage_$name" >"$log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'stage %s PASS exit 0 log %s\n' "$name" "$log"
    else
        failed=$((failed + 1))
        printf 'stage %s FAIL exit %s log %s\n' "$name" "$rc" "$log"
    fi
}

say "store $STORE"
say "scratch $ROSETTA_TMP"
if [ "$STATUS" -eq 1 ]; then
    print_status
    exit 0
fi
[ "$DRY" -eq 1 ] && say "dry run"
case "$STAGE" in
    all|sources|export) check_lock >/dev/null || exit 4 ;;
esac
case "$STAGE" in
    all)
        for name in sources export verify index; do
            run_stage "$name"
        done
        ;;
    *) run_stage "$STAGE" ;;
esac
printf 'stages failed: %d\n' "$failed"
[ "$failed" -eq 0 ]
