#!/bin/bash
# Start Vectorworks 2027 in a state the export driver can drive.
#
# The application aborts during start when the C numeric locale uses a comma as the
# decimal separator. Its Unreal Engine layer formats a layout string and asserts
# FString(OutputString) against a copy that holds full stops. The launchd environment
# holds a locale with a decimal comma, so the start sets the locale variables to en_US.UTF-8.
#
# The start goes through LaunchServices. A binary started from a tmux shell runs outside
# the login session, and System Events then lists no process for it. make-sources.py
# clicks menus through System Events.
#
# Use --restart when the application has collected windows from earlier runs. The
# exporter leaves a window titled Exporting up when it aborts, and that window holds
# every later menu press, so the driver then reports export_menu_refused.
#
# Usage: VWX_CLI=/path/to/vwx vw-launch.sh [--restart] [--wait-seconds N]
set -u

APP="${VW_APP:-/Applications/Vectorworks 2027/Vectorworks 2027.app}"
EXE="$APP/Contents/MacOS/Vectorworks"
if [ ! -f "${VWX_CLI:-}" ] || [ ! -x "$VWX_CLI" ]; then
  printf 'vw-launch.sh: VWX_CLI "%s" is not an executable file. Set it to the vwx binary that reads the File menu.\n' "${VWX_CLI:-}" >&2
  exit 2
fi
CLI=$VWX_CLI

wait_seconds=180
restart=0
while [ $# -gt 0 ]; do
  case "$1" in
    --restart) restart=1; shift;;
    --wait-seconds) wait_seconds="$2"; shift 2;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2;;
  esac
done

launch() {
  open -g -a "$APP" --env LANG=en_US.UTF-8 --env LC_ALL=en_US.UTF-8 --env LC_NUMERIC=en_US.UTF-8
}

# answer_mac_prompt presses Don't Reopen on the macOS crash-recovery alert.
# That alert carries no window title, so the button label is the only handle. Pressing
# Don't Reopen ends the start, and the caller starts the application again.
answer_mac_prompt() {
  local pid="$1" msg
  msg=$("$CLI" ui-dialog --pid "$pid" --expected-executable "$EXE" --timeout-ms 4000 2>&1 |
        awk -F'\t' '$1=="message"{print $2}')
  case "$msg" in
    *"unexpectedly quit"*)
      "$CLI" ui-dialog --pid "$pid" --expected-executable "$EXE" \
        --expected-text "$msg" --press "Don’t Reopen" --timeout-ms 8000 >/dev/null 2>&1
      return 0;;
  esac
  return 1
}

if [ "$restart" = 1 ]; then
  pkill -9 -f 'MacOS/Vectorworks$' 2>/dev/null || true
  sleep 6
fi

for attempt in 1 2 3; do
  pid=$(pgrep -f 'MacOS/Vectorworks$' | head -n 1 || true)
  if [ -z "${pid:-}" ]; then
    launch
  fi
  elapsed=0
  while [ "$elapsed" -lt "$wait_seconds" ]; do
    sleep 5
    elapsed=$((elapsed + 5))
    pid=$(pgrep -f 'MacOS/Vectorworks$' | head -n 1 || true)
    if [ -z "${pid:-}" ]; then
      break
    fi
    if answer_mac_prompt "$pid"; then
      sleep 6
      pid=$(pgrep -f 'MacOS/Vectorworks$' | head -n 1 || true)
      if [ -z "${pid:-}" ]; then
        break
      fi
    fi
    state=$("$CLI" ui-dialog --pid "$pid" --expected-executable "$EXE" --timeout-ms 4000 2>&1)
    modal=$(printf '%s' "$state" | awk -F'\t' '$1=="modal"{print $2}')
    if [ "$modal" != "true" ]; then
      # A window title is empty for an untitled document and for the start screen, so
      # the File menu is the readiness test. It reads only once the application has
      # finished starting, and it is the first thing the export driver presses.
      menu=$("$CLI" ui-menu --pid "$pid" --expected-executable "$EXE" --item File --timeout-ms 8000 2>&1)
      if printf '%s' "$menu" | awk -F'\t' '$1=="status" && $2=="read"{found=1} END{exit !found}'; then
        printf 'ready pid %s after %ss\n' "$pid" "$elapsed"
        exit 0
      fi
    fi
  done
  printf 'attempt %s did not reach a ready state\n' "$attempt" >&2
done

printf 'the application did not start\n' >&2
exit 1
