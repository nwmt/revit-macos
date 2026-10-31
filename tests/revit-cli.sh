#!/usr/bin/env bash
# Tests for ./revit and the argument checks of install.sh, in a sandbox: a fake HOME, a fake CrossOver
# (REVIT_CX) and stub install scripts. Runs them under /bin/bash 3.2, as on a user's Mac. Nothing real is touched.
# Usage: tests/revit-cli.sh (TEST_PART=1 or 2: one half of it, see below)
set -uo pipefail
# every control variable of the engine: none of the caller's may reach the sandbox (a REVIT_DATA or REVIT_SOURCE_LIST
# could point at real folders); tests set what they need after this
CLEAN_ENV=(-u REVIT_DATA -u REVIT_LOCK_DIR -u SHIMS_DIR -u REVIT_BUNDLED -u REVIT_EVENTS_FD -u REVIT_RUN_ID -u REVIT_RUN_CTX
  -u REVIT_ACCEPT_EULA -u REVIT_SOURCE_LIST -u REVIT_REUSE_EXTRACTED -u REVIT_REEXTRACT -u REVIT_UNPACK_AGAIN
  -u REVIT_FOR_BOTTLE -u INSTALL_PARENT -u W_CACHE -u SHIMS_FROM_SOURCE -u RUN_DIR -u RUN_KIND -u CX_RECREATE
  -u INSTALL_DRYRUN -u REVIT_LANG -u ODIS_PKGS -u REVIT_THEME -u REVIT_GDRIVE -u REVIT_GDRIVE_NAMES -u REVIT_DEFAULTS -u REVIT_YEAR -u SMOKE_TIMEOUT -u SMOKE_START_WAIT
  -u SMOKE_STALL -u SMOKE_WORKER_WAIT -u SMOKE_POLL -u SMOKE_PREP_TIMEOUT -u REVIT_CX_TMP -u REVIT_WATCH_IDLE -u REVIT_WATCH_LOCK_WAIT -u REVIT_WATCH_LSOF -u MCP_TEST_HOLD -u MCP_HANDOFF_S
  -u REVIT_RETINA -u REVIT_KEYS -u SETTINGS_SAVE_WAIT -u REVIT_FREE_GB -u REVIT_SWAP_FAIL_AT
  -u PYMCP_ROUTES_PORT -u PYMCP_DPAPI_S -u PYMCP_STATUS_S -u PYMCP_EXEC_HOLD -u PYMCP_TEST_HOLD -u REVIT_HOST -u REVIT_PORT)
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)" && [ -d "$TMP" ] || { echo "mktemp failed" >&2; exit 1; }   # an empty TOP would be the current folder
TOP="$(cd "$TMP" && pwd -P)" || exit 1   # /var → /private/var: lsof reports real paths
T="$TOP/sand box"                      # a space in every path: quoting bugs show up here
R="$T/repo"; H="$T/home"; CXF="$T/cx"; CALLS="$T/calls"
BOTTLES="$H/Library/Application Support/CrossOver/Bottles"
PIDS=""
SRV="$TOP/srv bin/wineserver"   # a fake wineserver: a copy of perl, so that its executable (ps comm) is a wineserver
mkdir -p "${SRV%/*}" && cp /usr/bin/perl "$SRV" || { echo "fake wineserver setup failed" >&2; exit 1; }
stop_fakes() { # the fake processes and their children (sleep), and wait so none is left for the next test's pgrep; a fake
  # that ignores TERM (winedevice.exe) gets KILL after 1 s
  local p i; for p in $PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10; do case "$(ps -o stat= -p "$p" 2>/dev/null)" in ""|Z*) break ;; esac; sleep 0.1; done
    kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; PIDS=""
}
trap 'stop_fakes; chmod -R u+w "$TOP" 2>/dev/null; rm -rf "$TOP"' EXIT
n=0; fails=0
ok()   { n=$((n + 1)); echo "ok   $1"; }
fail() { n=$((n + 1)); fails=$((fails + 1)); echo "FAIL $1"; printf '%s\n' "${2:-}" | sed 's/^/     /'; }

stub() { # a script that only records how it was called
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
#!/bin/bash
echo "\$(basename "\$0") \$* | REVIT_YEAR=\${REVIT_YEAR:-} INSTALL_DRYRUN=\${INSTALL_DRYRUN:-} CX_RECREATE=\${CX_RECREATE:-} WINEPREFIX=\${WINEPREFIX:-} RUN_KIND=\${RUN_KIND:-} EULA=\${REVIT_ACCEPT_EULA:-} REUSE=\${REVIT_REUSE_EXTRACTED:-} REEXTRACT=\${REVIT_REEXTRACT:-} RETINA=\${REVIT_RETINA:-} KEYS=\${REVIT_KEYS:-} THEME=\${REVIT_THEME:-} GDRIVE=\${REVIT_GDRIVE:-} GNAMES=\${REVIT_GDRIVE_NAMES-unset}" >> "$CALLS"
EOF
  chmod +x "$1"
}
slow_stub() { # $1 = path: records its start, works 3 s, turns INT/TERM into "stopped" and exit 1 (as install.sh does)
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
#!/bin/bash
trap 'echo "\$(basename "\$0") got-signal" >> "$CALLS"; exit 1' INT TERM
echo "\$(basename "\$0") started ctx=\${REVIT_RUN_CTX:-}" >> "$CALLS"
sleep 3 & wait \$!
echo "\$(basename "\$0") finished" >> "$CALLS"
EOF
  chmod +x "$1"
}
group_int() { # ./revit "$@" in a process group of its own; SIGINT to the group after $DELAY s (a terminal's Ctrl-C).
  # Sets OUT and HOW ("exit=N signal=M", from perl's waitpid: a death by a signal is not an exit code)
  : > "$CALLS"
  local in=/dev/null   # GI_HOLD=1: stdin is a pipe that stays open 5 s (a prompt waits on it)
  if [ -n "${GI_HOLD:-}" ]; then rm -f "$T/hold"; mkfifo "$T/hold"; ( sleep 5 > "$T/hold" ) & in="$T/hold"; fi
  OUT="$(cd / && env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" D="${DELAY:-1}" /usr/bin/perl -e '
    # the observer: a group of its own, INT ignored here only after fork (the child gets the default, as from a shell)
    setpgrp(0,0); my $p = fork; if (!$p) { $SIG{INT} = "DEFAULT"; exec @ARGV } $SIG{INT} = "IGNORE";
    if ($ENV{D}) { sleep $ENV{D}; kill "INT", -getpgrp() }
    waitpid($p, 0); printf "HOW exit=%d signal=%d\n", $? >> 8, $? & 127' /bin/bash "$R/revit" "$@" < "$in" 2>&1)"
  HOW="$(sed -n 's/^.*HOW \(exit=[0-9]* signal=[0-9]*\)$/\1/p' <<<"$OUT")"   # a prompt without a newline may come first
}
reset() { # a fresh sandbox for each test
  stop_fakes; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"
  mkdir -p "$R/scripts/lib" "$R/logs" "$R/installers/revit2024" "$H/Documents" "$H/Applications" "$BOTTLES" "$CXF/bin" \
    || { echo "sandbox setup failed"; exit 1; }
  cp "$REPO/revit" "$R/"; cp -R "$REPO/tools" "$R/"; cp "$REPO/scripts/lib/common.sh" "$REPO/scripts/lib/versions.sh" "$R/scripts/lib/"
  mkdir -p "$R/scripts/profiles"; cp "$REPO"/scripts/profiles/*.sh "$R/scripts/profiles/"
  cp "$REPO/scripts/lib/addins.sh" "$REPO/scripts/lib/points.sh" "$REPO/scripts/lib/mcp.sh" "$REPO/scripts/lib/pymcp.sh" "$REPO/scripts/lib/shims.sh" "$REPO/scripts/lib/handoff.sh" "$R/scripts/lib/" 2>/dev/null
  [ ! -f "$REPO/scripts/mcp-launch.sh" ] || cp "$REPO/scripts/mcp-launch.sh" "$R/scripts/"; cp "$REPO/scripts/hittest-launch.sh" "$REPO/scripts/theme-launch.sh" "$R/scripts/"; cp "$REPO/scripts/lib/wine.sh" "$R/scripts/lib/"; cp -R "$REPO/scripts/addins" "$REPO/scripts/steps" "$R/scripts/" 2>/dev/null
  stub "$R/install.sh"; stub "$R/scripts/run-steps.sh"; stub "$R/scripts/launch.sh"; stub "$R/scripts/smoke.sh"
  # ensure_shim's builder: done when build/<shim>/ holds a file, else it fails
  printf '#!/bin/bash\nfor f in "$(dirname "$0")/../build/$1"/*; do [ -f "$f" ] && exit 0; done\necho "no $1 to build"; exit 1\n' \
    > "$R/scripts/build-shims.sh"; chmod +x "$R/scripts/build-shims.sh"
  cat > "$CXF/bin/wineserver" <<EOF
#!/bin/bash
echo "wineserver \$* | REVIT_YEAR=\${REVIT_YEAR:-} INSTALL_DRYRUN=\${INSTALL_DRYRUN:-} CX_RECREATE=\${CX_RECREATE:-} WINEPREFIX=\${WINEPREFIX:-}" >> "$CALLS"
[ "\$1" = -k0 ] && [ -f "$T/wineserver-idle" ] && exit 1
[ "\$1" = -k ] && [ -f "$T/wineserver-fails" ] && exit 1
exit 0
EOF
  chmod +x "$CXF/bin/wineserver"
  cat > "$CXF/bin/cxbottle" <<EOF
#!/bin/bash
echo "cxbottle \$*" >> "$CALLS"
[ -f "$T/cxbottle-fails" ] && exit 1
[ "\$3" = --delete ] && rm -rf "$BOTTLES/\$2"
exit 0
EOF
  chmod +x "$CXF/bin/cxbottle"
  : > "$CALLS"
  touch "$H/Documents/project.rvt" "$R/installers/revit2024/Create_Installer_RVT_2024_3_6_English_WIN64.exe"
}
bottle() { # $1 = name, $2 = year in the description ("" = none), $3 = year of the Revit folder ("" = none)
  local b="$BOTTLES/$1"; mkdir -p "$b/drive_c/users/crossover"
  ln -s "$H/Documents" "$b/drive_c/users/crossover/Documents"
  [ -n "$2" ] && printf '[Bottle]\n"Description" = "Revit %s"\n' "$2" > "$b/cxbottle.conf"
  [ -n "$3" ] && mkdir -p "$b/drive_c/Program Files/Autodesk/Revit $3"
  return 0
}
apps() { local a; for a in "Revit $1" "Revit Viewer $1" "Autodesk Sign-In"; do mkdir -p "$H/Applications/$a ($2).app"; done; }
cxapp() { # $1 = path under ~/Applications/CrossOver, $2 = bottle: an app CrossOver makes for a Start Menu entry
  mkdir -p "$H/Applications/CrossOver/$1.app/Contents"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CXHelperAppBottleName</key><string>%s</string></dict></plist>\n' \
    "$2" > "$H/Applications/CrossOver/$1.app/Contents/Info.plist"
}
RDY="$TOP/ready"   # a fake writes it (perl, path in $ENV{RDY}) once it holds what it should; fake_ready waits for it
fake_ready() { local i; for i in $(seq 1 100); do [ -e "$RDY" ] && break; sleep 0.05; done; rm -f "$RDY"; }   # at most 5 s
fake_revit() { # $1 = bottle, $2 = year: a process that looks like Revit.exe and holds a file open in that bottle, and
  # the bottle's wineserver beside it (a Revit always has one: without it, Revit would be a leftover). Revit starts
  # last: callers take its PID from $!
  touch "$BOTTLES/$1/drive_c/open.tmp"
  RDY="$RDY" "$SRV" -e 'open(my $f, "<", $ARGV[0]) or die; open(my $r, ">", $ENV{RDY}) and close $r; sleep 60' "$BOTTLES/$1/drive_c/open.tmp" &
  PIDS="$PIDS $!"; fake_ready
  RDY="$RDY" perl -e 'open(my $f, "<", $ARGV[0]) or die; open(my $r, ">", $ENV{RDY}) and close $r; sleep 60' "$BOTTLES/$1/drive_c/open.tmp" \
    "C:\\Program Files\\Autodesk\\Revit $2\\Revit.exe" &
  PIDS="$PIDS $!"; fake_ready
}
fake_mcphost() { # $1 = bottle: a process that looks like our MCP launcher (mcphost.exe) and holds a file open there
  touch "$BOTTLES/$1/drive_c/mcp.tmp"
  RDY="$RDY" perl -e 'open(my $f, "<", $ARGV[0]) or die; open(my $r, ">", $ENV{RDY}) and close $r; sleep 60' "$BOTTLES/$1/drive_c/mcp.tmp" \
    "C:\\Program Files\\Autodesk\\Revit 2027 MCP Server Write-Tools Technical Preview\\mcphost.exe" --launch t &
  PIDS="$PIDS $!"; fake_ready
}
fake_leftover() { # $1 = bottle: a Windows program left behind by a wineserver that ended (winedevice.exe holds the
  # bottle's folder and, like the real one, ignores SIGTERM). Its PID in LEFT
  mkdir -p "$BOTTLES/$1/drive_c/windows"; touch "$BOTTLES/$1/drive_c/windows/held"
  RDY="$RDY" perl -e '$SIG{TERM} = "IGNORE"; open(my $f, "<", $ARGV[0]) or die; open(my $r, ">", $ENV{RDY}) and close $r; sleep 60' "$BOTTLES/$1/drive_c/windows/held" \
    'C:\windows\system32\winedevice.exe' &
  LEFT=$!; PIDS="$PIDS $LEFT"; fake_ready
}
fake_watch() { # $1 = bottle, $2 = the bottle path it names: watch-server as the Revit app starts it (perl, its folder in
  # the bottle), naming a bottle called wineserver
  mkdir -p "$BOTTLES/$1/revit-macos"; touch "$BOTTLES/$1/revit-macos/watch-server.pl"
  (cd "$BOTTLES/$1/revit-macos" && exec env RDY="$RDY" perl -e 'open(my $r, ">", $ENV{RDY}) and close $r; sleep 60' "$BOTTLES/$1/revit-macos/watch-server.pl" "$CXF" "$2") &
  PIDS="$PIDS $!"; fake_ready
}
fake_lock() { # $1 = owner text: a process that holds the repo's lock as a running script would
  mkdir -p "$H/Library/Application Support/revit-macos"
  RDY="$RDY" perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die;
    open(my $o, ">", "$ARGV[0].owner") or die; print $o "$ARGV[1]\n"; close $o; open(my $r, ">", $ENV{RDY}) and close $r; sleep 60' "$H/Library/Application Support/revit-macos/lock" "$1" &
  PIDS="$PIDS $!"; fake_ready
}
POINT_ENV=()   # more env for run (restore point tests)
run() { # $1 = what to type at the prompt; rest = ./revit arguments. Sets OUT and RC.
  local input="$1"; shift; : > "$CALLS"
  OUT="$(cd / && printf '%s\n' "$input" | env "${CLEAN_ENV[@]}" \
    HOME="$H" REVIT_CX="$CXF" REVIT_FREE_GB="${FREE_GB:-100}" ${POINT_ENV[@]+"${POINT_ENV[@]}"} /bin/bash "$R/revit" "$@" 2>&1)"; RC=$?
}
run_install() { # real install.sh in the sandbox; $1 = extra env (VAR=value or ""), rest = arguments
  local extra="$1"; shift; cp "$REPO/install.sh" "$R/install.sh"
  OUT="$(cd / && env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" $extra /bin/bash "$R/install.sh" "$@" 2>&1)"; RC=$?
}
run_racing() { # like run, but runs shell code $1 while ./revit waits at its prompt, then types $2
  local act="$1" input="$2" i; shift 2; : > "$CALLS"; : > "$T/out"
  { for i in $(seq 1 100); do grep -q "to continue" "$T/out" 2>/dev/null && break; sleep 0.1; done
    eval "$act"; printf '%s\n' "$input"; } \
    | (cd / && env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" REVIT_FREE_GB="${FREE_GB:-100}" /bin/bash "$R/revit" "$@" > "$T/out" 2>&1)
  RC=$?; OUT="$(cat "$T/out")"
}
expect() { # $1 = test name, $2 = exit code, $3 = text the output contains ("" = anything)
  if [ "$RC" = "$2" ] && { [ -z "$3" ] || grep -qF -- "$3" <<<"$OUT"; }; then ok "$1"
  else fail "$1" "rc=$RC (want $2), want text: $3
$OUT"; fi
}
check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name" "failed: $*"; fi; }
called()     { grep -qF -- "$1" "$CALLS"; }
not_called() { ! grep -qF -- "$1" "$CALLS"; }

# TEST_PART=1 runs the tests up to ./revit mcp --server pyrevit, TEST_PART=2 the rest (CI runs the halves side by side);
# unset: all of them
case "${TEST_PART:-}" in ""|1|2) ;; *) echo "TEST_PART is 1, 2 or unset, not ${TEST_PART}" >&2; exit 2 ;; esac
part() { [ -z "${TEST_PART:-}" ] || [ "$TEST_PART" = "$1" ]; }
if part 1; then
# ---- arguments ----
reset; run "";                       expect "no arguments print the help" 0 "Usage: ./revit <command> <year> [bottle]"
reset; run "" frobnicate 2024;       expect "unknown command" 1 "Unknown command: frobnicate"
reset; run "" install;               expect "missing year" 1 "Which Revit year? Example: ./revit install 2025"
reset; run "" install 2022;          expect "unsupported year" 1 "Revit 2022 is not supported yet"
reset; run "" remove rvt2024-a 2024; expect "swapped arguments" 1 '"rvt2024-a" is not a Revit year'
reset; run "" install 2024 default;  expect "bottle name default" 1 'cannot be "default"'
reset; run "" install 2024 "a b";    expect "bottle name with a space" 1 "Bottle name may contain only"
check "bad arguments run nothing" not_called "install.sh"

# ---- install, check ----
reset; run "" install 2024;          expect "install runs install.sh" 0 ""
check "install passes the year and the default bottle" called "install.sh 2024 rvt2024-a | REVIT_YEAR= INSTALL_DRYRUN= "
reset; run "" check 2025 rvt2025-b;  expect "check runs install.sh" 0 ""
check "check is a dry run of the named bottle" called "install.sh 2025 rvt2025-b | REVIT_YEAR= INSTALL_DRYRUN=1"
reset; fake_lock "install.sh 2025 rvt2025-a"; run "" install 2024
expect "install refuses while another task runs, and names it" 1 "Another task is running: install.sh 2025 rvt2025-a."
check "busy: no second install" not_called "install.sh 2024"

# ---- install.sh ----
reset; run_install "" 2024 default;  expect "install.sh refuses the bottle name default" 1 'cannot be "default"'
reset; run_install "" 2022;          expect "install.sh lists the supported years" 1 "Working versions: 2020, 2021, 2023, 2024, 2025, 2026, 2027."
reset; bottle rvt2024-b 2024 2024; run_install INSTALL_DRYRUN=1 2024 rvt2024-b
expect "install.sh: rebuild hint names the bottle" 1 "rebuild it: ./revit rebuild 2024 rvt2024-b"
expect "install.sh: final hint names the bottle" 1 "run ./revit install 2024 rvt2024-b again"
reset; bottle rvt2024-a 2024 2024; run_install INSTALL_DRYRUN=1 2024
check "install.sh: default bottle is not named" grep -qx '      fix: pick another name (./revit install 2024 rvt2024-b) or rebuild it: ./revit rebuild 2024' <<<"$OUT"

# ---- addins, stop, logs, debug ----
reset; run "" addins 2024;           expect "addins needs the bottle" 1 "There is no bottle rvt2024-a. To install Revit 2024: ./revit install 2024"
reset; bottle rvt2024-a 2024 2024; run "" addins 2024; expect "addins runs the add-in script" 0 ""
check "addins passes the year and the bottle" called "run-steps.sh 2024 rvt2024-a revitlookup pyrevit trust wpfsw check |"
check "addins logs as addins" grep -q "RUN_KIND=addins" "$CALLS"
reset; bottle rvt2024-a 2024 2024; fake_revit rvt2024-a 2024; run "" addins 2024
expect "addins refuses while Revit runs" 1 "Revit 2024 is running in rvt2024-a."
check "running: no add-ins installed" not_called "run-steps.sh"
reset; bottle rvt2024-a 2024 2024; fake_mcphost rvt2024-a; run "" addins 2024
expect "addins refuses while an AI assistant uses Revit through MCP" 1 "An AI assistant is using Revit 2024 in rvt2024-a through MCP. Close it, or run ./revit stop 2024, then try again."
check "MCP running: no add-ins installed" not_called "run-steps.sh"
reset; bottle rvt2024-a 2024 2024; bottle rvt2024-b 2024 2024; fake_mcphost rvt2024-b; run "" addins 2024
expect "an MCP launcher in another bottle does not block this one" 0 ""
for c in "2024|rebuild 2024|install.sh" "2024|remove 2024|cxbottle" "|test 2024|smoke.sh"; do
  reset; bottle rvt2024-a 2024 2024; fake_mcphost rvt2024-a; run "${c%%|*}" $(cut -d'|' -f2 <<<"$c")
  expect "$(cut -d'|' -f2 <<<"$c"): refused while MCP runs" 1 "through MCP. Close it, or run ./revit stop 2024"
  check "$(cut -d'|' -f2 <<<"$c"): nothing done while MCP runs" not_called "${c##*|}"
done
reset; bottle rvt2024-a 2024 2024; fake_mcphost rvt2024-a; run "" stop 2024; expect "stop works while MCP runs" 0 "Stopped"
check "stop with MCP: the bottle's wineserver is killed" called "wineserver -k | REVIT_YEAR= INSTALL_DRYRUN= CX_RECREATE= WINEPREFIX=$BOTTLES/rvt2024-a"
reset; bottle rvt2025-a 2025 2025; run "" stop 2024 rvt2025-a
expect "stop refuses a bottle of another year" 1 "Bottle rvt2025-a is for Revit 2025, not 2024."
check "wrong year: nothing stopped" not_called "wineserver"
reset; bottle exp "" ""; run "" stop 2024 exp; expect "stop refuses a non-Revit bottle" 1 "does not look like a Revit bottle"
reset; bottle rvt2024-b 2024 ""; run "" stop 2024 rvt2024-b; expect "stop accepts a half-installed bottle" 0 "Stopped"
check "stop kills that bottle's wineserver" called "wineserver -k | REVIT_YEAR= INSTALL_DRYRUN= CX_RECREATE= WINEPREFIX=$BOTTLES/rvt2024-b"
reset; bottle rvt2024-a 2024 2024; touch "$T/wineserver-idle"; run "" stop 2024; expect "stop when nothing runs" 0 "Nothing is running in rvt2024-a."
check "idle: nothing killed" not_called "wineserver -k |"
reset; bottle rvt2024-a 2024 2024; touch "$T/wineserver-fails"; run "" stop 2024; expect "stop reports a failure" 1 "Could not stop rvt2024-a."
reset; bottle rvt2024-a 2024 2024; touch "$T/wineserver-idle"; fake_leftover rvt2024-a
REVIT_LEFTOVER_AGE=0 run "" stop 2024
expect "stop without a wineserver ends what it left behind" 0 "Ended 1 Windows program(s) left running in rvt2024-a after Wine stopped unexpectedly."
check "leftover: the program is gone (SIGTERM would not do)" eval '! kill -0 "$LEFT" 2>/dev/null'
check "leftover: no wineserver -k" not_called "wineserver -k |"
reset; bottle rvt2024-a 2024 2024; touch "$T/wineserver-idle"; fake_watch rvt2024-a "$BOTTLES/wineserver"
fake_leftover rvt2024-a; REVIT_LEFTOVER_AGE=0 run "" stop 2024
expect "watch-server naming a bottle wineserver does not hide a leftover" 0 "Ended 1 Windows program(s) left running in rvt2024-a"
check "watch-server: the leftover is gone" eval '! kill -0 "$LEFT" 2>/dev/null'
reset; bottle rvt2024-a 2024 2024; touch "$T/wineserver-idle"; fake_revit rvt2024-a 2024; REVIT_LEFTOVER_AGE=0 run "" stop 2024
expect "a wineserver under a path with a space holds the bottle: nothing is a leftover" 0 "Nothing is running in rvt2024-a."
reset; bottle rvt2024-a 2024 2024; touch "$T/wineserver-idle"; fake_leftover rvt2024-a; run "" stop 2024
expect "a program younger than 10 s is not a leftover (Revit may be starting)" 0 "Nothing is running in rvt2024-a."
check "young: the program still runs" kill -0 "$LEFT"
reset; bottle rvt2024-a 2024 2024; bottle rvt2024-b 2024 2024; touch "$T/wineserver-idle"; fake_leftover rvt2024-b
REVIT_LEFTOVER_AGE=0 run "" stop 2024
expect "another bottle's leftover is not this bottle's" 0 "Nothing is running in rvt2024-a."
check "another bottle: its program still runs" kill -0 "$LEFT"
stop_fakes; kill -KILL "$LEFT" 2>/dev/null
reset; bottle rvt2024-a 2024 2024; ln -s "$BOTTLES/rvt2024-a" "$BOTTLES/rvt2024-t"; run "" stop 2024 rvt2024-t
expect "a bottle that is a link is refused" 1 "Bottle rvt2024-t is a link to another bottle."
reset; rm -rf "$CXF"; bottle rvt2024-a 2024 2024; run "" stop 2024; expect "stop without CrossOver" 1 "CrossOver not found"
reset; bottle rvt2024-a 2024 2024; fake_lock "install.sh 2024 rvt2024-a"; run "" stop 2024
expect "stop refuses while another task runs" 1 "Another task is running: install.sh 2024 rvt2024-a."
check "busy: nothing stopped" not_called "wineserver"
# ---- cleanup: programs left running (tools/leftovers.py); only the sandbox's fakes count (REVIT_CLEANUP_ONLY) ----
cleanup() { REVIT_CLEANUP_ONLY="$T" REVIT_CLEANUP_AGE="${AGE:-0}" REVIT_GDRIVE_STUCK_AGE=600 run "" cleanup "$@"; }
wine_as() { # $1 = executable under the fake CrossOver, $2 = argv[0], $3 = WINEPREFIX: a Wine process as the kernel tells
  # one (a copy of perl there; the sandbox's path in its arguments). It ignores TERM, as winedevice.exe does. PID in LEFT
  local x="$CXF/$1"; [ -x "$x" ] || { mkdir -p "${x%/*}"; cp /usr/bin/perl "$x"; }
  (export RDY; WINEPREFIX="$3" exec -a "$2" "$x" -e '$SIG{TERM} = "IGNORE"; open(my $r, ">", $ENV{RDY}) and close $r; sleep 60' "$T") &
  LEFT=$!; PIDS="$PIDS $LEFT"; fake_ready
}
wine_left() { wine_as lib/wine/x86_64-unix/wine 'C:\windows\system32\winedevice.exe' "$BOTTLES/$1"; }   # $1 = bottle
wine_server() { # $1 = WINEPREFIX: a wineserver; its PID in SRVP
  wine_as "CrossOver-Hosted Application/wineserver" "$CXF/CrossOver-Hosted Application/wineserver" "$1"; SRVP=$LEFT
}
fake_trackpad() { # $1 = the parent as --parent gives it (<pid>:<start>): the app's Trackpad helper; its PID in LEFT
  local x="$H/Applications/T.app/Contents/Helpers/T Trackpad.app/Contents/MacOS/T Trackpad"
  mkdir -p "${x%/*}"; cp /usr/bin/perl "$x"
  RDY="$RDY" "$x" -e 'open(my $r, ">", $ENV{RDY}) and close $r; sleep 60' -- --session S1 --parent "$1" --engine "$T/engine/revit" &
  LEFT=$!; PIDS="$PIDS $LEFT"; fake_ready
}
fake_warm() { # $1 = seconds since its last progress ("" = no heartbeat), rest = python3's arguments before the script
  # (default -I): ./revit gdrive warm of rvt2027-a, a python whose script is tools/gdrive.py; its PID in LEFT
  local since="$1"; shift; mkdir -p "$T/fake/tools"
  printf 'import os, time\nopen(os.environ["RDY"], "w").close()\ntime.sleep(60)\n' > "$T/fake/tools/gdrive.py"
  RDY="$RDY" python3 "${@:--I}" "$T/fake/tools/gdrive.py" warm "$BOTTLES/rvt2027-a" 'G:\Projects' 2027 &
  LEFT=$!; PIDS="$PIDS $LEFT"; fake_ready
  [ -z "$since" ] || { mkdir -p "$BOTTLES/rvt2027-a/revit-macos"; python3 -c 'import json, sys, time; t = time.time()
json.dump({"pid": int(sys.argv[1]), "started": t, "progress": t - int(sys.argv[2])}, open(sys.argv[3], "w"))' "$LEFT" "$since" "$BOTTLES/rvt2027-a/revit-macos/gdrive-warm-$LEFT"; }
}
plan_targets() { python3 -c 'import json, sys; print(",".join("%d:%d" % (i["pid"], i["start"]) for i in json.load(sys.stdin)["items"]))' <<<"$OUT"; }
gone() { ! kill -0 "$1" 2>/dev/null || case "$(ps -o stat= -p "$1")" in Z*) true ;; *) false ;; esac; }
reset; cleanup; expect "cleanup with nothing left" 0 "Nothing is left running."
reset; bottle rvt2024-a 2024 2024; wine_left rvt2024-a; cleanup --dry-run
expect "cleanup --dry-run lists a program Wine left behind" 0 "winedevice.exe"
check "dry run: it still runs" eval 'kill -0 "$LEFT"'
cleanup; expect "cleanup ends it" 0 "Closed 1 program(s)."
check "cleanup: it is gone (SIGTERM would not do), by PID: no wineserver -k" eval 'gone "$LEFT" && not_called "wineserver"'
reset; bottle rvt2024-a 2024 2024; wine_server "$BOTTLES/rvt2024-a"; wine_left rvt2024-a; cleanup
check "a bottle with its wineserver is no leftover" eval '[ "$RC" = 0 ] && kill -0 "$LEFT" && kill -0 "$SRVP" && grep -q "Nothing is left running." <<<"$OUT"'
reset; bottle probe 2027 2027; wine_as lib/wine/x86_64-unix/wine 'C:\windows\system32\services.exe' "$BOTTLES/probe"
rm -rf "$BOTTLES/probe"; cleanup --dry-run --json
check "a deleted bottle's program: bottle_gone, with its pid, start, CPU and age" eval 'python3 -c "import json, sys; d = json.load(sys.stdin)
i = d[\"items\"][0]; assert (i[\"pid\"], i[\"bottle\"], i[\"reason\"], i[\"name\"], i[\"revit\"]) == ($LEFT, \"probe\", \"bottle_gone\", \"services.exe\", False), d
assert isinstance(i[\"cpu\"], float) and i[\"age_s\"] >= 0 and i[\"start\"] > 1700000000 * 10 ** 6" <<<"$OUT"'
cleanup; check "a deleted bottle's program is ended" eval 'gone "$LEFT"'
reset; bottle rvt2024-a 2024 2024; wine_server "$T/elsewhere/pfx"; FOREIGN=$SRVP; wine_left rvt2024-a; cleanup
check "a wineserver of a prefix outside Bottles does not block cleanup, and stays" eval '[ "$RC" = 0 ] && gone "$LEFT" && kill -0 "$FOREIGN"'
reset; bottle rvt2024-a 2024 2024; mkdir -p "$BOTTLES/rvt2024-a/revit-macos"; touch "$BOTTLES/rvt2024-a/revit-macos/wineserver.log"
(cd "$BOTTLES/rvt2024-a/revit-macos" && export RDY && WINEPREFIX="$BOTTLES/rvt2024-a" exec perl -e 'open(my $f, "<", $ARGV[0]) or die; open(my $r, ">", $ENV{RDY}) and close $r; sleep 60' \
  "$BOTTLES/rvt2024-a/revit-macos/wineserver.log") & LEFT=$!; PIDS="$PIDS $LEFT"; fake_ready
cleanup --all; check "a Mac program reading a bottle's wineserver.log is no Wine program, also for --all" eval '[ "$RC" = 0 ] && kill -0 "$LEFT" && grep -q "Nothing is left running." <<<"$OUT"'
reset; wine_as lib/wine/x86_64-unix/wine 'C:\windows\system32\conhost.exe' ""; cleanup
check "a Wine program without a WINEPREFIX is left alone" eval '[ "$RC" = 0 ] && kill -0 "$LEFT"'
cleanup --all; check "--all ends it" eval '[ "$RC" = 0 ] && gone "$LEFT"'
reset; bottle rvt2024-a 2024 2024; wine_as lib/wine/x86_64-unix/wine 'C:\Program Files\Autodesk\Revit 2024\Revit.exe' "$BOTTLES/rvt2024-a"; REV=$LEFT
wine_left rvt2024-a; cleanup
expect "Revit among what Wine left: the bottle is skipped, and says how to close it" 0 "Skipped rvt2024-a: Revit is among what Wine left there. To close it without saving: ./revit cleanup --all"
check "skipped: nothing ended" eval 'kill -0 "$REV" && kill -0 "$LEFT"'
wine_server "$BOTTLES/rvt2024-a"; cleanup --all --dry-run; expect "--all lists Revit and says it closes without saving" 0 "Revit: unsaved changes are lost"
cleanup --all; check "--all ends Revit, its programs and its wineserver, by PID" eval '[ "$RC" = 0 ] && gone "$REV" && gone "$LEFT" && gone "$SRVP" && not_called "wineserver"'
reset; bottle rvt2024-a 2024 2024; wine_left rvt2024-a; A=$LEFT; cleanup --all --dry-run --json; tg="$(plan_targets)"; wine_left rvt2024-a
cleanup --all --targets "$tg" --json
check "--targets: what was approved is ended, a program found since is not" eval 'gone "$A" && kill -0 "$LEFT" && grep -q "\"closed\": \[$A\]" <<<"$OUT"'
cleanup --all --dry-run --json; st="$(sed -n 's/.*"start": \([0-9]*\).*/\1/p' <<<"$OUT")"; cleanup --all --targets "$LEFT:$((st - 1))"
check "--targets: a PID whose start changed (reused) is not signalled" eval 'kill -0 "$LEFT" && grep -q "Nothing is left running." <<<"$OUT"'
run "" cleanup --targets "1:x"; expect "--targets needs <pid>:<start>" 1 "--targets takes <pid>:<start>,…"
run "" cleanup --dry-run --targets "1:2"; expect "--targets is not for --dry-run" 1 "it is not for --dry-run"
reset; bottle rvt2024-a 2024 2024; bottle rvt2024-b 2024 2024; wine_left rvt2024-a; A=$LEFT; wine_left rvt2024-b; cleanup 2024 rvt2024-b
check "cleanup <year> <bottle> ends that bottle's programs only" eval '[ "$RC" = 0 ] && gone "$LEFT" && kill -0 "$A"'
reset; bottle rvt2024-a 2024 2024; wine_left rvt2024-a; AGE=60 cleanup --dry-run
expect "a program younger than 60 s is not counted (Revit may be starting)" 0 "Nothing is left running."
reset; fake_trackpad "999999:Thu Jan  1 00:00:00 2026"; cleanup
check "a Trackpad helper whose app is gone is ended" eval '[ "$RC" = 0 ] && grep -q "T Trackpad .*the program that started it is gone" <<<"$OUT" && gone "$LEFT"'
reset; fake_trackpad "$$:$(ps -o lstart= -p $$)"; cleanup --dry-run; expect "a Trackpad helper whose app runs stays" 0 "Nothing is left running."
reset; bottle rvt2027-a 2027 2027; fake_warm 700; cleanup --dry-run
expect "a gdrive warm whose own heartbeat is older than the limit is stuck" 0 "a Google Drive folder does not answer"
cleanup 2027; check "cleanup 2027 ends the stuck warm and its heartbeat" eval '[ "$RC" = 0 ] && gone "$LEFT" && [ ! -e "$BOTTLES/rvt2027-a/revit-macos/gdrive-warm-$LEFT" ]'
reset; bottle rvt2027-a 2027 2027; fake_warm 5; cleanup --dry-run; expect "a slow gdrive warm that still makes progress is not stuck" 0 "Nothing is left running."
reset; bottle rvt2027-a 2027 2027; fake_warm ""; cleanup --dry-run; expect "a gdrive warm without a heartbeat is not stuck" 0 "Nothing is left running."
reset; bottle rvt2027-a 2027 2027; fake_warm 700 -c 'import os, time; open(os.environ["RDY"], "w").close(); time.sleep(60)'; cleanup --dry-run
expect "python -c naming gdrive.py warm is not a warm" 0 "Nothing is left running."
reset; bottle rvt2024-a 2024 2024; wine_left rvt2024-a; fake_lock "install.sh 2025 rvt2025-a"; cleanup
check "cleanup needs no lock: it ends what Wine left while another task runs" eval '[ "$RC" = 0 ] && gone "$LEFT"'
reset; cleanup 2022; expect "cleanup of an unsupported year" 1 "Revit 2022 is not supported yet"
reset; run "" logs 2024;             expect "logs when there are none" 1 "No logs for rvt2024-a yet."
reset; mkdir -p "$R/logs/rvt2024-a/20261011-100000-install" "$R/logs/rvt2024-a/20261011-110000-debug" \
  "$R/logs/rvt2025-a/20261011-120000-install" "$R/logs/rvt2024-a-2/20261011-140000-install"
run "" logs 2024;                    expect "logs works without a bottle" 0 "logs/rvt2024-a/20261011-110000-debug"
check "logs leaves out other bottles" eval '! grep -q -e rvt2025-a -e rvt2024-a-2 <<<"$OUT"'
reset; ln -s "$BOTTLES/elsewhere" "$BOTTLES/rvt2024-a"; mkdir -p "$R/logs/rvt2024-a/20261011-100000-install"
run "" logs 2024;                    expect "logs is not blocked by a bottle link" 0 "logs/rvt2024-a/20261011-100000-install"
reset; mkdir -p "$R/logs/install-rvt2024-a-20261011-100000"; run "" logs 2024
expect "logs points at the older layout" 1 "Older logs are in logs/ directly"
reset; bottle rvt2024-a 2024 2024; run "" debug 2024; expect "debug starts Revit with logging" 0 "quit Revit, then run ./revit report 2024."
check "debug passes the year" called "launch.sh 2024 rvt2024-a |"
reset; bottle rvt2024-a 2024 2024; fake_revit rvt2024-a 2024; run "" debug 2024
expect "debug refuses while Revit runs" 1 "Revit 2024 is running in rvt2024-a."
reset; bottle rvt2024-a 2024 2024; fake_lock "run-steps.sh 2024 rvt2024-a wpfhw"; run "" debug 2024
expect "debug refuses while another task runs" 1 "Another task is running: run-steps.sh 2024 rvt2024-a wpfhw."

# ---- rebuild ----
reset; bottle rvt2024-a 2024 2024; run "no" rebuild 2024; expect "rebuild can be cancelled" 1 "Cancelled. Nothing changed."
check "cancelled rebuild ran nothing" not_called "install.sh"
reset; bottle rvt2024-a 2024 2024; run "2024" rebuild 2024; expect "rebuild explains the reset" 0 "run ./revit addins 2024 again"
check "rebuild reinstalls with CX_RECREATE" called "install.sh 2024 rvt2024-a | REVIT_YEAR= INSTALL_DRYRUN= CX_RECREATE=1"
reset; bottle rvt2024-b 2024 2024; run "" rebuild 2024 rvt2024-b; expect "rebuild hint names a non-default bottle" 1 "run ./revit addins 2024 rvt2024-b again"
reset; bottle rvt2025-a 2025 2025; run "2024" rebuild 2024 rvt2025-a; expect "rebuild refuses another year" 1 "is for Revit 2025"
check "wrong year: the 2025 bottle is untouched" test -d "$BOTTLES/rvt2025-a"
reset; bottle rvt2024-a 2024 2024; fake_revit rvt2024-a 2024; run "2024" rebuild 2024
expect "rebuild refuses while Revit runs" 1 "Save your work and quit Revit"
check "running: nothing reinstalled" not_called "install.sh"
reset; bottle rvt2024-a 2024 2024; bottle rvt2024-b 2024 2024; fake_revit rvt2024-b 2024; run "2024" rebuild 2024
expect "Revit in another bottle does not block rebuild" 0 ""

# ---- remove ----
reset; bottle rvt2024-a 2024 2024; apps 2024 rvt2024-a; mkdir -p "$R/installers/extracted/revit2024"
run "no" remove 2024;                expect "remove can be cancelled" 1 "Cancelled. Nothing changed."
check "cancelled remove kept the bottle" test -d "$BOTTLES/rvt2024-a"
run "2024" remove 2024;              expect "remove says Documents stays" 0 "Documents in this bottle is your Mac folder ~/Documents. It stays."
check "remove deleted the bottle" test ! -d "$BOTTLES/rvt2024-a"
check "remove stops the bottle's services before deleting it" eval '[ "$(grep -e "^wineserver -k |.*WINEPREFIX=$BOTTLES/rvt2024-a" -e "^cxbottle .*--delete" "$CALLS" | cut -c1-8 | tr "\n" " ")" = "wineserv cxbottle " ]'
check "remove deleted the Revit app" test ! -d "$H/Applications/Revit 2024 (rvt2024-a).app"
check "remove deleted the Sign-In app" test ! -d "$H/Applications/Autodesk Sign-In (rvt2024-a).app"
check "remove deleted the unpacked files" test ! -d "$R/installers/extracted/revit2024"
check "remove kept the downloads" test -f "$R/installers/revit2024/Create_Installer_RVT_2024_3_6_English_WIN64.exe"
check "remove kept the Mac's Documents" test -f "$H/Documents/project.rvt"
check "remove lines up the sizes" eval '[ "$(grep -E "^  (bottle|installers/extracted)" <<<"$OUT" | awk "{ print length(\$0) }" | sort -u | wc -l)" -eq 1 ]'
reset; bottle rvt2024-a 2024 2024; bottle rvt2024-b 2024 2024; mkdir -p "$R/installers/extracted/revit2024"
run "2024" remove 2024;              expect "remove keeps unpacked files another bottle uses" 0 "Kept: installers/extracted/revit2024 (bottle rvt2024-b still uses it)."
check "unpacked files still there" test -d "$R/installers/extracted/revit2024"
reset; bottle rvt2024-a 2024 2024; fake_lock "install.sh 2024 rvt2024-a"
run "2024" remove 2024;              expect "remove refuses during an install of this year" 1 "Another task is running: install.sh 2024 rvt2024-a."
check "install running: bottle kept" test -d "$BOTTLES/rvt2024-a"
reset; apps 2024 rvt2024-a; mkdir -p "$R/installers/extracted/revit2024"; fake_lock "unpack-revit.sh 2024"
run "2024" remove 2024;              expect "remove refuses while the installer is unpacked" 1 "Another task is running: unpack-revit.sh 2024."
check "busy: apps kept" test -d "$H/Applications/Revit 2024 (rvt2024-a).app"
check "busy: unpacked files kept" test -d "$R/installers/extracted/revit2024"
reset; ln -s "$BOTTLES/nowhere" "$BOTTLES/rvt2024-a"; apps 2024 rvt2024-a; run "2024" remove 2024
expect "remove refuses a dangling bottle link" 1 "is a link to another bottle"
check "dangling link: apps kept" test -d "$H/Applications/Revit 2024 (rvt2024-a).app"
reset; apps 2024 rvt2024-a; chmod 555 "$H/Applications"
run "2024" remove 2024;              expect "remove reports an app it could not delete" 1 "Could not delete ~/Applications/"
chmod 755 "$H/Applications"
reset; bottle rvt2024-a 2024 2024; bottle rvt2024-b 2024 2024; fake_revit rvt2024-b 2024
run "2024" remove 2024;              expect "Revit in another bottle does not block remove" 0 "Removed Revit 2024 (rvt2024-a)."
reset; bottle rvt2024-a 2024 2024; fake_revit rvt2024-a 2024
run "2024" remove 2024;              expect "remove refuses while Revit runs" 1 "Revit 2024 is running in rvt2024-a."
check "running: bottle kept" test -d "$BOTTLES/rvt2024-a"
reset; bottle rvt2025-a 2025 2025; run "2024" remove 2024 rvt2025-a; expect "remove refuses another year" 1 "is for Revit 2025"
check "wrong year: bottle kept" test -d "$BOTTLES/rvt2025-a"
reset; bottle rvt2024-a 2024 2024; apps 2024 rvt2024-a; touch "$T/cxbottle-fails"
run "2024" remove 2024;              expect "a failed bottle delete stops remove" 1 "The bottle is still there"
check "failed delete: apps kept" test -d "$H/Applications/Revit 2024 (rvt2024-a).app"
reset; apps 2024 rvt2024-a; run "2024" remove 2024; expect "remove finishes a partial remove" 0 "Removed Revit 2024 (rvt2024-a)."
check "partial remove: apps gone" test ! -d "$H/Applications/Revit Viewer 2024 (rvt2024-a).app"
reset; run "" remove 2024;           expect "nothing to remove" 0 "Nothing to remove for Revit 2024 (rvt2024-a)."
reset; bottle rvt2024-a 2024 2024; cxapp "Autodesk/Revit 2024/Revit 2024" rvt2024-a; cxapp "Chaos/Enscape" rvt2024-a
cxapp "Autodesk/Revit 2024 other" rvt2024-b; run "2024" remove 2024
expect "remove lists CrossOver's menu apps" 0 "2 CrossOver menu apps of rvt2024-a in ~/Applications/CrossOver"
check "remove deleted CrossOver's menu apps" test ! -e "$H/Applications/CrossOver/Autodesk/Revit 2024/Revit 2024.app"
check "remove deleted their empty folders" test ! -e "$H/Applications/CrossOver/Chaos"
check "remove kept another bottle's menu app" test -d "$H/Applications/CrossOver/Autodesk/Revit 2024 other.app"
reset; cxapp "Autodesk/Revit 2024" rvt2024-a; run "2024" remove 2024
expect "remove finishes leftover CrossOver menu apps" 0 "Removed Revit 2024 (rvt2024-a)."
reset; apps 2024 rvt2024-a; run_racing 'bottle rvt2024-a 2024 2024' 2024 remove 2024
expect "a bottle that appears during the prompt stops remove" 1 "Nothing was removed."
check "appeared bottle: not deleted" test -d "$BOTTLES/rvt2024-a"
check "appeared bottle: apps kept" test -d "$H/Applications/Revit 2024 (rvt2024-a).app"
reset; rm -rf "$CXF"; bottle rvt2024-a 2024 2024; run "2024" remove 2024; expect "remove without CrossOver" 1 "CrossOver not found"

# ---- supervisor ----
reset; run "" install 2024
check "install still calls install.sh" called "install.sh 2024 rvt2024-a"
check "the child gets a run context" eval 'ls -d "$R/logs/runs/"*/ >/dev/null 2>&1'
reset; printf '#!/bin/bash\nexit 3\n' > "$R/install.sh"; run "" install 2024
expect "revit exits with the child's code" 3 ""
reset; printf '#!/bin/bash\necho to-out; echo to-err >&2\n' > "$R/install.sh"; run "" install 2024
check "the child's stdout and stderr reach the terminal" eval 'grep -qx to-out <<<"$OUT" && grep -qx to-err <<<"$OUT"'
reset; printf '#!/bin/bash\nkill -TERM $$\n' > "$R/install.sh"; DELAY=0 group_int install 2024
check "a child that dies by TERM: revit dies by TERM" test "$HOW" = "exit=0 signal=15"
check "a child that dies by TERM: no message from the supervisor" eval '! grep -q "Terminated" <<<"$OUT"'
reset; slow_stub "$R/install.sh"; DELAY=1 group_int install 2024
check "INT during the child: the child handled it" called "install.sh got-signal"
check "INT during the child: revit exits as the child did" test "$HOW" = "exit=1 signal=0"
check "INT during the child: nothing keeps running" eval 'sleep 3; ! grep -q "install.sh finished" "$CALLS"'
reset; slow_stub "$R/scripts/run-steps.sh"; bottle rvt2024-a 2024 2024; DELAY=1 group_int addins 2024
check "INT during addins: the runner handled it" called "run-steps.sh got-signal"
check "INT during addins: exit 1" test "$HOW" = "exit=1 signal=0"
reset; slow_stub "$R/install.sh"; DELAY=1 group_int check 2024
check "INT during check: the child handled it" called "install.sh got-signal"
check "INT during check: nothing keeps running" eval 'sleep 3; ! grep -q "install.sh finished" "$CALLS"'
reset; slow_stub "$R/install.sh"
sed -i '' 's|^# ---- run the command ----$|sleep 2  # test: a slow start\n&|' "$R/revit"
grep -q '^sleep 2  # test' "$R/revit" || fail "the slow-start edit did not apply" ""
DELAY=1 group_int install 2024
check "INT before the child: the child never starts" not_called "install.sh started"
check "INT before the child: revit dies by SIGINT" test "$HOW" = "exit=0 signal=2"
reset; bottle rvt2024-a 2024 2024; slow_stub "$R/scripts/launch.sh"; sed -i '' 's|^# ---- run the command ----$|sleep 2  # test\n&|' "$R/revit"
DELAY=1 group_int debug 2024
check "INT before an unsupervised command: it dies by SIGINT as before" test "$HOW" = "exit=0 signal=2"
check "INT before an unsupervised command: it never starts" not_called "launch.sh started"
reset; bottle rvt2024-a 2024 2024; GI_HOLD=1 DELAY=1 group_int rebuild 2024
check "INT at the typed confirmation: death by SIGINT at once, as before" test "$HOW" = "exit=0 signal=2"
check "INT at the typed confirmation: nothing ran" not_called "install.sh"
reset; bottle rvt2024-a 2024 2024; run "" rebuild 2024 --yes
expect "--yes skips the typed confirmation" 0 ""
check "--yes: install.sh ran as a rebuild" called "install.sh 2024 rvt2024-a | REVIT_YEAR= INSTALL_DRYRUN= CX_RECREATE=1"
reset; run "" install 2024 --frob; expect "an unknown flag" 1 "Unknown option: --frob"
reset; run "" --help; expect "--help still prints the help" 0 "Usage: ./revit <command> <year> [bottle]"
reset; run "" -h;     expect "-h still prints the help" 0 "Usage: ./revit <command> <year> [bottle]"
reset; printf '#!/bin/bash\nprintf "result=partial\\nlog_dir=/x\\n" > "$REVIT_RUN_CTX/result"; exit 1\n' > "$R/install.sh"
run "" install 2024; check "the child's result file is kept in the run context" eval 'grep -qx "result=partial" "$R"/logs/runs/*/result'

# ---- events ----
EV() { cat "$T/ev/events.ndjson" 2>/dev/null; }
valid_ndjson() { /usr/bin/perl -MJSON::PP -ne 'eval { JSON::PP->new->decode($_) } or exit 1' "$1"; }
reset; run "" install 2024 --events "$T/ev"
check "events: every line is JSON" valid_ndjson "$T/ev/events.ndjson"
check "events: start first, with the year as a number and the default bottle" eval 'head -1 "$T/ev/events.ndjson" | grep -qF "{\"event\":\"start\",\"run_id\":\"ev\",\"command\":\"install\",\"year\":2024,\"bottle\":\"rvt2024-a\","'
check "events: end last, exactly once" eval '[ "$(EV | grep -c "\"event\":\"end\"")" = 1 ] && EV | tail -1 | grep -q "\"event\":\"end\""'
check "events: nothing on the terminal" eval '! grep -q "\"event\"" <<<"$OUT"'
reset; run "" install 2022 --events "$T/ev"
check "events: a bad year ends as usage" eval 'EV | tail -1 | grep -q "\"result\":\"usage\""'
check "events: a bad year still starts first" eval 'EV | head -1 | grep -q "\"event\":\"start\""'
reset; run "" install 2024 --frob --events "$T/ev"
check "events: an unknown flag ends as usage" eval 'EV | tail -1 | grep -q "\"result\":\"usage\""'
reset; fake_lock "install.sh 2025 rvt2025-a"; run "" install 2024 --events "$T/ev"
check "events: a busy lock ends as busy" eval 'EV | tail -1 | grep -q "\"result\":\"busy\""'
reset; printf '#!/bin/bash\nkill -9 $$\n' > "$R/install.sh"; run "" install 2024 --events "$T/ev"
check "events: a killed child still gets one end, stopped" eval 'EV | tail -1 | grep -q "\"event\":\"end\".*\"result\":\"stopped\""'
reset; printf '#!/bin/bash\nprintf "result=partial\\nfailed_steps=dynamo tlbpin\\nlog_dir=/l\\n" > "$REVIT_RUN_CTX/result"; exit 1\n' > "$R/install.sh"
run "" install 2024 --events "$T/ev"
check "events: end carries the child's result" eval 'EV | tail -1 | grep -qF "\"exit_code\":1,\"result\":\"partial\",\"failed_action\":\"\",\"failed_steps\":[\"dynamo\",\"tlbpin\"],\"log_dir\":\"/l\"}"'
reset; mkdir -p "$T/ev"; : > "$T/ev/events.ndjson"; run "" install 2024 --events "$T/ev"
expect "events: even an empty events file means a used folder" 1 "already holds a run"
reset; mkdir -p "$T/ev"; echo '{"event":"start"}' > "$T/ev/events.ndjson"; run "" install 2024 --events "$T/ev"
expect "events: a used folder is refused" 1 "already holds a run"
check "events: the used folder is left alone" eval '[ "$(EV)" = "{\"event\":\"start\"}" ]'
reset; run "" install 2024
check "no --events: no events file" eval '! ls "$R"/logs/runs/*/events.ndjson >/dev/null 2>&1'

# ---- status ----
revit_exe() { touch "$BOTTLES/$1/drive_c/Program Files/Autodesk/Revit $2/Revit.exe"; }   # $1 = bottle, $2 = year
reset; bottle rvt2024-a 2024 2024; revit_exe rvt2024-a 2024; bottle rvt2025-b 2025 ""; bottle exp "" ""; run "" status --json
expect "status --json" 0 '"bottles":['
check "status: valid JSON" eval 'printf "%s" "$OUT" | /usr/bin/perl -MJSON::PP -e "local \$/; JSON::PP->new->decode(<STDIN>)"'
check "status: a Revit bottle" grep -qF '{"name":"rvt2024-a","year":"2024","revit":true,"running":false,"revit_pids":[],"addins":[],"theme_mode":"","gdrive":{"mode": "auto", "mapping": "none", "accounts": "zero", "names": 0, "settings": false}}' <<<"$OUT"
check "status: a half-installed bottle" grep -qF '{"name":"rvt2025-b","year":"2025","revit":false,' <<<"$OUT"
check "status: a non-Revit bottle is left out" eval '! grep -q "\"exp\"" <<<"$OUT"'
reset; bottle rvt2027-a 2027 2027; mkdir -p "$BOTTLES/rvt2027-a/dosdevices" "$H/Library/CloudStorage/GoogleDrive-someone@example.com/My Drive"
env "${CLEAN_ENV[@]}" HOME="$H" python3 -I "$R/tools/gdrive.py" apply "$BOTTLES/rvt2027-a" --mode someone@example.com --names ru >/dev/null
run "" status --json
check "status: G: as gdrive.py state says, no email, no folder names" eval 'grep -qF "\"gdrive\":$(env "${CLEAN_ENV[@]}" HOME="$H" python3 -I "$R/tools/gdrive.py" state "$BOTTLES/rvt2027-a")}" <<<"$OUT" &&
  grep -qF "\"gdrive\":{\"mode\": \"account\", \"mapping\": \"ok\", \"accounts\": \"one\", \"names\": 3" <<<"$OUT" && ! grep -q -e example.com -e "Other computers=" <<<"$OUT"'
check "status: still valid JSON" eval 'printf "%s" "$OUT" | /usr/bin/perl -MJSON::PP -e "local \$/; JSON::PP->new->decode(<STDIN>)"'
reset; bottle rvt2024-a 2024 2024; revit_exe rvt2024-a 2024; fake_revit rvt2024-a 2024; run "" status --json
check "status: running" grep -qF '"name":"rvt2024-a","year":"2024","revit":true,"running":true' <<<"$OUT"
reset; for b in rvt2027-a rvt2027-b; do bottle $b 2027 2027; revit_exe $b 2027; done; bottle rvt2025-a 2025 2025; revit_exe rvt2025-a 2025
fake_revit rvt2027-a 2027; p27a=$!; fake_revit rvt2027-b 2027; p27b=$!; fake_revit rvt2025-a 2025; p25=$!; run "" status --json
check "status: revit_pids, each bottle its own Revit processes" eval 'grep -qF "\"name\":\"rvt2027-a\",\"year\":\"2027\",\"revit\":true,\"running\":true,\"revit_pids\":[$p27a]" <<<"$OUT" &&
  grep -qF "\"name\":\"rvt2027-b\",\"year\":\"2027\",\"revit\":true,\"running\":true,\"revit_pids\":[$p27b]" <<<"$OUT" &&
  grep -qF "\"name\":\"rvt2025-a\",\"year\":\"2025\",\"revit\":true,\"running\":true,\"revit_pids\":[$p25]" <<<"$OUT"'
run "" status; check "status: the human list has no pids" eval '! grep -q "$p27a" <<<"$OUT"'
reset; fake_lock "install.sh 2024 rvt2024-a"; run "" status --json
check "status: busy with its owner" grep -qF '"busy":{"busy":true,"command":"install.sh 2024 rvt2024-a"' <<<"$OUT"
reset; run "" status --json; check "status: CrossOver found in the fake" grep -qF '"crossover":{"found":true' <<<"$OUT"
reset; bottle rvt2024-a 2024 2024; run "" status; expect "status without --json" 0 ""
check "status in words" grep -qE '^  rvt2024-a +Revit 2024$' <<<"$OUT"

# ---- doctor ----
fake_wine() { # a wine in the fake CrossOver that records its calls, as wineserver and cxbottle do
  printf '#!/bin/bash\necho "wine $*" >> "%s"\n' "$CALLS" > "$CXF/bin/wine"; chmod +x "$CXF/bin/wine"
}
no_wine_calls() { ! grep -qE '^(wine|wineserver|cxbottle) ' "$CALLS"; }
rc_says() { # the exit code is 1 exactly when a check failed (a ✗ line, or "fail" in the JSON summary)
  local f; f="$(/usr/bin/perl -MJSON::PP -e 'local $/; my $j = eval { decode_json(<STDIN>) }; print $j ? $j->{summary}{fail} : -1' <<<"$OUT")"
  if [ "$f" = -1 ]; then grep -q '✗' <<<"$OUT" && f=1 || f=0; fi
  if [ "$f" -gt 0 ]; then [ "$RC" = 1 ]; else [ "$RC" = 0 ]; fi
}
valid_doctor_json() { /usr/bin/perl -MJSON::PP -e 'local $/; my $j = decode_json(<STDIN>); my $s = $j->{summary};
  exit 1 unless ref $j->{checks} eq "ARRAY" && @{$j->{checks}} == $s->{checks} && $s->{checks} == $s->{fail} + $s->{warn} + $s->{ok} + $s->{info};
  for (@{$j->{checks}}) { exit 1 unless $_->{status} =~ /^(ok|warn|fail|info)$/ && join(",", sort keys %$_) eq "detail,doc,fix,group,id,status,title" }' <<<"$OUT"; }
reset; run "" doctor 2022;           expect "doctor: an unsupported year" 1 "Revit 2022 is not supported yet"
reset; run "" doctor rvt2025-a;      expect "doctor: a bottle where the year goes" 1 '"rvt2025-a" is not a Revit year'
reset; run "" doctor 2025 "a b";     expect "doctor: a bad bottle name" 1 "Bottle name may contain only"
reset; run "" doctor --frob;         expect "doctor: an unknown flag" 1 "Unknown option: --frob"
reset; fake_wine; run "" doctor
check "doctor without a year: this Mac and CrossOver" grep -qx "Checking this Mac and CrossOver…" <<<"$OUT"
check "doctor without a year: exit 1 exactly with a ✗" rc_says
check "doctor without a year: the count of checks last" eval 'tail -1 <<<"$OUT" | grep -qE "\([0-9]+ checks\)$"'
check "doctor without a year: no bottles yet" grep -qF "  · no Revit bottles yet" <<<"$OUT"
reset; fake_wine; bottle rvt2025-a 2025 2025; revit_exe rvt2025-a 2025; bottle exp "" ""; run "" doctor
check "doctor without a year: one line per Revit bottle" eval 'grep -qxF "  · rvt2025-a: Revit 2025" <<<"$OUT" && ! grep -q exp <<<"$OUT"'
reset; run "" doctor 2025;           expect "doctor: no bottle is a ✗" 1 "  ✗ there is no bottle rvt2025-a"
check "doctor: the fix line says how to install" grep -qxF "      fix: to install Revit 2025: ./revit install 2025" <<<"$OUT"
reset; fake_wine; bottle rvt2025-a 2025 2025; revit_exe rvt2025-a 2025; apps 2025 rvt2025-a; mkdir -p "$R/logs"
touch "$T/stamp"; sleep 1
run "" doctor 2025 --json;           check "doctor --json: valid JSON in the shape of the spec" valid_doctor_json
check "doctor --json: exit 1 exactly when a check failed" rc_says
check "doctor --json: the bottle's checks are there" grep -qF '"id":"bottle.revit","group":"bottle","status":"ok"' <<<"$OUT"
run "" doctor 2025 --all;            check "doctor --all: the passed checks too" grep -qF "  ✓ Revit.exe is in the bottle" <<<"$OUT"
check "doctor --all: exit 1 exactly with a ✗" rc_says
run "" doctor 2025;                  check "doctor: problems only" eval '! grep -qF "  ✓ Revit.exe is in the bottle" <<<"$OUT"'
run "" doctor;                       check "doctor: no wine, wineserver or cxbottle" no_wine_calls
check "doctor writes nothing (no file newer than before it ran)" eval '[ -z "$(find "$H" "$R" -newer "$T/stamp" 2>/dev/null)" ]'
reset; fake_wine; bottle rvt2025-a 2025 2025; revit_exe rvt2025-a 2025; fake_lock "install.sh 2025 rvt2025-a"
run "" doctor 2025;                  check "doctor while another task holds the lock: it runs and names the task" \
  eval 'grep -qxF "  · another task is running: install.sh 2025 rvt2025-a" <<<"$OUT" && ! grep -q "Wait until it finishes" <<<"$OUT"'
check "doctor while the lock is held: exit as its checks say" rc_says
reset; fake_wine; bottle rvt2025-a 2025 2025; revit_exe rvt2025-a 2025; fake_revit rvt2025-a 2025; run "" doctor 2025
check "doctor while Revit runs: it says so and does not refuse" eval 'grep -qxF "  · Revit or its background services run in rvt2025-a" <<<"$OUT" && ! grep -q "Save your work" <<<"$OUT"'
check "doctor while Revit runs: no wine, wineserver or cxbottle" no_wine_calls
reset; bottle rvt2025-a 2024 2024; run "" doctor 2025; expect "doctor: a bottle of another year is a ✗" 1 "✗ bottle rvt2025-a is for Revit 2024, not 2025"

# ---- report ----
report_dir() { ls -d "$R/logs/$1/"*-report 2>/dev/null | head -1; }   # $1 = bottle (or mac): the report folder
zip_has() { # $1 = zip, $2 = member name. A variable, not a pipe into grep -q: under pipefail an early grep exit gives
  # unzip SIGPIPE, and the check failed now and then
  local l; l="$(/usr/bin/unzip -l "$1" 2>/dev/null)"; grep -qE " $2\$" <<<"$l"
}
reset; run "" report 2022;           expect "report: an unsupported year" 1 "Revit 2022 is not supported yet"
reset; run "" report rvt2025-a;      expect "report: a bottle where the year goes" 1 '"rvt2025-a" is not a Revit year'
reset; run "" report 2025 "a b";     expect "report: a bad bottle name" 1 "Bottle name may contain only"
reset; run "" report 2025 --run;     expect "report: --run needs a value" 1 "--run needs a value"
reset; run "" report 2025 --run "$T/no such run"; expect "report: --run takes a log folder" 1 "No such log folder"
reset; run "" doctor 2025 --run "$T"; expect "--run is for report only" 1 "--run is for ./revit report only."
reset; run "" status --exclude doctor.json; expect "--exclude is for report only" 1 "--exclude is for ./revit report only."
check "report: a refused argument writes nothing" eval '[ -z "$(ls -A "$R/logs")" ]'
reset; fake_wine; bottle rvt2025-a 2025 2025; revit_exe rvt2025-a 2025; apps 2025 rvt2025-a; mkdir -p "$R/logs/rvt2025-a" "$T/tmp"
touch "$T/stamp"; sleep 1
TMPDIR="$T/tmp" run "" report 2025; expect "report: it says where report.txt and report.zip are" 0 "Read both before you post them."
check "report: the files are in logs/<bottle>" eval 'd="$(report_dir rvt2025-a)"; [ -s "$d/report.txt" ] && [ -s "$d/report.zip" ] &&
  grep -qF "Report: " <<<"$OUT" && grep -qF "Attach: " <<<"$OUT"'
check "report: doctor's checks are in it" eval 'zip_has "$(report_dir rvt2025-a)/report.zip" doctor.json &&
  grep -q "^./revit doctor: " "$(report_dir rvt2025-a)/report.txt"'
check "report: no wine, wineserver or cxbottle" no_wine_calls
check "report: nothing written outside its logs folder" eval '[ -z "$(find "$H" "$R" -newer "$T/stamp" 2>/dev/null | grep -vF "$R/logs/rvt2025-a")" ]'
check "report: no temporary file left" eval '[ -z "$(ls -A "$T/tmp")" ]'
run "" report 2025 --json --exclude doctor.json
check "report --json: report.py's JSON" eval 'printf "%s" "$OUT" | /usr/bin/perl -MJSON::PP -e "local \$/; my \$j = decode_json(<STDIN>);
  exit 1 unless -s \$j->{report_txt} && -s \$j->{report_zip} && ref \$j->{left_out} eq q(ARRAY) && !defined \$j->{refused}"'
check "report --json: nothing but the JSON" eval '[ "$(printf "%s\n" "$OUT" | wc -l | tr -d " ")" = 1 ] && [ "$RC" = 0 ]'
check "report --exclude: that member is left out" eval 'z="$(printf "%s" "$OUT" | /usr/bin/perl -MJSON::PP -e "local \$/; print decode_json(<STDIN>)->{report_zip}")";
  [ -s "$z" ] && ! zip_has "$z" doctor.json && zip_has "$z" manifest.txt'
reset; fake_wine; mkdir -p "$R/logs/rvt2024-a/20261011-100000-install"; printf '   rvt        exit=0     RVT.msi (8 s)\n' > "$R/logs/rvt2024-a/20261011-100000-install/summary.txt"
run "" report; expect "report without a year: this Mac and the last runs" 0 "Read both before you post them."
check "report without a year: in logs/mac, with the last install" eval 'd="$(report_dir mac)"; grep -qx "Revit: no year given" "$d/report.txt" &&
  zip_has "$d/report.zip" install/summary.txt'
check "report without a year: no wine, wineserver or cxbottle" no_wine_calls
GONE="/Users/$(printf 'z%s' qtest)/Gone"   # a home path of someone else: the report cannot clean it and refuses
reset; fake_wine; bottle rvt2025-a 2025 2025; revit_exe rvt2025-a 2025; rm "$BOTTLES/rvt2025-a/drive_c/users/crossover/Documents"
ln -s "$GONE" "$BOTTLES/rvt2025-a/drive_c/users/crossover/Documents"; run "" report 2025
expect "report: refused when report.txt holds personal data" 1 "No report: report.txt holds personal data that could not be removed."
check "report refused: no report folder left" eval '[ -z "$(report_dir rvt2025-a)" ]'
run "" report 2025 --json
check "report refused --json: exit 1 and the reason" eval '[ "$RC" = 1 ] && printf "%s" "$OUT" | /usr/bin/perl -MJSON::PP -e "local \$/;
  my \$j = decode_json(<STDIN>); exit 1 unless \$j->{refused} && !defined \$j->{report_txt}"'
reset; bottle rvt2024-a 2024 2024; run "" --help; check "report is in the help" grep -q "^  report    make a report for a GitHub issue" <<<"$OUT"
reset; bottle rvt2024-a 2024 2024; revit_exe rvt2024-a 2024; run_install INSTALL_DRYRUN=1 2024
check "check on an installed Revit points at doctor" grep -qxF "  Revit 2024 is installed in rvt2024-a. To check it: ./revit doctor 2024" <<<"$OUT"
check "check on an installed Revit: not a ✗" eval '! grep -q "already exists" <<<"$OUT"'
reset; bottle rvt2024-b 2024 2024; revit_exe rvt2024-b 2024; run_install INSTALL_DRYRUN=1 2024 rvt2024-b
check "check on an installed Revit names a non-default bottle" grep -qF "To check it: ./revit doctor 2024 rvt2024-b" <<<"$OUT"
reset; bottle rvt2024-a 2024 2024; run_install "" 2024
check "install on an existing bottle is still refused" grep -qF "✗ bottle rvt2024-a already exists" <<<"$OUT"
# free space on the volume of each path the install writes: a fake stat puts installers/extracted on another volume
install_with() { # $1 = a folder put first on PATH: install.sh 2025 as ./revit check runs it (run_install splits at spaces)
  cp "$REPO/install.sh" "$R/install.sh"
  OUT="$(cd / && env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" PATH="$1:$PATH" INSTALL_DRYRUN=1 /bin/bash "$R/install.sh" 2025 2>&1)"; RC=$?
}
FK="$T/fake"; reset; mkdir -p "$FK" "$T/vol/x"; ln -s "$T/vol/x" "$R/installers/extracted"
printf '#!/bin/bash\nr="$(cd "${@: -1}" 2>/dev/null && pwd -P)"\ncase "$r" in *"/vol/"*) echo 2 ;; *) echo 1 ;; esac\n' > "$FK/stat"
printf '#!/bin/bash\ncase "$*" in *"/vol/"*) echo 5 ;; *) echo 500 ;; esac\n' > "$FK/osascript"; chmod +x "$FK/"*
install_with "$FK"
check "install: free space of another volume, on its own" eval 'grep -qxF "  ! only 5 GB free on the disk of installers/extracted" <<<"$OUT" &&
  grep -qxF "      this install puts up to ~15 GB there (extracted files)" <<<"$OUT" && ! grep -q "only 500" <<<"$OUT"'
reset; mkdir -p "$FK"; printf '#!/bin/bash\necho 30\n' > "$FK/osascript"; chmod +x "$FK/osascript"
install_with "$FK"
check "install: one volume adds up what goes there" eval 'grep -qxF "  ! only 30 GB free" <<<"$OUT" &&
  grep -qxF "      an install needs up to ~40 GB (extracted files, bottle)" <<<"$OUT"'
smoke_copy() { # $1 = name: a temporary copy made by ./revit test (its marker), of the bottle without .test
  bottle "$1" "$2" "$2"; mkdir -p "$BOTTLES/$1/revit-macos"
  printf 'smoke_clone=1\nsource=%s\nstate=ready\n' "${1%.test}" > "$BOTTLES/$1/revit-macos/smoke-clone"
}
reset; bottle rvt2024-a 2024 2024; smoke_copy rvt2024-a.test 2024; run "" status --json
check "status --json leaves out a copy of ./revit test" eval 'grep -qF "\"name\":\"rvt2024-a\"" <<<"$OUT" && ! grep -qF "rvt2024-a.test" <<<"$OUT"'
run "" status; check "status leaves out a copy of ./revit test" eval 'grep -qE "^  rvt2024-a " <<<"$OUT" && ! grep -qF "rvt2024-a.test" <<<"$OUT"'
reset; bottle rvt2024-a 2024 2024; smoke_copy rvt2024-a.test 2024; mkdir -p "$R/installers/extracted/revit2024"
run "2024" remove 2024; expect "remove: a copy of ./revit test does not keep the unpacked files" 0 "Removed Revit 2024 (rvt2024-a)."
check "remove: unpacked files deleted despite the copy" test ! -d "$R/installers/extracted/revit2024"

# ---- test ----
reset; run "" test;                  expect "test: missing year" 1 "Which Revit year? Example: ./revit test 2025"
reset; run "" test 2022;             expect "test: unsupported year" 1 "Revit 2022 is not supported yet"
reset; run "" test 2024 rvt2024-a.test; expect "test: the name of a copy is no bottle name" 1 "Bottle name may contain only"
reset; run "" test 2024;             expect "test: needs the bottle" 1 "There is no bottle rvt2024-a. To install Revit 2024: ./revit install 2024"
reset; bottle rvt2024-a 2024 2024; run "" test 2024; expect "test runs the test script" 0 ""
check "test passes the year and the bottle" called "smoke.sh 2024 rvt2024-a |"
check "test gets a run context" eval 'ls -d "$R/logs/runs/"*/ >/dev/null 2>&1'
reset; bottle rvt2024-b 2024 2024; run "" test 2024 rvt2024-b --log --keep
check "test passes the bottle, --log and --keep" called "smoke.sh 2024 rvt2024-b --log --keep |"
reset; bottle rvt2024-a 2024 2024; run "" install 2024 --log; expect "--log is for test only" 1 "--log is for ./revit test only."
check "--log elsewhere: nothing ran" not_called "install.sh"
reset; bottle rvt2024-a 2024 2024; run "" rebuild 2024 --keep; expect "--keep stays hidden elsewhere" 1 "Unknown option: --keep"
reset; bottle rvt2025-a 2025 2025; run "" test 2024 rvt2025-a; expect "test refuses another year" 1 "Bottle rvt2025-a is for Revit 2025, not 2024."
reset; bottle rvt2024-a 2024 2024; fake_revit rvt2024-a 2024; run "" test 2024
expect "test refuses while Revit runs" 1 "Revit 2024 is running in rvt2024-a."
check "Revit running: no test" not_called "smoke.sh"
reset; bottle rvt2024-a 2024 2024; fake_lock "install.sh 2025 rvt2025-a"; run "" test 2024
expect "test refuses while another task runs" 1 "Another task is running: install.sh 2025 rvt2025-a."
reset; rm -rf "$CXF"; bottle rvt2024-a 2024 2024; run "" test 2024; expect "test without CrossOver" 1 "CrossOver not found"
reset; printf '#!/bin/bash\nexit 3\n' > "$R/scripts/smoke.sh"; bottle rvt2024-a 2024 2024; run "" test 2024
expect "test: exit 3 (a person must act) passes through" 3 ""
reset; slow_stub "$R/scripts/smoke.sh"; bottle rvt2024-a 2024 2024; DELAY=1 group_int test 2024
check "INT during test: the runner handled it" called "smoke.sh got-signal"
check "INT during test: exit 1" test "$HOW" = "exit=1 signal=0"
reset; bottle rvt2024-a 2024 2024; run "" --help; check "test is not in the help (CONTRIBUTING documents it)" eval '! grep -q "^  test" <<<"$OUT"'

# ---- installer folder ----
reset; mkdir -p "$T/dl"; touch "$T/dl/Revit_2020_G1_Win_64bit_r3_dlm_001_002.sfx.exe"; run "" find-installer "$T/dl" --json
expect "find-installer --json" 0 '"year": "2020"'
check "find-installer names the missing part" grep -qF "Revit_2020_G1_Win_64bit_r3_dlm_002_002.sfx.exe" <<<"$OUT"
reset; mkdir -p "$T/dl"; touch "$T/dl/Revit_2020_G1_Win_64bit_r3_dlm_001_002.sfx.exe"; run "" find-installer "$T/dl"
expect "find-installer in words" 0 "Revit 2020, parts: missing Revit_2020_G1_Win_64bit_r3_dlm_002_002.sfx.exe"
reset; mkdir -p "$T/mine"; touch "$T/mine/a.exe"; rm -rf "$R/installers/revit2024"; run "" link-installer 2024 "$T/mine"
expect "link-installer links the folder" 0 "Revit 2024 installer:"
check "the link is there" test -L "$R/installers/revit2024"
reset; run "" link-installer 2024 "$T"; expect "link-installer refuses a folder with files" 1 "already holds files"

# ---- set: Retina and Mac keys (2027) ----
reset; bottle rvt2027-a 2027 2027; run "" set 2027
expect "set without settings: the usage and where to see the current ones" 1 "Usage: ./revit set 2027 retina=on|compact|off keys=mac|windows theme=mac|light|dark steel=on|off gdrive=auto|off|again|<email> gdrive_names=ru. ./revit doctor 2027 shows"
check "set without settings: nothing runs" not_called "run-steps.sh"
reset; bottle rvt2027-a 2027 2027; run "" set 2027 retina=off
expect "set retina=off" 0 "Revit 2027 (rvt2027-a): retina=off. Applies the next time Revit starts."
check "set retina=off: the retina step, with its value, as a steps run" called "run-steps.sh 2027 rvt2027-a retina | REVIT_YEAR= INSTALL_DRYRUN= CX_RECREATE= WINEPREFIX= RUN_KIND=steps"
check "set retina=off: the value reaches the step" called "RETINA=off KEYS="
check "set retina: a note on the window size" grep -qF "The first start may open Revit's window at another size" <<<"$OUT"
reset; bottle rvt2027-a 2027 2027; run "" set 2027 keys=windows
check "set keys=windows: the mackeys step" called "run-steps.sh 2027 rvt2027-a mackeys |"
check "set keys=windows: the value reaches the step" called "RETINA= KEYS=windows"
check "set keys: no note on the window size" eval '! grep -q "window at another size" <<<"$OUT"'
reset; bottle rvt2027-a 2027 2027; run "" set 2027 retina=compact keys=mac
check "set both: both steps" called "run-steps.sh 2027 rvt2027-a retina mackeys |"
reset; bottle rvt2027-b 2027 2027; run "" set 2027 rvt2027-b retina=on
check "set: the bottle before the settings" called "run-steps.sh 2027 rvt2027-b retina |"
reset; bottle rvt2027-b 2027 2027; run "" set 2027 retina=on rvt2027-b
check "set: the bottle after the settings" called "run-steps.sh 2027 rvt2027-b retina |"
reset; bottle rvt2027-b 2027 2027; run "" set 2027 rvt2027-b rvt2027-c retina=on
expect "set: two bottles" 1 "Too many arguments. Example: ./revit set 2027 [bottle] retina=off"
reset; bottle rvt2027-a 2027 2027; run "" set 2027 colour=red; expect "set: an unknown setting" 1 "Unknown setting: colour. Settings: retina, keys, theme, steel, gdrive, gdrive_names"
reset; bottle rvt2027-a 2027 2027; run "" set 2027 retina=big; expect "set: an unknown value" 1 "retina is on, compact or off"
reset; bottle rvt2027-a 2027 2027; run "" set 2027 keys=pc; expect "set: an unknown keys value" 1 "keys is mac or windows"
reset; bottle rvt2027-a 2027 2027; run "" set 2027 retina=on retina=off; expect "set: a setting twice" 1 "retina is given twice."
check "set: nothing runs after a bad setting" not_called "run-steps.sh"
reset; bottle rvt2026-a 2026 2026; run "" set 2026 retina=off; expect "set: only where the profile has the steps" 1 "Retina and Mac keys are tested on Revit 2020 and 2027 only."
reset; bottle rvt2027-a 2027 2027; run "" set 2027 theme=dark; expect "set theme=dark" 0 "Revit 2027 (rvt2027-a): theme=dark. Applies the next time Revit starts."
check "set theme=dark: the theme step with its value, one steps run" eval 'called "run-steps.sh 2027 rvt2027-a theme | " && called "THEME=dark" &&
  [ "$(grep -c run-steps.sh "$CALLS")" = 1 ]'
check "set theme: no note on the window size" eval '! grep -q "another size" <<<"$OUT"'
reset; bottle rvt2027-a 2027 2027; run "" set 2027 retina=on theme=mac; expect "set retina and theme" 0 ""
check "set retina and theme: both steps in one run" called "run-steps.sh 2027 rvt2027-a retina theme |"
reset; bottle rvt2027-a 2027 2027; run "" set 2027 steel=off; expect "set steel=off" 0 "Revit 2027 (rvt2027-a): steel=off"
check "set steel=off: the steel step, one steps run" called "run-steps.sh 2027 rvt2027-a steel |"
reset; bottle rvt2027-a 2027 2027; run "" set 2027 steel=maybe; expect "set: an unknown steel value" 1 "steel is on or off"
reset; bottle rvt2020-a 2020 2020; run "" set 2020 steel=off; expect "set steel on 2020: refused" 1 "The steel setting is for Revit 2027 only."
reset; bottle rvt2027-a 2027 2027; run "" set 2027 theme=blue; expect "set: an unknown theme" 1 "theme is mac (follow the Mac), light or dark"
reset; bottle rvt2026-a 2026 2026; run "" set 2026 theme=mac; expect "set theme: 2027 only" 1 "The theme setting is for Revit 2027 only."
check "set theme 2026: nothing runs" not_called "run-steps.sh"
# ---- set: G: from Google Drive (every year; the step gdrive and tools/gdrive.py have their own tests) ----
reset; bottle rvt2027-a 2027 2027; run "" set 2027 gdrive=auto
expect "set gdrive=auto" 0 "Revit 2027 (rvt2027-a): gdrive=auto. Applies the next time Revit starts."
check "set gdrive=auto: the gdrive step with its value" eval 'called "run-steps.sh 2027 rvt2027-a gdrive |" && called "GDRIVE=auto GNAMES=unset"'
reset; bottle rvt2026-a 2026 2026; run "" set 2026 gdrive=off; expect "set gdrive: every year" 0 "gdrive=off"
reset; bottle rvt2027-a 2027 2027; run "" set 2027 gdrive=someone@example.com --events "$T/ev"
expect "set gdrive=<email>: shown as account" 0 "Revit 2027 (rvt2027-a): gdrive=account. Applies"
check "set gdrive=<email>: the email reaches the step and nothing else" eval 'called "GDRIVE=someone@example.com" &&
  ! grep -q "example.com" <<<"$OUT" && ! grep -q "example.com" "$T/ev"'
reset; bottle rvt2027-a 2027 2027; run "" set 2027 "gdrive_names=My Drive=Mein Drive;Shared drives=Geteilte Ablagen" gdrive=auto
expect "set gdrive_names: shown as a count" 0 "Revit 2027 (rvt2027-a): gdrive_names=2 names gdrive=auto. Applies"
check "set gdrive_names: the value after the first =, spaces kept, one gdrive step" eval 'called "run-steps.sh 2027 rvt2027-a gdrive |" &&
  called "GNAMES=My Drive=Mein Drive;Shared drives=Geteilte Ablagen" && [ "$(grep -o " gdrive" "$CALLS" | wc -l | tr -d " ")" = 1 ]'
reset; bottle rvt2027-a 2027 2027; run "" set 2027 retina=off gdrive=auto
check "set retina and gdrive: gdrive first" called "run-steps.sh 2027 rvt2027-a gdrive retina |"
reset; bottle rvt2027-a 2027 2027; run "" set 2027 gdrive=auto retina=off
check "set gdrive and retina: gdrive first" called "run-steps.sh 2027 rvt2027-a gdrive retina |"
reset; bottle rvt2027-a 2027 2027; run "" set 2027 "gdrive_names=My Drive=nobody@example.com"
expect "set gdrive_names: a bad name, by its number" 1 "gdrive_names: name 1:"; check "set gdrive_names: the bad value is not shown" eval '! grep -q nobody <<<"$OUT"'
check "set gdrive_names: nothing runs after a bad name" not_called "run-steps.sh"
reset; bottle rvt2027-a 2027 2027; run "" set 2027 gdrive=again gdrive_names=ru; expect "set: again with names" 1 "gdrive=again keeps the folder names"
reset; bottle rvt2027-a 2027 2027; run "" set 2027 gdrive=maybe; expect "set gdrive: an unknown value" 1 "gdrive is auto, off, again or the email"
reset; bottle rvt2027-a 2027 2027; fake_revit rvt2027-a 2027; run "" set 2027 gdrive=auto
expect "set gdrive refuses while Revit runs" 1 "running"; check "set gdrive: nothing runs while Revit runs" not_called "run-steps.sh"
# ---- gdrive warm ----
reset; bottle rvt2027-a 2027 2027; run "" gdrive; expect "gdrive: the usage" 2 "Usage: ./revit gdrive warm <year> [bottle] <folder"
reset; bottle rvt2027-a 2027 2027; run "" gdrive warm 2027; expect "gdrive warm without a folder" 2 "Usage: ./revit gdrive warm"
reset; bottle rvt2027-a 2027 2027; mkdir -p "$BOTTLES/rvt2027-a/dosdevices"; run "" gdrive warm 2027 'G:\'
expect "gdrive warm without G:" 1 "Google Drive not found: no G: drive"
reset; bottle rvt2027-b 2027 2027; mkdir -p "$BOTTLES/rvt2027-b/dosdevices" "$H/Library/CloudStorage/GoogleDrive-someone@example.com/My Drive/a/b"
OUT="$(cd / && env "${CLEAN_ENV[@]}" HOME="$H" python3 -I "$R/tools/gdrive.py" apply "$BOTTLES/rvt2027-b" 2>&1)"
run "" gdrive warm 2027 rvt2027-b 'G:\My Drive'; expect "gdrive warm: the folder and its subfolders" 0 "2 folders listed, 0 were cloud-only"
check "gdrive warm: says what it left" grep -q "deeper folders were not listed" <<<"$OUT"
run "" gdrive warm 2027 rvt2027-b 'G:\My Drive' --depth 2; expect "gdrive warm --depth 2" 0 "3 folders listed"
run "" gdrive warm 2027 rvt2027-b 'G:\My Drive' --depth 9 --max 1; expect "gdrive warm --max 1" 0 "1 folders listed"
run "" status --depth 2; expect "--depth is for gdrive warm only" 1 "--depth and --max are for ./revit gdrive warm only."
check "gdrive warm: no email" eval '! grep -q example.com <<<"$OUT"'
reset; bottle rvt2027-a 2027 2027; run "" gdrive warm 2027 nope 'G:\'; expect "gdrive warm: no such bottle" 1 "There is no bottle nope"
reset; run "" set 2027 retina=off; expect "set: no bottle" 1 "There is no bottle rvt2027-a"
reset; bottle rvt2027-a 2027 2027; fake_revit rvt2027-a 2027; run "" set 2027 retina=off
expect "set refuses while Revit runs" 1 "Revit 2027 is running in rvt2027-a"; check "set: nothing runs while Revit runs" not_called "run-steps.sh"
reset; bottle rvt2027-a 2027 2027; fake_lock "bench-rfo rvt2027-a"; run "" set 2027 retina=off
expect "set refuses while another task holds the lock" 1 "Another task is running: bench-rfo rvt2027-a."
reset; bottle rvt2027-a 2027 2027; run "" set 2027 retina=off --events "$T/ev"
check "set events: start names the default bottle" eval 'EV | head -1 | grep -qF "\"command\":\"set\",\"year\":2027,\"bottle\":\"rvt2027-a\","'
check "set events: one end" eval '[ "$(EV | grep -c "\"event\":\"end\"")" = 1 ] && EV | tail -1 | grep -q "\"event\":\"end\""'
for args in "rvt2027-b retina=off" "retina=off rvt2027-b"; do
  reset; bottle rvt2027-b 2027 2027; run "" set 2027 $args --events "$T/ev"
  check "set events: start names the bottle ($args)" eval 'EV | head -1 | grep -qF "\"bottle\":\"rvt2027-b\","'
done

# ---- addins: list, only, import ----
reset; run "" addins list 2025 --json; expect "addins list --json" 0 '"id":"pyrevit"'
check "addins list: valid JSON" eval 'printf "%s" "$OUT" | /usr/bin/perl -MJSON::PP -e "local \$/; JSON::PP->new->decode(<STDIN>)"'
reset; bottle rvt2024-a 2024 2024; run "" addins 2024 --only pyrevit
check "--only runs the add-in and its after-steps" called "run-steps.sh 2024 rvt2024-a pyrevit trust wpfsw check |"
reset; bottle rvt2027-a 2027 2027; run "" addins 2027; expect "addins 2027 runs RevitLookup and pyRevit" 0 ""
check "addins 2027: the default list, not Enscape" called "run-steps.sh 2027 rvt2027-a revitlookup pyrevit trust wpfsw check |"
reset; bottle rvt2027-a 2027 2027; run "" addins 2027 --only enscape --accept-eula enscape
check "--accept-eula reaches the runner" called "run-steps.sh 2027 rvt2027-a enscape trust check |"
check "--accept-eula: the runner gets the consent" called "EULA=enscape"
reset; bottle rvt2024-a 2024 2024; run "" addins 2024 --only nonsense; expect "--only with an unknown add-in" 1 "Unknown add-in: nonsense"
reset; bottle rvt2024-a 2024 2024; run "" addins 2024 --only enscape; expect "--only with an add-in not for this year" 1 "Enscape is not available for Revit 2024"
reset; touch "$T/Enscape-4.18.2.1657-lts.exe"; run "" addins import enscape "$T/Enscape-4.18.2.1657-lts.exe"
expect "import copies an own file" 0 "Enscape"; check "import: the file is in installers/addins" test -f "$R/installers/addins/enscape/Enscape-4.18.2.1657-lts.exe"
reset; touch "$T/other.exe"; run "" addins import enscape "$T/other.exe"; expect "import refuses a file the catalog does not know" 1 "Enscape-4.18.2.1657-lts.exe"
reset; bottle rvt2024-a 2024 2024; revit_exe rvt2024-a 2024; mkdir -p "$BOTTLES/rvt2024-a/drive_c/users/crossover/AppData/Roaming/pyRevit-Master"; run "" status --json
check "status lists installed add-ins" grep -qF '"addins":["pyrevit"]' <<<"$OUT"
mkdir -p "$BOTTLES/rvt2024-a/drive_c/ProgramData/Autodesk/Revit/Addins/2024"; touch "$BOTTLES/rvt2024-a/drive_c/ProgramData/Autodesk/Revit/Addins/2024/RevitLookup.addin"; run "" status --json
check "status sees RevitLookup by its manifest" grep -qF '"revitlookup"' <<<"$OUT"

# ---- review fixes ----
reset; slow_stub "$R/install.sh"; /usr/bin/perl -pi -e "s/^(lock_flock9\(\) \{ \/usr\/bin\/perl -MFcntl=:flock -e ')/\\1sleep 2; /" "$R/scripts/lib/common.sh"
grep -q "flock -e 'sleep 2; " "$R/scripts/lib/common.sh" || fail "the slow-flock edit did not apply" ""
DELAY=1 group_int install 2024
check "INT while taking the lock: death by SIGINT, as before" test "$HOW" = "exit=0 signal=2"
check "INT while taking the lock: not reported as busy" eval '! grep -q "Another task" <<<"$OUT"'
reset; touch "$T/Enscape-4.18.2.1657-lts.exe"; run "" addins import enscape "$T/Enscape-4.18.2.1657-lts.exe"
check "import: no shell error" eval '! grep -q "command not found" <<<"$OUT"'
reset; run "" check 0000 --events "$T/ev"
check "events: a year like 0000 still gives valid JSON" eval 'test -s "$T/ev/events.ndjson" && valid_ndjson "$T/ev/events.ndjson"'

# ---- what the app needs (msls31, CrossOver support, ready add-ins, import msls31, reasons, dry runs) ----
jq_() { /usr/bin/perl -MJSON::PP -e 'local $/; my $d = JSON::PP->new->decode(<STDIN>); '"$1" <<<"$OUT"; }   # $1 = perl code on $d
run_data() { # like run, with REVIT_DATA=$1 (run's clean environment drops a REVIT_DATA set in front of it)
  local d="$1"; shift; : > "$CALLS"
  OUT="$(cd / && printf '\n' | env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" REVIT_DATA="$d" /bin/bash "$R/revit" "$@" 2>&1)"; RC=$?
}
cx_app() { # $1 = CFBundleShortVersionString: the fake CrossOver inside a CrossOver.app whose Info.plist has that version
  local c="$T/CrossOver.app/Contents"; mkdir -p "$c/SharedSupport"; rm -rf "$c/SharedSupport/CrossOver"; cp -R "$CXF" "$c/SharedSupport/CrossOver"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>%s</string></dict></plist>\n' "$1" > "$c/Info.plist"
}
reset; bottle rvt2027-a 2027 2027; D="$BOTTLES/rvt2027-a/drive_c/Program Files/Autodesk/Revit 2027 MCP Server Write-Tools Technical Preview"
mkdir -p "$D" "$BOTTLES/rvt2027-a/drive_c/Program Files/Autodesk/Revit/Addins/2027" "$BOTTLES/rvt2027-a/drive_c/ProgramData/revit-macos"
touch "$D/Autodesk.RevitMcpServer.Stdio.exe" "$D/mcphost.exe" "$D/mcppipes.dll"; echo 6.3.44.3 > "$BOTTLES/rvt2027-a/drive_c/ProgramData/revit-macos/adp"
printf '<RevitAddIns><AddIn><Assembly>C:\\Program Files\\Autodesk\\Revit 2027 MCP Server Write-Tools Technical Preview\\Autodesk.RevitMcpServer.Addin.dll</Assembly></AddIn></RevitAddIns>\n' \
  > "$BOTTLES/rvt2027-a/drive_c/Program Files/Autodesk/Revit/Addins/2027/Autodesk.RevitMcpServer.addin"
for a in "status --json" "addins list 2027 --json"; do
  run_data "$T/data" $a; expect "$a with an MCP install, data outside the repo" 0 ""
done
fake_wine; run_data "$T/data" doctor 2027; check "doctor with an MCP install, data outside the repo: it runs" eval 'grep -q "rvt2027-a" <<<"$OUT"'
reset; run "" status --json; check "status --json: msls31 false, then true once the file is there (1)" grep -qE '"rosetta":(true|false),"msls31":false,' <<<"$OUT"
mkdir -p "$R/installers/redist/win7sp1/x64"; touch "$R/installers/redist/win7sp1/x64/msls31.dll"; run "" status --json
check "status --json: msls31 false, then true once the file is there (2)" grep -qF '"msls31":true,' <<<"$OUT"
reset; cx_app 26.3.0; CXF="$T/CrossOver.app/Contents/SharedSupport/CrossOver" run "" status --json
check "status --json: crossover supported for 26.3.0" grep -qE '"crossover":\{"found":true,"path":"[^"]*","version":"26.3.0","supported":true\}' <<<"$OUT"
reset; cx_app 25.1.0; CXF="$T/CrossOver.app/Contents/SharedSupport/CrossOver" run "" status --json
check "status --json: crossover not supported for 25.1.0" grep -qF '"version":"25.1.0","supported":false}' <<<"$OUT"
reset; CXF="$T/none" run "" status --json
check "status --json: crossover not supported when missing" grep -qE '"crossover":\{"found":false,[^}]*"supported":false\}' <<<"$OUT"
ready_of() { jq_ 'for (@$d) { print $_->{ready} ? "true" : "false" if $_->{id} eq "'"$1"'" }'; }   # $1 = id
reset; run "" addins list 2027 --json
check "addins list --json: ready is the last key" eval 'grep -qE "\"tool_ok\":(true|false),\"ready\":(true|false)\}" <<<"$OUT"'
check "addins list --json: enscape ready only after import (before)" test "$(ready_of enscape)" = false
touch "$T/Enscape-4.18.2.1657-lts.exe"; run "" addins import enscape "$T/Enscape-4.18.2.1657-lts.exe"; run "" addins list 2027 --json
check "addins list --json: enscape ready only after import (after)" test "$(ready_of enscape)" = true
reset; touch "$T/PublicMcpServer.exe" "$T/PublicMcpServerExperimental.exe"; run "" addins import revitmcp "$T/PublicMcpServer.exe"
expect "import revitmcp" 0 "Revit MCP Server (Write-Tools): PublicMcpServer.exe is ready."
run "" addins import revitmcp-experimental "$T/PublicMcpServerExperimental.exe"; expect "import revitmcp-experimental" 0 "is ready."
check "import: the MCP Server installers in installers/addins/publicmcpserver" \
  test -f "$R/installers/addins/publicmcpserver/PublicMcpServer.exe" -a -f "$R/installers/addins/publicmcpserver/PublicMcpServerExperimental.exe"
run "" addins list 2027 --json
mcp_json() { jq_ 'for (@$d) { printf "%s|%s|%s|%s|%s\n", $_->{id}, $_->{tested} ? "t" : "f", $_->{ready} ? "r" : "-", $_->{eula}, $_->{notice} if $_->{id} =~ /revitmcp/ }'; }
N="Autodesk's MCP Server is a Technical Preview and runs only with Autodesk analytics (ADP); installing it turns ADP on in this bottle."
check "addins list --json: both MCP variants (Write-Tools tested), ready, eula and notice" test "$(mcp_json)" = \
  "revitmcp-experimental|f|r|https://www.autodesk.com/company/terms-of-use/en/general-terms|$N
revitmcp|t|r|https://www.autodesk.com/company/terms-of-use/en/general-terms|$N"
check "addins list --json: older entries have an empty notice" test "$(jq_ 'for (@$d) { print $_->{id}, "\n" if $_->{notice} eq "" }' | tr '\n' ' ')" = "enscape pdfprinter pyrevit revitlookup "
reset; run "" addins list 2025 --json; check "addins list --json: no MCP Server before 2027" eval '! grep -q revitmcp <<<"$(jq_ '"'"'for (@$d) { print $_->{id}, "\n" if $_->{available} }'"'"')"'
reset; run "" addins list 2025 --json; check "addins list --json: pyrevit is ready (auto)" test "$(ready_of pyrevit)" = true
check "addins list --json: pdfprinter ready follows tool_ok" eval '[ "$(ready_of pdfprinter)" = "$(jq_ '"'"'for (@$d) { print $_->{tool_ok} ? "true" : "false" if $_->{id} eq "pdfprinter" }'"'"')" ]'
pe_fixture() { # <file> <machine> <characteristics> <magic> [length]: a PE header (MZ, e_lfanew 0x40, PE, 1 section,
  # SizeOfOptionalHeader 0xF0), then zeros to length (default 0x200; the declared header ends at 0x170), cut to length
  /usr/bin/perl -e 'my ($f, $m, $c, $g, $len) = @ARGV; $len = hex($len // "0x200");
    my $d = "MZ" . ("\0" x 58) . pack("V", 0x40) . "PE\0\0" . pack("vvVVVvv", hex $m, 1, 0, 0, 0, 0xF0, hex $c) . pack("v", hex $g);
    $d .= "\0" x ($len - length $d) if $len > length $d; $d = substr($d, 0, $len);
    open(my $o, ">", $f) or die; binmode $o; print $o $d; close $o' "$@"
}
MS="installers/redist/win7sp1/x64"
reset; pe_fixture "$T/good.dll" 0x8664 0x2022 0x20b; run_data "$T/data" import msls31 "$T/good.dll"
expect "import msls31: a PE32+ x64 DLL is copied into a data folder that does not exist yet" 0 "msls31.dll is ready."
check "import msls31: the same bytes at their place, no .new left" eval 'cmp -s "$T/good.dll" "$T/data/$MS/msls31.dll" && [ ! -e "$T/data/$MS/msls31.dll.new" ]'
for c in "x64 EXE:0x8664 0x0022 0x20b" "PE32 DLL:0x014c 0x2102 0x10b" "cut inside the PE header:0x8664 0x2022 0x20b 0x44" \
  "cut after the magic:0x8664 0x2022 0x20b 0x5a" "cut inside the optional header:0x8664 0x2022 0x20b 0x100" \
  "cut inside the section table:0x8664 0x2022 0x20b 0x160" "text file:"; do
  reset; if [ -n "${c#*:}" ]; then pe_fixture "$T/bad.dll" ${c#*:}; else echo "not a dll" > "$T/bad.dll"; fi
  run_data "$T/data" import msls31 "$T/bad.dll"
  expect "import msls31 refuses: ${c%%:*}" 1 "This is not the 64-bit msls31.dll."
  check "import msls31 refuses: ${c%%:*}: nothing written, no folder made" test ! -e "$T/data"
done
reset; pe_fixture "$T/good.dll" 0x8664 0x2022 0x20b; mkdir -p "$T/data/$MS"; chmod 555 "$T/data/$MS"
run_data "$T/data" import msls31 "$T/good.dll"; chmod 755 "$T/data/$MS"
expect "import msls31: a copy that fails says so" 1 "Could not copy"
check "import msls31: a failed copy is not ready" eval '! grep -q "is ready" <<<"$OUT"'
reset; pe_fixture "$T/good.dll" 0x8664 0x2022 0x20b; fake_lock "install.sh 2025 rvt2025-a"; run_data "$T/data" import msls31 "$T/good.dll"
expect "import msls31: busy" 1 "Another task is running"
reset; run "" import frob "$T/x"; expect "import: unknown kind" 1 "Unknown file: frob. Files: msls31"
reset; run "" import msls31 "$T/nothing.dll"; expect "import msls31: a missing file" 1 "No such file"
reset; run "" check 2025 --reextract; check "check passes the source flags (--reextract)" called "REEXTRACT=1"
reset; run "" check 2025 --reuse-extracted; check "check passes the source flags (--reuse-extracted)" called "REUSE=1 "
reset; printf '#!/bin/bash\nprintf "result=failed\\nfailed_action=revit\\nreason=download\\nlog_dir=/l\\n" > "$REVIT_RUN_CTX/result"; exit 1\n' > "$R/install.sh"
run "" install 2024 --events "$T/ev"
check "events: end carries the reason" eval 'EV | tail -1 | grep -qF "\"failed_action\":\"revit\",\"failed_steps\":[],\"log_dir\":\"/l\",\"reason\":\"download\"}"'
# dry runs of remove and rebuild
plan_ok() { # the JSON plan is disjoint: no delete label names a path a kept label names (path = the label up to " (")
  jq_ 'my %k = map { (my $p = $_) =~ s/ \(.*//; ($p => 1) } @{$d->{kept}};
    for (@{$d->{delete}}) { (my $p = $_->{label}) =~ s/ \(.*//; exit 1 if $k{$p} } exit 0'
}
reset; bottle rvt2025-a 2025 2025; run "" remove 2025; cancelled="$OUT"
run "" remove 2025 --dry-run
check "remove --dry-run: the same lines, nothing deleted" eval '[ "$OUT" = "$(sed "/^Type 2025 to continue/,\$d" <<<"$cancelled")"$'"'"'\n'"'"'"(dry run: nothing changed)" ] && [ "$RC" = 0 ]'
check "remove --dry-run: the bottle is still there" test -d "$BOTTLES/rvt2025-a"
check "remove --dry-run: lock.owner is not written" test ! -e "$H/Library/Application Support/revit-macos/lock.owner"
reset; bottle rvt2025-a 2025 2025; apps 2025 rvt2025-a; mkdir -p "$R/installers/extracted/revit2025"; echo x > "$R/installers/extracted/revit2025/setup.xml"
run "" remove 2025 --dry-run --json
expect "remove --dry-run --json: a free unpacked folder is deleted (exit)" 0 '{"command":"remove","year":2025,"bottle":"rvt2025-a","nothing":false,"delete":[{"label":"bottle rvt2025-a","bytes":'
check "remove --dry-run --json: a free unpacked folder is deleted" jq_ 'my @l = map { $_->{label} } @{$d->{delete}};
  exit !(grep({ $_ eq "installers/extracted/revit2025 (unpacked files)" } @l) && grep({ $_ eq "~/Applications/Revit 2025 (rvt2025-a).app" } @l)
    && (grep { $_->{label} =~ /^bottle / && $_->{bytes} =~ /^\d+$/ } @{$d->{delete}}) && (grep { $_->{label} =~ /^~/ && !defined $_->{bytes} } @{$d->{delete}})
    && "@{$d->{kept}}" eq "installers/revit2025 (your downloads)"
    && $d->{notes}[0] eq "Documents in this bottle is your Mac folder ~/Documents. It stays." && @{$d->{notes}} == 2)'
check "remove --dry-run --json: free: delete and kept are disjoint" plan_ok
check "remove --dry-run --json: free: nothing else on stdout" eval '[ "$(wc -l <<<"$OUT" | tr -d " ")" = 1 ]'
check "remove --dry-run --json: free: nothing deleted" test -d "$R/installers/extracted/revit2025"
reset; bottle rvt2025-a 2025 2025; bottle rvt2025-b 2025 2025; mkdir -p "$R/installers/extracted/revit2025"; echo x > "$R/installers/extracted/revit2025/setup.xml"
run "" remove 2025 --dry-run --json
check "remove --dry-run --json: a shared unpacked folder is only kept" jq_ 'exit !(@{$d->{delete}} == 1 && $d->{delete}[0]{label} eq "bottle rvt2025-a"
  && join("|", @{$d->{kept}}) eq "installers/revit2025 (your downloads)|installers/extracted/revit2025 (bottle rvt2025-b still uses it)")'
check "remove --dry-run --json: shared: delete and kept are disjoint" plan_ok
reset; run "" remove 2025 --dry-run --json
check "remove --dry-run --json: nothing" eval '[ "$RC" = 0 ] && [ "$OUT" = "{\"command\":\"remove\",\"year\":2025,\"bottle\":\"rvt2025-a\",\"nothing\":true,\"delete\":[],\"kept\":[],\"notes\":[]}" ]'
reset; bottle rvt2025-a 2025 2025; run "" rebuild 2025 --dry-run --json
check "rebuild --dry-run --json: add-ins reset in 2025" jq_ 'exit !($d->{command} eq "rebuild" && $d->{year} == 2025 && $d->{bottle} eq "rvt2025-a"
  && $d->{addins_reset} && $d->{delete}[0]{label} eq "bottle rvt2025-a" && $d->{delete}[0]{bytes} =~ /^\d+$/ && @{$d->{notes}} == 2)'
check "rebuild --dry-run --json: nothing ran" eval 'not_called install.sh && [ -d "$BOTTLES/rvt2025-a" ]'
reset; bottle rvt2027-a 2027 2027; run "" rebuild 2027 --dry-run --json
check "rebuild --dry-run --json: add-ins reset in 2027" eval '[ "$RC" = 0 ] && grep -qF "\"addins_reset\":true" <<<"$OUT"'
reset; bottle rvt2025-a 2025 2025; run "" rebuild 2025 --dry-run
check "rebuild --dry-run: today's lines, then the dry-run line" eval '[ "$RC" = 0 ] && grep -qF "This deletes the bottle rvt2025-a" <<<"$OUT" && [ "$(tail -1 <<<"$OUT")" = "(dry run: nothing changed)" ] && not_called install.sh'
reset; run "" install 2024 --dry-run; expect "--dry-run on install is refused" 1 "--dry-run is for ./revit remove, rebuild, rollback, points and cleanup only."
reset; bottle rvt2025-a 2025 2025; touch "$T/stamp"; sleep 1; run "" remove 2025 --dry-run --events "$T/ev"
newer="$(find "$T" -mindepth 1 -newer "$T/stamp" ! -path "$T/ev" ! -path "$T/ev/*" ! -path "$CALLS")"
if [ -s "$T/ev/events.ndjson" ] && [ -z "$newer" ]; then ok "remove --dry-run with --events writes only the events folder"
else fail "remove --dry-run with --events writes only the events folder" "$newer"; fi
# ---- cache: downloaded and unpacked installer files the app can delete ----
items() { jq_ 'for (@{$d->{items}}) { printf "%s|%s|%s|%s\n", $_->{label}, $_->{removable} ? "rm" : "keep", $_->{kept}, $_->{bytes} }'; }
reset; mkdir -p "$R/installers/revit2025-dl" "$R/installers/extracted/revit2025" "$R/cache/winetricks"
echo data > "$R/installers/revit2025-dl/RVT_2025_B_002_002.7z"; echo x > "$R/installers/extracted/revit2025/setup.xml"; echo w > "$R/cache/winetricks/f"
run "" cache --json
check "cache --json: downloads, a free unpacked folder and winetricks are removable" eval '[ "$(items | cut -d"|" -f1,2 | tr "\n" ";")" = "installers/revit2025-dl (downloads)|rm;installers/extracted/revit2025 (unpacked files)|rm;cache/winetricks (winetricks downloads)|rm;" ]'
check "cache --json: sizes > 0 and their sum" jq_ 'my $s = 0; for (@{$d->{items}}) { exit 1 unless $_->{bytes} > 0; $s += $_->{bytes} } exit !($s == $d->{removable_bytes})'
check "cache --json: winetricks has no year" jq_ 'exit !(!defined $d->{items}[2]{year} && $d->{items}[0]{year} == 2025 && $d->{items}[0]{what} eq "downloads")'
reset; bottle rvt2025-a 2025 2025; mkdir -p "$R/installers/extracted/revit2025"; echo x > "$R/installers/extracted/revit2025/setup.xml"; run "" cache --json
check "cache: an unpacked folder with a bottle of its year is kept" eval '[ "$(items | cut -d"|" -f1-3)" = "installers/extracted/revit2025 (unpacked files)|keep|bottle rvt2025-a uses it" ]'
check "cache: nothing kept is removable bytes" jq_ 'exit !($d->{removable_bytes} == 0)'
reset; mkdir -p "$T/user"; echo i > "$T/user/RVT_2025_B_002_002.7z"; ln -s "$T/user" "$R/installers/revit2025"; run "" cache --json
check "cache: a clone's own installers folder and a linked folder are never listed" jq_ 'exit !(@{$d->{items}} == 0)'
cache_world() { # a free unpacked 2025, an unpacked 2026 with its bottle, a linked 2027 installer folder
  mkdir -p "$R/installers/extracted/revit2025" "$R/installers/extracted/revit2026" "$T/user27"
  echo x > "$R/installers/extracted/revit2025/setup.xml"; echo x > "$R/installers/extracted/revit2026/setup.xml"
  echo i > "$T/user27/RVT_2027_B_002_002.7z"; ln -s "$T/user27" "$R/installers/revit2027"; bottle rvt2026-a 2026 2026
}
reset; cache_world; run "" cache clear
check "cache clear without --yes changes nothing" eval '[ "$RC" = 1 ] && [ -d "$R/installers/extracted/revit2025" ] && grep -qF "To delete them: ./revit cache clear --yes" <<<"$OUT"'
reset; cache_world; run "" cache clear --yes
expect "cache clear --yes deletes only the removable" 0 "Freed"
check "cache clear --yes: the free unpacked folder is gone, the kept one and the linked folder stay" \
  eval '[ ! -e "$R/installers/extracted/revit2025" ] && [ -f "$R/installers/extracted/revit2026/setup.xml" ] && [ -f "$T/user27/RVT_2027_B_002_002.7z" ] && [ -L "$R/installers/revit2027" ]'
for target in "" /sub; do
  reset; mkdir -p "$R/installers/revit2024-dl/sub"; echo b > "$R/installers/revit2024-dl/sub/RVT_2025_B_002_002.7z"
  ln -s "$R/installers/revit2024-dl$target" "$R/installers/revit2025"; run "" cache --json
  check "cache: a downloads folder the installer link points into is kept (revit2024-dl$target)" eval '[ "$(items | cut -d"|" -f1-3)" = "installers/revit2024-dl (downloads)|keep|your installer folder" ]'
  run "" cache clear --yes; check "cache clear --yes leaves it (revit2024-dl$target)" test -f "$R/installers/revit2024-dl/sub/RVT_2025_B_002_002.7z"
done
for kind in file update chain; do
  reset; mkdir -p "$T/user" "$R/installers/revit2024-dl/upd" "$T/outside"; echo base > "$R/installers/revit2024-dl/base.7z"
  echo u > "$R/installers/revit2024-dl/upd/Revit_2025_5_0.exe"; echo far > "$T/outside/base.7z"
  case "$kind" in
    file) ln -s "$R/installers/revit2024-dl/base.7z" "$T/user/RVT_2025_B_002_002.7z" ;;
    update) echo own > "$T/user/RVT_2025_B_002_002.7z"; ln -s "$R/installers/revit2024-dl/upd" "$T/user/update" ;;
    chain) ln -s "$T/outside" "$R/installers/revit2024-dl/bridge"; ln -s "$R/installers/revit2024-dl/bridge/base.7z" "$T/user/RVT_2025_B_002_002.7z" ;;
  esac
  ln -s "$T/user" "$R/installers/revit2025"
  run "" find-installer "$T/user" --json; before="$OUT"
  run "" cache --json
  check "cache: a $kind link in the installer folder protects its target" eval '[ "$(items | cut -d"|" -f1-3)" = "installers/revit2024-dl (downloads)|keep|your installer folder" ]'
  run "" cache clear --yes; run "" find-installer "$T/user" --json
  check "cache clear --yes: the installer folder reads the same ($kind)" eval '[ "$OUT" = "$before" ] && [ -d "$R/installers/revit2024-dl" ]'
done
reset; mkdir -p "$R/installers/extracted/revit2025"; fake_lock "install.sh 2026 rvt2026-a"; run "" cache clear --yes
expect "cache clear: busy" 1 "Another task is running"
check "cache clear: busy deletes nothing" test -d "$R/installers/extracted/revit2025"
reset; mkdir -p "$R/installers/extracted/revit2025"; echo x > "$R/installers/extracted/revit2025/setup.xml"; bottle rvt2026-a 2026 2026
mkdir -p "$R/installers/extracted/revit2026"; echo x > "$R/installers/extracted/revit2026/setup.xml"; run "" cache
check "cache: the text without --json" eval '[ "$RC" = 0 ] && grep -qE "^  installers/extracted/revit2025 \(unpacked files\) +[0-9.]+[KMGB]" <<<"$OUT" \
  && grep -qF "installers/extracted/revit2026 (unpacked files)" <<<"$OUT" && grep -qF "kept: bottle rvt2026-a uses it" <<<"$OUT" \
  && [ "$(tail -1 <<<"$OUT")" = "To delete them: ./revit cache clear --yes" ]'
reset; run "" cache; check "cache: nothing to clear" eval '[ "$RC" = 0 ] && [ "$OUT" = "Nothing to clear." ]'
# ---- remove and cache with two DATA folders ----
# the app's DATA folder and the clone's (DATA=ROOT) each have an unpacked 2025; the bottles are shared. rvt2025-a was
# installed from the clone's, rvt2025-c from the app's: each one's run record says so
AD="$T/app data"
run_in() { # $1 = DATA folder ("" = the clone), $2 = what to type, rest = ./revit arguments. Sets OUT and RC
  local d="$1" input="$2"; shift 2; : > "$CALLS"
  OUT="$(cd / && printf '%s\n' "$input" | env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" ${d:+REVIT_DATA="$d"} \
    /bin/bash "$R/revit" "$@" 2>&1)"; RC=$?
}
from_x() { # $1 = bottle, $2 = DATA folder it was installed from: its run record, as install.sh writes it
  python3 -I -B "$R/tools/runlog.py" append "$BOTTLES/$1" --kind install --year 2025 --run-id r --result ok \
    --requested rvt --extracted "$2/installers/extracted/revit2025"
}
two_data() {
  reset; local d; for d in "$R" "$AD"; do mkdir -p "$d/installers/extracted/revit2025"; echo x > "$d/installers/extracted/revit2025/setup.xml"; done
  bottle rvt2025-a 2025 2025; bottle rvt2025-c 2025 2025; from_x rvt2025-a "$R"; from_x rvt2025-c "$AD"
}
two_data; run_in "$AD" "2025" remove 2025 rvt2025-c
check "app: remove deletes its own unpacked files when the other bottle was installed from the clone's" \
  eval '[ "$RC" = 0 ] && [ ! -e "$AD/installers/extracted/revit2025" ] && [ -f "$R/installers/extracted/revit2025/setup.xml" ] && ! grep -qF "Kept: installers/extracted" <<<"$OUT"'
two_data; run_in "" "2025" remove 2025 rvt2025-a
check "clone: remove deletes its own unpacked files when the other bottle was installed from the app's" \
  eval '[ "$RC" = 0 ] && [ ! -e "$R/installers/extracted/revit2025" ] && [ -f "$AD/installers/extracted/revit2025/setup.xml" ]'
two_data; run_in "" "2025" remove 2025 rvt2025-c
expect "clone: remove keeps the unpacked files a bottle was installed from" 0 "Kept: installers/extracted/revit2025 (bottle rvt2025-a still uses it)."
check "clone: those files are still there" test -f "$R/installers/extracted/revit2025/setup.xml"
two_data; run_in "$AD" "2025" remove 2025 rvt2025-a
expect "app: remove keeps the unpacked files a bottle was installed from" 0 "Kept: installers/extracted/revit2025 (bottle rvt2025-c still uses it)."
two_data; from_x rvt2025-a "$AD"; run_in "$AD" "2025" remove 2025 rvt2025-c
expect "app: a bottle installed from both keeps both" 0 "Kept: installers/extracted/revit2025 (bottle rvt2025-a still uses it)."
two_data; printf '{"run_id":"old","kind":"install","year":2025,"result":"ok"}\n' >> "$BOTTLES/rvt2025-a/revit-macos/runs.ndjson"
run_in "$AD" "2025" remove 2025 rvt2025-c
expect "app: a bottle with a record from before the field keeps them" 0 "Kept: installers/extracted/revit2025 (bottle rvt2025-a still uses it)."
two_data; rm -rf "$BOTTLES/rvt2025-c"; run_in "$AD" "" cache --json
check "app: cache: its unpacked folder is removable when the bottle of its year was installed from the clone's" \
  eval '[ "$(items | cut -d"|" -f1-2)" = "installers/extracted/revit2025 (unpacked files)|rm" ]'
run_in "" "" cache --json
check "clone: cache: its unpacked folder that bottle was installed from is kept" \
  eval '[ "$(items | cut -d"|" -f1-3)" = "installers/extracted/revit2025 (unpacked files)|keep|bottle rvt2025-a uses it" ]'
run_in "$AD" "" cache clear --yes
check "app: cache clear --yes frees its own, the clone's stays" \
  eval '[ "$RC" = 0 ] && [ ! -e "$AD/installers/extracted/revit2025" ] && [ -f "$R/installers/extracted/revit2025/setup.xml" ]'
fi
# ---- ./revit mcp (scripts/mcp-launch.sh) ----
MCPW="Revit 2027 MCP Server Write-Tools Technical Preview"; MCPE="Revit 2027 MCP Server Experimental-Tools Technical Preview"
mcp_install() { # $1 = bottle, $2 = variant folder: a complete MCP Server install (fixture files, our shims from build/)
  local b="$BOTTLES/$1" d="$BOTTLES/$1/drive_c/Program Files/Autodesk/$2" s
  mkdir -p "$d" "$b/drive_c/Program Files/Autodesk/Revit/Addins/2027" "$b/drive_c/ProgramData/revit-macos" \
    "$b/drive_c/Program Files/Common Files/Autodesk/AdpDesktopSDK/bin"
  for s in mcphost/mcphost.exe mcppipes/mcppipes.dll; do mkdir -p "$R/build/${s%/*}"; echo "fake $s" > "$R/build/$s"; cp "$R/build/$s" "$d/"; done
  touch "$d/Autodesk.RevitMcpServer.Stdio.exe" "$b/drive_c/Program Files/Common Files/Autodesk/AdpDesktopSDK/bin/AdpSDKCore.dll"
  printf '<RevitAddIns><AddIn><Assembly>C:\\Program Files\\Autodesk\\%s\\Autodesk.RevitMcpServer.Addin.dll</Assembly></AddIn></RevitAddIns>\r\n' "$2" \
    > "$b/drive_c/Program Files/Autodesk/Revit/Addins/2027/Autodesk.RevitMcpServer.addin"
  echo 6.3.44.3 > "$b/drive_c/ProgramData/revit-macos/adp"
}
mcp_cx() { # the fake CrossOver's wine plays mcphost.exe: records its arguments (and FD8/FD9 if they reached it), writes
  # the launch confirmation, echoes stdin to stdout, exits with $T/mcp-rc. $T/mcp-mode: noconfirm | ignoreterm | holdclose |
  # delayconfirm (echoes at once, confirms once $T/mcp-go exists)
  cat > "$CXF/bin/wine" <<EOF
#!/bin/bash
[ "\$1" = --bottle ] || exit 0
name="\$2"; shift 2; tok=""; prev=""
for a in "\$@"; do [ "\$prev" = --launch ] && tok="\$a"; prev="\$a"; done
{ printf '%s\n' "\$@"; [ -e /dev/fd/9 ] && echo FD9; [ -e /dev/fd/8 ] && echo FD8; } > "$T/mcp-argv"
bf="$BOTTLES/\$name/drive_c/mcp-open.tmp"; touch "\$bf"; exec 4<"\$bf"
case "\$(cat "$T/mcp-mode" 2>/dev/null)" in
  noconfirm) sleep 60 ;;
  ignoreterm) trap '' TERM; sleep 60 ;;
  orphan) ( trap '' TERM; exec sleep 61 ) & sleep 60 ;;   # a child without the token that outlives its parent
  holdclose) sleep 1; exec 4<&-; sleep 60 ;;
esac
d="$BOTTLES/\$name/drive_c/users/crossover/AppData/Local/Temp/revit-macos-mcp"; mkdir -p "\$d"
if [ "\$(cat "$T/mcp-mode" 2>/dev/null)" = delayconfirm ]; then
  exec 6<&0; "$T/rpc-echo" <&6 & c=\$!
  until [ -e "$T/mcp-go" ]; do sleep 0.1; done; echo \$\$ > "\$d/launch-\$tok"; wait "\$c"
else
  echo \$\$ > "\$d/launch-\$tok"
  [ "\$(cat "$T/mcp-mode" 2>/dev/null)" != stuck ] || sleep 60   # a server that no longer reads its stdin
  "$T/rpc-echo"
fi
exit "\$(cat "$T/mcp-rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$CXF/bin/wine"
}
mcp_world() { reset; bottle rvt2027-a 2027 2027; mcp_install rvt2027-a "${1:-$MCPW}"; mcp_cx; fake_revit rvt2027-a 2027; }
MCP_ENV=()
MCP_TIER=read; MCP_TOKEN=test-token-of-the-sandbox
rq() { printf '{"jsonrpc":"2.0","id":"%s","method":"ping"}\n' "$1"; }   # a request; rs: the fake server's answer to it
rs() { printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$1"; }
mcp_seed() { # what a server gets: a fake MCP server, and tools/mcp_gate.py a token for the bottles and servers used here
  printf '#!/usr/bin/perl\n$|=1; while(<STDIN>){ print qq({"jsonrpc":"2.0","id":"$1","result":{}}\\n) if /"id":"([^"]*)"/ }\n' > "$T/rpc-echo"
  chmod +x "$T/rpc-echo"; mkdir -p "$R/mcp"
  python3 -I -c 'import hashlib, json, sys
sha = hashlib.sha256(sys.argv[1].encode()).hexdigest()
json.dump([{"name": b + s, "sha256": sha, "tier": sys.argv[2], "bottle": b, "server": s}
           for b in ("rvt2027-a", "rvt2020-a", "rvt2021-a") for s in ("autodesk", "pyrevit", "python")], open(sys.argv[3], "w"))' \
    "$MCP_TOKEN" "$MCP_TIER" "$R/mcp/tokens.json"
}
run_mcp() { # stdin from $MCP_IN (default: nothing), rest = ./revit arguments; OUT = stdout only, ERR = stderr, RC
  : > "$CALLS"; mcp_seed
  (cd / && env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" REVIT_MCP_TOKEN="$MCP_TOKEN" ${MCP_ENV[@]+"${MCP_ENV[@]}"} /bin/bash "$R/revit" "$@" \
    < "${MCP_IN:-/dev/null}" > "$T/mcp-out" 2> "$T/mcp-err"); RC=$?
  OUT="$(cat "$T/mcp-out")"; ERR="$(cat "$T/mcp-err")"; MCP_IN=""
}
mcp_bg() { # $1 = connection a | b, rest = ./revit arguments: in the background with a held-open stdin (fd 5 writes a's,
  # fd 6 b's) and INT at its default; sets LPID_<id>, output in $T/mcp-out-<id> and $T/mcp-err-<id>
  local id="$1" fd; shift; [ "$id" = a ] && fd=5 || fd=6
  rm -f "$T/mcp-in-$id"; mkfifo "$T/mcp-in-$id"; : > "$T/mcp-out-$id"; : > "$T/mcp-err-$id"; mcp_seed
  (exec 5>&- 6>&-; cd / && exec env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" REVIT_MCP_TOKEN="$MCP_TOKEN" ${MCP_ENV[@]+"${MCP_ENV[@]}"} \
    perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' /bin/bash "$R/revit" "$@" < "$T/mcp-in-$id" > "$T/mcp-out-$id" 2> "$T/mcp-err-$id") &
  eval "LPID_$id=\$!"; eval "exec $fd>\"\$T/mcp-in-\$id\""
}
mcp_wait() { local i; for i in $(seq 1 ${2:-100}); do eval "$1" && return 0; sleep 0.1; done; return 1; }   # $1 = condition
confirmed() { ls "$BOTTLES/rvt2027-a/drive_c/users/crossover/AppData/Local/Temp/revit-macos-mcp/"launch-* >/dev/null 2>&1; }
sandboxed() { # $1 = pgrep pattern: a process that matches and belongs to this sandbox (a real MCP client or Revit on
  # this Mac matches the same patterns)
  local p; for p in $(pgrep -f "$1" 2>/dev/null); do ps -o command= -p "$p" 2>/dev/null | grep -qF "$T/" && return 0; done; return 1
}
own_alive() { sandboxed 'revit-mcp-[0-9a-f]{8}-'; }   # a process with a launch token in its arguments
revit_alive() { sandboxed 'Revit 2027.Revit.exe'; }   # the fake Revit (it holds a file of the sandbox open)
lock_is_free() { perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or exit 0; flock($f, LOCK_EX | LOCK_NB) or exit 1' "$H/Library/Application Support/revit-macos/lock"; }
mcp_stdout_empty() { [ -z "$OUT" ]; }

if part 1; then
reset; run_mcp mcp 2027; check "mcp: no bottle → refused, stdout empty" eval '[ "$RC" != 0 ] && grep -q "There is no bottle rvt2027-a" <<<"$ERR" && mcp_stdout_empty'
reset; bottle rvt2027-a 2027 2027; mcp_install rvt2027-a "$MCPW"; mcp_cx; run_mcp mcp 2027
check "mcp: no Revit → open Revit first" eval '[ "$RC" != 0 ] && grep -qx "Open Revit 2027 with a model first." <<<"$ERR" && mcp_stdout_empty'
check "mcp: no Revit → wine never started" test ! -e "$T/mcp-argv"
reset; bottle rvt2020-a 2020 2020; mcp_cx; fake_revit rvt2020-a 2020; run_mcp mcp 2020
check "mcp on 2020 → Autodesk's server is for 2027 only" eval '[ "$RC" != 0 ] && grep -qx "Autodesk'"'"'s Revit MCP Server is for Revit 2027 only." <<<"$ERR" && mcp_stdout_empty'
reset; bottle rvt2020-a 2020 2020; mcp_cx; run_mcp mcp 2020
check "mcp on 2020 without Revit → for 2027 only, not open Revit" eval 'grep -qx "Autodesk'"'"'s Revit MCP Server is for Revit 2027 only." <<<"$ERR"'
reset; bottle rvt2027-a 2027 2027; mcp_cx; fake_revit rvt2027-a 2027; run_mcp mcp 2027
check "mcp: not installed → the install command" eval '[ "$RC" != 0 ] && grep -qF "Install it: ./revit addins 2027 --only revitmcp --accept-eula revitmcp" <<<"$ERR" && mcp_stdout_empty'
reset; bottle rvt2027-a 2027 2027; run_mcp status --write; check "--write on another command" eval '[ "$RC" != 0 ] && grep -qx "Unknown option: --write" <<<"$ERR"'
reset; run_mcp mcp 2027 rvt2027-a extra; check "mcp: extra arguments" eval '[ "$RC" != 0 ] && grep -q "Too many arguments" <<<"$ERR" && mcp_stdout_empty'
reset; run "" --help; check "mcp is in the help" grep -qF "  mcp       connect an AI assistant to a running Revit (--server pyrevit|python; docs/mcp.md); first give it a token:" <<<"$OUT"
for c in "$MCPW|read|--tool-permission=StableReadOnly" "$MCPW|write|--tool-permission=Stable --tool-min-permission=StableReadOnly" \
  "$MCPE|read|--tool-permission=StableReadOnly" "$MCPE|write|--tool-permission=Experimental --tool-min-permission=StableReadOnly"; do
  v="${c%%|*}"; f="$(cut -d'|' -f2 <<<"$c")"; want="${c##*|}"
  mcp_world "$v"; rq 1 > "$T/in"; MCP_IN="$T/in"; MCP_TIER="$f"; run_mcp mcp 2027; MCP_TIER=read
  check "mcp ${v#Revit 2027 MCP Server } ${f:-read-only}: exit 0, stdout is the server's alone" eval '[ "$RC" = 0 ] && [ "$OUT" = "$(rs 1)" ] && [ -z "$ERR" ]'
  check "mcp ${v#Revit 2027 MCP Server } ${f:-read-only}: launcher, token, server and $want" eval '[ "$(sed -n "1p;4p;5p" "$T/mcp-argv" | tr "\n" "|")" = "C:\\Program Files\\Autodesk\\$v\\mcphost.exe|--|C:\\Program Files\\Autodesk\\$v\\Autodesk.RevitMcpServer.Stdio.exe|" ] && [ "$(sed -n "6,\$p" "$T/mcp-argv" | tr "\n" " ")" = "$want " ]'
done
check "mcp: neither the lock (fd 9) nor fd 8 reaches the launcher" eval '! grep -qx -e FD9 -e FD8 "$T/mcp-argv"'
mcp_world; echo 5 > "$T/mcp-rc"; run_mcp mcp 2027; check "mcp: EOF → the launcher's exit code" test "$RC" = 5
mcp_world; mcp_bg a mcp 2027; mcp_wait confirmed 100; mcp_wait 'lock_is_free' 50
check "mcp: the lock is released after the handoff" lock_is_free
rq ping >&5; mcp_wait 'grep -qF "\"ping\"" "$T/mcp-out-a"' 50; check "mcp: input after the handoff still reaches the server" grep -qF '"ping"' "$T/mcp-out-a"
exec 5>&-; wait "$LPID_a"; check "mcp: EOF after the handoff → exit 0" test "$?" = 0
for p in 'rm "$D/Autodesk.RevitMcpServer.Stdio.exe"|the MCP Server files' 'rm "$M"|the MCP add-in manifest' 'rm "$D/mcphost.exe"|mcphost.exe' \
  'rm "$D/mcppipes.dll"|mcppipes.dll' 'echo x >> "$D/mcphost.exe"|the current mcphost.exe' 'echo x >> "$D/mcppipes.dll"|the current mcppipes.dll' \
  'rm "$BOTTLES/rvt2027-a/drive_c/ProgramData/revit-macos/adp"|Autodesk analytics (ADP)'; do
  mcp_world; D="$BOTTLES/rvt2027-a/drive_c/Program Files/Autodesk/$MCPW"; M="$BOTTLES/rvt2027-a/drive_c/Program Files/Autodesk/Revit/Addins/2027/Autodesk.RevitMcpServer.addin"
  eval "${p%|*}"; run_mcp mcp 2027
  if [ "${p#*|}" = "the MCP add-in manifest" ]; then want="is not installed in rvt2027-a"; else want="is not complete (${p#*|} is missing)"; fi
  check "mcp refuses without ${p#*|}" eval '[ "$RC" != 0 ] && grep -qF "$want" <<<"$ERR" && [ ! -e "$T/mcp-argv" ]'
done
# the bottle goes between the first check and the lock: the check under the lock refuses, wine never starts
mcp_world; touch "$T/hold"; MCP_ENV=(MCP_TEST_HOLD="$T/hold"); mcp_bg a mcp 2027; mcp_wait '[ -e "$T/hold.reached" ]' 100
chmod -R u+w "$BOTTLES/rvt2027-a"; stop_fakes; rm -rf "$BOTTLES/rvt2027-a"; rm "$T/hold"; exec 5>&-; wait "$LPID_a"; rc=$?; MCP_ENV=()
check "mcp: bottle removed before the lock → refused under the lock" eval '[ "$rc" != 0 ] && grep -q "There is no bottle rvt2027-a" "$T/mcp-err-a" && [ ! -e "$T/mcp-argv" ]'
reset; bottle rvt2027-a 2027 2027; mcp_install rvt2027-a "$MCPW"; echo 'addin_plan() { return 1; }' >> "$R/scripts/lib/addins.sh"; run "" addins 2027 --only revitmcp --accept-eula revitmcp
check "addins: a failing plan → refused, no runner" eval '[ "$RC" != 0 ] && grep -q "Could not plan" <<<"$OUT" && ! grep -q run-steps "$CALLS"'
reset; bottle rvt2027-a 2027 2027; echo 'addin_plan() { :; }' >> "$R/scripts/lib/addins.sh"; run "" addins 2027 --only revitmcp --accept-eula revitmcp
check "addins: an empty plan → refused, no runner" eval '[ "$RC" != 0 ] && grep -q "Could not plan" <<<"$OUT" && ! grep -q run-steps "$CALLS"'
reset; bottle rvt2027-a 2027 2027; fake_wine; run "" addins 2027 --only revitmcp,revitmcp-experimental --accept-eula revitmcp,revitmcp-experimental
check "addins: both MCP variants at once → refused before anything" eval '[ "$RC" != 0 ] && grep -q "not both" <<<"$OUT" && ! grep -q -e run-steps -e "^wine" "$CALLS"'
# signals: before the handoff (no confirmation yet) and after it; a second client of the same bottle lives on
for s in TERM:143 HUP:129 INT:130; do
  for ph in before after; do
    mcp_world; fake_mcphost rvt2027-a; other=$!
    [ "$ph" = before ] && echo noconfirm > "$T/mcp-mode"
    mcp_bg a mcp 2027; mcp_wait '[ -s "$T/mcp-argv" ]' 100; [ "$ph" = after ] && mcp_wait confirmed 100; sleep 0.5
    kill -"${s%:*}" "$LPID_a"; wait "$LPID_a"; rc=$?; exec 5>&-
    check "mcp: $s ${s%:*} $ph the handoff → exit ${s#*:}, own launcher gone, the other client and Revit alive" \
      eval '[ "$rc" = "${s#*:}" ] && ! own_alive && kill -0 "$other" 2>/dev/null && revit_alive'
    rm -f "$T/mcp-mode"
  done
done
mcp_world; echo noconfirm > "$T/mcp-mode"; MCP_ENV=(MCP_HANDOFF_S=3); t0=$SECONDS; run_mcp mcp 2027; MCP_ENV=()
check "mcp: no confirmation → refused after the deadline" eval '[ "$RC" = 1 ] && grep -q "did not start within 3 s" <<<"$ERR" && mcp_stdout_empty'
check "mcp: no confirmation → own launcher gone, lock free" eval '! own_alive && lock_is_free'
sleep 2; check "mcp: no late launcher afterwards" eval '! own_alive && ! confirmed'
mcp_world; fake_mcphost rvt2027-a; other=$!; echo ignoreterm > "$T/mcp-mode"; MCP_ENV=(MCP_HANDOFF_S=2); run_mcp mcp 2027; MCP_ENV=()
check "mcp: a loader that ignores TERM → killed; Revit and the other client alive" \
  eval '[ "$RC" = 1 ] && ! own_alive && kill -0 "$other" 2>/dev/null && revit_alive'
mcp_world; echo orphan > "$T/mcp-mode"; MCP_ENV=(MCP_HANDOFF_S=2); run_mcp mcp 2027; MCP_ENV=()
check "mcp: a child that ignores TERM after its parent ended is killed too" eval '[ "$RC" = 1 ] && ! pgrep -f "^sleep 61" >/dev/null'
mcp_world; echo holdclose > "$T/mcp-mode"; MCP_ENV=(MCP_HANDOFF_S=6); mcp_bg a mcp 2027; MCP_ENV=(); mcp_wait '[ -s "$T/mcp-argv" ]' 100; sleep 2
stop_fakes; sleep 0.5; run "2027" remove 2027   # Revit closed, the loader's bottle file closed: only the lock stops it
check "mcp: while the launcher starts (its bottle file closed, no confirmation), remove is refused" eval '[ "$RC" != 0 ] && grep -q "Another task is running: ./revit mcp 2027 rvt2027-a" <<<"$OUT" && [ -d "$BOTTLES/rvt2027-a" ]'
wait "$LPID_a"; exec 5>&-; check "mcp: then the lock is free and nothing of it is left" eval 'lock_is_free && ! own_alive'
reset; for a in "2027 rvt2027-a 0" "2027 rvt2027-a 2 autodesk" "27 rvt2027-a 0 autodesk" "2027 rvt2027-a 0 foo" "2027 rvt2027-a 0 autodesk x"; do
  (cd / && env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" /bin/bash "$R/scripts/mcp-launch.sh" $a > "$T/o" 2> "$T/e"); rc=$?
  check "mcp-launch.sh $a: usage, exit 2, stdout empty" eval '[ "$rc" = 2 ] && [ ! -s "$T/o" ] && grep -q "^Usage: scripts/mcp-launch.sh" "$T/e"'
done
reset; bottle rvt2027-a 2027 2027; run "" addins 2027 --only revitmcp
check "addins --only revitmcp without consent: the notice, nothing runs" eval '[ "$RC" = 1 ] && grep -qF "turns ADP on in this bottle. To accept, add --accept-eula revitmcp: ./revit addins 2027 --only revitmcp --accept-eula revitmcp" <<<"$OUT" && ! grep -q run-steps "$CALLS"'
reset; bottle rvt2027-a 2027 2027; run "" addins 2027 --only revitmcp --accept-eula revitmcp
check "addins --only revitmcp with consent: the step runs with it" eval '[ "$RC" = 0 ] && called "run-steps.sh 2027 rvt2027-a revitmcp check |"'
fi
if part 2; then
# ---- ./revit mcp --server pyrevit (pyRevit's agent through mcphost --plain) ----
PYEXE='C:\users\crossover\AppData\Roaming\pyRevit-Master\bin\pyrevit.exe'; PLAINH='C:\ProgramData\revit-macos\mcphost\mcphost.exe'
PYA="$BOTTLES/rvt2027-a/drive_c/users/crossover/AppData/Roaming"; PYH="$BOTTLES/rvt2027-a/drive_c/ProgramData/revit-macos/mcphost/mcphost.exe"
pyrevit_world() { # $1 = year (2027): pyRevit 7 with its agent on (pyRevit writes Windows line ends), one agent instance,
  # our mcphost in build/, the fake CrossOver and a fake Revit
  local y="${1:-2027}" a; reset; bottle "rvt$y-a" "$y" "$y"; a="$BOTTLES/rvt$y-a/drive_c/users/crossover/AppData/Roaming"
  mkdir -p "$a/pyRevit-Master/pyrevitlib/pyrevit/agent" "$a/pyRevit-Master/bin" "$a/pyRevit/agent/instances" "$R/build/mcphost"
  touch "$a/pyRevit-Master/pyrevitlib/pyrevit/agent/_runner.py" "$a/pyRevit-Master/bin/pyrevit.exe"
  printf '[core]\r\ncheckupdates = false\r\n\r\n[agent]\r\nenabled = True\r\npolicy = "ask"\r\n' > "$a/pyRevit/pyRevit_config.ini"
  echo '{"pid": 416}' > "$a/pyRevit/agent/instances/416.json"; echo "fake mcphost.exe v2" > "$R/build/mcphost/mcphost.exe"
  mcp_cx; fake_revit "rvt$y-a" "$y"
}
refused() { [ "$RC" != 0 ] && grep -qF -- "$1" <<<"$ERR" && mcp_stdout_empty && [ ! -e "$T/mcp-argv" ]; }   # $1 = stderr text
launches() { ls "$BOTTLES/rvt2027-a/drive_c/users/crossover/AppData/Local/Temp/revit-macos-mcp/" 2>/dev/null | grep -c '^launch-'; }
AGENT_OFF="Turn on pyRevit's agent: pyRevit → Settings → Agent Runtime → Agent Host, Save, then reload pyRevit."

pyrevit_world; run_mcp mcp 2027 --server foo; check "mcp --server foo → the known servers" refused "Unknown MCP server: foo. Known: autodesk, pyrevit"
pyrevit_world; run_mcp addins 2027 --server pyrevit
check "--server on another command → refused" eval '[ "$RC" != 0 ] && grep -qxF -- "--server is for ./revit mcp only." <<<"$ERR"'
pyrevit_world; run_mcp mcp 2027 --server pyrevit --write
check "mcp --server pyrevit --write → refused" refused "comes with its token"
pyrevit_world 2021; run_mcp mcp 2021 --server pyrevit; check "pyrevit on 2021 → not offered here" refused "pyRevit is not available for Revit 2021 here."
pyrevit_world; rm -rf "$PYA/pyRevit-Master"; run_mcp mcp 2027 --server pyrevit
check "pyrevit not installed → the install command" refused "pyRevit is not installed in rvt2027-a. Install it: ./revit addins 2027 --only pyrevit"
pyrevit_world 2020; rm "$BOTTLES/rvt2020-a/drive_c/users/crossover/AppData/Roaming/pyRevit-Master/pyrevitlib/pyrevit/agent/_runner.py"
run_mcp mcp 2020 --server pyrevit; check "pyRevit 4.8 (2020) → needs pyRevit 7" refused "pyRevit's agent needs pyRevit 7; Revit 2020 gets pyRevit 4.8 here."
pyrevit_world 2020; rm -rf "$BOTTLES/rvt2020-a/drive_c/users/crossover/AppData/Roaming/pyRevit-Master"; run_mcp mcp 2020 --server pyrevit
check "pyRevit not installed on 2020 → needs pyRevit 7, not an install" refused "pyRevit's agent needs pyRevit 7; Revit 2020 gets pyRevit 4.8 here."
for ini in '[agent]\r\nenabled = false\r\n' '[agent]\r\npolicy = "auto"\r\n' '[core]\r\nenabled = true\r\n[agent]\r\npolicy = "ask"\r\n' '' none; do
  pyrevit_world; if [ "$ini" = none ]; then rm "$PYA/pyRevit/pyRevit_config.ini"; else printf "$ini" > "$PYA/pyRevit/pyRevit_config.ini"; fi
  run_mcp mcp 2027 --server pyrevit; check "pyrevit config parsing: agent off ($ini) → how to turn it on" refused "$AGENT_OFF"
done
for ini in '[agent]\nenabled=true\n' '[core]\r\nx = 1\r\n[agent]\r\npolicy = "auto"\r\nenabled = TRUE\r\n' '[agent]\r\n  enabled   =   true  \r\n'; do
  pyrevit_world; printf "$ini" > "$PYA/pyRevit/pyRevit_config.ini"; run_mcp mcp 2027 --server pyrevit
  check "pyrevit config parsing: agent on ($ini) → started" eval '[ "$RC" = 0 ] && [ -s "$T/mcp-argv" ]'
done
pyrevit_world; rm "$PYA/pyRevit/agent/instances/416.json"; run_mcp mcp 2027 --server pyrevit
check "pyrevit agent not running in Revit → reload pyRevit" refused "pyRevit's agent is on but not running in this Revit: reload pyRevit or restart Revit."
pyrevit_world; stop_fakes; run_mcp mcp 2027 --server pyrevit; check "pyrevit without Revit → open Revit first" refused "Open Revit 2027 with a model first."
pyrevit_world; rq 1 > "$T/in"; MCP_IN="$T/in"; run_mcp mcp 2027 --server pyrevit
check "pyrevit: exit 0, stdout is the server's alone, stderr empty" eval '[ "$RC" = 0 ] && [ "$OUT" = "$(rs 1)" ] && [ -z "$ERR" ]'
check "pyrevit: mcphost --plain starts pyrevit.exe mcp --revit=2027" eval '[ "$(sed -n "1p;2p;4,8p" "$T/mcp-argv" | tr "\n" "|")" = "$PLAINH|--launch|--plain|--|$PYEXE|mcp|--revit=2027|" ]'
check "pyrevit: a launch token, nothing after the server's arguments" eval 'sed -n 3p "$T/mcp-argv" | grep -Eqx "revit-mcp-[0-9a-f-]{36}" && [ "$(wc -l < "$T/mcp-argv")" -eq 8 ]'
check "pyrevit: mcphost.exe delivered from build/" cmp -s "$PYH" "$R/build/mcphost/mcphost.exe"
pyrevit_world; mkdir -p "$(dirname "$PYH")"; echo "old mcphost.exe" > "$PYH"; run_mcp mcp 2027 --server pyrevit
check "pyrevit: an old mcphost.exe is replaced, no temporary file left" eval '[ "$RC" = 0 ] && cmp -s "$PYH" "$R/build/mcphost/mcphost.exe" && [ "$(ls "$(dirname "$PYH")")" = mcphost.exe ]'
pyrevit_world; mkdir -p "$(dirname "$PYH")"; cp "$R/build/mcphost/mcphost.exe" "$PYH"; touch -t 202001010000 "$PYH"; m0="$(stat -f %m "$PYH")"; run_mcp mcp 2027 --server pyrevit
check "pyrevit: the same mcphost.exe is not rewritten" eval '[ "$RC" = 0 ] && [ "$(stat -f %m "$PYH")" = "$m0" ]'
pyrevit_world; rm -rf "$R/build/mcphost"; run_mcp mcp 2027 --server pyrevit; check "pyrevit: no mcphost.exe to deliver → refused" refused "Cannot get mcphost.exe"
mcp_world; run_mcp mcp 2027; cp "$T/mcp-argv" "$TOP/argv-plain"; mcp_world; run_mcp mcp 2027 --server autodesk
check "mcp --server autodesk = no flag (read-only)" eval '[ "$(sed 3d "$T/mcp-argv")" = "$(sed 3d "$TOP/argv-plain")" ]'
MCP_TIER=write; mcp_world; run_mcp mcp 2027; cp "$T/mcp-argv" "$TOP/argv-plain"; mcp_world; run_mcp mcp 2027 --server autodesk; MCP_TIER=read
check "mcp --server autodesk = no flag (tier write)" eval '[ "$(sed 3d "$T/mcp-argv")" = "$(sed 3d "$TOP/argv-plain")" ]'
# the gate in front: no token, the launcher never starts; a stuck server after EOF; the commands of tokens
mcp_world; MCP_TOKEN=wrong-token; mcp_seed; MCP_TOKEN=test-token-of-the-sandbox
(cd / && env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" /bin/bash "$R/revit" mcp 2027 </dev/null >"$T/mcp-out" 2>"$T/mcp-err"); RC=$?
check "mcp without a token → the command to get one, wine never started" eval '[ "$RC" = 1 ] && [ ! -s "$T/mcp-out" ] && [ ! -e "$T/mcp-argv" ] && grep -qF "./revit mcp token 2027 rvt2027-a --server autodesk" "$T/mcp-err"'
mcp_world; run_mcp mcp 2027; check "a session is in the log of its bottle" eval 'grep -q "\"event\": \"session_end\"" "$R/mcp/audit/rvt2027-a.jsonl" && ! grep -q "$MCP_TOKEN" "$R/mcp/audit/rvt2027-a.jsonl"'
mcp_world; run_mcp mcp token 2027; check "mcp token without a terminal → refused" eval '[ "$RC" = 1 ] && grep -qF "Run this in Terminal" <<<"$ERR"'
mcp_world; (cd / && env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" script -q /dev/null /bin/bash "$R/revit" mcp token 2027 --tier write --name mine </dev/null >"$T/tok" 2>&1)
check "mcp token in a terminal: shown once, with the command to connect" eval 'grep -qF "tier write" "$T/tok" && grep -qF "claude mcp add revit-2027 -e REVIT_MCP_TOKEN=" "$T/tok" && grep -q "\"name\": \"mine\"" "$R/mcp/tokens.json"'
cp "$R/mcp/tokens.json" "$T/keep"; mcp_cli() { (cd / && env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" /bin/bash "$R/revit" "$@" </dev/null >"$T/mcp-out" 2>"$T/mcp-err"); RC=$?; OUT="$(cat "$T/mcp-out")"; ERR="$(cat "$T/mcp-err")"; }
mcp_cli mcp tokens; check "mcp tokens lists without secrets" eval 'grep -q "^mine" <<<"$OUT" && ! grep -q sha256 <<<"$OUT"'
mcp_cli mcp tokens extra; check "mcp tokens: no extra arguments" eval '[ "$RC" != 0 ] && grep -q "Too many arguments" <<<"$ERR"'
mcp_cli mcp revoke mine other; check "mcp revoke: no extra arguments, nothing revoked" eval '[ "$RC" != 0 ] && grep -q "\"name\": \"mine\"" "$R/mcp/tokens.json"'
mcp_cli mcp revoke mine; check "mcp revoke" eval '[ "$RC" = 0 ] && grep -qF "Token mine is revoked" <<<"$OUT"'
(cd / && env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" script -q /dev/null /bin/bash "$R/revit" mcp token 2027 --tier code </dev/null >"$T/tok" 2>&1)
check "mcp token: Write-Tools have no code tier" grep -qF "Autodesk's Write-Tools have no code tier" "$T/tok"
mcp_world "$MCPE"; (cd / && env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" script -q /dev/null /bin/bash "$R/revit" mcp token 2027 --tier code </dev/null >"$T/tok" 2>&1)
check "mcp token: Experimental may have the top tier" grep -qF "tier code" "$T/tok"
pyrevit_world; (cd / && env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" script -q /dev/null /bin/bash "$R/revit" mcp bundle 2027 --server pyrevit --tier code </dev/null >"$T/tok" 2>&1)
check "mcp bundle: a .mcpb in Downloads, its token shown, not inside" eval 'f="$H/Downloads/revit-rvt2027-a-pyrevit.mcpb"; [ -f "$f" ] && t="$(sed -n "s/^  \([A-Za-z0-9_-]\{40,\}\).*/\1/p" "$T/tok" | head -1)" && [ -n "$t" ] && ! unzip -p "$f" | grep -qF "$t"'
run_mcp mcp 2027 --tier write; check "--tier is for token and bundle" refused "--tier and --name are for ./revit mcp token and bundle only."
# the client goes: a stuck server gets TERM from the gate; before the handoff the launcher's own cleanup still decides
mcp_world; fake_mcphost rvt2027-a; other=$!; echo stuck > "$T/mcp-mode"; mcp_bg a mcp 2027; mcp_wait confirmed 100; mcp_wait lock_is_free 50
exec 5>&-; t0=$SECONDS; wait "$LPID_a"
check "mcp: client gone, server stuck after the handoff → ended by the gate; Revit and the other client alive" \
  eval '[ $((SECONDS - t0)) -le 12 ] && ! own_alive && kill -0 "$other" 2>/dev/null && revit_alive && lock_is_free'
mcp_world; fake_mcphost rvt2027-a; other=$!; echo ignoreterm > "$T/mcp-mode"; mcp_bg a mcp 2027; mcp_wait '[ -s "$T/mcp-argv" ]' 100
exec 5>&-; wait "$LPID_a"
check "mcp: client gone before the handoff, a loader that ignores TERM → cleaned up, lock free, Revit alive" \
  eval '! own_alive && kill -0 "$other" 2>/dev/null && revit_alive && lock_is_free'
# two connections at once: the file is not rewritten, each echoes its own, closing one leaves the other
pyrevit_world; mcp_bg a mcp 2027 --server pyrevit; mcp_wait '[ "$(launches)" -ge 1 ]' 100; mcp_wait lock_is_free 50; m1="$(stat -f %m "$PYH")"; sleep 1.1
mcp_bg b mcp 2027 --server pyrevit; mcp_wait '[ "$(launches)" -ge 2 ]' 100
rq from-a >&5; rq from-b >&6; mcp_wait 'grep -q from-a "$T/mcp-out-a" && grep -q from-b "$T/mcp-out-b"' 50
check "pyrevit: two connections live together, each answers its own" eval 'kill -0 "$LPID_a" && kill -0 "$LPID_b" && [ "$(cat "$T/mcp-out-a")" = "$(rs from-a)" ] && [ "$(cat "$T/mcp-out-b")" = "$(rs from-b)" ]'
check "pyrevit: the second connection did not rewrite mcphost.exe" test "$(stat -f %m "$PYH")" = "$m1"
exec 5>&-; wait "$LPID_a"; rq again-b >&6; mcp_wait 'grep -q again-b "$T/mcp-out-b"' 50
check "pyrevit: closing one connection leaves the other" eval 'kill -0 "$LPID_b" && grep -q again-b "$T/mcp-out-b"'
exec 6>&-; wait "$LPID_b"
# input sent before the handoff reaches the server byte for byte (both servers)
for sv in pyrevit autodesk; do
  if [ "$sv" = pyrevit ]; then pyrevit_world; else mcp_world; fi
  echo delayconfirm > "$T/mcp-mode"; mcp_bg a mcp 2027 --server "$sv"; mcp_wait '[ -s "$T/mcp-argv" ]' 100
  rq first >&5; sleep 0.5
  check "$sv: not confirmed yet while the first input waits" eval '! confirmed'
  touch "$T/mcp-go"; mcp_wait confirmed 100; mcp_wait 'grep -q first "$T/mcp-out-a"' 50
  check "$sv: input sent before the handoff reaches the server" eval '[ "$(cat "$T/mcp-out-a")" = "$(rs first)" ]'
  exec 5>&-; wait "$LPID_a"; rm -f "$T/mcp-mode" "$T/mcp-go"
done
# the launcher's life cycle with pyRevit: signals with a second client alive, the deadline, a loader ignoring TERM
for s in TERM:143 INT:130; do
  for ph in before after; do
    pyrevit_world; fake_mcphost rvt2027-a; other=$!
    [ "$ph" = before ] && echo noconfirm > "$T/mcp-mode"
    mcp_bg a mcp 2027 --server pyrevit; mcp_wait '[ -s "$T/mcp-argv" ]' 100; [ "$ph" = after ] && mcp_wait confirmed 100; sleep 0.5
    kill -"${s%:*}" "$LPID_a"; wait "$LPID_a"; rc=$?; exec 5>&-
    check "pyrevit: $s ${s%:*} $ph the handoff → exit ${s#*:}, own launcher gone, the other client and Revit alive" \
      eval '[ "$rc" = "${s#*:}" ] && ! own_alive && kill -0 "$other" 2>/dev/null && revit_alive'
    rm -f "$T/mcp-mode"
  done
done
pyrevit_world; echo noconfirm > "$T/mcp-mode"; MCP_ENV=(MCP_HANDOFF_S=3); run_mcp mcp 2027 --server pyrevit; MCP_ENV=()
check "pyrevit: no confirmation → refused after the deadline, nothing left" eval '[ "$RC" = 1 ] && grep -q "did not start within 3 s" <<<"$ERR" && mcp_stdout_empty && ! own_alive && lock_is_free'
pyrevit_world; fake_mcphost rvt2027-a; other=$!; echo ignoreterm > "$T/mcp-mode"; MCP_ENV=(MCP_HANDOFF_S=2); run_mcp mcp 2027 --server pyrevit; MCP_ENV=()
check "pyrevit: a loader that ignores TERM → killed; Revit and the other client alive" \
  eval '[ "$RC" = 1 ] && ! own_alive && kill -0 "$other" 2>/dev/null && revit_alive'
rm -f "$T/mcp-mode"
# a live pyRevit connection with Revit closed and the lock free still keeps remove, rebuild and addins away
for c in "2027|remove 2027|cxbottle" "2027|rebuild 2027|install.sh" "|addins 2027|run-steps.sh"; do
  pyrevit_world; mcp_bg a mcp 2027 --server pyrevit; mcp_wait confirmed 100; mcp_wait lock_is_free 50; stop_fakes
  run "${c%%|*}" $(cut -d'|' -f2 <<<"$c")
  check "pyrevit connected, Revit closed: $(cut -d'|' -f2 <<<"$c") refused" eval '[ "$RC" != 0 ] && grep -q "through MCP" <<<"$OUT" && ! called "${c##*|}" && [ -d "$BOTTLES/rvt2027-a" ]'
  exec 5>&-; wait "$LPID_a"
done
# ---- ./revit mcp --server python (the MCP server for Revit (Python), add-in python-mcp) ----
PMC=6ca46b3ea96a8f7cce9894cf865d8f19ca2c549d; PMTOK=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
PMPORT=$((40000 + RANDOM % 20000))   # the fake Routes: never the real 48884, where a real Revit may listen
pm_install() { # $1 = bottle: what addin_is_installed and the launcher look at; the venv python is a fake that records
  # its arguments and fd 4's type, holds like the wrapper (PYMCP_TEST_HOLD, before it closes fd 9), then echoes stdin
  local b="$BOTTLES/$1" e="$BOTTLES/$1/drive_c/users/crossover/AppData/Roaming" v="$R/mcp/python-mcp/$PMC/venv/bin"
  mkdir -p "$e/pyRevit/Extensions/revit-mcp-python.extension" "$e/pyRevit-Master/pyrevitlib/pyrevit/routes/server" \
    "$b/drive_c/users/crossover/AppData/Local/RevitMCPPython" "$v" "$R/mcp/python-mcp/$PMC/src" "$R/build/dpapi" "$R/tools/pyrevit48"
  touch "$e/pyRevit/Extensions/revit-mcp-python.extension/startup.py"
  cp "$REPO/tools/pyrevit48/revitmacos_serial.py" "$R/tools/pyrevit48/"
  cp "$REPO/tools/pyrevit48/revitmacos_serial.py" "$e/pyRevit-Master/pyrevitlib/pyrevit/routes/server/"
  printf '            return revitmacos_serial.dispatch(self, request, route_handler)\r\n' > "$e/pyRevit-Master/pyrevitlib/pyrevit/routes/server/server.py"
  echo blob > "$b/drive_c/users/crossover/AppData/Local/RevitMCPPython/pairing.dpapi"; echo "fake dpapi.exe" > "$R/build/dpapi/dpapi.exe"
  cat > "$v/python3" <<EOF
#!/bin/bash
[ "\$1 \$2" != "-I -c" ] || exit 0   # the launcher's "does the venv work" probe
{ printf '%s\n' "\$@"; stat -f %HT /dev/fd/4; echo "token=\$(cat <&4)"; [ -e /dev/fd/9 ] && echo FD9; echo "host=\${REVIT_HOST:-}"; env | grep -q "$PMTOK" && echo TOKEN-IN-ENV; } > "$T/py-argv"
if [ -n "\${PYMCP_TEST_HOLD:-}" ]; then touch "\$PYMCP_TEST_HOLD.reached"; while [ -e "\$PYMCP_TEST_HOLD" ]; do sleep 0.1; done; fi
exec 9>&-; "$T/rpc-echo"
EOF
  chmod +x "$v/python3"
}
pm_cx() { # the fake CrossOver's wine plays dpapi.exe: prints the token, or fails ($T/dpapi-mode fail), or hangs (hang)
  cat > "$CXF/bin/wine" <<EOF
#!/bin/bash
[ "\$1" = --bottle ] || exit 0
printf '%s\n' "\$@" > "$T/dpapi-argv"
case "\$(cat "$T/dpapi-mode" 2>/dev/null)" in
  fail) echo "DPAPI refused" >&2; exit 2 ;;
  hang) exec perl -e 'sleep 60' "$T/dpapi-hang" ;;
  orphan) perl -e 'sleep 60' "$T/dpapi-child" & exit 0 ;;   # a child that outlives the launcher and keeps its stdout
esac
printf '%s' "$PMTOK"
EOF
  chmod +x "$CXF/bin/wine"
}
pm_routes() { # $1 = bottle, $2 = address (127.0.0.1 | 0.0.0.0), $3 = exe ($SRV: a wineserver of the bottle): a fake
  # pyRevit Routes on $PMPORT; $T/routes-mode: 200 (default) | 401 | 503 | 404 | hang | garbage
  touch "$BOTTLES/$1/drive_c/routes.tmp"
  RDY="$RDY" "${3:-$SRV}" -MIO::Socket::INET -e '
    open(my $f, "<", $ARGV[0]) or die; my $s = IO::Socket::INET->new(LocalAddr => $ARGV[1], LocalPort => $ARGV[2],
      Listen => 5, ReuseAddr => 1) or die; open(my $r, ">", $ENV{RDY}) and close $r; while (my $c = $s->accept) { my $h = ""; while (<$c>) { $h .= $_; last if /^\r?$/ }
      open(my $m, "<", $ARGV[3]); my $mode = $m ? <$m> : "200"; $mode = "200" unless defined $mode; chomp $mode;
      open(my $l, ">>", $ARGV[4]); print $l $h; close $l;
      if ($mode eq "hang") { sleep 30; next }
      if ($mode eq "garbage") { print $c "HTTP/1.0 200 OK\r\n\r\nnot json"; close $c; next }
      my $b = $mode eq "200" ? q({"status": "active", "health": "healthy", "api_name": "revit_mcp"}) : q({"error": "x"});
      print $c "HTTP/1.0 $mode X\r\nContent-Type: application/json\r\n\r\n$b"; close $c }' \
    "$BOTTLES/$1/drive_c/routes.tmp" "$2" "$PMPORT" "$T/routes-mode" "$T/routes-log" &
  PIDS="$PIDS $!"; fake_ready
}
pm_world() { # $1 = bottle (rvt2020-a): installed add-in, Revit running, Routes answering, dpapi giving the token
  reset; bottle "${1:-rvt2020-a}" 2020 2020; pm_install "${1:-rvt2020-a}"; pm_cx; fake_revit "${1:-rvt2020-a}" 2020
  pm_routes "${1:-rvt2020-a}" 127.0.0.1; rm -f "$T/routes-mode" "$T/dpapi-mode" "$T/py-argv"
}
PMENV=(PYMCP_ROUTES_PORT="$PMPORT" PYMCP_DPAPI_S=3 PYMCP_STATUS_S=2)
pmr() { MCP_ENV=("${PMENV[@]}" ${PMX[@]+"${PMX[@]}"}); PMX=(); run_mcp mcp 2020 --server python "$@"; MCP_ENV=(); }
PMX=()
refused_pm() { [ "$RC" != 0 ] && grep -qF -- "$1" <<<"$ERR" && mcp_stdout_empty && [ ! -e "$T/py-argv" ]; }
reset; bottle rvt2027-a 2027 2027; MCP_ENV=("${PMENV[@]}"); run_mcp mcp 2027 --server python; MCP_ENV=()
check "python: 1 on 2027 → for 2020 here" refused_pm "MCP server for Revit (Python) is for Revit 2020 here."
reset; bottle rvt2020-a 2020 2020; pm_cx; fake_revit rvt2020-a 2020; pmr
check "python: 2 not installed → the install command" refused_pm "./revit addins 2020 --only python-mcp --accept-eula python-mcp"
pm_world; stop_fakes; pmr; check "python: 3 no Revit → open Revit first" refused_pm "Open Revit 2020 with a model first."
pm_world; printf 'Traceback (most recent call last):\nSyntaxError: x\n' > "$BOTTLES/rvt2020-a/drive_c/users/crossover/AppData/Local/RevitMCPPython/startup-error.txt"; pmr
check "python: 4 startup error → its first line" refused_pm "The MCP extension failed to load in Revit: Traceback (most recent call last)"
reset; bottle rvt2020-a 2020 2020; pm_install rvt2020-a; pm_cx; fake_revit rvt2020-a 2020; pmr
check "python: 5 nobody listens → turn on Routes" refused_pm "Turn on pyRevit Routes, or reload pyRevit"
reset; bottle rvt2020-a 2020 2020; pm_install rvt2020-a; pm_cx; fake_revit rvt2020-a 2020; pm_routes rvt2020-a 0.0.0.0; pmr
check "python: 5 Routes on the network → refused" refused_pm "pyRevit Routes listens on the network"
reset; bottle rvt2020-a 2020 2020; pm_install rvt2020-a; pm_cx; fake_revit rvt2020-a 2020; pm_routes rvt2020-a 127.0.0.1 perl; pmr
check "python: 5 another program on the port → refused" refused_pm "Port $PMPORT is taken by another program"
pm_world; rm "$BOTTLES/rvt2020-a/drive_c/users/crossover/AppData/Local/RevitMCPPython/pairing.dpapi"; pmr
check "python: 6 no pairing → Connect" refused_pm "In Revit: MCP → Bridge → Connect"
pm_world; echo fail > "$T/dpapi-mode"; pmr; check "python: 7 dpapi fails → Connect again" refused_pm "Connect again"
pm_world; echo hang > "$T/dpapi-mode"; t0=$SECONDS; pmr
check "python: 7 dpapi hangs → refused within its deadline, nothing left" eval 'refused_pm "Connect again" && [ $((SECONDS - t0)) -le 8 ] && ! sandboxed "dpapi-hang"'
pm_world; echo orphan > "$T/dpapi-mode"; t0=$SECONDS; pmr
check "python: 7 dpapi leaves a child holding its output → refused at once, the child ended" eval 'refused_pm "Connect again" && [ $((SECONDS - t0)) -le 8 ] && ! sandboxed "dpapi-child"'
for c in "401|Revit refused the pairing" "503|Open a model in Revit 2020" "404|reload pyRevit" "garbage|Unexpected answer from Revit" "hang|Revit does not answer"; do
  pm_world; echo "${c%%|*}" > "$T/routes-mode"; t0=$SECONDS; pmr
  check "python: 8 status ${c%%|*} → ${c#*|}" eval 'refused_pm "${c#*|}" && [ $((SECONDS - t0)) -le 8 ]'
done
check "python: the status check sends the token, never in an argument" eval 'grep -qF "Authorization: Bearer $PMTOK" "$T/routes-log" && ! grep -rqF "$PMTOK" "$T/dpapi-argv"'
pm_world; printf '            return base.Request(\r\n' > "$BOTTLES/rvt2020-a/drive_c/users/crossover/AppData/Roaming/pyRevit-Master/pyrevitlib/pyrevit/routes/server/server.py"; pmr
check "python: 2 pyRevit installed again over the patch → the install command" refused_pm "./revit addins 2020 --only python-mcp --accept-eula python-mcp"
pm_world; printf '{"jsonrpc":"2.0"}\n' > "$T/in"; MCP_IN="$T/in"; PMX=(http_proxy=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9); pmr
check "python: a proxy in the environment does not get the status check" eval '[ "$RC" = 0 ] && grep -qF "GET /revit_mcp/status/" "$T/routes-log"'
pm_world; echo 503 > "$T/routes-mode"; t0=$SECONDS
mcp_seed; (cd / && env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" REVIT_MCP_TOKEN="$MCP_TOKEN" PYMCP_ROUTES_PORT="$PMPORT" PYMCP_DPAPI_S=8 PYMCP_STATUS_S=2 /bin/bash "$R/revit" mcp 2020 --server python </dev/null 2>/dev/null | cat >/dev/null)
check "python: a refusal after the token closes the client's stdout at once" eval '[ $((SECONDS - t0)) -le 5 ]'
pm_world; MCP_ENV=(); run_mcp mcp 2020 --server python --write
check "python: --write refused" eval '[ "$RC" != 0 ] && grep -qF "comes with its token" <<<"$ERR" && mcp_stdout_empty'
pm_world; run_mcp mcp 2020 --server nope; check "mcp: unknown server names python" eval 'grep -qF "Known: autodesk, pyrevit, python" <<<"$ERR"'
pm_world; rq 1 > "$T/in"; MCP_IN="$T/in"; PMX=(REVIT_HOST=10.0.0.1 REVIT_PORT=1); pmr
check "python: connected, stdout is the server's alone" eval '[ "$RC" = 0 ] && [ "$OUT" = "$(rs 1)" ] && [ -z "$ERR" ]'
check "python: the wrapper, its marker, the bottle, the sources, fds 4 and 9" eval '[ "$(sed -n "1,9p" "$T/py-argv" | tr "\n" "|")" = "-I|$R/tools/python_mcp_run.py|revit-macos-python-mcp|$(cd "$BOTTLES/rvt2020-a" && pwd -P)|$R/mcp/python-mcp/$PMC/src|--token-fd|4|--lock-fd|9|" ]'
check "python: the token comes through a pipe on fd 4" eval 'grep -qx "Fifo File" "$T/py-argv" && grep -qx "token=$PMTOK" "$T/py-argv"'
check "python: the lock fd reaches the wrapper" grep -qx FD9 "$T/py-argv"
check "python: REVIT_HOST/REVIT_PORT of the caller do not change the address checked" grep -qF "GET /revit_mcp/status/" "$T/routes-log"
pm_world; printf '{"jsonrpc":"2.0"}\n' > "$T/in"; MCP_IN="$T/in"; PMX=(tok=exported-by-the-caller); pmr
check "python: an exported tok of the caller does not carry the token into the wrapper's environment" eval '[ "$RC" = 0 ] && ! grep -qx TOKEN-IN-ENV "$T/py-argv"'
# a here-string (a temp file in bash 3.2) instead of the pipe: the fd 4 check catches it
pm_world; cp "$R/scripts/mcp-launch.sh" "$T/launch.orig"; perl -pi -e 's/4< <\(printf %s "\$tok"\)/4<<<"\$tok"/' "$R/scripts/mcp-launch.sh"
pmr; check "python: a here-string launcher fails the fd 4 check" eval '[ -s "$T/py-argv" ] && ! grep -qx "Fifo File" "$T/py-argv"'; cp "$T/launch.orig" "$R/scripts/mcp-launch.sh"
# handoff: the lock is held until the marked wrapper runs; protection never lapses
for hold in PYMCP_EXEC_HOLD PYMCP_TEST_HOLD; do
  pm_world; touch "$T/hold"; MCP_ENV=("${PMENV[@]}" "$hold=$T/hold"); mcp_bg a mcp 2020 --server python; MCP_ENV=()
  mcp_wait '[ -e "$T/hold.reached" ]' 100
  check "python: at $hold the lock is held" eval '! lock_is_free'
  run "" stop 2020; check "python: at $hold stop refused: the lock is busy" eval '[ "$RC" != 0 ] && grep -q "Another task is running" <<<"$OUT" && sandboxed "Revit 2020.Revit.exe"'
  rm "$T/hold"; mcp_wait '[ -s "$T/py-argv" ]' 100; mcp_wait lock_is_free 50
  check "python: after $hold the lock is free" lock_is_free
  stop_fakes; run "" addins 2020; check "python: after $hold, Revit closed, addins refused through MCP" eval '[ "$RC" != 0 ] && grep -q "through MCP" <<<"$OUT"'
  exec 5>&-; wait "$LPID_a"
done
for c in "2020|remove 2020|cxbottle" "2020|rebuild 2020|install.sh" "|addins 2020|run-steps.sh"; do
  pm_world; MCP_ENV=("${PMENV[@]}"); mcp_bg a mcp 2020 --server python; MCP_ENV=(); mcp_wait '[ -s "$T/py-argv" ]' 100; mcp_wait lock_is_free 50; stop_fakes
  run "${c%%|*}" $(cut -d'|' -f2 <<<"$c")
  check "python connected, Revit closed: $(cut -d'|' -f2 <<<"$c") refused" eval '[ "$RC" != 0 ] && grep -q "through MCP" <<<"$OUT" && ! called "${c##*|}" && [ -d "$BOTTLES/rvt2020-a" ]'
  exec 5>&-; wait "$LPID_a"
done
pm_world; MCP_ENV=("${PMENV[@]}"); mcp_bg a mcp 2020 --server python; MCP_ENV=(); mcp_wait '[ -s "$T/py-argv" ]' 100; stop_fakes
exec 5>&-; wait "$LPID_a"; run "" addins 2020 --only revitlookup
check "python: EOF ends the wrapper, protection goes" eval '! grep -q "through MCP" <<<"$OUT"'
# another bottle's wrapper does not keep this one away; stop ends this bottle's wrapper only
pm_world rvt2020-a; bottle rvt2020-b 2020 2020; pm_install rvt2020-b; MCP_ENV=("${PMENV[@]}"); mcp_bg a mcp 2020 --server python; MCP_ENV=()
mcp_wait '[ -s "$T/py-argv" ]' 100; mcp_wait lock_is_free 50
run "" addins 2020 rvt2020-b --only revitlookup; check "python: another bottle's wrapper does not block" eval '! grep -q "through MCP" <<<"$OUT"'
run "" stop 2020 rvt2020-b; check "python: stop of another bottle leaves this wrapper" eval 'sandboxed "revit-macos-python-mcp"'
run "" stop 2020; check "python: stop ends this bottle's wrapper" eval '[ "$RC" = 0 ] && mcp_wait "! sandboxed revit-macos-python-mcp" 50'
run "" addins 2020 --only revitlookup; check "python: after stop, addins runs" eval '! grep -q "through MCP" <<<"$OUT"'
exec 5>&-; wait "$LPID_a" 2>/dev/null
# ---- ./revit hittest (scripts/hittest-launch.sh): the app's window-under-a-point helper ----
hit_cx() { # the fake CrossOver's wine plays hittest.exe: records its arguments (and FD8/FD9 if they reached it), holds a
  # file of the bottle open, writes the ready file (--ready Z:\… → its Mac path), prints hello, echoes stdin.
  # $T/hit-mode: noready | ignoreterm (no ready file, ignores TERM) | norevit (exit 3 at once)
  cat > "$CXF/bin/wine" <<EOF
#!/bin/bash
[ "\$1" = --bottle ] || exit 0
name="\$2"; shift 2; rf=""; prev=""
for a in "\$@"; do [ "\$prev" = --ready ] && rf="\$a"; prev="\$a"; done
{ printf '%s\n' "\$@"; [ -e /dev/fd/9 ] && echo FD9; [ -e /dev/fd/8 ] && echo FD8; } > "$T/hit-argv"
bf="$BOTTLES/\$name/drive_c/hit-open.tmp"; touch "\$bf"; exec 4<"\$bf"
case "\$(cat "$T/hit-mode" 2>/dev/null)" in
  noready) sleep 60 ;;
  ignoreterm) trap '' TERM; sleep 60 ;;
  norevit) exit 3 ;;
esac
rf="\${rf#Z:}"; touch "\${rf//\\\\//}"
echo "hello 1 0 0 3024 1964"; cat
EOF
  chmod +x "$CXF/bin/wine"
}
hit_shim() { mkdir -p "$R/build/hittest"; echo "fake hittest.exe" > "$R/build/hittest/hittest.exe"; }
hit_world() { reset; bottle rvt2027-a 2027 2027; hit_shim; hit_cx; fake_revit rvt2027-a 2027; REVITP=$!; }
hit_alive() { sandboxed 'revit-hittest\.'; }   # a process with this sandbox's ready-file token in its arguments

reset; hit_shim; hit_cx; run_mcp hittest 2027
check "hittest: no bottle → 1, stdout empty" eval '[ "$RC" = 1 ] && grep -q "There is no bottle rvt2027-a" <<<"$ERR" && mcp_stdout_empty'
reset; bottle rvt2027-a 2027 2027; hit_shim; hit_cx; run_mcp hittest 2027
check "hittest: Revit not running → 75, wine never started" eval '[ "$RC" = 75 ] && grep -q "Revit 2027 is not running in rvt2027-a" <<<"$ERR" && mcp_stdout_empty && [ ! -e "$T/hit-argv" ]'
hit_world; rm -rf "$R/build/hittest"; run_mcp hittest 2027
check "hittest: no hittest.exe → 1 with how to build it, wine never started" eval '[ "$RC" = 1 ] && grep -q "build-shims.sh hittest" <<<"$ERR" && mcp_stdout_empty && [ ! -e "$T/hit-argv" ]'
for a in "2027 rvt2027-a extra" "2027 --json" "2027 --events $T/ev" "abcd" "20270"; do
  hit_world; run_mcp hittest $a
  check "hittest $a: usage → 2, wine never started" eval '[ "$RC" = 2 ] && grep -q "Usage: ./revit hittest <year> \[bottle\]" <<<"$ERR" && mcp_stdout_empty && [ ! -e "$T/hit-argv" ]'
done
reset; run "" --help; check "hittest is in the help" grep -qx "  hittest   for the app: the Windows window under a point (stdin/stdout)" <<<"$OUT"
hit_world; printf '1 10 10\n' > "$T/in"; MCP_IN="$T/in"; run_mcp hittest 2027
check "hittest: exit 0, stdout is hittest.exe's alone, stderr empty" eval '[ "$RC" = 0 ] && [ "$OUT" = "$(printf "hello 1 0 0 3024 1964\n1 10 10")" ] && [ -z "$ERR" ]'
check "hittest: the shim by its Mac path, --ready Z:\\…\\revit-hittest.*, the year" eval '[ "$(sed -n 1p "$T/hit-argv")" = "$R/build/hittest/hittest.exe" ] &&
  [ "$(sed -n 2p "$T/hit-argv")" = --ready ] && sed -n 3p "$T/hit-argv" | grep -q "^Z:\\\\.*\\\\revit-hittest\.[A-Za-z0-9]*$" && [ "$(sed -n 4p "$T/hit-argv")" = 2027 ]'
check "hittest: neither the lock (fd 9) nor fd 8 reaches it" eval '! grep -qx -e FD9 -e FD8 "$T/hit-argv"'
check "hittest: the ready file is gone afterwards" eval 'f="$(sed -n 3p "$T/hit-argv")"; [ -n "${f##*\\}" ] && [ ! -e "${TMPDIR:-/tmp}/${f##*\\}" ]'   # its own: a real hittest may run beside
hit_world; mcp_bg a hittest 2027; mcp_wait '[ -s "$T/mcp-out-a" ]' 100; mcp_wait lock_is_free 50
check "hittest: the lock is released once it is ready" lock_is_free
echo "7 1 2" >&5; mcp_wait 'grep -qx "7 1 2" "$T/mcp-out-a"' 50; check "hittest: requests after the handoff reach it" grep -qx "7 1 2" "$T/mcp-out-a"
exec 5>&-; wait "$LPID_a"; check "hittest: end of input after the handoff → 0" test "$?" = 0
hit_world; fake_lock "install.sh 2025 rvt2025-a"; locker=$!; run_mcp hittest 2027
check "hittest: lock busy → 75 at once, wine never started" eval '[ "$RC" = 75 ] && grep -q "Another task is running" <<<"$ERR" && [ ! -e "$T/hit-argv" ]'
run_mcp hittest 2027; check "hittest: still busy → 75 again" test "$RC" = 75
run_mcp hittest 2027; check "hittest: busy a third time → 75" test "$RC" = 75
kill "$locker"; wait "$locker" 2>/dev/null; MCP_IN=/dev/null; run_mcp hittest 2027
check "hittest: the lock free again → it starts" eval '[ "$RC" = 0 ] && grep -q "^hello 1 " <<<"$OUT"'
# the lock is taken between the first checks and lock_take: 75, not a failure
hit_world; touch "$T/hold"; MCP_ENV=(HITTEST_TEST_HOLD="$T/hold"); mcp_bg a hittest 2027; mcp_wait '[ -e "$T/hold.reached" ]' 100
fake_lock "install.sh 2025 rvt2025-a"; rm "$T/hold"; exec 5>&-; wait "$LPID_a"; rc=$?; MCP_ENV=()
check "hittest: lock taken during the first checks → 75" eval '[ "$rc" = 75 ] && [ ! -e "$T/hit-argv" ]'
hit_world; echo norevit > "$T/hit-mode"; run_mcp hittest 2027
check "hittest: hittest.exe finds no Revit.exe (Revit just ended) → 75" eval '[ "$RC" = 75 ] && ! hit_alive && lock_is_free'
hit_world; fake_mcphost rvt2027-a; other=$!; echo noready > "$T/hit-mode"; MCP_ENV=(HITTEST_HANDOFF_S=2); run_mcp hittest 2027; MCP_ENV=()
check "hittest: not ready in time → 1, its processes gone, Revit and an MCP client alive, lock free" \
  eval '[ "$RC" = 1 ] && grep -q "did not start within 2 s" <<<"$ERR" && mcp_stdout_empty && ! hit_alive && revit_alive && kill -0 "$other" 2>/dev/null && lock_is_free'
hit_world; echo ignoreterm > "$T/hit-mode"; MCP_ENV=(HITTEST_HANDOFF_S=2); run_mcp hittest 2027; MCP_ENV=()
check "hittest: a loader that ignores TERM → killed" eval '[ "$RC" = 1 ] && ! hit_alive && revit_alive'
hit_world; echo noready > "$T/hit-mode"; MCP_ENV=(HITTEST_HANDOFF_S=20); mcp_bg a hittest 2027; mcp_wait '[ -s "$T/hit-argv" ]' 100; MCP_ENV=()
kill "$REVITP"; wait "$REVITP" 2>/dev/null; run "2027" remove 2027
check "hittest starting, Revit closed: remove refused, the bottle stays" \
  eval '[ "$RC" != 0 ] && grep -q -e "is still closing" -e "Another task is running" <<<"$OUT" && ! called cxbottle && [ -d "$BOTTLES/rvt2027-a" ]'
kill -TERM "$LPID_a"; wait "$LPID_a"; rc=$?; exec 5>&-
check "hittest: TERM before the handoff → 143, its processes gone, lock free" eval '[ "$rc" = 143 ] && ! hit_alive && lock_is_free'
hit_world; mcp_bg a hittest 2027; mcp_wait '[ -s "$T/mcp-out-a" ]' 100; mcp_wait lock_is_free 50
kill -TERM "$LPID_a"; wait "$LPID_a"; rc=$?; exec 5>&-
check "hittest: TERM after the handoff → 143, its processes gone, Revit alive" eval '[ "$rc" = 143 ] && ! hit_alive && revit_alive'
# Revit closed, hittest.exe still there (the real one ends with Revit within a second): remove and rebuild wait
for c in "2027|remove 2027|cxbottle" "2027|rebuild 2027|install.sh"; do
  hit_world; mcp_bg a hittest 2027; mcp_wait '[ -s "$T/mcp-out-a" ]' 100; mcp_wait lock_is_free 50; stop_fakes
  run "${c%%|*}" $(cut -d'|' -f2 <<<"$c")
  check "hittest running, Revit closed: $(cut -d'|' -f2 <<<"$c") refused (still closing)" eval '[ "$RC" != 0 ] && grep -q "is still closing" <<<"$OUT" && ! called "${c##*|}" && [ -d "$BOTTLES/rvt2027-a" ]'
  exec 5>&-; wait "$LPID_a"
done
# ---- ./revit theme (scripts/theme-launch.sh): the app's "the Mac's look changed" ----
theme_cx() { # the fake CrossOver's wine plays themeset.exe: records its arguments (and FD9/FD8 if they reached it); exit
  # from $T/theme-rc (default 0)
  cat > "$CXF/bin/wine" <<EOF
#!/bin/bash
{ printf '%s\n' "\$@"; [ -e /dev/fd/9 ] && echo FD9; [ -e /dev/fd/8 ] && echo FD8; } > "$T/theme-argv"
exit "\$(cat "$T/theme-rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$CXF/bin/wine"
  printf '#!/bin/bash\n[ "$(cat "%s" 2>/dev/null)" = dark ] && echo Dark\nexit 0\n' "$T/look" > "$T/defaults"; chmod +x "$T/defaults"
}
theme_world() { # $1 = bottle, $2 = mode ("" = no mode file), $3 = the Mac's look (dark | light)
  reset; bottle "$1" 2027 2027; theme_cx; echo "$3" > "$T/look"
  local d="$BOTTLES/$1/drive_c/Program Files/revit-macos"; mkdir -p "$d"; : > "$d/themeset.exe"
  [ -z "$2" ] || echo "$2" > "$d/theme"
}
MCP_ENV=(REVIT_DEFAULTS="$T/defaults")
theme_world rvt2027-a mac dark; run_mcp theme 2027
check "theme: mac on a dark Mac → 0, themeset.exe dark in the bottle" eval '[ "$RC" = 0 ] && [ "$OUT" = "Revit 2027 (rvt2027-a): dark." ] &&
  [ "$(sed -n 1,4p "$T/theme-argv" | tr "\n" "|")" = "--bottle|rvt2027-a|--wait-children|C:\\Program Files\\revit-macos\\themeset.exe|" ] &&
  [ "$(sed -n 5p "$T/theme-argv")" = dark ]'
check "theme: neither the lock (fd 9) nor fd 8 reaches wine" eval '! grep -qx -e FD9 -e FD8 "$T/theme-argv"'
check "theme: wineserver is not stopped" not_called "wineserver"
theme_world rvt2027-a mac light; run_mcp theme 2027; check "theme: a light Mac → light" eval '[ "$RC" = 0 ] && [ "$(sed -n 5p "$T/theme-argv")" = light ]'
theme_world rvt2027-a light dark; run_mcp theme 2027
check "theme: a fixed theme → 0, nothing run" eval '[ "$RC" = 0 ] && grep -q "the theme is fixed (light)" <<<"$OUT" && [ ! -e "$T/theme-argv" ]'
theme_world dark mac dark; run_mcp theme 2027 dark
check "theme: a bottle named dark is a bottle" eval '[ "$RC" = 0 ] && [ "$(sed -n 2p "$T/theme-argv")" = dark ]'
theme_world rvt2027-a mac dark; echo 3 > "$T/theme-rc"; run_mcp theme 2027
check "theme: Revit did not answer → 1" eval '[ "$RC" = 1 ] && grep -q "Revit did not get the change" <<<"$OUT"'
theme_world rvt2027-a mac dark; echo 1 > "$T/theme-rc"; run_mcp theme 2027
check "theme: themeset.exe failing → 1" eval '[ "$RC" = 1 ] && grep -q "themeset.exe ended (exit 1)" <<<"$OUT"'
theme_world rvt2027-b mac dark; rm "$BOTTLES/rvt2027-b/drive_c/Program Files/revit-macos/themeset.exe"; run_mcp theme 2027 rvt2027-b
check "theme: no themeset.exe → 1 with ./revit set for that bottle" eval '[ "$RC" = 1 ] &&
  grep -qF "Run: ./revit set 2027 rvt2027-b theme=mac" <<<"$ERR" && [ ! -e "$T/theme-argv" ]'
reset; bottle rvt2026-a 2026 2026; theme_cx; run_mcp theme 2026; check "theme: 2026 → 1" eval '[ "$RC" = 1 ] && grep -q "for Revit 2027 only" <<<"$ERR"'
theme_world rvt2027-a mac dark; fake_lock "install.sh 2025 rvt2025-a"; run_mcp theme 2027
check "theme: lock busy → 75, wine never started" eval '[ "$RC" = 75 ] && grep -q "Another task is running" <<<"$ERR" && [ ! -e "$T/theme-argv" ]'
theme_world rvt2027-a mac dark; fake_revit rvt2027-a 2027; run_mcp theme 2027
check "theme: while Revit runs (that is the point) → 0" eval '[ "$RC" = 0 ] && [ -e "$T/theme-argv" ]'
for a in "2027 x=y" "2027 rvt2027-a extra" "2027 --json" "2027 --yes" "2027 --bogus" "" "rvt2027-a"; do
  theme_world rvt2027-a mac dark; run_mcp theme $a
  check "theme $a: usage → 2, wine never started" eval '[ "$RC" = 2 ] && grep -q "Usage: ./revit theme <year> \[bottle\]" <<<"$ERR" && [ ! -e "$T/theme-argv" ]'
done
theme_world rvt2027-a mac dark; run_mcp theme 2027 --events "$T/ev"
check "theme --events: usage → 2, no events folder" eval '[ "$RC" = 2 ] && [ ! -e "$T/ev" ]'
theme_world rvt2027-b light dark; touch "$BOTTLES/rvt2027-b/drive_c/Program Files/Autodesk/Revit 2027/Revit.exe"
run "" doctor 2027 rvt2027-b --json --all
check "doctor: bottle.theme says the theme is fixed, with ./revit set for that bottle" eval 'printf "%s" "$OUT" | /usr/bin/perl -MJSON::PP -e '"'"'
  local $/; my ($c) = grep { $_->{id} eq "bottle.theme" } @{JSON::PP->new->decode(<STDIN>)->{checks}};
  exit !($c && $c->{title} eq "Revit'"'"'"'"'"'"'"'"'s theme is fixed: light" && $c->{fix} eq "./revit set 2027 rvt2027-b theme=mac to follow the Mac")'"'"''
reset; run "" --help; check "theme is in the help" grep -qx "  theme     for the app: Revit's theme follows the Mac's light or dark look now" <<<"$OUT"
MCP_ENV=()
for m in mac light dark junk; do
  theme_world rvt2027-a "$m" dark; run "" status --json
  want="$m"; [ "$m" = junk ] && want=""
  check "status: theme_mode $m" grep -qF "\"theme_mode\":\"$want\"," <<<"$OUT"
done
# ---- restore points ----
PR="$H/Library/Application Support/CrossOver/Revit Restore Points"
pt_bottle() { # $1 = name, $2 = year: a bottle with Revit in it and a BottleID, a hidden file, a marker to tell it apart
  bottle "$1" "$2" "$2"; touch "$BOTTLES/$1/drive_c/Program Files/Autodesk/Revit $2/Revit.exe" "$BOTTLES/$1/.hidden" "$BOTTLES/$1/system.reg"
  printf '"BottleID" = "id-%s"\n' "${3:-one}" >> "$BOTTLES/$1/cxbottle.conf"; echo "${3:-one}" > "$BOTTLES/$1/mark"
}
pt_make() { # $1 = bottle, $2 = year, $3 = id: a finished point
  local d="$PR/$1/$3"; mkdir -p "$d/bottle"; cp -R "$BOTTLES/$1/" "$d/bottle"
  printf 'year=%s\nbottle=%s\ntime=2026-10-30T10:00:00Z\nbytes=13000000000\nreason=rebuild\n' "$2" "$1" > "$d/point.conf"
}
pt_ids() { ls "$PR/$1" 2>/dev/null | tr '\n' ' '; }
fake_fs() { # the file system as diskutil reports it comes from $T/fstype; on PATH until unfake_fs
  mkdir -p "$T/bin"; echo apfs > "$T/fstype"; OLDPATH="$PATH"; PATH="$T/bin:$PATH"
  printf '#!/bin/bash\nprintf "<plist version=\\"1.0\\"><dict><key>FilesystemType</key><string>%%s</string></dict></plist>" "$(cat "%s/fstype")"\n' "$T" > "$T/bin/diskutil"
  chmod +x "$T/bin/diskutil"
}
unfake_fs() { PATH="$OLDPATH"; }
reset; pt_bottle rvt2024-a 2024; run "2024" rebuild 2024
expect "rebuild keeps a restore point" 0 "A restore point is kept first"
check "the point is a full copy, hidden files too" eval '[ -f "$PR/rvt2024-a/"*/bottle/.hidden ] && [ -f "$PR/rvt2024-a/"*/point.conf ]'
check "the point knows its bottle and year" eval 'grep -qx "year=2024" "$PR/rvt2024-a/"*/point.conf && grep -qx "bottle=rvt2024-a" "$PR/rvt2024-a/"*/point.conf'
check "its BottleID stays" eval 'grep -qF "id-one" "$PR/rvt2024-a/"*/bottle/cxbottle.conf'
check "the point comes before install.sh" eval 'grep -n "wineserver -k\|install.sh 2024" "$CALLS" | head -1 | grep -q wineserver'
check "install.sh ran" called "install.sh 2024 rvt2024-a"
reset; pt_bottle rvt2024-a 2024; run "no" rebuild 2024; expect "cancelled rebuild" 1 "Cancelled"
check "cancelled: no point" eval '[ ! -e "$PR" ]'
reset; pt_bottle rvt2024-a 2024; run "" rebuild 2024 --dry-run --json
check "dry run promises a point" grep -qF '"restore_point":true' <<<"$OUT"
check "dry run: the note" grep -qF 'A restore point is kept first' <<<"$OUT"
check "dry run: no point made" eval '[ ! -e "$PR" ]'
FREE_GB=10; reset; pt_bottle rvt2024-a 2024; mkdir -p "$R/installers/extracted/revit2024"; run "" rebuild 2024 --yes
expect "--yes without room for a point refuses" 1 "Nothing was deleted"
check "refused: no install.sh" not_called "install.sh"
check "refused: the way out is named" grep -qF -- "--no-point" <<<"$OUT"
run "" rebuild 2024 --dry-run --json; check "dry run says no point" grep -qF '"restore_point":false' <<<"$OUT"
run "" rebuild 2024 --yes --no-point; expect "--no-point goes on" 0 ""
check "--no-point: install.sh ran, no point" eval 'called "install.sh 2024" && [ -z "$(pt_ids rvt2024-a)" ]'
run "2024" rebuild 2024; expect "typed year accepts no point" 0 "No restore point: only 10 GB free"
check "typed: install.sh ran" called "install.sh 2024"
FREE_GB=30; reset; pt_bottle rvt2024-a 2024; run "" rebuild 2024 --yes
expect "no unpacked files: 55 GB needed" 1 "about 55 GB"
mkdir -p "$R/installers/extracted/revit2024"; run "" rebuild 2024 --yes; expect "unpacked files there: 25 GB is enough" 0 ""
run "" rebuild 2024 --yes --reextract; expect "--reextract: 55 GB needed" 1 "about 55 GB"
FREE_GB=100
reset; fake_fs; pt_bottle rvt2024-a 2024; echo hfs > "$T/fstype"; run "" rebuild 2024 --yes
expect "not APFS: refused without --no-point" 1 "not on an APFS volume"
echo apfs > "$T/fstype"; run_racing 'echo hfs > "$T/fstype"' 2024 rebuild 2024
expect "a promised point that became impossible stops the rebuild" 1 "Nothing was deleted"
check "stopped before install.sh and wineserver" eval 'not_called "install.sh" && not_called "wineserver"'
unfake_fs
reset; fake_fs; pt_bottle rvt2024-a 2024
cat > "$T/bin/diskutil" <<EOF
#!/bin/bash
n=\$(cat "$T/du-calls" 2>/dev/null || echo 0); echo \$((n + 1)) > "$T/du-calls"
if [ "\$n" = 1 ]; then   # the second look, under the lock: Revit starts right now
  perl -e 'open(my \$f, "<", \$ARGV[0]) or die; sleep 20' "$BOTTLES/rvt2024-a/cxbottle.conf" "C:\\\\Program Files\\\\Autodesk\\\\Revit 2024\\\\Revit.exe" </dev/null >/dev/null 2>&1 7>&- 9>&- &
  echo \$! > "$T/rv-pid"; sleep 1
fi
printf '<plist version="1.0"><dict><key>FilesystemType</key><string>apfs</string></dict></plist>'
EOF
run "" rebuild 2024 --yes; kill "$(cat "$T/rv-pid")" 2>/dev/null; unfake_fs
expect "Revit started after the check stops the rebuild" 1 "Nothing was deleted"
check "started after the check: not killed, no install, no point" eval 'not_called "wineserver -k" && not_called "install.sh" && [ -z "$(pt_ids rvt2024-a)" ]'
reset; pt_bottle rvt2024-a 2024; POINT_ENV=(TZ=Pacific/Kiritimati); run "" rebuild 2024 --yes; POINT_ENV=()
check "a point's id is in UTC, in any time zone" eval '[ "$(pt_ids rvt2024-a | cut -c1-11)" = "$(date -u +%Y%m%d-%H)" ]'
reset; bottle rvt2024-a 2024 2024; run "2024" rebuild 2024; expect "no Revit in the bottle: no point needed" 0 ""
check "no Revit: none made" eval '[ -z "$(pt_ids rvt2024-a)" ]'
reset; pt_bottle rvt2024-a 2024; mkdir -p "$PR/rvt2024-a/20260101-000000.partial"; run "" rebuild 2024 --yes --no-point
check "--no-point clears what a cut-short run left" eval '[ ! -e "$PR/rvt2024-a/20260101-000000.partial" ]'
reset; pt_bottle rvt2024-a 2024
printf '#!/bin/bash\nexit 1\n' > "$T/cp"; chmod +x "$T/cp"; POINT_ENV=(PATH="$T:$PATH"); run "" rebuild 2024 --yes; POINT_ENV=()
expect "a failed copy stops the rebuild" 1 "Nothing was deleted"
check "failed copy: no install.sh, no partial left" eval 'not_called "install.sh" && [ -z "$(pt_ids rvt2024-a)" ]'

reset; run "" rollback 2024; expect "rollback without a point" 1 "There is no restore point"
reset; pt_bottle rvt2024-a 2024; pt_make rvt2024-a 2024 20260101-000000; pt_make rvt2024-a 2024 20260201-000000
echo newer > "$PR/rvt2024-a/20260201-000000/bottle/mark"; echo older > "$PR/rvt2024-a/20260101-000000/bottle/mark"
echo current > "$BOTTLES/rvt2024-a/mark"; touch "$BOTTLES/rvt2024-a/.extra"; ino="$(stat -f %i "$BOTTLES/rvt2024-a")"
run "no" rollback 2024; expect "rollback can be cancelled" 1 "Cancelled"
check "cancelled: bottle as it was" grep -qx current "$BOTTLES/rvt2024-a/mark"
run "" rollback 2024 --dry-run; expect "rollback --dry-run" 0 "dry run"
run "2024" rollback 2024; expect "rollback" 0 "is back"
check "rollback: the newest point" grep -qx newer "$BOTTLES/rvt2024-a/mark"
check "rollback: hidden files of the point, none of the bottle" eval '[ -f "$BOTTLES/rvt2024-a/.hidden" ] && [ ! -e "$BOTTLES/rvt2024-a/.extra" ]'
check "rollback: the bottle's folder is the same folder" eval '[ "$(stat -f %i "$BOTTLES/rvt2024-a")" = "$ino" ]'
check "rollback: the point stays, nothing else" eval '[ "$(pt_ids rvt2024-a)" = "20260101-000000 20260201-000000 " ]'
check "rollback: no cxbottle" not_called "cxbottle"
run "" rollback 2024 --yes --to 20260101-000000; expect "rollback --to" 0 "is back"
check "rollback --to: that point" grep -qx older "$BOTTLES/rvt2024-a/mark"
run "" rollback 2024 --yes --to 20250101-000000; expect "rollback --to an unknown id" 1 "No restore point 20250101-000000"
run "" rollback 2024 --yes --to junk; expect "rollback --to junk" 1 "as ./revit points lists it"
reset; pt_bottle rvt2024-a 2024; pt_make rvt2024-a 2024 20260101-000000; mv "$BOTTLES/rvt2024-a" "$T/gone"
run "" rollback 2024 --yes; expect "rollback with no bottle there" 0 "is back"
check "no bottle: it is back" eval '[ -f "$BOTTLES/rvt2024-a/cxbottle.conf" ]'
reset; pt_bottle rvt2024-a 2024; pt_make rvt2024-a 2024 20260101-000000; mv "$BOTTLES/rvt2024-a" "$T/gone"; mkdir "$BOTTLES/rvt2024-a"
run "" rollback 2024 --yes; expect "rollback over a half-made bottle" 0 "is back"
reset; pt_bottle rvt2024-a 2024; pt_bottle rvt2025-a 2025; pt_make rvt2025-a 2025 20260101-000000
run "" rollback 2024 rvt2025-a --yes; expect "rollback of another year's bottle" 1 "is for Revit 2025"
mv "$BOTTLES/rvt2025-a" "$T/gone"; run "" rollback 2024 rvt2025-a --yes; expect "a point of another year is not used" 1 "There is no restore point"
reset; pt_bottle rvt2024-a 2024; pt_make rvt2024-a 2024 20260101-000000; fake_revit rvt2024-a 2024; run "" rollback 2024 --yes
expect "rollback refuses while Revit runs" 1 "Save your work and quit Revit"; stop_fakes
for at in 1 3 9; do
  reset; pt_bottle rvt2024-a 2024; pt_make rvt2024-a 2024 20260101-000000; echo current > "$BOTTLES/rvt2024-a/mark"; ino="$(stat -f %i "$BOTTLES/rvt2024-a")"
  POINT_ENV=(REVIT_SWAP_FAIL_AT="$at"); run "" rollback 2024 --yes; POINT_ENV=()
  expect "a swap that fails at entry $at" 1 "The bottle was not changed"
  check "failed swap $at: all back" eval 'grep -qx current "$BOTTLES/rvt2024-a/mark" && [ -f "$BOTTLES/rvt2024-a/.hidden" ] && [ -f "$BOTTLES/rvt2024-a/system.reg" ] && [ "$(stat -f %i "$BOTTLES/rvt2024-a")" = "$ino" ]'
  check "failed swap $at: nothing left over" eval '[ "$(pt_ids rvt2024-a)" = "20260101-000000 " ]'
done
reset; pt_bottle rvt2024-a 2024; pt_make rvt2024-a 2024 20260101-000000; echo current > "$BOTTLES/rvt2024-a/mark"
mkdir -p "$T/lie"; printf '#!/bin/bash\n[ "$1" = -R ] || [ "$1" = -cR ] || exit 1\n/bin/cp "$@"; rc=$?; chmod 000 "${!#}"; exit $rc\n' > "$T/lie/cp"; chmod +x "$T/lie/cp"
POINT_ENV=(PATH="$T/lie:$PATH"); run "" rollback 2024 --yes; POINT_ENV=(); chmod -R u+rwx "$PR" 2>/dev/null
expect "an unreadable clone stops the rollback" 1 "was not changed"
check "unreadable clone: the bottle stays" grep -qx current "$BOTTLES/rvt2024-a/mark"
reset; pt_bottle rvt2024-a 2024; pt_make rvt2024-a 2024 20260101-000000; echo current > "$BOTTLES/rvt2024-a/mark"
mkdir -p "$T/lie"; cat > "$T/lie/cp" <<EOF
#!/bin/bash
/bin/cp "\$@"; rc=\$?
perl -e 'open(my \$f, "<", \$ARGV[0]) or die; sleep 20' "$BOTTLES/rvt2024-a/cxbottle.conf" "C:\\\\Program Files\\\\Autodesk\\\\Revit 2024\\\\Revit.exe" </dev/null >/dev/null 2>&1 7>&- 9>&- &
echo \$! > "$T/lie/pid"; sleep 1; exit \$rc
EOF
chmod +x "$T/lie/cp"; POINT_ENV=(PATH="$T/lie:$PATH"); run "" rollback 2024 --yes; POINT_ENV=(); kill "$(cat "$T/lie/pid")" 2>/dev/null
expect "Revit started during the copy stops the rollback" 1 "Save your work and quit Revit"
check "started during the copy: not killed, bottle stays" eval 'not_called "wineserver -k" && grep -qx current "$BOTTLES/rvt2024-a/mark"'
check "started during the copy: the clone is gone" eval '[ "$(pt_ids rvt2024-a)" = "20260101-000000 " ]'
reset; pt_bottle rvt2024-a 2024; pt_make rvt2024-a 2024 20260101-000000; echo current > "$BOTTLES/rvt2024-a/mark"
printf '#!/bin/bash\n[ "$1" = -k ] && kill -TERM $PPID; exit 0\n' > "$CXF/bin/wineserver"; run "" rollback 2024 --yes
expect "TERM after the copy stops the rollback" 1 "Stopped."
check "TERM: bottle stays, nothing left" eval 'grep -qx current "$BOTTLES/rvt2024-a/mark" && [ "$(pt_ids rvt2024-a)" = "20260101-000000 " ]'
reset; pt_bottle rvt2024-a 2024 two; pt_make rvt2024-a 2024 20260101-000000
sed -i '' 's/id-two/id-one/' "$PR/rvt2024-a/20260101-000000/bottle/cxbottle.conf"; cxapp "Programs/Thing.app" rvt2024-a
run "" rollback 2024 --yes; expect "rollback to another BottleID" 0 "is back"
check "menu apps of the replaced bottle go" eval '[ -z "$(find "$H/Applications/CrossOver" -name "*.app" 2>/dev/null)" ]'

reset; run "" points 2024; expect "points: none" 0 "No restore points"
reset; pt_bottle rvt2024-a 2024; pt_make rvt2024-a 2024 20260101-000000; pt_make rvt2024-a 2024 20260201-000000
mkdir -p "$PR/rvt2024-a/20260301-000000.partial/bottle"
run "" points 2024; expect "points lists them" 0 "20260201-000000"
check "points: size, newest first, no partial" eval 'grep -qF "up to 13 GB" <<<"$OUT" && ! grep -qF "20260301" <<<"$OUT" && [ "$(grep -n 20260201 <<<"$OUT" | cut -d: -f1)" -lt "$(grep -n 20260101 <<<"$OUT" | cut -d: -f1)" ]'
run "" points 2024 --json; check "points --json" eval '/usr/bin/perl -MJSON::PP -e "local \$/; my \$j = decode_json(<STDIN>); exit !(@{\$j->{points}} == 2 && \$j->{points}[0]{bytes} == 13000000000)" <<<"$OUT"'
run "" status; check "status shows the size" grep -qF "Restore points: rvt2024-a 2 (up to 26 GB, unfinished files)" <<<"$OUT"
run "" status --json
check "status --json: points and leftovers" eval '/usr/bin/perl -MJSON::PP -e "local \$/; my \$j = decode_json(<STDIN>); exit !(@{\$j->{restore_points}} == 2 && \$j->{restore_leftovers}[0] eq q(rvt2024-a))" <<<"$OUT"'
run "no" points 2024 --clear old; expect "points --clear can be cancelled" 1 "Cancelled"
run "" points 2024 --clear old --dry-run; expect "points --clear --dry-run" 0 "dry run"
check "dry run: all there" eval '[ -d "$PR/rvt2024-a/20260101-000000" ]'
run "2024" points 2024 --clear old; expect "points --clear old" 0 "Deleted"
check "--clear old: the newest stays, leftovers go" eval '[ "$(pt_ids rvt2024-a)" = "20260201-000000 " ]'
run "" points 2024 --clear old; expect "--clear old with one point" 0 "Nothing to delete"
ln -s "$H/Documents" "$PR/rvt2024-a/20260201-000000/bottle/link"
run "" points 2024 --clear all --yes; expect "points --clear all" 0 "Deleted"
check "--clear all: gone, links not followed" eval '[ ! -e "$PR" ] && [ -f "$H/Documents/project.rvt" ]'
run "" points 2024 --clear junk; expect "--clear junk" 1 "--clear is old"
run "" rollback 2024 --no-point; expect "--no-point elsewhere" 1 "for ./revit rebuild only"
run "" status; check "status without points says nothing of them" eval '! grep -qF "Restore points" <<<"$OUT"'

reset; pt_bottle rvt2024-a 2024; pt_make rvt2024-a 2024 20260101-000000; mkdir -p "$PR/rvt2024-a/replaced.20260101-000000"
run "" remove 2024 --dry-run; expect "remove lists the points" 0 "restore point 20260101-000000"
run "" remove 2024 --dry-run --json; check "remove --json lists the point" grep -qF '"label":"restore point 20260101-000000","bytes":13000000000' <<<"$OUT"
run "2024" remove 2024; expect "remove" 0 "Removed"
check "remove deletes the points and leftovers" eval '[ ! -e "$PR" ]'
reset; pt_bottle rvt2024-a 2024; pt_make rvt2024-a 2024 20260101-000000; mv "$BOTTLES/rvt2024-a" "$T/gone"
run "2024" remove 2024; expect "remove with only a point left" 0 "Removed"
check "only a point left: gone" eval '[ ! -e "$PR" ]'
reset; pt_bottle rvt2025-a 2025; pt_make rvt2025-a 2025 20260101-000000; mv "$BOTTLES/rvt2025-a" "$T/gone"
run "2024" remove 2024 rvt2025-a; expect "remove with another year's point" 0 "Nothing to remove"
check "another year's point stays" eval '[ -d "$PR/rvt2025-a/20260101-000000" ]'
reset; run "" --help; check "the help names rollback" grep -q "^  rollback " <<<"$OUT"
fi

# ---- end ----
echo; echo "$((n - fails))/$n passed"; [ "$fails" -eq 0 ]
