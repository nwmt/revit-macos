#!/usr/bin/env bash
# ./revit hittest <year> [bottle]: for the menu bar app's trackpad gestures. Runs our hittest.exe (tools/shims/hittest,
# by its Mac path: nothing is copied into the bottle) in the bottle where Revit runs; the app asks it on stdin/stdout
# which Windows window is under a point (the protocol is in hittest.c), so everything of this script goes to stderr.
# The lock is held only while it starts: until hittest.exe has written its ready file nothing may delete the bottle;
# afterwards a running hittest.exe counts as activity for bottle_guard, and it ends when Revit does. On a signal, the
# deadline or an error, only its own processes are ended (never wineserver -k).
# Exit code: hittest.exe's; 75 try again later (the lock is busy, or Revit is not running yet or has just ended); 1 it
# cannot run here; 2 usage.
# Usage: scripts/hittest-launch.sh <year> <bottle>
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/handoff.sh"
exec 3>&1 1>&2   # fd 3 = the app's stdout, for hittest.exe only
[ $# = 2 ] && [[ "$1" =~ ^[0-9]{4}$ ]] || { echo "Usage: scripts/hittest-launch.sh <year> <bottle>"; exit 2; }
YEAR="$1"; NAME="$2"; B="$(bottle_path "$NAME")"
TOKEN=""; WPID=""; LF=""; PHASE=starting; SEEN=""
HANDOFF_S="${HITTEST_HANDOFF_S:-10}"   # how long hittest.exe may take to be ready (tests change it)
EXE="$(shim_dir)/hittest/hittest.exe"

checks() { # the bottle, a running Revit of this year, our hittest.exe
  bottle_guard running_ok "$YEAR" "$NAME"
  revit_running "$B" "$YEAR" || { echo "Revit $YEAR is not running in $NAME."; exit 75; }
  [ -f "$EXE" ] || die "There is no $(tilde "$EXE"). Build it: ./scripts/build-shims.sh hittest"
}

checks
[ -z "${HITTEST_TEST_HOLD:-}" ] || { touch "$HITTEST_TEST_HOLD.reached"; while [ -e "$HITTEST_TEST_HOLD" ]; do sleep 0.1; done; }   # tests
trap 'on_signal INT 130' INT; trap 'on_signal TERM 143' TERM; trap 'on_signal HUP 129' HUP
lock_take --no-trap --busy-exit 75 "./revit hittest $YEAR $NAME"
checks   # again, under the lock: the bottle or Revit may have changed meanwhile

# the ready file: a new name in this Mac's temporary folder; its name is the token that finds our Windows processes
T="${TMPDIR:-/tmp}"; LF="$(mktemp -u "${T%/}/revit-hittest.XXXXXXXX")" || die "Cannot name a temporary file in $T."
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
      *) echo "hittest.exe ended (exit $rc)."; finish "$rc" ;;
    esac
  fi
  i=$((i + 1)); [ $i -le $((HANDOFF_S * 5)) ] || { echo "hittest.exe did not start within $HANDOFF_S s."; finish 1; }
  sleep 0.2
done
exec 9>&-; PHASE=running   # handed over: a running hittest.exe now keeps remove and rebuild away until Revit is gone
rc=0
while :; do wait "$WPID"; rc=$?; kill -0 "$WPID" 2>/dev/null || break; done   # a trap interrupts wait
rm -f "$LF"
exit "$rc"
