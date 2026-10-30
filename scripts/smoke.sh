#!/usr/bin/env bash
# ./revit test <year> [bottle]: Revit runs with no one at it, in a temporary copy of the bottle (<bottle>.test) that
# this script makes and deletes, and plays the journals of scripts/smoke/: start (start and quit), core (a new project
# from a template, Save As), reopen (that file opened again, Save As). Wine never runs in the bottle itself, and the
# copy's links to the Mac's own folders (Documents, Desktop, …) are empty folders there.
# Usage: scripts/smoke.sh <year> <bottle> [--log] [--keep] [--scenarios start,core,reopen]
#   --log   also CrossOver's log, wine.cxlog (hundreds of MB)     --keep   keep the copy (for the maintainer)
# Exit: 0 every scenario passed, 3 a person must act (sign in, a question of CrossOver), 1 anything else.
# Logs: logs/<bottle>/<time>-test/: result.json, the journals Revit wrote while it played ours, the output of each run.
# SMOKE_TIMEOUT, SMOKE_START_WAIT, SMOKE_STALL, SMOKE_WORKER_WAIT, SMOKE_POLL, SMOKE_PREP_TIMEOUT: seconds, tests only.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/common.sh"
USAGE="Usage: scripts/smoke.sh <year> <bottle> [--log] [--keep] [--scenarios start,core,reopen]"
YEAR_ARG=""; NAME=""; LOG=0; KEEP=0; SCEN_ARG="start,core,reopen"
while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOG=1 ;;
    --keep) KEEP=1 ;;
    --scenarios) [ $# -ge 2 ] || usage_die "$USAGE"; SCEN_ARG="$2"; shift ;;
    -*) usage_die "Unknown option: $1" ;;
    *) if [ -z "$YEAR_ARG" ]; then YEAR_ARG="$1"; elif [ -z "$NAME" ]; then NAME="$1"; else usage_die "$USAGE"; fi ;;
  esac
  shift
done
[ -n "$NAME" ] || usage_die "$USAGE"
load_profile "$YEAR_ARG" || usage_die "Revit $YEAR_ARG is not supported yet. Supported: ${REVIT_SUPPORTED[*]}."
revit_bottle_name_ok "$NAME" || usage_die "Bottle name may contain only letters, digits, - and _: \"$NAME\""
SCEN=(); IFS=, read -r -a parts <<<"$SCEN_ARG"
for s in ${parts[@]+"${parts[@]}"}; do in_list "$s" start core reopen || usage_die "--scenarios: start, core, reopen"; done
for s in start core reopen; do case ",$SCEN_ARG," in *",$s,"*) SCEN+=("$s") ;; esac; done   # always in this order
[ ${#SCEN[@]} -gt 0 ] || usage_die "--scenarios: start, core, reopen"
TIMEOUT="${SMOKE_TIMEOUT:-600}"            # one scenario, from the start of Revit
START_WAIT="${SMOKE_START_WAIT:-120}"      # until Revit is idle (54 real journals: 16 s median, 46 s the longest)
STALL="${SMOKE_STALL:-180}"                # the journal not growing (healthy pauses in real journals: up to 107 s)
WORKER_WAIT="${SMOKE_WORKER_WAIT:-30}"     # RevitWorker.exe after Revit has quit
POLL="${SMOKE_POLL:-2}"
PREP_TIMEOUT="${SMOKE_PREP_TIMEOUT:-600}"  # CrossOver's upgrade of the copy and a first program in it
for v in "$TIMEOUT" "$START_WAIT" "$STALL" "$WORKER_WAIT" "$PREP_TIMEOUT"; do
  [[ "$v" =~ ^[0-9]+$ ]] || usage_die "Not a number of seconds: $v"
done
[[ "$POLL" =~ ^[0-9]+(\.[0-9]+)?$ ]] || usage_die "Not a number of seconds: $POLL"

B="$(bottle_path "$NAME")"; SFX="$(bottle_sfx "$NAME" "$YEAR")"
CLONE="$(smoke_clone_name "$NAME")"; C="$(bottle_path "$CLONE")"; CR=""   # the copy; CR: its real path, once made
RUN_ID="${REVIT_RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
REVIT_EXE="C:\\Program Files\\Autodesk\\Revit $YEAR\\Revit.exe"
WD="$C/drive_c/revit-smoke"   # C:\revit-smoke, the working folder of every run
OURS=0; RUN_DIR=""; LAUNCHER=""; FIN=0; WHY=""; TPL=""; RUNF=/dev/null; OUTLOG=/dev/null
STATE="$(mktemp -d "${TMPDIR:-/tmp}/revit-smoke.XXXXXX")" || die "Cannot create a temporary folder."
: > "$STATE/meta"

shielded() { ( trap '' INT TERM HUP; exec "$@" ); }   # <command…> that a signal does not cut short: this script
# notes the signal (lock_take's trap) and stops at its next stop_point, with what the command gave
py() { shielded python3 -I -B "$ROOT/tools/smoke.py" "$@"; }
meta() { printf '%s=%s\n' "$1" "$2" >> "$STATE/meta"; }   # $1 = key, $2 = value, for result.json (smoke.py result)
kv()   { printf '%s=%s\n' "$1" "$2" >> "$RUNF"; }          # the same for the scenario that runs
refuse() { # $1 = result, $2 = exit code, rest = the message: a check failed before anything was made
  result_set result "$1"; echo "${*:3}" >&2; exit "$2"
}
fail_run() { meta error "$*"; exit 1; }   # $* = why the test cannot go on: result.json and the summary say it
stop_point() { # a Ctrl-C (or TERM, HUP) was noted: stop here; the cleanup on exit does the rest
  [ "$STOP_REQUESTED" = 0 ] && return 0
  meta stopped 1; stop_check
}
bounded() { # $1 = seconds, rest = a command: in the background with stdin from /dev/null and fd 7 and 9 closed (a
  # Ctrl-C at the terminal does not reach it, the lock and the events stay ours), ended after $1 s (124) or, outside the
  # cleanup, at a stop request (130). Returns its exit code
  local lim=$(( $1 * 10 )) i=0 p; shift
  "$@" </dev/null 7>&- 9>&- & p=$!
  while kill -0 "$p" 2>/dev/null; do
    if [ $i -ge $lim ] || { [ "$STOP_REQUESTED" != 0 ] && [ "$FIN" = 0 ]; }; then
      kill -TERM "$p" 2>/dev/null; sleep 0.5; kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null
      [ $i -ge $lim ] && return 124; return 130
    fi
    sleep 0.1; i=$((i + 1))
  done
  wait "$p"
}
bg_wait() { # <command…>: like bounded without a limit and not stopped by a signal (deleting a copy)
  local p; "$@" </dev/null 7>&- 9>&- & p=$!
  while kill -0 "$p" 2>/dev/null; do wait "$p"; done
  wait "$p"
}

# ---- the copy: its marker, what may delete it ----
marker_get() { sed -n "s/^$2=//p" "$1/$SMOKE_MARK" 2>/dev/null | head -1; }   # $1 = copy path, $2 = key
marker_write() { # $1 = state (creating, ready, kept) of this run's copy, through a temporary file and mv
  printf 'smoke_clone=1\nrun_id=%s\nsource=%s\ntime=%s\nstate=%s\n' "$RUN_ID" "$NAME" "$T_START" "$1" \
    > "$C/$SMOKE_MARK.new" && mv -f "$C/$SMOKE_MARK.new" "$C/$SMOKE_MARK"
}
clone_guard() { # $1 = copy path: ours to delete only as a real folder right inside the bottles folder (not a link),
  # named <bottle>.test, with our marker as a file of its own
  local rp rb
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  case "$(basename "$1")" in ?*.test) ;; *) return 1 ;; esac
  rp="$(cd "$1" 2>/dev/null && pwd -P)" && rb="$(cd "$BOTTLES" 2>/dev/null && pwd -P)" || return 1
  [ "$(dirname "$rp")" = "$rb" ] && is_smoke_clone "$1" && grep -qx 'smoke_clone=1' "$1/$SMOKE_MARK"
}
wait_stopped() { # $1 = bottle path, $2 = seconds: 0 once nothing runs in it
  local t=$SECONDS
  while [ "$(bottle_activity "$1")" != stopped ]; do
    [ $((SECONDS - t)) -lt "$2" ] || return 1
    sleep 1
  done
}
rm_clone() { # $1 = a copy that passed clone_guard, deleted by hand: the marker last, and only once all else is gone,
  # so a delete cut short or failed leaves a copy that the next run still knows as one of ours
  bg_wait shielded find "$1" -mindepth 1 -maxdepth 1 ! -name revit-macos -exec rm -rf {} + 2>/dev/null
  [ -z "$(find "$1" -mindepth 1 -maxdepth 1 ! -name revit-macos 2>/dev/null)" ] || return 1
  bg_wait shielded rm -rf "$1" 2>/dev/null
}
KEEP_FOR_CX=(! -name revit-macos ! -name system.reg ! -name cxbottle.conf)   # find: all but our marker's folder and
# what CrossOver needs to find the bottle and read it
menu_apps_remove() { # $1 = bottle name: its CrossOver menu apps, then the folders they leave empty
  local a any=0
  while IFS= read -r a; do [ -n "$a" ] && rm -rf "$a" && any=1; done < <(cx_menu_apps "$1")
  [ $any = 0 ] || find "$HOME/Applications/CrossOver" -mindepth 1 -type d -empty -delete 2>/dev/null
  return 0
}
clone_remove() { # $1 = name of a copy of ours: ends what runs in it, then deletes it with CrossOver (a copy CrossOver
  # cannot find, one without system.reg, by hand) and its menu apps. A copy cut short while it was made (state
  # creating) never ran Wine: by hand at once. CrossOver deletes in no set order, so it gets only the last few files:
  # the bulk goes by hand first, and a delete cut short anywhere leaves a copy that still has its marker. Signals do
  # not cut these deletes short. 1 with WHY when it cannot
  local name="$1" p state rest; p="$(bottle_path "$1")"
  if [ -e "$p" ] || [ -L "$p" ]; then
    clone_guard "$p" || { WHY="it is not a copy made by ./revit test"; return 1; }
    state="$(marker_get "$p" state)"
    [ "$state" = creating ] || bounded 30 env WINEPREFIX="$p" "$CX/bin/wineserver" -k >/dev/null 2>&1
    wait_stopped "$p" 30 || { WHY="programs still run in it"; return 1; }
    bg_wait shielded find "$p" -mindepth 1 -maxdepth 1 "${KEEP_FOR_CX[@]}" -exec rm -rf {} + 2>/dev/null
    rest="$(find "$p" -mindepth 1 -maxdepth 1 "${KEEP_FOR_CX[@]}" 2>/dev/null)"
    if [ "$state" != creating ] && [ -f "$p/system.reg" ] && [ -z "$rest" ]; then
      bg_wait shielded "$CX/bin/cxbottle" --bottle "$name" --delete --force >/dev/null 2>&1
    fi
    if [ -e "$p" ] && clone_guard "$p"; then rm_clone "$p"; fi
    [ ! -e "$p" ] || { WHY="some of its files could not be deleted"; return 1; }
  fi
  menu_apps_remove "$name"
}
old_copies() { # copies left by earlier runs (one that was killed, a Mac that went off): a kept one stays; one with
  # programs running stops the test; any other is deleted
  local p n
  for p in "$BOTTLES"/*.test; do
    [ -d "$p" ] && [ ! -L "$p" ] && is_smoke_clone "$p" || continue
    n="$(basename "$p")"
    [ "$(marker_get "$p" state)" != kept ] || continue
    if [ "$(bottle_activity "$p")" != stopped ]; then
      refuse in_use 1 "Programs of an earlier test still run in its copy $n. To end them:
  WINEPREFIX=\"\$HOME/Library/Application Support/CrossOver/Bottles/$n\" \"$CX/bin/wineserver\" -k
or restart the Mac. Then run ./revit test $YEAR$SFX again."
    fi
    echo "Deleting the copy $n that an earlier test left behind…"
    clone_remove "$n" || refuse failed 1 "Could not delete the copy $n of an earlier test: $WHY. Delete it in CrossOver, then run ./revit test $YEAR$SFX again."
  done
}

# ---- Revit in the copy ----
clone_procs() { # $1 = pgrep pattern: those processes with a file open in the copy (as revit_running, without name
  # lookups for network connections: Revit has them, and each lookup can take seconds), a pid a line
  local p out
  [ -n "$CR" ] || return 0
  for p in $(pgrep -f "$1" 2>/dev/null); do
    out="$(lsof -n -P -p "$p" -Fn 2>/dev/null)"
    grep -qF "n$CR/" <<<"$out" && echo "$p"
  done
  return 0
}
kill_revit() { # Revit in the copy: taskkill first, then wineserver -k ends everything there (the licensing services too)
  bounded 20 "$CX/bin/wine" --bottle "$CLONE" taskkill /f /im Revit.exe >>"$OUTLOG" 2>&1
  bounded 30 env WINEPREFIX="$C" "$CX/bin/wineserver" -k >/dev/null 2>&1
}
launcher_stop() { # the wine that started Revit, if it is still there: TERM, 2 s, then KILL (never a wait that hangs)
  local i
  [ -n "$LAUNCHER" ] || return 0
  kill -TERM "$LAUNCHER" 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do kill -0 "$LAUNCHER" 2>/dev/null || break; sleep 0.1; done
  kill -KILL "$LAUNCHER" 2>/dev/null; wait "$LAUNCHER" 2>/dev/null; LAUNCHER=""
}

# ---- the end: one cleanup for every way out ----
finish() { # on every exit after lock_take (whose Ctrl-C handling stays): the launcher, CrossOver's lock, this run's
  # copy with everything running in it and its menu apps; then result.json and the summary. Idempotent. Keeps the exit
  # code, or gives the run's own once its log folder exists: 0 ok, 3 a person must act, 1 anything else
  local rc=$? res
  [ "$FIN" = 0 ] || return 0
  FIN=1
  cx_bottle_unlock
  launcher_stop
  if [ "$OURS" = 1 ]; then
    if [ "$KEEP" = 1 ] && [ "$(marker_get "$C" state)" = ready ] && clone_guard "$C"; then
      bounded 30 env WINEPREFIX="$C" "$CX/bin/wineserver" -k >/dev/null 2>&1
      marker_write kept; meta kept 1; meta copy_removed 0
      echo "Kept the copy $CLONE (--keep): ./revit test never deletes a kept copy. To delete it:"
      echo "  \"$CX/bin/cxbottle\" --bottle \"$CLONE\" --delete --force"
    elif clone_remove "$CLONE"; then
      meta copy_removed 1
    else
      meta copy_removed 0; meta copy_problem "$WHY"   # the run fails (smoke.py result), whatever its scenarios gave
      echo "! Could not delete the temporary copy $CLONE: $WHY." >&2
      echo "  The next ./revit test $YEAR$SFX deletes it; or delete it in CrossOver." >&2
    fi
  fi
  if [ -n "$RUN_DIR" ]; then
    if res="$(py result "$STATE" --out "$RUN_DIR/result.json")" && [ -n "$res" ]; then
      result_set result "$res"
      if [ "$res" != stopped ]; then
        echo; py summary "$RUN_DIR/result.json" --history "$DATA/logs"
        echo "Logs: logs/${RUN_DIR#"$DATA/logs/"}"
      fi
      case "$res" in ok) rc=0 ;; needs_person) rc=3 ;; *) rc=1 ;; esac
    else   # no result.json: never a pass
      rc=1; [ "$STOP_REQUESTED" != 0 ] || result_set result failed
      echo "! result.json could not be written in logs/${RUN_DIR#"$DATA/logs/"}, so the test counts as failed." >&2
      echo "  Check the free space on this Mac, then run ./revit test $YEAR$SFX again." >&2
    fi
  fi
  rm -rf "$STATE"
  exit "$rc"
}

lock_take "./revit test $YEAR $NAME"
trap finish EXIT
T_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- checks: any failing one stops the test before anything is made ----
[ -x "$CX/bin/wine" ] && [ -x "$CX/bin/wineserver" ] && [ -x "$CX/bin/cxbottle" ] \
  || refuse failed 1 "CrossOver not found in /Applications. Install it from https://www.codeweavers.com/crossover"
bottle_guard must_exist "$YEAR" "$NAME"
[ -f "$(revit_dir_unix "$B" "$YEAR")/Revit.exe" ] || refuse failed 1 "Revit $YEAR is not installed in $NAME. To install it: ./revit install $YEAR$SFX"
revit_anywhere() { # a Revit.exe of any year with files open in any bottle (as revit_running, for every bottle)
  local p out rb; rb="$(cd "$BOTTLES" 2>/dev/null && pwd -P)" || return 1
  for p in $(pgrep -f 'Autodesk.Revit 20[0-9][0-9].Revit\.exe' 2>/dev/null); do
    out="$(lsof -n -P -p "$p" -Fn 2>/dev/null)"
    grep -qF "n$rb/" <<<"$out" && return 0
  done
  return 1
}
! revit_anywhere || refuse in_use 1 "Revit is running. Save your work and quit every Revit, then run ./revit test $YEAR$SFX again."
if [ -L "$C" ]; then
  refuse failed 1 "$(tilde "$C") is a link. ./revit test does not touch it: delete the link, then run ./revit test $YEAR$SFX again."
elif [ -e "$C" ] && ! is_smoke_clone "$C"; then
  refuse failed 1 "A bottle named $CLONE exists, not made by ./revit test. Rename or delete it in CrossOver, then run ./revit test $YEAR$SFX again."
elif [ -e "$C" ] && [ "$(marker_get "$C" state)" = kept ]; then
  refuse failed 1 "The copy $CLONE was kept by an earlier test (--keep). Delete it first:
  \"$CX/bin/cxbottle\" --bottle \"$CLONE\" --delete --force"
fi
bottles_on_apfs "$B" || refuse failed 1 "The CrossOver bottles are not on an APFS volume, so a copy would take the full size of the bottle. ./revit test needs them on APFS."
read -r s_in s_age s_days <<<"$(py signin "$B" "$YEAR" 2>/dev/null | shielded /usr/bin/perl -MJSON::PP -e '
  my $d = eval { decode_json(join "", <STDIN>) } || {};
  printf "%d %s %s\n", ($d->{signed_in} ? 1 : 0), $d->{journal_age_days} // "-", $d->{license_days_left} // "-"')"
stop_point   # a Ctrl-C during the check: stopped, not "sign in"
[ "${s_in:-0}" = 1 ] \
  || refuse needs_person 3 "Open Revit $YEAR ($NAME) from ~/Applications, sign in, quit Revit, then run ./revit test $YEAR$SFX again."
case "$(bottle_activity "$B")" in
  stopped) ;;
  active) refuse in_use 1 "Revit's background services still run in $NAME. Quit them with ./revit stop $YEAR$SFX, then run ./revit test $YEAR$SFX again." ;;
  *) refuse failed 1 "Could not check whether programs run in $NAME (lsof did not answer). Nothing was changed. Try again in a minute." ;;
esac
old_copies
stop_point
if [[ "${s_age:-}" =~ ^[0-9]+$ ]] && [ "$s_age" -gt 30 ]; then
  echo "! Revit last ran in $NAME $s_age days ago: Autodesk may ask to sign in again."
  echo "  If the test stops at sign-in: open Revit $YEAR ($NAME) from ~/Applications, sign in, quit Revit, run the test again."
fi
if [[ "${s_days:-}" =~ ^[0-9]+$ ]] && [ "$s_days" -le 7 ]; then
  echo "! Revit said its license in $NAME ends in $s_days days."
  echo "  If the test stops at licensing, check the license in your Autodesk Account."
fi

# ---- the copy ----
echo "Revit opens and closes by itself for about $(( ${#SCEN[@]} * 2 )) minutes. Do not click in its windows."
echo "If a browser sign-in page opens, close it: the test stops and says what to do. Your bottle is not changed."
echo "Revit runs in a temporary copy of your bottle on this Mac, using the sign-in you made there; the copy is deleted"
echo "afterwards. Autodesk files and licensing are not changed."
RUN_DIR="$(run_dir_new "$NAME" test)" || { RUN_DIR=""; die "Cannot create a log folder in $(tilde "$DATA/logs")."; }
result_set log_dir "$RUN_DIR"
meta run_id "$RUN_ID"; meta time "$T_START"; meta year "$YEAR"; meta bottle "$NAME"; meta copy "$CLONE"
meta crossover "$(crossover_build)"; meta engine "$(runlog_engine 7>&- 9>&-)"; meta scenarios "${SCEN[*]}"
echo "Making the temporary copy ${CLONE}…"
mkdir "$C" 2>/dev/null || fail_run "could not make the folder of the copy"
OURS=1   # from here the cleanup deletes the copy: the marker comes first, before anything is copied into it
mkdir "$C/revit-macos" && marker_write creating || fail_run "could not write the marker of the copy"
# CrossOver's lock of the bottle while it is copied: nothing starts in it meanwhile, and it must still be at rest
bottle_copy_at_rest "$B" "$C"; rc=$?   # the contents into the folder that holds the marker
stop_point
if [ $rc != 0 ]; then
  case "$COPY_WHY" in
    busy) fail_run "CrossOver is busy with $NAME; try again in a minute" ;;
    active) fail_run "programs started in $NAME; quit them with ./revit stop $YEAR$SFX and run the test again" ;;
    copy) fail_run "copying the bottle failed" ;;
    *) fail_run "programs started in $NAME while it was copied; quit them with ./revit stop $YEAR$SFX and run the test again" ;;
  esac
fi
rm -rf "$C/desktopdata" "$C/files"   # as cxbottle --copy: CrossOver's menu and association records of the bottle
cut_links() { # the copy's links to the Mac's own folders (Documents, Desktop, …) become empty folders before any wine
  # call, so Revit in the copy writes nothing outside it; their paths go to result.json
  py cut-links "$C" >> "$STATE/links" 2>/dev/null \
    || fail_run "the user folder of the copy (C:\\users\\crossover) is a link to another folder, or a link in it to a folder of this Mac could not be replaced"
}
cut_links
[ -f "$C/system.reg" ] && [ -f "$C/cxbottle.conf" ] || fail_run "the copy has no system.reg or cxbottle.conf"
py clone-conf "$C/cxbottle.conf" --uuid "$(uuidgen 2>/dev/null)" >/dev/null || fail_run "could not change cxbottle.conf of the copy"
marker_write ready || fail_run "could not write the marker of the copy"
CR="$(cd "$C" && pwd -P)"

# ---- preparing the copy: CrossOver upgrades a bottle at the first wine after an update; here it must say so ----
echo "Preparing the copy (CrossOver)…"
t_prep=$SECONDS
prep_fail() { meta prepare failed; meta prepare_reason "$1"; meta prepare_seconds $((SECONDS - t_prep)); exit 1; }
prep_left() { local l=$(( PREP_TIMEOUT - (SECONDS - t_prep) )); [ $l -gt 0 ] || l=1; echo $l; }
cx_t="$(py conf-get "$CX/etc/CrossOver.conf" CrossOver BuildTimestamp 2>/dev/null)"
[ -n "$cx_t" ] || prep_fail "CrossOver's BuildTimestamp was not found"
[ "$(py conf-get "$C/cxbottle.conf" Bottle Timestamp 2>/dev/null)" = "$cx_t" ] && meta upgraded 0 || meta upgraded 1
# --update-only: CrossOver ends with an error when the upgrade fails (a plain wine would go on as if nothing happened)
bounded "$(prep_left)" "$CX/bin/wine" --bottle "$CLONE" --update-only >>"$RUN_DIR/prepare.log" 2>&1; rc=$?
stop_point
case $rc in 0) ;; 124) prep_fail "the upgrade took longer than $PREP_TIMEOUT s" ;; *) prep_fail "the upgrade failed (exit $rc)" ;; esac
[ "$(py conf-get "$C/cxbottle.conf" Bottle Timestamp 2>/dev/null)" = "$cx_t" ] \
  || prep_fail "the copy is not at this CrossOver's build after the upgrade (Timestamp)"
cut_links   # again: an upgrade may link an empty Documents to the Mac's folder (Wine's shell32)
bounded "$(prep_left)" "$CX/bin/wine" --bottle "$CLONE" cmd /c ver >>"$RUN_DIR/prepare.log" 2>&1; rc=$?
stop_point
case $rc in 0) ;; 124) prep_fail "a first program took longer than $PREP_TIMEOUT s" ;; *) prep_fail "a first program did not run (cmd /c ver, exit $rc)" ;; esac
meta prepare ok; meta prepare_seconds $((SECONDS - t_prep))

if in_list core "${SCEN[@]}" && t="$(py template "$C" "$YEAR" 2>/dev/null)"; then
  TPL="${t%%$'\t'*}"; meta template "$TPL"; meta template_source "${t#*$'\t'}"
fi
rm -rf "$WD"; mkdir -p "$WD/out" || fail_run "could not make C:\\revit-smoke in the copy"

# ---- the scenarios ----
run_scenario() { # $1 = scenario, $2 = its number: plays its journal in the copy, without --wait-children (the
  # licensing services outlive Revit): the watchdog follows Revit.exe and the journal. 0 when it passed
  local s="$1" j="$WD/$1.txt" mark="$STATE/$1.since" t0 tw r jp="" js="" ji=0 last="" grown alive seen=0 idle=0
  local wd=none signin=0 nostart=0 worker=0 v why envs=()
  RUNF="$STATE/$s.run"; OUTLOG="$RUN_DIR/$s-stdout.log"; : > "$RUNF"
  echo "Scenario $2 of ${#SCEN[@]}: ${s}…"
  case "$s" in
    core)
      if [ -z "$TPL" ]; then kv seconds 0; kv error "no project template of Revit $YEAR in the bottle"; echo "  no project template"; return 1; fi
      rm -f "$WD/out/"* ;;   # out\ empty before core; reopen needs the smoke.rvt core saves
    reopen) rm -f "$WD/out/smoke2.rvt" ;;
  esac
  py journal "$s" --year "$YEAR" ${TPL:+--template "$TPL"} --out "$j" || { kv error "its journal could not be written"; return 1; }
  [ "$LOG" = 0 ] || envs=(CX_LOG="$RUN_DIR/wine.cxlog" CX_DEBUGMSG="${CX_DEBUGMSG:-err,+seh}")
  touch "$mark"; t0=$SECONDS; grown=$SECONDS   # the marker right before Revit starts: its journal is newer
  ( cd "$WD" && exec env ${envs[@]+"${envs[@]}"} "$CX/bin/wine" --bottle "$CLONE" "$REVIT_EXE" "C:\\revit-smoke\\$s.txt" ) \
    </dev/null >"$OUTLOG" 2>&1 7>&- 9>&- &
  LAUNCHER=$!
  while [ "$STOP_REQUESTED" = 0 ]; do
    alive=0; [ -z "$(clone_procs "Autodesk.Revit $YEAR.Revit\.exe")" ] || alive=1
    [ "$alive" = 1 ] || [ "$seen" = 0 ] || break   # it was there (Revit.exe or its journal) and now is gone
    [ "$alive" = 0 ] || seen=1
    if r="$(py replayed "$C" "$YEAR" --since "$mark" 2>/dev/null)"; then
      IFS=$'\t' read -r jp js ji <<<"$r"; seen=1
      [ "$js" = "$last" ] || { last="$js"; grown=$SECONDS; }
      [ "$ji" != 1 ] || idle=1
    fi
    [ "$signin" = 1 ] || [ -z "$(clone_procs 'AdskIdentityManager\.exe|AdSSO\.exe')" ] || signin=1
    if [ "$seen" = 0 ]; then
      [ $((SECONDS - t0)) -lt "$START_WAIT" ] || { nostart=1; break; }
    elif [ "$idle" = 0 ] && [ $((SECONDS - t0)) -ge "$START_WAIT" ]; then wd=start; break
    elif [ $((SECONDS - grown)) -ge "$STALL" ]; then wd=stall; break
    fi
    [ $((SECONDS - t0)) -lt "$TIMEOUT" ] || { wd=total; break; }
    sleep "$POLL"
  done
  kv seconds $((SECONDS - t0))
  if [ "$STOP_REQUESTED" != 0 ]; then kv stopped 1; stop_point; fi
  if [ "$wd" != none ] || [ "$nostart" = 1 ]; then kill_revit; fi   # taskkill, then wineserver -k of the copy
  tw=$SECONDS   # RevitWorker.exe can outlive Revit: some time to finish, then it is ended
  while [ "$wd" = none ] && [ -n "$(clone_procs 'RevitWorker\.exe')" ]; do
    stop_point
    if [ $((SECONDS - tw)) -ge "$WORKER_WAIT" ]; then
      bounded 20 "$CX/bin/wine" --bottle "$CLONE" taskkill /f /im RevitWorker.exe >>"$OUTLOG" 2>&1; worker=1; break
    fi
    sleep "$POLL"
  done
  tw=$SECONDS; while [ -n "$LAUNCHER" ] && kill -0 "$LAUNCHER" 2>/dev/null && [ $((SECONDS - tw)) -lt 5 ]; do sleep 0.1; done
  launcher_stop
  stop_point
  kv watchdog "$wd"; kv worker_killed "$worker"; kv signin_seen "$signin"; kv no_start "$nostart"
  if r="$(py replayed "$C" "$YEAR" --since "$mark" 2>/dev/null)"; then IFS=$'\t' read -r jp js ji <<<"$r"; fi
  [ -z "$jp" ] || cp "$jp" "$RUN_DIR/$s-journal.txt" 2>/dev/null
  py verdict "$s" --journal "$j" --replayed "$jp" --since "$mark" --outputs "$WD/out" --watchdog "$wd" \
    $([ "$signin" = 1 ] && echo --signin-seen) $([ "$nostart" = 1 ] && echo --no-start) --crash-log "$OUTLOG" \
    > "$STATE/$s.verdict.json" || { kv error "no verdict"; echo "  failed: no verdict"; return 1; }
  IFS=$'\t' read -r v why <<<"$(shielded /usr/bin/perl -MJSON::PP -0 -ne \
    'my $d = eval { decode_json($_) } or exit 0; print "$d->{verdict}\t$d->{reason}\n"' "$STATE/$s.verdict.json")"
  case "$v" in
    pass) echo "  passed ($((SECONDS - t0)) s)"; return 0 ;;
    person) echo "  needs you: $why" ;;
    *) echo "  failed: $why" ;;
  esac
  return 1
}
n=0; passed=1
for s in "${SCEN[@]}"; do
  n=$((n + 1))
  run_scenario "$s" "$n" || { passed=0; break; }   # the next one needs this one: result.json lists the rest as skipped
done
stop_point   # a Ctrl-C noted while the last helper ran
exit $((1 - passed))   # finish gives the exit code of the run from result.json; without one, never 0 after a failure
