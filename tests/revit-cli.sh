#!/usr/bin/env bash
# Tests for ./revit and the argument checks of install.sh, in a sandbox: a fake HOME, a fake CrossOver
# (REVIT_CX) and stub install scripts. Runs them under /bin/bash 3.2, as on a user's Mac. Nothing real is touched.
# Usage: tests/revit-cli.sh
set -uo pipefail
# every control variable of the engine: none of the caller's may reach the sandbox (a REVIT_DATA or REVIT_SOURCE_LIST
# could point at real folders); tests set what they need after this
CLEAN_ENV=(-u REVIT_DATA -u REVIT_LOCK_DIR -u SHIMS_DIR -u REVIT_BUNDLED -u REVIT_EVENTS_FD -u REVIT_RUN_ID -u REVIT_RUN_CTX
  -u REVIT_ACCEPT_EULA -u REVIT_SOURCE_LIST -u REVIT_REUSE_EXTRACTED -u REVIT_REEXTRACT -u REVIT_UNPACK_AGAIN
  -u REVIT_FOR_BOTTLE -u INSTALL_PARENT -u W_CACHE -u SHIMS_FROM_SOURCE -u RUN_DIR -u RUN_KIND -u CX_RECREATE
  -u INSTALL_DRYRUN -u REVIT_LANG -u ODIS_PKGS -u REVIT_THEME -u REVIT_YEAR -u SMOKE_TIMEOUT -u SMOKE_START_WAIT
  -u SMOKE_STALL -u SMOKE_WORKER_WAIT -u SMOKE_POLL -u SMOKE_PREP_TIMEOUT -u REVIT_CX_TMP)
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)" && [ -d "$TMP" ] || { echo "mktemp failed" >&2; exit 1; }   # an empty TOP would be the current folder
TOP="$(cd "$TMP" && pwd -P)" || exit 1   # /var → /private/var: lsof reports real paths
T="$TOP/sand box"                      # a space in every path: quoting bugs show up here
R="$T/repo"; H="$T/home"; CXF="$T/cx"; CALLS="$T/calls"
BOTTLES="$H/Library/Application Support/CrossOver/Bottles"
PIDS=""
stop_fakes() { # the fake processes and their children (sleep), and wait so none is left for the next test's pgrep
  local p; for p in $PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; PIDS=""
}
trap 'stop_fakes; chmod -R u+w "$TOP" 2>/dev/null; rm -rf "$TOP"' EXIT
n=0; fails=0
ok()   { n=$((n + 1)); echo "ok   $1"; }
fail() { n=$((n + 1)); fails=$((fails + 1)); echo "FAIL $1"; printf '%s\n' "${2:-}" | sed 's/^/     /'; }

stub() { # a script that only records how it was called
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
#!/bin/bash
echo "\$(basename "\$0") \$* | REVIT_YEAR=\${REVIT_YEAR:-} INSTALL_DRYRUN=\${INSTALL_DRYRUN:-} CX_RECREATE=\${CX_RECREATE:-} WINEPREFIX=\${WINEPREFIX:-} RUN_KIND=\${RUN_KIND:-} EULA=\${REVIT_ACCEPT_EULA:-} REUSE=\${REVIT_REUSE_EXTRACTED:-} REEXTRACT=\${REVIT_REEXTRACT:-}" >> "$CALLS"
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
  cp "$REPO/scripts/lib/addins.sh" "$REPO/scripts/lib/mcp.sh" "$R/scripts/lib/" 2>/dev/null
  [ ! -f "$REPO/scripts/mcp-launch.sh" ] || cp "$REPO/scripts/mcp-launch.sh" "$R/scripts/"; cp -R "$REPO/scripts/addins" "$REPO/scripts/steps" "$R/scripts/" 2>/dev/null
  stub "$R/install.sh"; stub "$R/scripts/run-steps.sh"; stub "$R/scripts/launch.sh"; stub "$R/scripts/smoke.sh"
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
fake_revit() { # $1 = bottle, $2 = year: a process that looks like Revit.exe and holds a file open in that bottle
  touch "$BOTTLES/$1/drive_c/open.tmp"
  perl -e 'open(my $f, "<", $ARGV[0]) or die; sleep 60' "$BOTTLES/$1/drive_c/open.tmp" \
    "C:\\Program Files\\Autodesk\\Revit $2\\Revit.exe" &
  PIDS="$PIDS $!"; sleep 1
}
fake_mcphost() { # $1 = bottle: a process that looks like our MCP launcher (mcphost.exe) and holds a file open there
  touch "$BOTTLES/$1/drive_c/mcp.tmp"
  perl -e 'open(my $f, "<", $ARGV[0]) or die; sleep 60' "$BOTTLES/$1/drive_c/mcp.tmp" \
    "C:\\Program Files\\Autodesk\\Revit 2027 MCP Server Write-Tools Technical Preview\\mcphost.exe" --launch t &
  PIDS="$PIDS $!"; sleep 1
}
fake_lock() { # $1 = owner text: a process that holds the repo's lock as a running script would
  mkdir -p "$H/Library/Application Support/revit-macos"
  perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die;
    open(my $o, ">", "$ARGV[0].owner") or die; print $o "$ARGV[1]\n"; close $o; sleep 60' "$H/Library/Application Support/revit-macos/lock" "$1" &
  PIDS="$PIDS $!"; sleep 1
}
run() { # $1 = what to type at the prompt; rest = ./revit arguments. Sets OUT and RC.
  local input="$1"; shift; : > "$CALLS"
  OUT="$(cd / && printf '%s\n' "$input" | env "${CLEAN_ENV[@]}" \
    HOME="$H" REVIT_CX="$CXF" /bin/bash "$R/revit" "$@" 2>&1)"; RC=$?
}
run_install() { # real install.sh in the sandbox; $1 = extra env (VAR=value or ""), rest = arguments
  local extra="$1"; shift; cp "$REPO/install.sh" "$R/install.sh"
  OUT="$(cd / && env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" $extra /bin/bash "$R/install.sh" "$@" 2>&1)"; RC=$?
}
run_racing() { # like run, but runs shell code $1 while ./revit waits at its prompt, then types $2
  local act="$1" input="$2" i; shift 2; : > "$CALLS"; : > "$T/out"
  { for i in $(seq 1 100); do grep -q "to continue" "$T/out" 2>/dev/null && break; sleep 0.1; done
    eval "$act"; printf '%s\n' "$input"; } \
    | (cd / && env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" /bin/bash "$R/revit" "$@" > "$T/out" 2>&1)
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
reset; bottle rvt2024-a 2024 2024; ln -s "$BOTTLES/rvt2024-a" "$BOTTLES/rvt2024-t"; run "" stop 2024 rvt2024-t
expect "a bottle that is a link is refused" 1 "Bottle rvt2024-t is a link to another bottle."
reset; rm -rf "$CXF"; bottle rvt2024-a 2024 2024; run "" stop 2024; expect "stop without CrossOver" 1 "CrossOver not found"
reset; bottle rvt2024-a 2024 2024; fake_lock "install.sh 2024 rvt2024-a"; run "" stop 2024
expect "stop refuses while another task runs" 1 "Another task is running: install.sh 2024 rvt2024-a."
check "busy: nothing stopped" not_called "wineserver"
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
check "status: a Revit bottle" grep -qF '{"name":"rvt2024-a","year":"2024","revit":true,"running":false,"addins":[]}' <<<"$OUT"
check "status: a half-installed bottle" grep -qF '{"name":"rvt2025-b","year":"2025","revit":false,' <<<"$OUT"
check "status: a non-Revit bottle is left out" eval '! grep -q "\"exp\"" <<<"$OUT"'
reset; bottle rvt2024-a 2024 2024; revit_exe rvt2024-a 2024; fake_revit rvt2024-a 2024; run "" status --json
check "status: running" grep -qF '"name":"rvt2024-a","year":"2024","revit":true,"running":true' <<<"$OUT"
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
reset; run "" install 2024 --dry-run; expect "--dry-run on install is refused" 1 "--dry-run is for ./revit remove and rebuild only."
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
# ---- end ----
echo; echo "$((n - fails))/$n passed"; [ "$fails" -eq 0 ]
