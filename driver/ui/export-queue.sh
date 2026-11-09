#!/bin/bash
# Print the ordered export steps of one case, or of every case, from export-queue.jsonl.
#   export-queue.sh <case_id> | all
# Write the queue first with driver/ui/export-queue.py. The script only prints.
# Exit status 2 means a usage error or an unknown case id.
set -euo pipefail

QUEUE="${EXPORT_QUEUE:-$(dirname "$0")/export-queue.jsonl}"

if [ $# -ne 1 ]; then
    echo "usage: $0 <case_id>|all" >&2
    exit 2
fi
if [ ! -f "$QUEUE" ]; then
    echo "export-queue.sh: $QUEUE is missing. Run export-queue.py." >&2
    exit 2
fi
if [ "$1" != all ] && ! jq -e --arg c "$1" 'select(.case_id == $c)' "$QUEUE" >/dev/null; then
    echo "export-queue.sh: case $1 is not in $QUEUE" >&2
    exit 2
fi

jq -r --arg c "$1" '
def opt:
  (if .when == "rescue" then "only if the accept button is disabled: "
   elif .when then "if the active layer is a \(.when): "
   else "" end) as $cond
  | (if .note then " (\(.note))" else "" end) as $note
  | if .action == "key Tab" then "press the Tab key"
    elif .action == "type" then "type \(.value)\($note)"
    elif .action == "pane" then "select \(.value) in the Settings list of the dialog"
    elif .action == "script" then "run through Tools > Plug-ins > Run Script...: \(.value)"
    else "\($cond)set \(.control) = \(.value)\($note)" end;

select($c == "all" or .case_id == $c)
| "== \(.case_id)  \(.profile)  \(.format)",
  (if .needs_live_app | not then
     "   SKIP needs_live_app=false: \(.reason)"
   else
     ([ "open a copy of \(.source_path) and wait for the window title \(.case_id).vwx" ]
      + [ .fit_steps[].step ]
      + (if .route.menu then [ "menu \(.route.menu | join(" > "))" ] else [] end)
      + (if .route.dialog then [ "wait for the dialog \(.route.dialog)" ] else [] end)
      + [ .options[] | opt ]
      + (if .route.accept then [ "accept \(.route.dialog) with \(.route.accept)" ] else [] end)
      + (if .route.save_panel then
           [ "in the save panel (\(.route.save_panel)) press Return",
             "move the written file to \(.artifact_path)" ]
         else [ "check that \(.artifact_path) exists" ] end)
     ) | to_entries[] | "  \(.key + 1). \(.value)"
   end)
' "$QUEUE"
