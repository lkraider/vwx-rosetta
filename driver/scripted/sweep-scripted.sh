#!/bin/bash
# Scripted (tier A) export sweep against a live Vectorworks instance.
#
# This driver calls vs.* functions inside the application through an AppleEvent
# script send. It needs an unsandboxed caller, because a sandbox refuses the
# AppleEvent. It never writes to a sealed source. It copies each source to a
# writable work path, exports from the copy, and closes the copy.
#
# Every wait is bounded and ends on a real signal. The driver polls for the
# sidecar and results files at 0.5 s intervals and inspects the accessibility
# tree for modals instead of sleeping for a fixed period.
#
# Usage:
#   sweep-scripted.sh [--cases FILE] [--formats stl,sat] [--limit N] [--only CASE]
#
# Outputs, under the reference store:
#   runs/<run-id>/requests/<case>.json     the request handed to exporter.py
#   runs/<run-id>/out/<case>/              raw exporter output
#   runs/<run-id>/records/<case>.json      per-case record
#   runs/<run-id>/records/modals.tsv       every modal seen and how it was answered
#   runs/<run-id>/driver/                  snapshot of the exact driver files used
#   ledger/corpus-ledger.jsonl             one line per collected artifact
#
# Exit 2: another process holds the lock that driver/vw_lock.py describes.
# Exit 3: driver/run_provenance.py refuses the worktree, no Vectorworks process runs at the
# start, or it ended during a case. With ROSETTA_OPEN_UNDER_PAUSE=1 a case opens its document
# while the pause file holds, and exit 3 also means that Vectorworks came to the front after
# the open. The front goes back to the application read before the open. A case that it ended during has a vectorworks_gone row in
# records/blockers.jsonl. The cases after it did not run.
set -u

R=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
C=${ROSETTA_TMP:-${ROSETTA_VOLUME:-/Volumes/volxxxx}/Caches/tmp/rosetta-corpus}
D="$R/driver/scripted"
python3 "$R/driver/vw_lock.py" --mine || exec python3 "$R/driver/vw_lock.py" bash "$0" "$@"
. "$D/run.env"

CASES="$R/driver/source-map.tsv"
FORMATS="stl,sat,step,iges"
LIMIT=0
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --cases)   CASES="$2"; shift 2 ;;
    --formats) FORMATS="$2"; shift 2 ;;
    --limit)   LIMIT="$2"; shift 2 ;;
    --only)    ONLY="$2"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

DRIVER_STATE="$(python3 "$R/driver/run_provenance.py" "$R" --binary "$VWX_CLI")" || exit 3

EXE="$APP_PATH/Contents/MacOS/Vectorworks"
PID="$(pgrep -f "MacOS/Vectorworks$" | head -n 1)"
if [ -z "$PID" ]; then printf 'no running Vectorworks process\n' >&2; exit 3; fi

RUN_ID="$(date +%Y%m%dT%H%M%S)-scripted"
RUN="$R/runs/$RUN_ID"
mkdir -p "$RUN/requests" "$RUN/out" "$RUN/records" "$RUN/driver" "$R/files" "$R/ledger"
cp "$D/exporter.py" "$D/probe.py" "$D/run.env" "$RUN/driver/"
cp "$0" "$RUN/driver/sweep-scripted.sh"
printf '%s\n' "$DRIVER_STATE" > "$RUN/driver/provenance.json"
printf 'formats=%s\napp_version=%s\nsource_map_sha256=%s\ncases_file=%s\n' \
  "$FORMATS" "$APP_VERSION" "$(shasum -a 256 "$CASES" | cut -d' ' -f1)" "$CASES" \
  > "$RUN/driver/run-facts.txt"

send() {
  "$VWX_CLI" native-script-send --pid "$PID" --expected-executable "$EXE" \
    --program "$1" --operator-authorized --timeout-ms 45000 >/dev/null 2>&1
}

alive() {
  kill -0 "$PID" 2>/dev/null
}

# Poll for a file at a short interval. The loop ends on the signal.
wait_for_file() {
  local path="$1" tries="${2:-24}" i=0
  while [ "$i" -lt "$tries" ]; do
    [ -f "$path" ] && return 0
    alive || return 1
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

# Answer whatever modal is up, recording its text. One press per pass, so a
# second stacked alert is handled on the next pass.
dismiss_modals() {
  local note="$1" max="${2:-6}" i=0 dump msg buttons
  while [ "$i" -lt "$max" ]; do
    i=$((i + 1))
    dump="$RUN/records/modal-$note-$i.tsv"
    "$VWX_CLI" ui-dialog --pid "$PID" --expected-executable "$EXE" --timeout-ms 2500 > "$dump" 2>&1 || true
    [ "$(awk -F'\t' '$1=="modal"{print $2}' "$dump")" = "true" ] || return 0
    msg="$(awk -F'\t' '$1=="message"{print substr($0,9)}' "$dump")"
    buttons="$(awk -F'\t' '$1=="button"{printf "%s,", $2}' "$dump")"
    printf '%s\t%s\t%s\t%s\n' "$(date +%H:%M:%S)" "$note" "$buttons" "$msg" >> "$RUN/records/modals.tsv"
    case "$buttons" in
      *OK,*)     "$VWX_CLI" ui-dialog --pid "$PID" --expected-executable "$EXE" --expected-text "$msg" --press OK >/dev/null 2>&1 || true ;;
      *Cancel,*) "$VWX_CLI" ui-dialog --pid "$PID" --expected-executable "$EXE" --expected-text "$msg" --press Cancel >/dev/null 2>&1 || true ;;
    esac
    sleep 0.5
  done
}

# vs.ExportSTL raises this alert for a source with no 3D object, and the alert holds the script
# until OK is pressed.
STL_NO_OBJECTS='There are no valid objects available for export'

# While the export script runs, press OK on the STL alert as soon as it shows. Any other modal
# waits for the send timeout, as before.
watch_export() {
  local sender="$1" case="$2"
  local dump="$RUN/records/modal-watch-$case.tsv"
  while kill -0 "$sender" 2>/dev/null; do
    "$VWX_CLI" ui-dialog --pid "$PID" --expected-executable "$EXE" --timeout-ms 2500 > "$dump" 2>&1 || true
    if [ "$(awk -F'\t' '$1=="modal"{print $2}' "$dump")" = "true" ] && grep -qF "$STL_NO_OBJECTS" "$dump"; then
      dismiss_modals "export-$case"
    fi
    sleep 0.5
  done
  wait "$sender"
}

window_listed() {
  osascript -e 'with timeout of 10 seconds' \
    -e 'tell application "System Events" to tell process "Vectorworks" to return name of every window' \
    -e 'end timeout' 2>/dev/null | grep -qF "$1"
}

front_app() {
  osascript -e 'tell application "System Events" to return name of (first process whose frontmost is true)' 2>/dev/null
}

# A batch under a pause opens documents with the person at the screen, so a document that brings
# Vectorworks to the front ends the run.
give_front_back() {
  [ -n "$1" ] && osascript -e "tell application \"System Events\" to set frontmost of process \"$1\" to true" >/dev/null 2>&1
  printf '%s\tself-activated\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$RUN/records/front.tsv"
}

close_document() {
  local note="$1"
  "$VWX_CLI" ui-menu --pid "$PID" --expected-executable "$EXE" \
    --item File --item Close --press >/dev/null 2>&1
  sleep 1
  dismiss_modals "close-$note"
}

write_request() {
  python3 - "$1" "$2" "$3" "$FORMATS" <<'PY'
import json, sys
path, case, out, formats = sys.argv[1:5]
with open(path, "w") as f:
    json.dump({"case_id": case, "out_dir": out,
               "formats": [s for s in formats.split(",") if s],
               "bbox_mm": [], "layers": [], "allow_modal": False,
               "worksheets": []}, f, indent=1)
PY
}

write_wrapper() {
  python3 - "$1" "$2" "$3" "$D/exporter.py" <<'PY'
import sys
path, case, req, exporter = sys.argv[1:5]
body = '''import importlib.util
import json
import vs

REQ = {req!r}
SIDE = {side!r}
EXPECTED = {expected!r}
EXP = {exporter!r}
actual = ""
try:
    actual = vs.GetFName()
except Exception as exc:
    actual = "ERROR:" + type(exc).__name__
with open(SIDE, "w") as f:
    json.dump({{"expected": EXPECTED, "actual": actual}}, f)
if actual == EXPECTED:
    spec = importlib.util.spec_from_file_location("exporter", EXP)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.run_request(REQ)
'''.format(req=req, side=req[:-5] + ".doc.json", expected=case + ".vwx", exporter=exporter)
with open(path, "w") as f:
    f.write(body)
PY
}

collect() {
  python3 - "$RUN" "$R" "$1" "$2" "$3" "$4" "$APP_VERSION" "$RUN_ID" <<'PY'
import hashlib, json, os, shutil, sys, time
run, root, case, out, src, work, appver, run_id = sys.argv[1:9]
sys.path.insert(0, os.path.join(root, "driver"))
from store_path import relative
src_stored = relative(src, root)

def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def profile(fmt):
    return {"stl": "stl.binary.high-all", "sat": "sat.solids",
            "step": "step.solids", "iges": "iges.solids",
            "ifc": "ifc.semantic"}.get(fmt, fmt)

src_sha = sha(src)
rec = {"run_id": run_id, "case": case, "source": src_stored, "source_sha256": src_sha,
       "work_copy": work, "app_version": appver,
       "exporter_sha256": sha(os.path.join(root, "driver/scripted/exporter.py")),
       "collected": [], "errors": [], "alerts": []}

modals = os.path.join(run, "records", "modals.tsv")
if os.path.exists(modals):
    with open(modals) as f:
        for line in f:
            cells = line.rstrip("\n").split("\t")
            if len(cells) >= 4 and cells[1] in ("export-" + case, "alerts-" + case):
                rec["alerts"].append(cells[3])

results_path = os.path.join(out, "results.json")
if not os.path.exists(results_path):
    rec["errors"].append("exporter wrote no results.json within the wait")
    results = []
else:
    with open(results_path) as f:
        results = json.load(f)
    if isinstance(results, dict):
        results = results.get("results", [])

for item in results:
    fmt = item.get("format", "?")
    status = item.get("status", "?")
    path = item.get("path") or ""
    if status != "ok" or not path or not os.path.exists(path):
        rec["errors"].append({"format": fmt, "status": status,
                              "detail": str(item.get("detail"))[:300], "path": path})
        continue
    ext = os.path.splitext(path)[1].lstrip(".").lower() or fmt
    dest_dir = os.path.join(root, "files", case)
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, case + "." + ext)
    if os.path.exists(dest):
        if sha(dest) == sha(path):
            rec["collected"].append({"format": fmt, "path": relative(dest, root),
                                     "bytes": os.path.getsize(dest), "sha256": sha(dest),
                                     "note": "identical artifact already present"})
            continue
        dest = os.path.join(dest_dir, case + "." + fmt + "." + ext)
    shutil.move(path, dest)
    entry = {"format": fmt, "profile": profile(fmt), "route": item.get("route"),
             "status": status, "path": relative(dest, root), "bytes": os.path.getsize(dest),
             "sha256": sha(dest), "api_return": str(item.get("api_return")),
             "origin_path": path}
    rec["collected"].append(entry)
    line = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "run_id": run_id,
            "case": case, "format": fmt, "profile": entry["profile"],
            "route": entry["route"], "path": entry["path"], "bytes": entry["bytes"],
            "sha256": entry["sha256"], "origin_path": path,
            "work_copy": work, "source": src_stored, "source_sha256": src_sha,
            "app_version": appver, "exporter_sha256": rec["exporter_sha256"]}
    with open(os.path.join(root, "ledger", "corpus-ledger.jsonl"), "a") as f:
        f.write(json.dumps(line) + "\n")

with open(os.path.join(run, "records", case + ".json"), "w") as f:
    json.dump(rec, f, indent=1)
print(json.dumps({"case": case, "collected": len(rec["collected"]),
                  "errors": len(rec["errors"])}))
PY
}

process_case() {
  local case="$1" src="$2"
  local work="$C/work-sources/$case.vwx"
  local out="$RUN/out/$case"
  local req="$RUN/requests/$case.json"
  local wrapper="$RUN/requests/$case-wrapper.py"
  local side="$RUN/requests/$case.doc.json"
  mkdir -p "$out" "$R/files/$case" "$C/work-sources"

  if [ ! -f "$work" ]; then
    cp "$src" "$work" || return 1
    chmod u+w "$work"
  fi

  write_request "$req" "$case" "$out"
  write_wrapper "$wrapper" "$case" "$req"

  local pause_end
  if [ "${ROSETTA_OPEN_UNDER_PAUSE:-}" != 1 ] && pause_end=$(python3 "$R/driver/pause.py" --active); then
    printf '{"case":"%s","status":"paused","detail":"paused until %s"}\n' \
      "$case" "$pause_end" >> "$RUN/records/blockers.jsonl"
    return 1
  fi
  local front_before
  front_before=$(front_app)
  open -g -a "$APP_PATH" "$work" >/dev/null 2>&1
  # vs.GetFName() in the wrapper crashed Vectorworks with SIGSEGV when the script came before the
  # document window (2026-10-20 07:22Z).
  local waited=0
  until window_listed "$case.vwx"; do
    waited=$((waited + 1))
    if [ "$waited" -ge 120 ] || ! alive; then
      printf '{"case":"%s","status":"document_window_missing","seconds":%s}\n' \
        "$case" "$((waited / 2))" >> "$RUN/records/blockers.jsonl"
      alive || return 3
      return 1
    fi
    sleep 0.5
  done
  printf '%s\t%s\n' "$case" "$((waited / 2))" >> "$RUN/records/window-wait.tsv"
  local attempt=0 matched=0 sender=
  while [ "$attempt" -lt 12 ]; do
    attempt=$((attempt + 1))
    rm -f "$side"
    send "$wrapper" &
    sender=$!
    wait_for_file "$side" 24 || true
    if [ -f "$side" ] && grep -q "\"$case.vwx\"" "$side"; then matched=1; break; fi
    wait "$sender"
    sender=
    wait_for_file "$side" 24 || true
    if [ -f "$side" ] && grep -q "\"$case.vwx\"" "$side"; then matched=1; break; fi
    alive || break
    dismiss_modals "docwait-$case-$attempt"
  done
  if [ -n "$sender" ]; then watch_export "$sender" "$case"; fi

  if ! alive; then
    printf '{"case":"%s","status":"vectorworks_gone","pid":%s}\n' "$case" "$PID" >> "$RUN/records/blockers.jsonl"
    return 3
  fi
  if [ "$matched" -ne 1 ]; then
    printf '{"case":"%s","status":"document_not_active","attempts":%s}\n' \
      "$case" "$attempt" >> "$RUN/records/blockers.jsonl"
    close_document "$case"
    return 1
  fi

  if [ "${ROSETTA_OPEN_UNDER_PAUSE:-}" = 1 ] && [ "$(front_app)" = Vectorworks ] && [ "$front_before" != Vectorworks ]; then
    give_front_back "$front_before"
    printf '{"case":"%s","status":"took_front","detail":"Vectorworks came to the front after open -g"}\n' \
      "$case" >> "$RUN/records/blockers.jsonl"
    close_document "$case"
    return 3
  fi
  dismiss_modals "alerts-$case"
  wait_for_file "$out/results.json" 120 || true
  if ! alive; then
    printf '{"case":"%s","status":"vectorworks_gone","pid":%s}\n' "$case" "$PID" >> "$RUN/records/blockers.jsonl"
    return 3
  fi
  collect "$case" "$out" "$src" "$work"
  close_document "$case"
}

count=0
while IFS=$'\t' read -r case src src_sha src_alts; do
  [ -n "${case:-}" ] || continue
  if [ -n "$ONLY" ] && [ "$case" != "$ONLY" ]; then continue; fi
  count=$((count + 1))
  if [ "$LIMIT" -gt 0 ] && [ "$count" -gt "$LIMIT" ]; then break; fi
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$case"
  code=0
  process_case "$case" "$(python3 "$R/driver/store_path.py" "$R" "$src")" || code=$?
  if [ "$code" -eq 3 ]; then
    printf 'run %s stopped during %s: %s\n' "$RUN_ID" "$case" "$(tail -n 1 "$RUN/records/blockers.jsonl")"
    exit 3
  fi
done < "$CASES"

printf 'run %s finished\n' "$RUN_ID"
