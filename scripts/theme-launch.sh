#!/usr/bin/env bash
# ./revit theme <year> [bottle]: for the menu bar app, when the Mac turns light or dark or a Revit starts. Sets the
# bottle's Windows theme to the Mac's look with the bottle's themeset.exe (the step theme put it there), which tells a
# running Revit; Revit with "Use system setting" repaints. Does nothing when the bottle's theme is fixed (./revit set
# <year> theme=light|dark). Holds the lock while themeset.exe runs; never stops wineserver.
# Exit code: 0 done, or the theme is fixed; 1 it cannot run here, or Revit did not answer (the app tries again);
# 2 usage; 75 try again later (the lock is busy).
# Usage: scripts/theme-launch.sh <year> <bottle>
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/wine.sh"
[ $# = 2 ] && [[ "$1" =~ ^[0-9]{4}$ ]] || usage_die "Usage: scripts/theme-launch.sh <year> <bottle>"
load_profile "$1" || usage_die "Revit $1 is not supported yet. Supported: ${REVIT_SUPPORTED[*]}."
NAME="$2"; B="$(bottle_path "$NAME")"; SFX="$(bottle_sfx "$NAME" "$YEAR")"
D="$B/drive_c/Program Files/revit-macos"

checks() { # the year, the bottle, its themeset.exe; MODE = the bottle's theme mode
  in_list theme ${STEPS[@]+"${STEPS[@]}"} || die "The theme setting is for Revit 2027 only."
  bottle_guard running_ok "$YEAR" "$NAME"
  [ -f "$D/themeset.exe" ] || die "Revit $YEAR in $NAME does not follow the Mac's look yet. Run: ./revit set $YEAR$SFX theme=mac"
  MODE="$(head -1 "$D/theme" 2>/dev/null)"
}

checks
[ "$MODE" = mac ] || { echo "Revit $YEAR ($NAME): the theme is fixed (${MODE:-not set})."; exit 0; }
lock_take --busy-exit 75 "./revit theme $YEAR $NAME"
checks   # again, under the lock: the bottle may have changed meanwhile
[ "$MODE" = mac ] || { echo "Revit $YEAR ($NAME): the theme is fixed (${MODE:-not set})."; exit 0; }
t="$(mac_appearance)"
w "C:\\Program Files\\revit-macos\\themeset.exe" "$t"; rc=$?
case "$rc" in
  0) echo "Revit $YEAR ($NAME): $t." ;;
  3) echo "Revit $YEAR ($NAME): $t, but Revit did not get the change. Try again in a moment."; exit 1 ;;
  *) echo "themeset.exe ended (exit $rc)."; exit 1 ;;
esac
