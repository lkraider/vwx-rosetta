#!/bin/sh
# Run every store check in order and exit 1 when any step exits non-zero.
#
# Usage: sh driver/ui/validate-store.sh [--write]
#
# The default mode reads the store and writes nothing under it. coverage.py and
# audit-corpus.py run without --write. inert-pairs.py --check compares
# ledger/inert-pairs.tsv against ledger/corpus-audit.json. export-queue.py --check
# compares driver/ui/export-queue.jsonl against ledger/coverage.tsv and the routes table.
# reader-audit.py --check reads every DXF, DWG, PDF, SAT and STEP file again and compares the rows
# with ledger/reader-audit.tsv. It runs under $ROSETTA_READER_PYTHON, a Python with
# ezdxf 1.4.5, and needs LibreDWG dwgread and qpdf on PATH. test_reader_audit.py runs under the
# same Python. mesh-topology.py --check measures
# every 3DS, OBJ, FBX and glTF file again and compares the rows with ledger/mesh-topology.tsv.
# plugin-presence.py --check reads every export of each combined source again and compares the
# rows with ledger/plugin-presence.tsv. It runs under $ROSETTA_READER_PYTHON and needs dwgread.
# export-inventory.py builds the covering lists from that table.
# --write passes --write to coverage.py and audit-corpus.py. Those steps then replace
# ledger/coverage.tsv, ledger/corpus-audit.json and ledger/companions.tsv.
#
# The store root is two directories above this file. Each step writes its output to
# stepN.log in a new mktemp directory under ROSETTA_TMP, and a failed step line names
# that log.
set -u

write=
case "${1-}" in
    "") ;;
    --write) write=--write ;;
    *) printf 'usage: validate-store.sh [--write]\n' >&2; exit 2 ;;
esac

STORE=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
READER_PYTHON=${ROSETTA_READER_PYTHON:-${ROSETTA_VOLUME:-/Volumes/volxxxx}/Caches/tmp/rosetta-readers/bin/python}

# Python writes no __pycache__ directory beside the drivers in the store.
export PYTHONDONTWRITEBYTECODE=1

ROSETTA_TMP=${ROSETTA_TMP:-${ROSETTA_VOLUME:-/Volumes/volxxxx}/Caches/tmp/rosetta-run-$(date +%Y%m%d)}
mkdir -p "$ROSETTA_TMP" || exit 1
LOGS=$(mktemp -d "${ROSETTA_TMP%/}/validate-store.XXXXXX") || exit 1
failed=0
steps=

# step NUMBER DIRECTORY COMMAND...
# In check mode every step reads the store only, so the steps run at the same time and
# report in step order. With --write, steps 4 and 5 read what steps 1 and 3 write, so the
# steps run one after the other.
step() {
    number=$1
    dir=$2
    shift 2
    steps="$steps $number"
    printf '%s\n' "$*" >"$LOGS/step$number.command"
    if [ -n "$write" ]; then
        run_step "$number" "$dir" "$@"
    else
        run_step "$number" "$dir" "$@" &
    fi
}

run_step() {
    number=$1
    dir=$2
    shift 2
    if (cd "$dir" && "$@") >"$LOGS/step$number.log" 2>&1; then
        echo ok >"$LOGS/step$number.status"
    else
        echo failed >"$LOGS/step$number.status"
    fi
}

printf 'mode %s\n' "${write:-check}"
step 0 "$STORE" sh tools/no-rm-rf.sh
step 1 "$STORE" python3 driver/ui/coverage.py $write
step 2 "$STORE" python3 driver/ui/verify-artifacts.py --all
step 3 "$STORE" "$READER_PYTHON" driver/ui/audit-corpus.py $write
step 4 "$STORE" python3 driver/ui/inert-pairs.py --check
step 5 "$STORE" python3 driver/ui/export-queue.py --check
step 6 "$STORE" python3 driver/tests/test_export_settings.py
step 7 "$STORE" "$READER_PYTHON" driver/reader-audit.py --check
step 8 "$STORE" python3 driver/tests/test_make_sources.py
step 9 "$STORE" python3 driver/ui/mesh-topology.py --check
step 10 "$STORE" "$READER_PYTHON" driver/tests/test_reader_audit.py
step 11 "$STORE" python3 driver/tests/test_audit_corpus.py
step 12 "$STORE" "$READER_PYTHON" driver/plugin-presence.py --check
wait

for number in $steps; do
    command=$(cat "$LOGS/step$number.command")
    if [ "$(cat "$LOGS/step$number.status" 2>/dev/null)" = ok ]; then
        printf 'step %s  %s  ok\n' "$number" "$command"
    else
        failed=$((failed + 1))
        printf 'step %s  %s  failed  log %s\n' "$number" "$command" "$LOGS/step$number.log"
    fi
done

printf 'steps failed: %d\n' "$failed"
[ "$failed" -eq 0 ]
