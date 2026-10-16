#!/usr/bin/env bash
# Runs install and add-in steps in a bottle.
# Usage: ./scripts/run-steps.sh <year> <bottle> [step…]
#   without steps: the year's STEPS (scripts/profiles/<year>.sh); ./revit addins passes ADDIN_STEPS
#   REVIT_LANG=en-US (default) | ru-RU — Revit's interface language; ODIS_PKGS="A|B" — other packages for step pkgs
# Each step is a function step_<name> in scripts/steps/*.sh. Its output goes to <run folder>/<step>.log; the run folder
# is RUN_DIR (install.sh passes it) or a new logs/<bottle>/<time>-<RUN_KIND or steps>/. One line per step goes to
# summary.txt, failed steps to failed.txt. A failed critical step stops the run: the steps after it need it.
# Exit: 0 all done, 1 a step failed or the run was stopped (TERM/HUP after the current step), 2 bad arguments.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/wine.sh"; . "$ROOT/scripts/lib/shims.sh"
for _f in "$ROOT"/scripts/steps/*.sh; do . "$_f"; done; unset _f
CRITICAL="netfx vc dotnet licensing svcshim rvt"                              # the steps after these need them
NEEDS_INSTALLER="vc netfx dotnet licensing idmgr adsso rvt rcl ret materials pkgs asc register" # these read the unpacked installer

[ $# -ge 2 ] || usage_die "Usage: scripts/run-steps.sh <year> <bottle> [step…]"
YEAR_ARG="$1"; NAME_ARG="$2"; shift 2
load_profile "$YEAR_ARG" || usage_die "Revit $YEAR_ARG is not supported yet. Supported: ${REVIT_SUPPORTED[*]}."
revit_bottle_name_ok "$NAME_ARG" \
  || usage_die "Bottle name may contain only letters, digits, - and _, and cannot be \"default\": \"$NAME_ARG\""
LIST=("$@"); [ ${#LIST[@]} -gt 0 ] || LIST=(${STEPS[@]+"${STEPS[@]}"})
[ ${#LIST[@]} -gt 0 ] || usage_die "There are no steps to run for Revit $YEAR."
for s in "${LIST[@]}"; do declare -F "step_$s" >/dev/null || usage_die "Unknown step: $s"; done

lock_take "run-steps.sh $YEAR $NAME_ARG ${LIST[*]}"
bottle_guard must_exist "$YEAR" "$NAME_ARG"
wine_init "$NAME_ARG"
DIST="$(revit_dist "$YEAR")"; RD="$(revit_dir_unix "$B" "$YEAR")"; LANG_UI="${REVIT_LANG:-en-US}"
for s in "${LIST[@]}"; do
  case " $NEEDS_INSTALLER " in *" $s "*)
    [ -f "$DIST/setup.xml" ] || [ -f "$DIST/Setup.ini" ] \
      || die "No unpacked Revit $YEAR installer in installers/extracted/revit$YEAR (step $s). Run: ./scripts/unpack-revit.sh $YEAR" ;;
  esac
done
if [ -z "${RUN_DIR:-}" ] || [ ! -d "$RUN_DIR" ]; then
  RUN_DIR="$(run_dir_new "$NAME" "${RUN_KIND:-steps}")" || die "Cannot create a log folder in $(tilde "$DATA/logs")."
fi
export RUN_DIR
# Wine's working folder is the script's: relative MSI paths (INSTALLDIR without Setup.exe) would land there
cd "$B/drive_c" || die "Cannot enter $(tilde "$B/drive_c")."
echo ">> Revit $YEAR → bottle $NAME, logs: $(tilde "$RUN_DIR")"

failed=0
for s in "${LIST[@]}"; do
  stop_check
  rm -f "$RUN_DIR/.detail" "$RUN_DIR/.skip"; t0=$SECONDS
  ( "step_$s" ) >>"$RUN_DIR/$s.log" 2>&1 </dev/null; rc=$?
  text="$(cat "$RUN_DIR/.detail" 2>/dev/null)"; code=$rc
  if [ $rc = 0 ] && [ -f "$RUN_DIR/.skip" ]; then code=skip; text="$(cat "$RUN_DIR/.skip")"; fi
  [ $rc = 0 ] || text="${text:+$text; }see $(tilde "$RUN_DIR/$s.log")"
  say "$s" "$code" "$text ($((SECONDS - t0)) s)"
  [ $rc = 0 ] && continue
  echo "$s" >> "$RUN_DIR/failed.txt"; failed=1
  case " $CRITICAL " in *" $s "*) echo "!! Step $s failed, and the steps after it need it: stopped." >&2; exit 1 ;; esac
done
rm -f "$RUN_DIR/.detail" "$RUN_DIR/.skip"
stop_check
exit $failed
