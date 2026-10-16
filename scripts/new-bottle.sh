#!/usr/bin/env bash
# Creates the CrossOver bottle for Revit <year>, described as "Revit <year>" (./revit and the scripts recognise a
# bottle's year by that, even before Revit is in it).
# Usage: ./scripts/new-bottle.sh <year> <bottle> [template=win10_64]
#   CX_RECREATE=1 deletes an existing bottle of that year first (./revit rebuild)
# Log: bottle.log in RUN_DIR (install.sh passes it) or in a new logs/<bottle>/<time>-bottle/.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/wine.sh"
[ $# -ge 2 ] || usage_die "Usage: scripts/new-bottle.sh <year> <bottle> [template]"
load_profile "$1" || usage_die "Revit $1 is not supported yet. Supported: ${REVIT_SUPPORTED[*]}."
revit_bottle_name_ok "$2" || usage_die "Bottle name may contain only letters, digits, - and _, and cannot be \"default\": \"$2\""
TEMPLATE="${3:-win10_64}"
[ -x "$CX/bin/cxbottle" ] || die "CrossOver not found in /Applications. Install it from https://www.codeweavers.com/crossover"
lock_take "new-bottle.sh $YEAR $2"
bottle_guard allow_missing "$YEAR" "$2"
wine_init "$2"
if [ -z "${RUN_DIR:-}" ] || [ ! -d "$RUN_DIR" ]; then RUN_DIR="$(run_dir_new "$NAME" bottle)" || die "Cannot create a log folder."; fi
LOG="$RUN_DIR/bottle.log"
if [ -d "$B" ]; then
  [ "${CX_RECREATE:-0}" = 1 ] || die "Bottle $NAME already exists. To delete and rebuild it: ./revit rebuild $YEAR$(bottle_sfx "$NAME" "$YEAR")"
  echo ">> deleting the old bottle $NAME"
  "$CX/bin/cxbottle" --bottle "$NAME" --delete --force >>"$LOG" 2>&1 </dev/null 7>&- 9>&-
  [ ! -d "$B" ] || die "Could not delete bottle $NAME (log: $(tilde "$LOG")). Quit CrossOver and try again."
fi
echo ">> creating $NAME ($TEMPLATE), log: $(tilde "$LOG")"
"$CX/bin/cxbottle" --bottle "$NAME" --create --template "$TEMPLATE" --description "Revit $YEAR" >>"$LOG" 2>&1 </dev/null 7>&- 9>&- \
  || die "CrossOver could not create bottle $NAME (log: $(tilde "$LOG"))."
w wineboot -u >>"$LOG" 2>&1   # its code says nothing; the next command shows whether the bottle runs programs
w cmd /c ver 2>>"$LOG" | tr -d '\r' || die "The new bottle $NAME does not run Windows programs (log: $(tilde "$LOG"))."
echo ">> done: $(tilde "$B")"
