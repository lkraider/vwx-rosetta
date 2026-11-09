#!/bin/sh
# Press Save in an open "Export as PDF Document" panel fast, and time every action.
# Usage: save-pdf.sh LABEL EXPECTED_NAME DEST_DIR [WANT_WHERE]
#   LABEL         run label for the dump and timing rows
#   EXPECTED_NAME the file name the panel must hold
#   DEST_DIR      the absolute directory the file must land in
#   WANT_WHERE    the expected value of the Where popup. Default tmp.
# Environment:
#   VWX           vwx binary for targeted reads. Default $E/tools/vwx.
#   VWX_EXE       executable path of the Vectorworks process. Default `ps -o comm=` of the pid.
#
# Rules this script follows.
# - Reads use `vwx ui-dialog --read-field`, `--read-enabled` and `--read-popup` when $VWX lists
#   them in `ui-dialog --help`. One targeted read costs 70 to 90 ms on a panel with a 3000-file
#   listing. A vwx status other than read or window_absent switches the run to the axpanel dump.
# - The axpanel dump is the fallback. The panel is read once, and the Where popup, the name
#   field and the Save button state all come from that one read.
# - The Where popup is opened only when its value differs from WANT_WHERE. The value is
#   already correct on entry in this run, so the dropdown never opens.
# - No fixed sleep stands in for a signal. Each retry watches a value the previous read
#   reported, and the retry gap is 0.05 s.
# - Every action is timed into $E/log/timings.tsv. Actions over 1000 ms are printed.
E=${ROSETTA_RUN:-${ROSETTA_VOLUME:-/Volumes/volxxxx}/Caches/tmp/rosetta-vw-export-20261016}
P=$E/tools/axpanel
VWX=${VWX:-$E/tools/vwx}
PANEL="Export as PDF Document"
label=$1; want=$2; destdir=$3; want_where=${4:-tmp}
[ -n "$label" ] && [ -n "$want" ] && [ -n "$destdir" ] || { echo "usage: save-pdf.sh LABEL EXPECTED_NAME DEST_DIR [WANT_WHERE]"; exit 2; }
pid=${VWX_PID:-$(pgrep -f 'MacOS/Vectorworks$')}
[ -n "$pid" ] || { echo "no Vectorworks process"; exit 1; }
exe=${VWX_EXE:-$(ps -o comm= -p "$pid")}
mkdir -p "$destdir" "$E/dialogs" "$E/log"
timings=$E/log/timings.tsv
[ -f "$timings" ] || printf 'time\tlabel\taction\tms\trc\n' > $timings
dest=$destdir/$want
dump=$E/dialogs/$label-savepanel.txt
slow=
fast=no
[ -x "$VWX" ] && "$VWX" ui-dialog --help 2>/dev/null | grep -q -- '--read-field' && fast=yes
echo "targeted reads: $fast ($VWX)"

# timed CMD... records the wall time of one action.
timed() { t_label=$1; t_action=$2; shift 2
  t0=$(python3 -c 'import time;print(int(time.time()*1000))')
  "$@" > $dump 2>&1; rc=$?
  t1=$(python3 -c 'import time;print(int(time.time()*1000))')
  ms=$((t1-t0))
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%H:%M:%S')" "$t_label" "$t_action" "$ms" "$rc" >> $timings
  printf '%s %s %sms rc=%s\n' "$t_label" "$t_action" "$ms" "$rc"
  [ $ms -gt 1000 ] && slow="$slow $t_action=${ms}ms"
  return $rc
}

# fast_read ACTION OPTION ID... runs one timed targeted read into $dump and sets st to the vwx
# status. It returns 1 and sets fast=no when the status is neither read nor window_absent.
fast_read() { f_action=$1; shift
  timed "$label" "$f_action" "$VWX" ui-dialog --pid "$pid" --expected-executable "$exe" --window-title "$PANEL" "$@"
  st=$(awk -F'\t' '$1=="status"{print $2}' $dump)
  case $st in read|window_absent) return 0 ;; esac
  echo "vwx ui-dialog status '$st', the axpanel dump takes over"
  fast=no
  return 1
}

# value KIND ID prints the value of one successful read line of $dump.
value() { awk -F'\t' -v k="$1" -v id="$2" '$1=="read" && $2==k && $3==id && $4=="read" {print $7}' $dump; }

# dump_value ID prints the value column of one control line of an axpanel dump.
dump_value() { grep "id=$1	" $dump | sed 's/.*value=\([^	]*\).*/\1/'; }

# read_panel waits for the panel to appear and reads the name and the Where popup once.
# The retry gap is 0.05 s.
read_panel() {
  i=0
  while [ $i -lt 20 ]; do i=$((i+1))
    if [ $fast = yes ] && fast_read "panel-read-$i" --read-field saveAsNameTextField --read-popup "where popup"; then
      [ "$st" = read ] && { name=$(value field saveAsNameTextField); where=$(value popup "where popup"); return 0; }
      sleep 0.05; continue
    fi
    timed "$label" "panel-read-$i" $P $pid "$PANEL"
    grep -q "window	$PANEL" $dump && { name=$(dump_value saveAsNameTextField); where=$(dump_value "where popup"); return 0; }
    sleep 0.05
  done
  return 1
}

# read_where reads the Where popup into where.
read_where() {
  if [ $fast = yes ] && fast_read "$1" --read-popup "where popup"; then
    where=$(value popup "where popup"); return 0
  fi
  timed "$label" "$1" $P $pid "$PANEL"
  where=$(dump_value "where popup")
}

# read_enabled sets enabled to yes when the Save button reads enabled.
read_enabled() {
  enabled=no
  if [ $fast = yes ] && fast_read "$1" --read-enabled OKButton; then
    [ "$(value enabled OKButton)" = true ] && enabled=yes
    return 0
  fi
  timed "$label" "$1" $P $pid "$PANEL"
  grep -q 'id=OKButton.*enabled=true' $dump && enabled=yes
}

# read_present sets present to yes while the panel window exists.
read_present() {
  if [ $fast = yes ] && fast_read "$1" --read-enabled OKButton; then
    if [ "$st" = window_absent ]; then present=no; else present=yes; fi
    return 0
  fi
  timed "$label" "$1" $P $pid "$PANEL"
  if grep -q "window	$PANEL" $dump; then present=yes; else present=no; fi
}

read_panel || { echo "save panel absent after $i reads"; exit 1; }
echo "name='$name' where='$where'"
[ "$name" = "$want" ] || { echo "save name is '$name', expected '$want'"; exit 1; }

# The dropdown opens only when the value is wrong. It is correct on entry, so this is skipped.
if [ "$where" != "$want_where" ]; then
  timed "$label" "popup-pick" $P $pid "$PANEL" --pick-popup "where popup=$want_where" || { echo "popup pick failed"; exit 1; }
  i=0
  while [ $i -lt 20 ]; do i=$((i+1))
    read_where "popup-confirm-$i"
    [ "$where" = "$want_where" ] && break
    sleep 0.05
  done
  [ "$where" = "$want_where" ] || { echo "where popup reads '$where' after the pick"; exit 1; }
else
  echo "where popup already reads '$want_where', the dropdown stays shut"
fi

# Press Save. Each attempt follows a read that observed enabled=true.
attempt=0
pressed=no
while [ $attempt -lt 3 ] && [ "$pressed" = no ]; do
  attempt=$((attempt+1))
  i=0; enabled=no
  while [ $i -lt 20 ] && [ "$enabled" = no ]; do i=$((i+1))
    read_enabled "button-read-$attempt-$i"
    [ "$enabled" = yes ] || sleep 0.05
  done
  [ "$enabled" = yes ] || { echo "Save button stayed disabled after $i reads"; exit 1; }
  t0=$(python3 -c 'import time;print(int(time.time()*1000))')
  $P $pid "$PANEL" --expect-field "saveAsNameTextField=$want" --press OKButton > $E/dialogs/$label-save.txt 2>&1; rc=$?
  t1=$(python3 -c 'import time;print(int(time.time()*1000))')
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%H:%M:%S')" "$label" "press-$attempt" "$((t1-t0))" "$rc" >> $timings
  printf '%s press-%s %sms rc=%s\n' "$label" "$attempt" "$((t1-t0))" "$rc"
  grep -q 'result	pressed' $E/dialogs/$label-save.txt && pressed=yes
  # The panel closes when the press is accepted. Wait for the window to go, not for a clock.
  k=0
  while [ $k -lt 20 ]; do k=$((k+1))
    read_present "panel-gone-$attempt-$k"
    [ "$present" = no ] && break
    sleep 0.05
  done
  [ "$present" = no ] && { [ "$pressed" = no ] && echo "panel closed without result pressed"; break; }
done
[ "$pressed" = yes ] || { echo "save refused after $attempt attempts"; exit 1; }

# The file appears when the write finishes. Watch the path, then watch the size settle.
i=0
while [ $i -lt 200 ]; do i=$((i+1))
  [ -s "$dest" ] && break
  sleep 0.05
done
[ -s "$dest" ] || { echo "no file at $dest after $i reads"; find "$destdir" -maxdepth 1 -name "$want" | head -3; exit 1; }
s1=$(stat -f %z "$dest"); n=0
while [ $n -lt 20 ]; do n=$((n+1)); s2=$(stat -f %z "$dest"); [ "$s1" = "$s2" ] && break; s1=$s2; sleep 0.05; done
echo "saved $dest bytes=$s2"
[ -n "$slow" ] && echo "SLOW ACTIONS:$slow"
exit 0
