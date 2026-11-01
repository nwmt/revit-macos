#!/usr/bin/env bash
# ./revit mcp --server ui: tools/ui_server.py starts this for the windows of a running Revit. Runs our uibridge.exe
# (tools/shims/uibridge, by its Mac path: nothing is copied into the bottle) in the bottle where Revit runs; the server
# talks to it on stdin/stdout (the protocol is in uibridge.c), so everything of this script goes to stderr.
# The lock is held only while it starts: until uibridge.exe has written its ready file nothing may delete the bottle;
# afterwards a running uibridge.exe counts as activity for bottle_guard, and it ends when Revit does. On a signal, the
# deadline or an error, only its own processes are ended (never wineserver -k).
# Exit code: uibridge.exe's; 75 Revit is not running yet or has just ended; 1 it cannot run here; 2 usage.
# Usage: scripts/uibridge-launch.sh <year> <bottle>
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/handoff.sh"
exec 3>&1 1>&2   # fd 3 = the app's stdout, for uibridge.exe only
[ $# = 2 ] && [[ "$1" =~ ^[0-9]{4}$ ]] || { echo "Usage: scripts/uibridge-launch.sh <year> <bottle>"; exit 2; }
YEAR="$1"; NAME="$2"; B="$(bottle_path "$NAME")"
TOKEN=""; WPID=""; LF=""; PHASE=starting; SEEN=""
HANDOFF_S="${UIBRIDGE_HANDOFF_S:-10}"   # how long uibridge.exe may take to be ready (tests change it)
EXE="$(shim_dir)/uibridge/uibridge.exe"

checks() { # the bottle, a running Revit of this year, our uibridge.exe
  bottle_guard running_ok "$YEAR" "$NAME"
  revit_running "$B" "$YEAR" || { echo "Revit $YEAR is not running in $NAME."; exit 75; }
  [ -f "$EXE" ] || die "There is no $(tilde "$EXE"). Build it: ./scripts/build-shims.sh uibridge"
}

checks
[ -z "${UIBRIDGE_TEST_HOLD:-}" ] || { touch "$UIBRIDGE_TEST_HOLD.reached"; while [ -e "$UIBRIDGE_TEST_HOLD" ]; do sleep 0.1; done; }   # tests
trap 'on_signal INT 130' INT; trap 'on_signal TERM 143' TERM; trap 'on_signal HUP 129' HUP
lock_take --no-trap "./revit mcp ui $YEAR $NAME"
checks   # again, under the lock: the bottle or Revit may have changed meanwhile

# the ready file: a new name in this Mac's temporary folder; its name is the token that finds our Windows processes
T="${TMPDIR:-/tmp}"; LF="$(mktemp -u "${T%/}/revit-uibridge.XXXXXXXX")" || die "Cannot name a temporary file in $T."
TOKEN="$(basename "$LF")"
# the app's stdin explicitly: bash gives a background job /dev/null otherwise. fd 7/8/9 (events, lock) stay here
"$CX/bin/wine" --bottle "$NAME" "$EXE" --ready "Z:${LF//\//\\}" "$YEAR" <&0 >&3 3>&- 7>&- 8>&- 9>&- &
WPID=$!
i=0
until [ -e "$LF" ]; do
  if ! kill -0 "$WPID" 2>/dev/null; then   # ended before it was ready
    wait "$WPID"; rc=$?
    case "$rc" in
      3) echo "Revit $YEAR is not running in $NAME."; finish 75 ;;   # Revit ended just now
      0) finish 1 ;;
      *) echo "uibridge.exe ended (exit $rc)."; finish "$rc" ;;
    esac
  fi
  i=$((i + 1)); [ $i -le $((HANDOFF_S * 5)) ] || { echo "uibridge.exe did not start within $HANDOFF_S s."; finish 1; }
  sleep 0.2
done
exec 9>&-; PHASE=running   # handed over: a running uibridge.exe now keeps remove and rebuild away until Revit is gone
rc=0
while :; do wait "$WPID"; rc=$?; kill -0 "$WPID" 2>/dev/null || break; done   # a trap interrupts wait
rm -f "$LF"
exit "$rc"
