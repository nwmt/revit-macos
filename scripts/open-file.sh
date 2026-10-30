#!/usr/bin/env bash
# ./revit open <file>: opens a Revit file in the Revit it was saved in. tools/rvtfile.py reads the version and decides;
# a file goes only to a bottle of its own year, or, with --copy-for, as a copy beside it. Never upgrades a file unasked.
# A Revit already running gets the file; otherwise the bottle's Revit app starts, as from the menu (its server watch,
# theme and shortcut arguments), and revitopen.exe (tools/shims/revitopen, by its Mac path) hands the file over by DDE.
# revitopen.exe starts nothing, so this never makes a second Revit. The lock is held only while deciding and starting.
# The file is read again right before it is sent: a sync may have replaced it during the minutes Revit took to start.
# Exit code: 0 sent, or the --plan answer; 1 refused or failed (the reason on stderr); 75 try again later (the lock is busy).
# Usage: scripts/open-file.sh <file> <bottle or ""> <copy year or ""> <1: only answer with the plan as JSON>
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/shims.sh"; . "$ROOT/scripts/lib/wine.sh"
[ $# = 4 ] || usage_die "Usage: scripts/open-file.sh <file> <bottle> <copy year> <plan>"
FILE="$1"; ONLY="$2"; COPY="$3"; PLAN="$4"
OPENER="${REVIT_OPENER:-/usr/bin/open}"   # tests: a fake one
START_WAIT="${REVIT_OPEN_START_WAIT:-60}"; ATTEMPT_S="${REVIT_OPEN_ATTEMPT_S:-120}"
rf() { python3 -I -B "$ROOT/tools/rvtfile.py" "$@" 7>&- 8>&- 9>&-; }
field() { python3 -I -c 'import json,sys; v=json.loads(sys.argv[1])
for k in sys.argv[2:]:
    v=v[int(k)] if k.isdigit() else v[k]
print(v)' "$@"; }

[ -z "$ONLY" ] || revit_bottle_name_ok "$ONLY" || die "Bottle name may contain only letters, digits, - and _: \"$ONLY\""
[ -f "$FILE" ] || die "There is no file $FILE."
FILE="$(cd "$(dirname "$FILE")" && pwd -P)/$(basename "$FILE")"
SUPPORTED="$(IFS=,; echo "${REVIT_SUPPORTED[*]}")"

bottles() { # the bottles that have Revit: "<year> <name> <running 0|1>" per line, as ./revit status finds them
  local b ys n
  for b in "$BOTTLES"/*/; do
    b="${b%/}"; [ -L "$b" ] && continue; is_smoke_clone "$b" && continue
    ys="$(bottle_years "$b" | sort -u | tr '\n' ' ')"; ys="${ys% }"
    case "$ys" in [0-9][0-9][0-9][0-9]) ;; *) continue ;; esac
    [ -f "$(revit_dir_unix "$b" "$ys")/Revit.exe" ] || continue
    n=0; revit_running "$b" "$ys" && n=1
    echo "$ys $(basename "$b") $n"
  done
}
P="$(bottles | rf plan "$FILE" "$SUPPORTED" "$ONLY" "$COPY")" || die "Could not read $FILE."
if [ "$PLAN" = 1 ]; then printf '%s\n' "$P"; exit 0; fi
ACTION="$(field "$P" action)"
case "$ACTION" in open|copy) ;; *) die "$(field "$P" say)" ;; esac
YEAR="$(field "$P" year)"; NAME="$(field "$P" bottles 0 name)"
load_profile "$YEAR" || die "Revit $YEAR is not supported yet. Supported: ${REVIT_SUPPORTED[*]}."
wine_init "$NAME"
APP="$HOME/Applications/Revit $YEAR ($NAME).app"; MARK="$B/revit-macos/open-start"
WIN="$(rf winpath "$B" "$FILE")" || exit 1   # before Revit starts: a name Windows cannot reach is refused at once
ensure_shim revitopen >/dev/null || die "revitopen.exe is missing. Run: ./scripts/build-shims.sh revitopen"
EXE="$(shim_dir)/revitopen/revitopen.exe"
ro() { w "$EXE" "$@" 2>/dev/null; }
attempt_fresh() { # a start of ours less than ATTEMPT_S ago, Revit perhaps not visible yet: it must not be started again
  local t; t="$(cat "$MARK" 2>/dev/null)" && [[ "$t" =~ ^[0-9]+$ ]] && [ $(($(date +%s) - t)) -lt "$ATTEMPT_S" ]
}

lock_take --busy-exit 75 "./revit open $YEAR $NAME"
bottle_guard running_ok "$YEAR" "$NAME"
pids="$(revit_pids "$B" "$YEAR")"
[ "$(wc -w <<<"$pids")" -le 1 ] || die "Two Revit $YEAR windows run in $NAME and Windows would pick one. Quit one, then try again."
DEADLINE=$((SECONDS + ${REVIT_OPEN_WAIT_BUSY:-60}))
if [ -z "$pids" ]; then
  DEADLINE=$((SECONDS + ${REVIT_OPEN_WAIT:-300}))
  if ! attempt_fresh; then
    [ -d "$APP" ] || die "There is no $(tilde "$APP"). Run ./revit rebuild $YEAR$(bottle_sfx "$NAME" "$YEAR"), or open Revit and use File > Open."
    mkdir -p "$(dirname "$MARK")" && date +%s > "$MARK" || die "Cannot write in $NAME."
    "$OPENER" "$APP" </dev/null >/dev/null 2>&1 7>&- 8>&- 9>&- || { rm -f "$MARK"; die "Could not start $(tilde "$APP")."; }
  fi
  for ((i = 0; i < START_WAIT; i++)); do revit_running "$B" "$YEAR" && break; sleep 1; done
fi
exec 9>&-   # Revit is up or on its way: the wait below must not stop other work on this Mac

prepare() { # right before sending: the file is what the plan saw. A copy is made only now, when it can be opened
  local now
  if [ "$ACTION" = copy ]; then
    FILE="$(rf copy "$FILE" "$YEAR")" || exit 1
    ACTION=open
    now="$(rf info "$FILE")"
    [ "$(field "$now" format)" = "$(field "$P" format)" ] || die "The file changed while Revit started. Nothing was opened: try again."
    WIN="$(rf winpath "$B" "$FILE")" || exit 1
    echo "Copy: $(tilde "$FILE")"
    return 0
  fi
  now="$(rf info "$FILE")"
  [ "$(field "$now" format)/$(field "$now" size)/$(field "$now" mtime_ns)" = "$(field "$P" format)/$(field "$P" size)/$(field "$P" mtime_ns)" ] \
    || die "The file changed while Revit started. Nothing was opened: try again."
}

while :; do
  revit_running "$B" "$YEAR" || attempt_fresh || die "Revit $YEAR is not running in $NAME any more. Nothing was opened."
  rc=3
  if revit_running "$B" "$YEAR"; then ro ready 10; rc=$?; else sleep 2; fi
  case "$rc" in
    0) prepare
       ro send "$WIN"; rc=$?
       case "$rc" in
         0) echo "Opened in Revit $YEAR ($NAME)."; exit 0 ;;
         3) ;;   # Revit has just left DDE: below
         4) die "Revit $YEAR is busy: close its open dialog, then try again." ;;
         5) die "Revit $YEAR did not answer. It may still open the file: look before you try again." ;;
         *) die "Revit $YEAR refused the file. Open it with File > Open." ;;
       esac ;;
    3) ;;
    *) die "revitopen.exe could not run (exit $rc)." ;;
  esac
  [ "$SECONDS" -lt "$DEADLINE" ] || die "Revit $YEAR did not take the file in time. When it is open, try again."
done
