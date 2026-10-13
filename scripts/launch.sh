#!/usr/bin/env bash
# Starts Revit <year> in a bottle with a log (./revit debug) and waits until Revit has its files open (at most 60 s),
# so ./revit sees it as running before the lock is free again. Revit itself runs without the lock.
# Usage: ./scripts/launch.sh <year> <bottle> [backend: default|d3dmetal|dxmt|wined3d|dxvk] [file.rvt/.rfa, Windows path]
# Logs: logs/<bottle>/<time>-debug/ (stdout.log, wine.cxlog, pid). CX_DEBUGMSG=… changes the Wine channels.
# Revit's journals: drive_c/users/crossover/AppData/Local/Autodesk/Revit/Autodesk Revit <year>/Journals
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/wine.sh"
[ $# -ge 2 ] || usage_die "Usage: scripts/launch.sh <year> <bottle> [backend] [file]"
load_profile "$1" || usage_die "Revit $1 is not supported yet. Supported: ${REVIT_SUPPORTED[*]}."
revit_bottle_name_ok "$2" || usage_die "Bottle name may contain only letters, digits, - and _: \"$2\""
BE="${3:-default}"; FILE="${4:-}"
lock_take "launch.sh $YEAR $2"
bottle_guard must_exist "$YEAR" "$2"
wine_init "$2"
RUN_DIR="$(run_dir_new "$NAME" debug)" || die "Cannot create a log folder in $(tilde "$ROOT/logs")."
cd "$B/drive_c" || die "Cannot enter $(tilde "$B/drive_c")."
[ "$BE" = default ] || export CX_GRAPHICS_BACKEND="$BE"
# fd 9 closed on the backgrounded call itself: the subshell that runs the function would keep the lock until Revit quits
CX_LOG="$RUN_DIR/wine.cxlog" CX_DEBUGMSG="${CX_DEBUGMSG:-err,+seh}" \
  w_nowait "C:\\Program Files\\Autodesk\\Revit $YEAR\\Revit.exe" ${FILE:+"$FILE"} >"$RUN_DIR/stdout.log" 2>&1 </dev/null 9>&- &
echo "$!" > "$RUN_DIR/pid"
wait_s="${REVIT_LAUNCH_WAIT:-60}"   # tests only: a shorter wait
for i in $(seq 1 "$wait_s"); do revit_running "$B" "$YEAR" && break; sleep 1; done
if revit_running "$B" "$YEAR"; then echo "Revit $YEAR started (backend $BE). Logs: $(tilde "$RUN_DIR")"
else echo "Revit $YEAR has not opened yet after $wait_s s. Logs: $(tilde "$RUN_DIR")"; fi
