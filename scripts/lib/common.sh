# Shared basics for every script: paths, messages, the run folder, the lock, the bottle checks.
# Source after setting ROOT:  ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/common.sh"
# Defines functions and variables only. REVIT_CX (tests only) points at a fake CrossOver.
. "$ROOT/scripts/lib/versions.sh"
if [ -f "$ROOT/.app-bundle" ]; then   # inside <App>.app/Contents/Resources/engine (app/make-bundle.sh writes the file):
  # the app's data folder, its shims only, and the tools next to the engine before anything on PATH (Homebrew, the CLT)
  APP_NAME="$(sed -n 's/^app_name=//p' "$ROOT/.app-bundle")"; APP_RES="${ROOT%/engine}"
  export REVIT_BUNDLED="${REVIT_BUNDLED:-1}" REVIT_DATA="${REVIT_DATA:-$HOME/Library/Application Support/$APP_NAME}"
  case "$PATH" in "$APP_RES/bin:$APP_RES/python/bin:"*) ;; *) export PATH="$APP_RES/bin:$APP_RES/python/bin:$PATH" ;; esac
fi
DATA="${REVIT_DATA:-$ROOT}"   # what the scripts write (installers, unpacked files, logs); the app sets it, a clone does not
shim_dir() { echo "${SHIMS_DIR:-$ROOT/build}"; }   # our shims: build/ of a clone, or the app's prebuilt copy
CX="${REVIT_CX:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver}"
BOTTLES="$HOME/Library/Application Support/CrossOver/Bottles"
LOCK_DIR="${REVIT_LOCK_DIR:-$HOME/Library/Application Support/revit-macos}"   # one for every clone and the app:
LOCK_FILE="$LOCK_DIR/lock"                                                    # they share the bottles
STOP_REQUESTED=0; CHILD=""
# the run record (runlog_append): install.sh and run-steps.sh set the kind once the run is one to record, the steps
# asked for and the Revit build the installer gives; result_set keeps the result
RUNLOG_KIND=""; RUNLOG_REQUESTED=""; RUNLOG_BUILD=""; RUNLOG_RESULT=""

die()       { echo "$*" >&2; exit 1; }
usage_die() { echo "$*" >&2; exit 2; }
tilde() { case "$1" in "$HOME"/*) echo "~${1#"$HOME"}" ;; *) echo "$1" ;; esac; }
bottle_path() { echo "$BOTTLES/$1"; }
app_path() { # the <App>.app this engine is inside; 1 for a clone
  [ -f "$ROOT/.app-bundle" ] || return 1
  case "$ROOT" in */Contents/Resources/engine) echo "${ROOT%/Contents/Resources/engine}" ;; *) return 1 ;; esac
}
app_placement() { # $1 = app path → ok (in /Applications or ~/Applications) | move (a DMG, Downloads, App Translocation)
  case "$1" in */AppTranslocation/*) echo move; return 0 ;; esac
  case "$1" in /Applications/*|"$HOME"/Applications/*) echo ok ;; *) echo move ;; esac
}
bottle_sfx() { [ "$1" = "$(revit_bottle_default "$2")" ] || printf ' %s' "$1"; }   # hints name a non-default bottle

free_gb() { # $1 = a path (default /): GB free on its volume, what Finder and System Settings call "available"
  # (purgeable space included, which df does not count). A path that is not there yet counts on the volume of the
  # nearest folder above it; a link counts where it points
  local p="${1:-/}" g
  while [ ! -e "$p" ] && [ "$p" != / ] && [ "$p" != . ]; do p="$(dirname "$p")"; done
  p="$(cd "$p" 2>/dev/null && pwd -P)" || p=/
  g=$(osascript -l JavaScript -e 'function run(a) { ObjC.import("Foundation"); var r = Ref();
    $.NSURL.fileURLWithPath(a[0]).getResourceValueForKeyError(r, $.NSURLVolumeAvailableCapacityForImportantUsageKey, null);
    return Math.floor(ObjC.unwrap(r[0]) / 1e9) }' "$p" 2>/dev/null)
  [[ "$g" =~ ^[0-9]+$ ]] || g=$(df -g "$p" 2>/dev/null | awk 'NR==2 {print $4}')
  echo "${g:-0}"
}
volume_id() { # $1 = a path: its volume (device number), from the nearest folder above it that is there
  local p="$1"
  while [ ! -e "$p" ] && [ "$p" != / ] && [ "$p" != . ]; do p="$(dirname "$p")"; done
  stat -L -f %d "$p" 2>/dev/null || echo 0
}

run_dir_new() { # $1 = folder under logs/ (a bottle name, or revit<year>), $2 = kind (install, steps, addins, debug, …).
  # Prints logs/<$1>/<time>-<$2>, created now; a second run in the same second gets -2, -3, …
  local base d n=1
  mkdir -p "$DATA/logs/$1" || return 1
  base="$DATA/logs/$1/$(date +%Y%m%d-%H%M%S)-$2"; d="$base"
  until mkdir "$d" 2>/dev/null; do n=$((n + 1)); d="$base-$n"; [ $n -lt 100 ] || return 1; done
  echo "$d"
}

# ---- events for the app: one JSON object per line on fd 7, only when ./revit --events opened it ----
json_str() { # $1 = text → a JSON string literal (through the system perl, like the lock). The perl ignores Ctrl-C:
  # ./revit notes a Ctrl-C and ends the run itself, and a killed encoder would leave an empty value in an event
  ( trap '' INT TERM HUP; exec /usr/bin/perl -e 'my $s = shift; $s =~ s/(["\\])/\\$1/g; $s =~ s/\n/\\n/g; $s =~ s/\r/\\r/g; $s =~ s/\t/\\t/g;
    $s =~ s/([\x00-\x1f])/sprintf("\\u%04x", ord $1)/ge; print "\"$s\""' -- "$1" )
}
json_list() { # $@ = texts → a JSON array of strings
  local out="" x
  for x in "$@"; do out+="${out:+,}$(json_str "$x")"; done
  printf '[%s]' "$out"
}
profile_json() { # the profile load_profile loaded, as one JSON object (tools/doctor.py reads it): each variable under
  # its name, arrays as lists, PKGS split at |, YEAR a number, the rest strings
  local pk=() v out
  IFS='|' read -r -a pk <<< "$PKGS"
  out="{\"YEAR\":$((10#$YEAR))"
  for v in INSTALLER DOTNET PRODKEY SIGNIN LICENSING_OK THEME DYNAMO ADDIN_WPF_SW LOOKUP PYREVIT PYREVIT_ATTACH ENSCAPE; do
    out+=",\"$v\":$(json_str "${!v}")"
  done
  out+=",\"STEPS\":$(json_list ${STEPS[@]+"${STEPS[@]}"}),\"PKGS\":$(json_list ${pk[@]+"${pk[@]}"})"
  out+=",\"REVITINI\":$(json_list ${REVITINI[@]+"${REVITINI[@]}"}),\"RICHEDIT\":$(json_list ${RICHEDIT[@]+"${RICHEDIT[@]}"})"
  out+=",\"RVTFIX_ENV\":$(json_list ${RVTFIX_ENV[@]+"${RVTFIX_ENV[@]}"}),\"ADDIN_STEPS\":$(json_list ${ADDIN_STEPS[@]+"${ADDIN_STEPS[@]}"})}"
  printf '%s\n' "$out"
}
emit() { # $1 = event, then key and JSON value pairs (strings through json_str, numbers as they are)
  [ -n "${REVIT_EVENTS_FD:-}" ] && [ -e /dev/fd/7 ] || return 0
  local line="{\"event\":$(json_str "$1")" k; shift
  while [ $# -ge 2 ]; do
    k="$(json_str "$1")"; [ -n "$k" ] && [ -n "$2" ] || return 0   # an empty value is not JSON: the event is dropped
    line+=",$k:$2"; shift 2
  done
  printf '%s}\n' "$line" | emit_line ""
}
emit_line() { # stdin = one line; $1 = "end" for the last one. Every writer takes <ctx>/.events.lock (a file of its own:
  # a flock on the shared fd 7 would be shared too) and checks .ended under it, so nothing lands after the end, not
  # even from a helper that outlived its parent (a progress poller); "end" writes the line and .ended under the lock
  ( trap '' INT TERM HUP; exec /usr/bin/perl -MFcntl=:flock -e 'my ($ctx, $end) = @ARGV; my $l;
    if ($ctx ne "") { open($l, ">>", "$ctx/.events.lock") or exit 0; flock($l, LOCK_EX) or exit 0; exit 0 if -e "$ctx/.ended" }
    open(my $o, ">>&=", 7) or exit 0; local $/; print $o <STDIN>; close $o;
    if ($ctx ne "" && $end) { open(my $m, ">", "$ctx/.ended"); close $m }' "${REVIT_RUN_CTX:-}" "$1" )
}

result_set() { # $1 = key, $2 = value: the run's result for ./revit (and the app); nothing without a run context.
  # The run record takes the same result, with or without one
  [ "$1" != result ] || RUNLOG_RESULT="$2"
  [ -n "${REVIT_RUN_CTX:-}" ] && [ -d "$REVIT_RUN_CTX" ] || return 0
  local f="$REVIT_RUN_CTX/result"
  { grep -v "^$1=" "$f" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } > "$f.new" && mv -f "$f.new" "$f"
}
result_default() { # $1 = result, set only when nothing more precise was set (in_use, source_mismatch, busy)
  [ -n "${REVIT_RUN_CTX:-}" ] && ! grep -q '^result=' "$REVIT_RUN_CTX/result" 2>/dev/null && result_set result "$1"; return 0
}

# ---- the lock: one for everything that changes state, shared by every clone and the app (bottles are shared) ----
# flock on fd 9 (macOS has no flock(1), so through the system perl). It holds while any process keeps fd 9 open: the
# script, its child scripts, curl, 7zz. The kernel drops it when the last one closes, so there is no stale lock to
# remove. Wine runs with fd 9 closed (scripts/lib/wine.sh): wineserver outlives the script by hours.
lock_fd_ours() { # fd 9 is open on the shared lock file: a script up the chain took the lock
  [ -e /dev/fd/9 ] || return 1
  /usr/bin/perl -e 'open(my $f, ">&=", 9) or exit 2; my @a = stat($f); my @b = stat($ARGV[0]) or exit 3;
    exit(($a[0] == $b[0] && $a[1] == $b[1]) ? 0 : 1)' "$LOCK_FILE" 2>/dev/null
}
lock_flock9() { /usr/bin/perl -MFcntl=:flock -e 'open(my $f, ">&=", 9) or exit 2; flock($f, LOCK_EX | LOCK_NB) or exit 1' 2>/dev/null; }
lock_owner_field() { sed -n "s/^$1=//p" "$LOCK_FILE.owner" 2>/dev/null | head -1; }   # $1 = key
lock_owner() { # the owner's command text; an owner file of an older clone is one line of text
  local c; c="$(lock_owner_field command)"
  [ -n "$c" ] || c="$(head -1 "$LOCK_FILE.owner" 2>/dev/null)"
  echo "${c:-another task}"
}
lock_owner_write() { # $1 = command text. Through a temporary file and mv: a reader sees the old file or the new one
  local tmp="$LOCK_FILE.owner.$$"
  { printf 'command=%s\nrun_id=%s\npid=%s\n' "$1" "${REVIT_RUN_ID:-}" "$$"
    printf 'pid_start=%s\n' "$(ps -o lstart= -p $$ 2>/dev/null | sed 's/^ *//')"
    printf 'pgid=%s\nctx=%s\n' "$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" "${REVIT_RUN_CTX:-}"; } > "$tmp" \
    && mv -f "$tmp" "$LOCK_FILE.owner"
}
lock_cancelled() { # ./revit noted a Ctrl-C (or TERM/HUP) while taking the lock: end as that signal, not as "busy"
  [ -n "${SIG_GOT:-}" ] && declare -F supervise >/dev/null && supervise true; return 0
}
lock_take() { # [--no-trap] $* = what this script does (shown to whoever finds the lock busy). --no-trap: ./revit
  # supervising a child sets its own handlers
  local traps=1; [ "${1:-}" = --no-trap ] && { traps=0; shift; }
  mkdir -p "$LOCK_DIR" || { lock_cancelled; die "Cannot write to $(tilde "$LOCK_DIR")."; }
  if ! { lock_fd_ours && lock_flock9; }; then   # not inherited: take it
    exec 9>>"$LOCK_FILE" || die "Cannot open $(tilde "$LOCK_FILE")."
    lock_flock9 || { lock_cancelled; result_set result busy; die "Another task is running: $(lock_owner). Wait until it finishes, then try again."; }
    lock_owner_write "$*"
  fi
  # TERM/HUP/INT (Ctrl-C): let the running Wine program finish (bash runs the trap after the foreground command), pass
  # TERM on to a child script started with run_child (a background child ignores INT), stop at the next stop_check
  [ $traps = 0 ] || trap 'STOP_REQUESTED=1; [ -z "$CHILD" ] || kill -TERM "$CHILD" 2>/dev/null' TERM HUP INT
}
lock_free() { # 0 when nobody else holds the lock (for ./revit's checks before it takes the lock itself)
  lock_fd_ours && lock_flock9 && return 0
  [ -e "$LOCK_FILE" ] || return 0
  /usr/bin/perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or exit 0; flock($f, LOCK_EX | LOCK_NB) or exit 1' "$LOCK_FILE"
}
other_bottle_of_year() { # another bottle of this year still needs installers/extracted/revit<year>
  local b ys
  for b in "$BOTTLES"/*/; do
    b="${b%/}"
    if [ "$b" = "$B" ] || [ -L "$b" ] || is_smoke_clone "$b"; then continue; fi
    ys="$(bottle_years "$b")"   # a variable, not a pipe into grep -q: see revit_running
    grep -qx "$YEAR" <<<"$ys" && { basename "$b"; return 0; }
  done
  return 1
}
extracted_recover() { # $1 = an unpacked folder: a swap that was cut short (unpack-revit.sh) — only the backup there →
  # it is the unpacked folder; both there → the new one won. Under the lock only
  local old
  for old in "$1".old.*; do
    [ -d "$old" ] || continue
    if [ -d "$1" ]; then rm -rf "$old"; else mv "$old" "$1" || die "!! cannot restore $old"; fi
  done
}
stop_check() { [ "$STOP_REQUESTED" = 0 ] || { result_set result stopped; echo "Stopped." >&2; exit 1; }; }
run_child() { # [--log <file>] <command…>: runs it in the background so that TERM/HUP/INT reach it as TERM (the
  # trap passes them on; a background child ignores INT itself), and waits until it has finished. With --log its output
  # also goes to <file> through tee, which runs without the lock's fd and gets up to 2 s to finish writing (a process
  # the command left behind may keep its output open). Returns the command's exit code
  local rc log="" fifo="" tpid="" i
  if [ "${1:-}" = --log ]; then log="$2"; shift 2; fi
  if [ -n "$log" ]; then
    fifo="$(mktemp -u "${TMPDIR:-/tmp}/revit-macos.XXXXXX")" && mkfifo "$fifo" || return 1
    tee -a "$log" < "$fifo" 7>&- 9>&- & tpid=$!
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
crossover_version() { plutil -extract CFBundleShortVersionString raw -o - "$CX/../../Info.plist" 2>/dev/null; }
crossover_build() { plutil -extract CFBundleVersion raw -o - "$CX/../../Info.plist" 2>/dev/null; }   # 26.3.0.39832
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
  ! is_smoke_clone "$b" || die "Bottle $name is a temporary copy made by ./revit test, not a bottle to use."
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

# ---- the temporary copies of ./revit test (scripts/smoke.sh) and what runs in a bottle ----
SMOKE_MARK="revit-macos/smoke-clone"   # in a copy: written before the copying starts, so even a cut-short copy has it
smoke_clone_name() { echo "$1.test"; }   # $1 = bottle: its copy. revit_bottle_name_ok refuses the dot, so no
                                         # install, rebuild or remove of the user ever picks that name
is_smoke_clone() { # $1 = bottle path: a copy made by ./revit test (its marker, a file not reached through a link).
  # status, other_bottle_of_year and bottle_guard leave such copies out
  [ -f "$1/$SMOKE_MARK" ] && [ ! -L "$1/$SMOKE_MARK" ] && [ ! -L "$1/revit-macos" ]
}
bottle_activity() { # $1 = bottle path → stopped | active | unknown. Active: a Wine process (wineserver, a Windows
  # program, a launcher) has the bottle's folder itself open (wineserver keeps its working directory there) or a file
  # inside. The licensing services run for hours without Revit, so this is not revit_running. lsof failing for a process
  # that still runs is unknown: callers refuse then. -n -P: no name lookups for network connections (seconds each).
  # Output goes through variables, as in revit_running
  local rb pids p out o
  rb="$(cd "$1" 2>/dev/null && pwd -P)" || { echo unknown; return 0; }   # lsof prints real paths
  pids="$(pgrep -i -f 'wine|\.exe' 2>/dev/null | grep -vx "$$" | tr '\n' ',')"; pids="${pids%,}"
  [ -n "$pids" ] || { echo stopped; return 0; }
  if ! out="$(lsof -w -n -P -p "$pids" -Fn 2>/dev/null)"; then   # one that ended meanwhile fails the call: ask each
    out=""
    for p in ${pids//,/ }; do
      if o="$(lsof -w -n -P -p "$p" -Fn 2>/dev/null)"; then out+="$o"$'\n'
      elif kill -0 "$p" 2>/dev/null; then echo unknown; return 0; fi
    done
  fi
  if P="n$rb" awk 'index($0, ENVIRON["P"] "/") == 1 || $0 == ENVIRON["P"] { f = 1 } END { exit !f }' <<<"$out"
  then echo active; else echo stopped; fi
}
cx_lock_dir() { # where CrossOver keeps its locks (CXUtils::cxlock: $TMPDIR/.wine-<uid>), with the TMPDIR that the apps
  # in ~/Applications get from macOS. REVIT_CX_TMP (tests only) stands for it
  local d="${REVIT_CX_TMP:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)}"
  d="${d%/}"; echo "${d:-/tmp}/.wine-$(id -u)"
}
CX_LOCK_PID=""
cx_bottle_lock() { # $1 = bottle path: holds CrossOver's own lock of that bottle (CXBottle::lock_bottle, the file
  # bottle-<dev>-<ino>.lock) in a background process until cx_bottle_unlock or until this script ends. CrossOver's
  # wine takes it at every start and cxbottle while it changes the bottle, so nothing starts in the bottle meanwhile:
  # a launch from ~/Applications waits. 1 when it is not free within 30 s. Not in a command substitution: the holder
  # would keep it open
  local ready i
  ready="$(mktemp "${TMPDIR:-/tmp}/revit-cxlock.XXXXXX")" || return 1
  /usr/bin/perl -MFcntl=:flock -e 'my ($prefix, $dir, $parent, $ready) = @ARGV;
    my ($dev, $ino) = (stat $prefix)[0, 1]; defined $ino or exit 3;
    # the id as CXUtils::get_wine_dir_id writes it
    my $id = ($dev > 0xffffffff ? sprintf("%lx%08lx-", $dev >> 32, $dev & 0xffffffff) : sprintf("%lx-", $dev))
      . ($ino > 0xffffffff ? sprintf("%lx%08lx", $ino >> 32, $ino & 0xffffffff) : sprintf("%lx", $ino));
    mkdir $dir, 0700 unless lstat $dir;   # as cxlock: our own folder, closed to others
    my @d = lstat $dir; exit 4 unless @d && -d _ && $d[4] == $> && !($d[2] & 077);
    my $path = "$dir/bottle-$id.lock"; exit 5 if -e $path && (-l $path || !-f $path);
    open(my $l, ">", $path) or exit 5;
    my $until = time + 30;
    until (flock($l, LOCK_EX | LOCK_NB)) { exit 6 if time > $until || !kill(0, $parent); select(undef, undef, undef, 0.2) }
    open(my $r, ">", $ready) or exit 7; print $r "locked\n"; close $r;
    select(undef, undef, undef, 0.2) while kill(0, $parent);' "$1" "$(cx_lock_dir)" "$$" "$ready" \
    </dev/null >/dev/null 2>&1 7>&- 9>&- &
  CX_LOCK_PID=$!
  for i in $(seq 1 700); do
    if [ -s "$ready" ]; then rm -f "$ready"; return 0; fi
    kill -0 "$CX_LOCK_PID" 2>/dev/null || break
    sleep 0.05
  done
  rm -f "$ready"; cx_bottle_unlock; return 1
}
cx_bottle_unlock() { # ends the holder of cx_bottle_lock: the kernel drops the lock with it
  [ -n "$CX_LOCK_PID" ] || return 0
  kill "$CX_LOCK_PID" 2>/dev/null; wait "$CX_LOCK_PID" 2>/dev/null; CX_LOCK_PID=""; return 0
}
cx_menu_apps() { # $1 = bottle name: the apps CrossOver made for its Start Menu entries; deleting a bottle leaves them
  local a
  find "$HOME/Applications/CrossOver" -type d -name '*.app' -prune 2>/dev/null | while IFS= read -r a; do
    [ "$(plutil -extract CXHelperAppBottleName raw -o - "$a/Contents/Info.plist" 2>/dev/null)" = "$1" ] && echo "$a"
  done
  return 0
}

# ---- the run record: what ran in a bottle and how it ended, <bottle>/revit-macos/runs.ndjson (tools/runlog.py) ----
runlog_engine() { # what made the run: app:<version> | git:<short HEAD>[+dirty: tracked files changed] | unknown. A copy
  # without .git asks no git: on a Mac without the Command Line Tools, /usr/bin/git opens an install prompt
  local v
  if [ -f "$ROOT/.app-bundle" ]; then echo "app:$(sed -n 's/^app_version=//p' "$ROOT/.app-bundle")"; return 0; fi
  if [ -e "$ROOT/.git" ] && v="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"; then
    [ -z "$(GIT_OPTIONAL_LOCKS=0 git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ] || v+="+dirty"
    echo "git:$v"; return 0
  fi
  echo unknown
}
runlog_shims() { # the shims the steps took: the release in $(shim_dir) (its .prebuilt) | source:<tree of tools/shims at
  # HEAD>[+dirty: build-shims.sh compiles every source file there, new ones too] | unknown
  local v
  if [ -f "$(shim_dir)/.prebuilt" ]; then head -n 1 "$(shim_dir)/.prebuilt"; return 0; fi
  if [ -e "$ROOT/.git" ] && v="$(git -C "$ROOT" rev-parse --short HEAD:tools/shims 2>/dev/null)"; then
    [ -z "$(GIT_OPTIONAL_LOCKS=0 git -C "$ROOT" status --porcelain -- tools/shims 2>/dev/null)" ] || v+="+dirty"
    echo "source:$v"; return 0
  fi
  echo unknown
}
runlog_compatdb() { # CrossOver's newest compatibility database: it updates itself, without a new CrossOver
  local f c=""
  for f in "$HOME/Library/Application Support/CrossOver/"compatdb-*.dat; do
    [ -f "$f" ] && { [ -z "$c" ] || [ "$f" -nt "$c" ]; } && c="$f"
  done
  echo "$c"
}
runlog_append() { # $1 = result: one line in the run record of bottle $B (kind, steps and build from RUNLOG_*, done,
  # skipped and failed from RUN_DIR), only for a bottle that exists. A write error is one warning line and never
  # changes the exit code. INT/TERM/HUP are ignored meanwhile: a Ctrl-C at the end must not cut the record short.
  # Nothing it starts gets fd 9 or 7 (git may leave a daemon behind)
  [ -n "${RUNLOG_KIND:-}" ] && [ -f "${B:-}/cxbottle.conf" ] || return 0
  local err
  err="$(trap '' INT TERM HUP; exec 7>&- 9>&-
    python3 -I -B "$ROOT/tools/runlog.py" append "$B" --kind "$RUNLOG_KIND" --year "$YEAR" \
      --run-id "${REVIT_RUN_ID:-$(basename "${RUN_DIR:-none}")}" --result "$1" --requested "${RUNLOG_REQUESTED:-}" \
      --run-dir "${RUN_DIR:-}" --engine "$(runlog_engine)" --crossover "$(crossover_build)" \
      --compatdb "$(runlog_compatdb)" --shims "$(runlog_shims)" --build "${RUNLOG_BUILD:-}" 2>&1 >/dev/null)" \
    || echo "could not write the run record: $(tail -n 1 <<<"${err:-no message}")" >&2
  return 0
}
runlog_exit() { # $1 = exit code: the record from an EXIT handler. Its result is the one result_set reported; without
  # one, a signal or a stop is stopped, 0 is ok, anything else failed
  local r="${RUNLOG_RESULT:-}"
  if [ -z "$r" ]; then
    if [ "$1" -gt 128 ] || [ "${STOP_REQUESTED:-0}" != 0 ]; then r=stopped; elif [ "$1" = 0 ]; then r=ok; else r=failed; fi
  fi
  runlog_append "$r"
}
