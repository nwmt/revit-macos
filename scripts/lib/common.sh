# Shared basics for every script: paths, messages, the run folder, the lock, the bottle checks.
# Source after setting ROOT:  ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/common.sh"
# Defines functions and variables only. REVIT_CX (tests only) points at a fake CrossOver.
. "$ROOT/scripts/lib/versions.sh"
CX="${REVIT_CX:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver}"
BOTTLES="$HOME/Library/Application Support/CrossOver/Bottles"
LOCK_FILE="$ROOT/logs/.lock"
STOP_REQUESTED=0; CHILD=""

die()       { echo "$*" >&2; exit 1; }
usage_die() { echo "$*" >&2; exit 2; }
tilde() { case "$1" in "$HOME"/*) echo "~${1#"$HOME"}" ;; *) echo "$1" ;; esac; }
bottle_path() { echo "$BOTTLES/$1"; }
bottle_sfx() { [ "$1" = "$(revit_bottle_default "$2")" ] || printf ' %s' "$1"; }   # hints name a non-default bottle

free_gb() { # what Finder and System Settings call "available": includes purgeable space that df does not count
  local g
  g=$(osascript -l JavaScript -e 'ObjC.import("Foundation"); var r = Ref();
    $.NSURL.fileURLWithPath("/").getResourceValueForKeyError(r, $.NSURLVolumeAvailableCapacityForImportantUsageKey, null);
    Math.floor(ObjC.unwrap(r[0]) / 1e9)' 2>/dev/null)
  [[ "$g" =~ ^[0-9]+$ ]] || g=$(df -g "$ROOT" | awk 'NR==2 {print $4}')
  echo "${g:-0}"
}

run_dir_new() { # $1 = folder under logs/ (a bottle name, or revit<year>), $2 = kind (install, steps, addins, debug, …).
  # Prints logs/<$1>/<time>-<$2>, created now; a second run in the same second gets -2, -3, …
  local base d n=1
  mkdir -p "$ROOT/logs/$1" || return 1
  base="$ROOT/logs/$1/$(date +%Y%m%d-%H%M%S)-$2"; d="$base"
  until mkdir "$d" 2>/dev/null; do n=$((n + 1)); d="$base-$n"; [ $n -lt 100 ] || return 1; done
  echo "$d"
}

# ---- the lock: one for everything that changes state (bottles, installers/, build/, toolchain/) ----
# flock on fd 9 (macOS has no flock(1), so through the system perl). It holds while any process keeps fd 9 open: the
# script, its child scripts, curl, 7zz. The kernel drops it when the last one closes, so there is no stale lock to
# remove. Wine runs with fd 9 closed (scripts/lib/wine.sh): wineserver outlives the script by hours.
lock_fd_ours() { # fd 9 is open on this clone's logs/.lock: a script up the chain took the lock
  [ -e /dev/fd/9 ] || return 1
  /usr/bin/perl -e 'open(my $f, ">&=", 9) or exit 2; my @a = stat($f); my @b = stat($ARGV[0]) or exit 3;
    exit(($a[0] == $b[0] && $a[1] == $b[1]) ? 0 : 1)' "$LOCK_FILE" 2>/dev/null
}
lock_flock9() { /usr/bin/perl -MFcntl=:flock -e 'open(my $f, ">&=", 9) or exit 2; flock($f, LOCK_EX | LOCK_NB) or exit 1' 2>/dev/null; }
lock_owner() { cat "$LOCK_FILE.owner" 2>/dev/null || echo "another task"; }
lock_take() { # $* = what this script does (shown to whoever finds the lock busy)
  mkdir -p "$ROOT/logs" || die "Cannot write to $(tilde "$ROOT/logs")."
  if ! { lock_fd_ours && lock_flock9; }; then   # not inherited: take it
    exec 9>>"$LOCK_FILE" || die "Cannot open $(tilde "$LOCK_FILE")."
    lock_flock9 || die "Another task is running: $(lock_owner). Wait until it finishes, then try again."
    printf '%s\n' "$*" > "$LOCK_FILE.owner"
  fi
  # TERM/HUP/INT (Ctrl-C): let the running Wine program finish (bash runs the trap after the foreground command), pass
  # TERM on to a child script started with run_child (a background child ignores INT), stop at the next stop_check
  trap 'STOP_REQUESTED=1; [ -z "$CHILD" ] || kill -TERM "$CHILD" 2>/dev/null' TERM HUP INT
}
lock_free() { # 0 when nobody else holds the lock (for ./revit's checks before it takes the lock itself)
  lock_fd_ours && lock_flock9 && return 0
  [ -e "$LOCK_FILE" ] || return 0
  /usr/bin/perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or exit 0; flock($f, LOCK_EX | LOCK_NB) or exit 1' "$LOCK_FILE"
}
stop_check() { [ "$STOP_REQUESTED" = 0 ] || { echo "Stopped." >&2; exit 1; }; }
run_child() { # [--log <file>] <command…>: runs it in the background so that TERM/HUP/INT reach it as TERM (the
  # trap passes them on; a background child ignores INT itself), and waits until it has finished. With --log its output
  # also goes to <file> through tee, which runs without the lock's fd and gets up to 2 s to finish writing (a process
  # the command left behind may keep its output open). Returns the command's exit code
  local rc log="" fifo="" tpid="" i
  if [ "${1:-}" = --log ]; then log="$2"; shift 2; fi
  if [ -n "$log" ]; then
    fifo="$(mktemp -u "${TMPDIR:-/tmp}/revit-macos.XXXXXX")" && mkfifo "$fifo" || return 1
    tee -a "$log" < "$fifo" 9>&- & tpid=$!
    "$@" > "$fifo" 2>&1 & CHILD=$!
  else
    "$@" & CHILD=$!
  fi
  while :; do wait "$CHILD"; rc=$?; kill -0 "$CHILD" 2>/dev/null || break; done
  CHILD=""
  if [ -n "$tpid" ]; then
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do kill -0 "$tpid" 2>/dev/null || break; sleep 0.1; done
    rm -f "$fifo"
  fi
  return $rc
}

# ---- bottle checks, shared by ./revit and every script that changes a bottle ----
bottle_years() { # the Revit years of bottle path $1: its description (new-bottle.sh names it "Revit <year>" before
  # installing anything, so a half-done install has it too) and its Revit folders
  sed -n 's/^"Description" = "Revit \([0-9][0-9][0-9][0-9]\)"$/\1/p' "$1/cxbottle.conf" 2>/dev/null
  local d; for d in "$1/drive_c/Program Files/Autodesk/Revit "[0-9][0-9][0-9][0-9]; do [ -d "$d" ] && echo "${d##* }"; done
  return 0
}
revit_running() { # $1 = bottle path, $2 = year: a Revit.exe of that year with files open in that bottle. The bottle's
  # background services (licensing) run for hours without Revit, so "wineserver is up" is not the test. Output goes
  # through variables, not `| grep -q`: under pipefail an early grep exit gives the writer SIGPIPE
  local p rb out; rb="$(cd "$1" 2>/dev/null && pwd -P)" || return 1   # lsof prints real paths
  for p in $(pgrep -f "Autodesk.Revit $2.Revit\.exe" 2>/dev/null); do
    out="$(lsof -p "$p" -Fn 2>/dev/null)"
    grep -qF "n$rb/" <<<"$out" && return 0
  done
  return 1
}
bottle_guard() { # $1 = must_exist | running_ok (like must_exist, Revit may run: ./revit stop) | allow_missing
  # (creating, removing leftovers), $2 = year, $3 = bottle. Dies with the reason. A wrong year/bottle pair would
  # rebuild or delete another Revit; CrossOver follows a link to the real bottle, so checks and actions could differ
  local mode="$1" year="$2" name="$3" b ys sfx
  b="$(bottle_path "$name")"; sfx="$(bottle_sfx "$name" "$year")"
  [ ! -L "$b" ] || die "Bottle $name is a link to another bottle. Use the real bottle name."
  if [ ! -d "$b" ]; then
    [ "$mode" = allow_missing ] && return 0
    die "There is no bottle $name. To install Revit $year: ./revit install $year$sfx"
  fi
  ys="$(bottle_years "$b" | sort -u | tr '\n' ' ')"; ys="${ys% }"
  [ -n "$ys" ] || die "Bottle $name does not look like a Revit bottle. If you do not need it, delete it in CrossOver."
  [ "$ys" = "$year" ] || die "Bottle $name is for Revit $ys, not $year. Check the year and the bottle name."
  [ "$mode" = running_ok ] || ! revit_running "$b" "$year" \
    || die "Revit $year is running in $name. Save your work and quit Revit, then try again. If it hangs: ./revit stop $year$sfx"
}
