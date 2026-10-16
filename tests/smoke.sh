#!/usr/bin/env bash
# Tests for ./revit test (scripts/smoke.sh), in a sandbox: a copy of the repo, a fake HOME with fake bottles and a fake
# CrossOver (REVIT_CX) whose wine maps C:\ through --bottle and starts a stand-in for Revit.exe. The stand-in writes a
# journal over time into the copy, as Revit does when it plays one, in a mode the test picks: pass, crash, hang,
# hang_start, dialog, nostart, signin, worker, stubborn (ignores INT and TERM). Fakes on PATH: diskutil, cp (notes
# CrossOver's bottle lock), lsof (can fail). Runs under /bin/bash 3.2. Nothing real is touched. Usage: tests/smoke.sh
set -uo pipefail
# every control variable of the engine: none of the caller's may reach the sandbox (a REVIT_DATA or REVIT_SOURCE_LIST
# could point at real folders); tests set what they need after this
CLEAN_ENV=(-u REVIT_DATA -u REVIT_LOCK_DIR -u SHIMS_DIR -u REVIT_BUNDLED -u REVIT_EVENTS_FD -u REVIT_RUN_ID -u REVIT_RUN_CTX
  -u REVIT_ACCEPT_EULA -u REVIT_SOURCE_LIST -u REVIT_REUSE_EXTRACTED -u REVIT_REEXTRACT -u REVIT_UNPACK_AGAIN
  -u REVIT_FOR_BOTTLE -u INSTALL_PARENT -u W_CACHE -u SHIMS_FROM_SOURCE -u RUN_DIR -u RUN_KIND -u CX_RECREATE
  -u INSTALL_DRYRUN -u REVIT_LANG -u ODIS_PKGS -u REVIT_THEME -u REVIT_YEAR -u SMOKE_TIMEOUT -u SMOKE_START_WAIT
  -u SMOKE_STALL -u SMOKE_WORKER_WAIT -u SMOKE_POLL -u SMOKE_PREP_TIMEOUT -u REVIT_CX_TMP -u CX_LOG -u CX_DEBUGMSG)
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)" && [ -d "$TMP" ] || { echo "mktemp failed" >&2; exit 1; }
TOP="$(cd "$TMP" && pwd -P)" || exit 1   # lsof reports real paths
T="$TOP/sand box"                      # a space in every path
R="$T/repo"; H="$T/home"; CXF="$T/CrossOver.app/Contents/SharedSupport/CrossOver"; CALLS="$T/calls"
BOTTLES="$H/Library/Application Support/CrossOver/Bottles"
PIDS=""
stop_bg() { # the test's own helpers, then any stand-in that outlived its run
  local p; for p in $PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; PIDS=""
  pkill -9 -f "$TOP" 2>/dev/null; return 0
}
trap 'stop_bg; chmod -R u+w "$TOP" 2>/dev/null; rm -rf "$TOP"' EXIT
n=0; fails=0
ok()   { n=$((n + 1)); echo "ok   $1"; }
fail() { n=$((n + 1)); fails=$((fails + 1)); echo "FAIL $1"; printf '%s\n' "${2:-}" | sed 's/^/     /'; }
expect() { # $1 = name, $2 = exit code, $3 = text the output contains ("" = anything)
  if [ "$RC" = "$2" ] && { [ -z "$3" ] || grep -qF -- "$3" <<<"$OUT"; }; then ok "$1"
  else fail "$1" "rc=$RC (want $2), want text: $3
$OUT"; fi
}
check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name" "failed: $*
$(cat "$CALLS" 2>/dev/null | head -40)"; fi; }
called()     { grep -qF -- "$1" "$CALLS"; }
not_called() { ! grep -qF -- "$1" "$CALLS"; }
no_wine()    { ! grep -q '^wine \[' "$CALLS"; }
only_copy()  { # every wine call goes to the copy, none gets the lock's or the events fd
  ! grep '^wine \[' "$CALLS" | grep -vqF "wine [--bottle] [$1.test]" && ! grep -qE ' FD[79]$|^FD[79]' "$CALLS"
}
no_fakes()   { sleep 0.2; ! pgrep -f "$TOP" >/dev/null; }   # no stand-in left (their command lines hold the sandbox)
lock_free()  { /usr/bin/perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or exit 0; flock($f, LOCK_EX | LOCK_NB) or exit 1' \
  "$H/Library/Application Support/revit-macos/lock"; }
gone()       { [ ! -e "$BOTTLES/$1" ] && [ ! -L "$BOTTLES/$1" ]; }
source_kept() { [ -z "$(find "$BOTTLES/rvt$1-a" -newer "$T/stamp" 2>/dev/null)" ]; }   # the bottle itself unchanged

reset() { # a fresh sandbox: the repo's revit, scripts and tools, a fake CrossOver, fakes on PATH
  stop_bg; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"
  mkdir -p "$R" "$H/Applications/CrossOver" "$BOTTLES" "$CXF/bin" "$CXF/etc" "$T/bin" "$T/cxtmp" \
    || { echo "sandbox setup failed"; exit 1; }
  cp -R "$REPO/revit" "$REPO/scripts" "$REPO/tools" "$R/"
  printf '[CrossOver]\n;; BuildTimestamp       The build timestamp.\n"BuildTimestamp" = "20260715T103801Z"\n' > "$CXF/etc/CrossOver.conf"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleVersion</key><string>26.3.0.39832</string><key>CFBundleShortVersionString</key><string>26.3</string></dict></plist>\n' \
    > "$T/CrossOver.app/Contents/Info.plist"
  fake "$CXF/bin/wine" <<'EOF'
#!/bin/bash
# fake wine: records its arguments (FD9/FD7 when the lock's or the events fd reached it); --bottle names the bottle
T="@T@"; BOTTLES="@BOTTLES@"
{ printf 'wine'; for a in "$@"; do printf ' [%s]' "$a"; done; [ -e /dev/fd/9 ] && printf ' FD9'; [ -e /dev/fd/7 ] && printf ' FD7'; echo; } >> "$T/calls"
[ "$1" = --bottle ] || exit 2
name="$2"; b="$BOTTLES/$2"; shift 2
[ -f "$b/system.reg" ] || { echo "bottle $name not found" >&2; exit 1; }
if [ ! -e "$T/first-conf" ]; then   # the copy as the first wine call finds it
  cp "$b/cxbottle.conf" "$T/first-conf"; cp "$b/revit-macos/smoke-clone" "$T/first-marker" 2>/dev/null; ls -a "$b" > "$T/first-ls"
  [ ! -e "$b/drive_c/half" ] || touch "$T/first-half"
fi
[ -z "${CX_LOG:-}" ] || echo "fake log line" >> "$CX_LOG"
case "$1" in
  --update-only)
    [ ! -f "$T/upgrade-fails" ] || { echo "the upgrade failed" >&2; exit 1; }
    [ -f "$T/upgrade-silent" ] || /usr/bin/perl -pi -e 's/^"Timestamp" = ".*"/"Timestamp" = "20260715T103801Z"/' "$b/cxbottle.conf"
    exit 0 ;;
  cmd) echo "Microsoft Windows [Version 10.0.19045]"; exit 0 ;;
  taskkill)   # taskkill /f /im <image>: the stand-ins of that image in this bottle
    [ -f "$b/.fakeprocs" ] || exit 128
    while read -r p img; do [ "$img" = "$4" ] && kill -9 "$p" 2>/dev/null; done < "$b/.fakeprocs"; exit 0 ;;
  *'\Revit.exe')
    mode="$(cat "$T/mode" 2>/dev/null)"
    [ "$mode" != nostart ] || { echo "Expired Bottle" >&2; exit 1; }
    a="$HOME/Applications/CrossOver/Autodesk/Revit copy.app/Contents"; mkdir -p "$a"   # as if CrossOver made a menu app
    printf '<plist version="1.0"><dict><key>CXHelperAppBottleName</key><string>%s</string></dict></plist>\n' "$name" > "$a/Info.plist"
    if [ "$(cat "$T/launcher" 2>/dev/null)" = block ]; then exec /bin/bash "$T/fake-revit" "$1" "$b" "$2"; fi
    /bin/bash "$T/fake-revit" "$1" "$b" "$2" </dev/null >/dev/null 2>&1 &
    exit 0 ;;
esac
exit 0
EOF
  fake "$T/fake-revit" <<'EOF'
#!/bin/bash
# stand-in for Revit.exe: $1 its Windows path, $2 the bottle, $3 the journal to play (C:\...). Writes the journal Revit
# writes while it plays one, a line at a time, in the mode of $T/mode-<scenario> or $T/mode (default pass)
T="@T@"; b="$2"; jw="$3"
year="$(sed -n 's/.*Revit \([0-9][0-9][0-9][0-9]\).*/\1/p' <<<"$1")"
jm="$b/drive_c/$(printf '%s' "${jw#C:\\}" | tr '\\' '/')"; s="$(basename "$jm" .txt)"
mode="$(cat "$T/mode-$s" 2>/dev/null || cat "$T/mode" 2>/dev/null)"; mode="${mode:-pass}"
[ "$mode" != stubborn ] || trap '' INT TERM HUP
exit_at="$(grep -n 'ID_APP_EXIT' "$jm" | tail -1 | cut -d: -f1)"
if [ "$year" -ge 2026 ]; then d="$b/drive_c/revit-smoke"; else d="$b/drive_c/users/crossover/AppData/Local/Autodesk/Revit/Autodesk Revit $year/Journals"; fi
mkdir -p "$d"; i=1; while [ -e "$d/$(printf 'journal.%04d.txt' $i)" ]; do i=$((i + 1)); done
exec 3>>"$d/$(printf 'journal.%04d.txt' $i)"
echo "$$ Revit.exe" >> "$b/.fakeprocs"
{ [ ! -e /dev/fd/9 ] || echo "FD9 in Revit"; [ ! -e /dev/fd/7 ] || echo "FD7 in Revit"; } >> "$T/calls"
st()  { printf "'C %s.000;  %s \r\n" "$(LC_ALL=C date '+%d-%b-%Y %H:%M:%S')" "$1" >&3; sleep 0.02; }
raw() { printf '%s\r\n' "$1" >&3; }
forever() { touch "$T/revit-started"; while :; do sleep 1; done; }
side() { # $1 = image: another program of the bottle that holds a file in it until it is killed
  /bin/bash -c 'exec 3>>"$1"; while :; do sleep 1; done' "C:\\Program Files\\Autodesk\\$1" "$b/drive_c/.$1.open" </dev/null >/dev/null 2>&1 &
  echo "$! $1" >> "$b/.fakeprocs"
}
ole() { printf '\320\317\021\340\241\261\032\341fake' > "$1"; }
st "started recording journal file"
raw "' Build: 20991231_0000(x64)"; raw "' Release: $year.3"; raw "Dim Jrn"; raw "Set Jrn = CrsJournalScript"
st "  0:< manage licensing"
[ "$mode" != signin ] || { side AdskIdentityManager.exe; forever; }
st "  0:< License Update: (reason=1)"
st "  0:< Delayed start"
raw "' 0:< License mode: User"
[ "$mode" != hang_start ] || forever
st "  0:< appPriv idle"
st "started journal file playback of \"$jw\""
case "$mode" in
  crash) st "  0:< unrecoverable error: synthetic"; exit 1 ;;
  hang|stubborn) forever ;;
  dialog) raw "  ' 1:< TaskDialog \"Something needs an answer\""; raw "  'Id : TaskDialog_Synthetic_Question"; forever ;;
esac
case "$s" in
  core) ole "$b/drive_c/revit-smoke/out/smoke.rvt" ;;
  reopen) [ ! -f "$b/drive_c/revit-smoke/out/smoke.rvt" ] || ole "$b/drive_c/revit-smoke/out/smoke2.rvt" ;;
esac
[ "$mode" != worker ] || side RevitWorker.exe
st "JOURNAL_MARKER_TAIL_END: stopped at line $exit_at journal file playback"
st "finished recording journal file"
EOF
  fake "$CXF/bin/wineserver" <<'EOF'
#!/bin/bash
# fake wineserver: -k ends the stand-ins of $WINEPREFIX only
T="@T@"
{ printf 'wineserver %s WINEPREFIX=%s' "$*" "${WINEPREFIX:-}"; [ -e /dev/fd/9 ] && printf ' FD9'; [ -e /dev/fd/7 ] && printf ' FD7'; echo; } >> "$T/calls"
[ "$1" = -k ] && [ -f "$WINEPREFIX/.fakeprocs" ] || exit 1
while read -r p img; do kill -9 "$p" 2>/dev/null; done < "$WINEPREFIX/.fakeprocs"; : > "$WINEPREFIX/.fakeprocs"
EOF
  fake "$CXF/bin/cxbottle" <<'EOF'
#!/bin/bash
# fake cxbottle: --bottle <name> --delete --force deletes a bottle it finds (one with system.reg)
T="@T@"; BOTTLES="@BOTTLES@"
{ printf 'cxbottle'; for a in "$@"; do printf ' [%s]' "$a"; done; [ -e /dev/fd/9 ] && printf ' FD9'; [ -e /dev/fd/7 ] && printf ' FD7'; echo; } >> "$T/calls"
[ "$1" = --bottle ] && [ "$3" = --delete ] || exit 0
[ -f "$BOTTLES/$2/system.reg" ] || { echo "bottle $2 not found" >&2; exit 1; }
rm -rf "$BOTTLES/$2"
EOF
  fake "$T/bin/diskutil" <<'EOF'
#!/bin/bash
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>FilesystemType</key><string>%s</string></dict></plist>\n' \
  "$(cat "@T@/fstype" 2>/dev/null || echo apfs)"
EOF
  fake "$T/bin/cp" <<'EOF'
#!/bin/bash
# cp as usual; for the copy of a bottle (-cR) it first notes whether CrossOver's lock of that bottle is held
if [ "$1" = -cR ]; then
  read -r dev ino <<<"$(stat -f '%d %i' "${2%/}")"
  lock="@T@/cxtmp/.wine-$(id -u)/bottle-$(printf '%x-%x' "$dev" "$ino").lock"
  if /usr/bin/perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or exit 2; flock($f, LOCK_EX | LOCK_NB) or exit 1' "$lock"
  then echo free; else echo held; fi > "@T@/cp-lock"
  [ ! -f "@T@/cp-fails" ] || { mkdir -p "$3/drive_c"; exit 1; }
fi
exec /bin/cp "$@"
EOF
  fake "$T/bin/lsof" <<'EOF'
#!/bin/bash
[ ! -f "@T@/lsof-fails" ] || exit 1
exec /usr/sbin/lsof "$@"
EOF
  : > "$CALLS"
  mkbottle 2027
}
fake() { # $1 = path: an executable from stdin, with the sandbox's paths filled in
  mkdir -p "$(dirname "$1")"; sed -e "s|@T@|$T|g" -e "s|@BOTTLES@|$BOTTLES|g" > "$1"; chmod +x "$1"
}
mkbottle() { # $1 = year: bottle rvt<year>-a with Revit installed and signed in, a template, CrossOver's records, a
  # menu app; everything in it dated a minute back, then the stamp (source_kept)
  local b="$BOTTLES/rvt$1-a" j="drive_c/users/crossover/AppData/Local/Autodesk/Revit/Autodesk Revit $1/Journals"
  mkdir -p "$b/drive_c/Program Files/Autodesk/Revit $1" "$b/$j" "$b/desktopdata/menus" \
    "$b/drive_c/ProgramData/Autodesk/RVT $1/Templates/English" "$b/revit-macos"
  printf '[Bottle]\n"Description" = "Revit %s"\n"BottleID" = "SOURCE-ID"\n"Timestamp" = "20250101T000000Z"\n"MenuMode" = "install"\n\n[EnvironmentVariables]\n"A" = "b"\n' \
    "$1" > "$b/cxbottle.conf"
  echo "WINE REGISTRY Version 2" > "$b/system.reg"; echo "WINE REGISTRY Version 2" > "$b/user.reg"
  : > "$b/drive_c/Program Files/Autodesk/Revit $1/Revit.exe"; echo "files list" > "$b/files"
  : > "$b/drive_c/ProgramData/Autodesk/RVT $1/Templates/English/Default-Multi-Discipline_Metric.rte"
  printf "' 0:< License mode: User\r\n' 0:< Status: Your license will expire in 200 days.\r\n" > "$b/$j/journal.0001.txt"
  echo '{"run_id":"r0"}' > "$b/revit-macos/runs.ndjson"
  menu_app "Autodesk/Revit $1" "rvt$1-a"
  find "$b" -exec touch -h -A -0100 {} +
  touch "$T/stamp"
}
menu_app() { # $1 = path under ~/Applications/CrossOver, $2 = bottle
  mkdir -p "$H/Applications/CrossOver/$1.app/Contents"
  printf '<plist version="1.0"><dict><key>CXHelperAppBottleName</key><string>%s</string></dict></plist>\n' "$2" \
    > "$H/Applications/CrossOver/$1.app/Contents/Info.plist"
}
old_copy() { # $1 = copy name, $2 = state, $3 = 1: with system.reg (CrossOver finds it)
  mkdir -p "$BOTTLES/$1/revit-macos" "$BOTTLES/$1/drive_c"
  printf 'smoke_clone=1\nrun_id=old\nsource=%s\ntime=2026-01-01T00:00:00Z\nstate=%s\n' "${1%.test}" "$2" > "$BOTTLES/$1/revit-macos/smoke-clone"
  touch "$BOTTLES/$1/drive_c/half"
  [ "${3:-0}" = 0 ] || { echo "WINE REGISTRY Version 2" > "$BOTTLES/$1/system.reg"; printf '[Bottle]\n"Description" = "Revit 2026"\n' > "$BOTTLES/$1/cxbottle.conf"; }
  return 0
}
hold() { # $1 = a file to hold open, $2 = a word for its command line, $3 = folder to work in (default: the file's)
  touch "$1"
  (cd "${3:-$(dirname "$1")}" && exec /usr/bin/perl -e 'open(my $f, "<", $ARGV[0]) or die; sleep 60' "$1" "$2") &
  PIDS="$PIDS $!"; sleep 0.3
}
SB_ENV=(env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" REVIT_CX_TMP="$T/cxtmp" PATH="$T/bin:$PATH" SMOKE_TIMEOUT=20
  SMOKE_START_WAIT=4 SMOKE_STALL=3 SMOKE_WORKER_WAIT=1 SMOKE_POLL=0.1 SMOKE_PREP_TIMEOUT=5)   # watchdogs that fire: XENV
fresh() { : > "$CALLS"; rm -f "$T/first-conf" "$T/first-marker" "$T/first-ls" "$T/first-half" "$T/revit-started"; }
ran() { RUN="$(ls -td "$R/logs/"*/*-test 2>/dev/null | head -1)"; RES="$RUN/result.json"; }
XENV=()   # VAR=value pairs for the next smoke only
smoke() { # scripts/smoke.sh "$@"; sets OUT, RC, RUN (the newest test log folder) and RES (its result.json)
  fresh; OUT="$(cd / && "${SB_ENV[@]}" ${XENV[@]+"${XENV[@]}"} /bin/bash "$R/scripts/smoke.sh" "$@" 2>&1)"; RC=$?; ran; XENV=()
}
revit_test() { # ./revit test "$@" --events $T/ev, as the app runs it; sets what smoke sets, EV: the events
  fresh; rm -rf "$T/ev"; OUT="$(cd / && "${SB_ENV[@]}" /bin/bash "$R/revit" test "$@" --events "$T/ev" 2>&1)"; RC=$?; ran
  EV="$(cat "$T/ev/events.ndjson" 2>/dev/null)"
}
json() { # $1 = name, $2 = perl expression on $d (result.json), $3 = what it must give
  local got; got="$(/usr/bin/perl -MJSON::PP -e 'local $/; my $d = decode_json(<STDIN>); print eval $ARGV[0]' "$2" < "$RES" 2>&1)"
  if [ "$got" = "$3" ]; then ok "$1"; else fail "$1" "got: $got
want: $3"; fi
}
one_end() { # $1 = result: exactly one end event, the last one, with that result
  [ "$(grep -c '"event":"end"' <<<"$EV")" = 1 ] && tail -1 <<<"$EV" | grep -q "\"event\":\"end\".*\"result\":\"$1\""
}

# ---- the helpers in common.sh ----
helpers() { # bash code on stdin, run with common.sh loaded in the sandbox; sets OUT, RC
  cat > "$T/h.sh"
  OUT="$(cd / && "${SB_ENV[@]}" ROOT="$R" /bin/bash -c '. "$ROOT/scripts/lib/common.sh"; . "$1"' _ "$T/h.sh" 2>&1)"; RC=$?
}
reset; old_copy rvt2026-a.test ready 1; mkdir -p "$BOTTLES/plain/revit-macos" "$T/elsewhere"; touch "$T/elsewhere/smoke-clone"
ln -s "$T/elsewhere/smoke-clone" "$BOTTLES/plain/revit-macos/smoke-clone"
helpers <<'EOF'
echo "name=$(smoke_clone_name rvt2027-a)"
is_smoke_clone "$BOTTLES/rvt2026-a.test" && echo copy-marked
is_smoke_clone "$BOTTLES/plain" || echo link-not-marked
is_smoke_clone "$BOTTLES/rvt2027-a" || echo bottle-not-marked
echo "idle=$(bottle_activity "$BOTTLES/rvt2027-a")"
echo "missing=$(bottle_activity "$BOTTLES/none")"
bottle_guard must_exist 2026 rvt2026-a.test
EOF
expect "a copy is <bottle>.test" 1 "name=rvt2027-a.test"
check "is_smoke_clone: a copy with its marker" grep -qx copy-marked <<<"$OUT"
check "is_smoke_clone: a marker through a link does not count" grep -qx link-not-marked <<<"$OUT"
check "is_smoke_clone: a bottle is no copy" grep -qx bottle-not-marked <<<"$OUT"
check "bottle_activity: nothing runs" grep -qx idle=stopped <<<"$OUT"
check "bottle_activity: a missing bottle is unknown" grep -qx missing=unknown <<<"$OUT"
expect "bottle_guard refuses a copy" 1 "Bottle rvt2026-a.test is a temporary copy made by ./revit test"
reset; menu_app "Autodesk/Revit 2026 copy" rvt2026-a.test; menu_app "Autodesk/Revit 2026" rvt2026-a
hold "$BOTTLES/rvt2027-a/drive_c/held.tmp" "C:\\x\\AdskLicensingService.exe"
helpers <<'EOF'
echo "apps=$(cx_menu_apps rvt2026-a.test | sed 's|.*/||')"
echo "busy=$(bottle_activity "$BOTTLES/rvt2027-a")"
cx_bottle_lock "$BOTTLES/rvt2027-a" || exit 9
read -r dev ino <<<"$(stat -f '%d %i' "$BOTTLES/rvt2027-a")"
l="$(cx_lock_dir)/bottle-$(printf '%x-%x' "$dev" "$ino").lock"
try() { /usr/bin/perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or exit 2; flock($f, LOCK_EX | LOCK_NB) or exit 1' "$l"; }
try || echo held
cx_bottle_unlock
try && echo freed
echo "mode=$(stat -f %Lp "$(cx_lock_dir)")"
EOF
expect "cx_menu_apps: the apps of that bottle only" 0 "apps=Revit 2026 copy.app"
check "bottle_activity: a program with a file inside" grep -qx busy=active <<<"$OUT"
check "cx_bottle_lock holds CrossOver's lock of the bottle (bottle-<dev>-<ino>.lock)" grep -qx held <<<"$OUT"
check "cx_bottle_unlock frees it" grep -qx freed <<<"$OUT"
check "CrossOver's lock folder is made closed to others" grep -qx mode=700 <<<"$OUT"

# ---- a pass through ./revit: every scenario, a launcher that returns at once ----
reset; menu_app "Autodesk/Other" rvt2025-a
mkdir -p "$R/logs/rvt2027-a/20260101-000000-test"
echo '{"year":2027,"time":"2026-01-01T00:00:00Z","scenarios":[{"name":"start","result":"passed","t_start_idle":15,"t_total":30}]}' \
  > "$R/logs/rvt2027-a/20260101-000000-test/result.json"
revit_test 2027
expect "pass: exit 0 with the table" 0 "Not checked: sign-in, add-ins, web panels, how Revit looks."
expect "pass: says how to share it" 0 "To share this result: ./revit report 2027"
expect "pass: says the copy is temporary and how the sign-in is used" 0 "a temporary copy of your bottle on this Mac, using the sign-in you made there"
check "pass: no 'without signing in'" eval '! grep -qi "without signing in" <<<"$OUT"'
check "pass: every scenario passed" test "$(grep -cE '^  (start|core|reopen) +passed' <<<"$OUT")" = 3
expect "pass: earlier times of this year" 0 "earlier passes: ready in 15 s, done in 30 s"
check "pass: one end event, ok, with the log folder" eval 'one_end ok && tail -1 <<<"$EV" | grep -q "\"log_dir\":\".*-test\""'
check "pass: the copy got its marker before the first wine call" eval 'grep -qx "smoke_clone=1" "$T/first-marker" && grep -qx "state=ready" "$T/first-marker" && grep -qx "source=rvt2027-a" "$T/first-marker"'
check "pass: menus and associations off before the first wine call" eval 'grep -qx "\"MenuMode\" = \"ignore\"" "$T/first-conf" && grep -qx "\"AssocMode\" = \"ignore\"" "$T/first-conf"'
check "pass: a new BottleID before the first wine call" eval 'grep -q "^\"BottleID\" = \"[0-9A-F-]\{8,\}\"$" "$T/first-conf"'
check "pass: the rest of cxbottle.conf kept" eval 'grep -qx "\"Description\" = \"Revit 2027\"" "$T/first-conf" && grep -qx "\"A\" = \"b\"" "$T/first-conf"'
check "pass: desktopdata and files not in the copy" eval '! grep -qx -e desktopdata -e files "$T/first-ls"'
check "pass: CrossOver's lock of the bottle held while it was copied" grep -qx held "$T/cp-lock"
check "pass: the upgrade ran in the copy" called "wine [--bottle] [rvt2027-a.test] [--update-only]"
check "pass: Revit started in C:\\revit-smoke" called "[C:\\Program Files\\Autodesk\\Revit 2027\\Revit.exe] [C:\\revit-smoke\\core.txt]"
check "pass: Revit started without --wait-children" not_called "--wait-children"
check "pass: every wine call went to the copy, none got the lock or events fd" only_copy rvt2027-a
check "pass: the copy is deleted with CrossOver" called "cxbottle [--bottle] [rvt2027-a.test] [--delete] [--force]"
check "pass: the copy is gone" gone rvt2027-a.test
check "pass: its menu app is gone" test ! -e "$H/Applications/CrossOver/Autodesk/Revit copy.app"
check "pass: menu apps of other bottles stay" eval 'test -d "$H/Applications/CrossOver/Autodesk/Revit 2027.app" && test -d "$H/Applications/CrossOver/Autodesk/Other.app"'
check "pass: the bottle itself is not changed" source_kept 2027
check "pass: the bottle kept its settings" eval 'grep -qx "\"BottleID\" = \"SOURCE-ID\"" "$BOTTLES/rvt2027-a/cxbottle.conf" && test -d "$BOTTLES/rvt2027-a/desktopdata"'
json "pass: result.json: ok, three passes" 'join " ", $d->{result}, map { $_->{result} } @{$d->{scenarios}}' "ok passed passed passed"
json "pass: result.json: the copy deleted, CrossOver's build, an upgrade" \
  'join " ", ($d->{copy_removed} ? "removed" : "kept"), $d->{crossover}, ($d->{prepare}{upgraded} ? "upgraded" : "same")' \
  "removed 26.3.0.39832 upgraded"
json "pass: result.json: Autodesk's template by its path" '$d->{template}{path}' \
  'C:\ProgramData\Autodesk\RVT 2027\Templates\English\Default-Multi-Discipline_Metric.rte'
check "pass: result.json has no path of the Mac" eval '! grep -qF -e "$TOP" -e "$H" "$RES"'
check "pass: the journals Revit wrote are in the log" eval 'test -f "$RUN/start-journal.txt" && test -f "$RUN/reopen-journal.txt"'
check "pass: no wine.cxlog without --log" test ! -e "$RUN/wine.cxlog"
check "pass: nothing left running" no_fakes
check "pass: the lock is free" lock_free

# ---- 2025: journals in AppData, a launcher that waits for Revit, a RevitWorker that stays, --log ----
reset; mkbottle 2025; echo block > "$T/launcher"; echo worker > "$T/mode-start"
smoke 2025 rvt2025-a --log --scenarios start,core
expect "2025, blocking launcher: exit 0" 0 ""
check "2025: both scenarios passed" test "$(grep -cE '^  (start|core) +passed' <<<"$OUT")" = 2
check "2025: the RevitWorker that stayed was ended after the wait" called "[taskkill] [/f] [/im] [RevitWorker.exe]"
check "2025: --log writes wine.cxlog" test -s "$RUN/wine.cxlog"
check "2025: the copy is gone" gone rvt2025-a.test
check "2025: nothing left running" no_fakes

# ---- failures ----
reset; echo crash > "$T/mode-core"; smoke 2027 rvt2027-a --scenarios core,reopen
expect "crash: exit 1" 1 "Revit crashed (unrecoverable error)"
expect "crash: the next scenario is skipped" 1 "reopen  skipped    core did not pass"
check "crash: the copy is gone" gone rvt2027-a.test
json "crash: result.json says failed" '$d->{result}' failed
reset; rm "$BOTTLES/rvt2027-a/drive_c/ProgramData/Autodesk/RVT 2027/Templates/English/Default-Multi-Discipline_Metric.rte"
smoke 2027 rvt2027-a --scenarios core,reopen
expect "no project template: core fails, reopen is skipped" 1 "core    FAILED     no project template of Revit 2027 in the bottle"
check "no project template: Revit never started" not_called "Revit.exe]"
reset; echo dialog > "$T/mode"; XENV=(SMOKE_STALL=2); smoke 2027 rvt2027-a --scenarios start
expect "a dialog: exit 1 with its id" 1 "Revit stopped at a dialog (TaskDialog_Synthetic_Question)"
check "dialog: Revit ended with taskkill in the copy" called "wine [--bottle] [rvt2027-a.test] [taskkill] [/f] [/im] [Revit.exe]"
check "dialog: then wineserver -k of the copy" called "wineserver -k WINEPREFIX=$BOTTLES/rvt2027-a.test"
check "dialog: no wineserver -k of the bottle itself" not_called "WINEPREFIX=$BOTTLES/rvt2027-a "
check "dialog: every wine call went to the copy" only_copy rvt2027-a
check "dialog: the copy and its menu app are gone" eval 'gone rvt2027-a.test && test ! -e "$H/Applications/CrossOver/Autodesk/Revit copy.app"'
check "dialog: nothing left running" no_fakes

# ---- a person must act ----
reset; echo nostart > "$T/mode"; XENV=(SMOKE_START_WAIT=2); smoke 2027 rvt2027-a --scenarios start
expect "Revit never starts: exit 3" 3 "Revit did not start: CrossOver stopped it or showed a question"
check "never starts: the copy is gone" gone rvt2027-a.test
reset; echo signin > "$T/mode"; XENV=(SMOKE_START_WAIT=2); smoke 2027 rvt2027-a --scenarios start
expect "a sign-in process: exit 3" 3 "Revit asked to sign in"
expect "sign-in: says what to do" 3 "Open Revit from ~/Applications, sign in, quit Revit, then run the test again."
check "sign-in: the sign-in process ended too" no_fakes
json "sign-in: result.json says needs_person" '$d->{result}' needs_person

# ---- preparing the copy ----
reset; touch "$T/upgrade-fails"; smoke 2027 rvt2027-a
expect "a failed upgrade of the copy" 1 "CrossOver could not prepare the copy: the upgrade failed (exit 1)"
expect "failed upgrade: not a Revit failure" 1 "This is not a Revit failure"
check "failed upgrade: Revit never started" not_called "Revit.exe]"
check "failed upgrade: the copy is gone" gone rvt2027-a.test
json "failed upgrade: result.json says prepare_failed" '$d->{result}' prepare_failed
reset; touch "$T/upgrade-silent"; smoke 2027 rvt2027-a
expect "an upgrade that changed nothing" 1 "CrossOver could not prepare the copy: the copy is not at this CrossOver's build"

# ---- refusals: nothing is made, Wine never runs ----
refused() { check "$1: no copy" gone rvt2027-a.test; check "$1: no wine call" no_wine; }
reset; hold "$BOTTLES/rvt2027-a/drive_c/open.tmp" "C:\\Program Files\\Autodesk\\Revit 2027\\Revit.exe"
smoke 2027 rvt2027-a; expect "Revit in the bottle itself" 1 "Revit 2027 is running in rvt2027-a."
refused "Revit in the bottle"
reset; hold "$T/elsewhere.tmp" wineserver "$BOTTLES/rvt2027-a"   # only its working directory is in the bottle
smoke 2027 rvt2027-a; expect "a wineserver of the bottle" 1 "Revit's background services still run in rvt2027-a. Quit them with ./revit stop 2027"
refused "wineserver of the bottle"
reset; hold "$T/elsewhere.tmp" dummy.exe; touch "$T/lsof-fails"; smoke 2027 rvt2027-a
expect "lsof fails: refused" 1 "Could not check whether programs run in rvt2027-a"
refused "lsof fails"
reset; : > "$BOTTLES/rvt2027-a/drive_c/users/crossover/AppData/Local/Autodesk/Revit/Autodesk Revit 2027/Journals/journal.0001.txt"
smoke 2027 rvt2027-a; expect "not signed in: exit 3" 3 "Open Revit 2027 (rvt2027-a) from ~/Applications, sign in, quit Revit, then run ./revit test 2027 again."
refused "not signed in"
reset; echo hfs > "$T/fstype"; smoke 2027 rvt2027-a; expect "not on APFS" 1 "not on an APFS volume"
refused "not APFS"
reset; ln -s "$BOTTLES/rvt2027-a" "$BOTTLES/rvt2027-a.test"; smoke 2027 rvt2027-a
expect "a link where the copy goes" 1 "is a link. ./revit test does not touch it"
check "link: still there" test -L "$BOTTLES/rvt2027-a.test"; check "link: no wine call" no_wine
reset; mkdir -p "$BOTTLES/rvt2027-a.test/drive_c"; smoke 2027 rvt2027-a
expect "a bottle of someone else where the copy goes" 1 "exists, not made by ./revit test"
check "someone else's: still there" test -d "$BOTTLES/rvt2027-a.test/drive_c"
reset; old_copy rvt2026-a.test ready 1; hold "$BOTTLES/rvt2026-a.test/drive_c/open.tmp" "C:\\x\\AdskLicensingService.exe"
smoke 2027 rvt2027-a; expect "an earlier copy where programs run" 1 "Programs of an earlier test still run in its copy rvt2026-a.test"
check "busy earlier copy: kept" test -d "$BOTTLES/rvt2026-a.test"; refused "busy earlier copy"

# ---- copies of earlier runs ----
reset; old_copy rvt2027-a.test creating; old_copy rvt2024-a.test creating; old_copy rvt2026-a.test ready 1
old_copy rvt2025-a.test kept 1; menu_app "Autodesk/Revit 2026 copy" rvt2026-a.test
smoke 2027 rvt2027-a --scenarios start
expect "earlier copies: the test runs" 0 "passed"
check "a cut-short copy is deleted before the new one is made" eval 'test ! -e "$T/first-half"'
check "cut-short copies: deleted by hand, not with cxbottle" eval 'not_called "[rvt2024-a.test]" && gone rvt2024-a.test && [ "$(grep -c "^cxbottle .*\[rvt2027-a.test\]" "$CALLS")" = 1 ]'
check "an earlier finished copy: deleted with CrossOver" called "cxbottle [--bottle] [rvt2026-a.test] [--delete] [--force]"
check "an earlier finished copy: gone with its menu app" eval 'gone rvt2026-a.test && test ! -e "$H/Applications/CrossOver/Autodesk/Revit 2026 copy.app"'
check "a kept copy is not touched" eval 'test -f "$BOTTLES/rvt2025-a.test/drive_c/half" && not_called "rvt2025-a.test"'
reset; smoke 2027 rvt2027-a --scenarios start --keep
expect "--keep: the copy stays" 0 "Kept the copy rvt2027-a.test (--keep)"
check "--keep: marked kept" grep -qx "state=kept" "$BOTTLES/rvt2027-a.test/revit-macos/smoke-clone"
smoke 2027 rvt2027-a --scenarios start; expect "a kept copy where the copy goes" 1 "was kept by an earlier test"
check "kept copy: still there" test -d "$BOTTLES/rvt2027-a.test/drive_c"
reset; touch "$T/cp-fails"; smoke 2027 rvt2027-a
expect "a copy that fails" 1 "The test did not run: copying the bottle failed."
check "failed copy: deleted by hand" eval 'gone rvt2027-a.test && not_called "cxbottle"'

# ---- Ctrl-C through ./revit, with a Revit that ignores INT and TERM ----
reset; echo stubborn > "$T/mode"; echo block > "$T/launcher"; fresh
OUT="$(cd / && "${SB_ENV[@]}" STARTED="$T/revit-started" /usr/bin/perl -e '
  setpgrp(0, 0); my $p = fork; if (!$p) { $SIG{INT} = "DEFAULT"; exec @ARGV } $SIG{INT} = "IGNORE";
  for (1 .. 150) { last if -e $ENV{STARTED}; select(undef, undef, undef, 0.1) }
  kill "INT", -getpgrp(); waitpid($p, 0); printf "HOW exit=%d signal=%d\n", $? >> 8, $? & 127' \
  /bin/bash "$R/revit" test 2027 --events "$T/ev" 2>&1)"
HOW="$(sed -n 's/^HOW //p' <<<"$OUT")"; EV="$(cat "$T/ev/events.ndjson" 2>/dev/null)"
check "Ctrl-C: Revit had started" test -e "$T/revit-started"
check "Ctrl-C: ./revit ends with 1" test "$HOW" = "exit=1 signal=0"
check "Ctrl-C: says stopped" grep -q "^Stopped." <<<"$OUT"
check "Ctrl-C: nothing left running" no_fakes
check "Ctrl-C: the copy and its menu app are gone" eval 'gone rvt2027-a.test && test ! -e "$H/Applications/CrossOver/Autodesk/Revit copy.app"'
check "Ctrl-C: exactly one end event, last, stopped" one_end stopped
check "Ctrl-C: every wine call went to the copy, none got the lock or events fd" only_copy rvt2027-a
check "Ctrl-C: the lock is free" lock_free

# ---- end ----
echo; echo "$((n - fails))/$n passed"; [ "$fails" -eq 0 ]
