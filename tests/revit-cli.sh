#!/usr/bin/env bash
# Tests for ./revit and the argument checks of install.sh, in a sandbox: a fake HOME, a fake CrossOver
# (REVIT_CX) and stub install scripts. Runs them under /bin/bash 3.2, as on a user's Mac. Nothing real is touched.
# Usage: tests/revit-cli.sh
set -uo pipefail
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
echo "\$(basename "\$0") \$* | REVIT_YEAR=\${REVIT_YEAR:-} INSTALL_DRYRUN=\${INSTALL_DRYRUN:-} CX_RECREATE=\${CX_RECREATE:-} WINEPREFIX=\${WINEPREFIX:-}" >> "$CALLS"
EOF
  chmod +x "$1"
}
reset() { # a fresh sandbox for each test
  stop_fakes; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"
  mkdir -p "$R/scripts/lib" "$R/logs" "$R/installers/revit2024" "$H/Documents" "$H/Applications" "$BOTTLES" "$CXF/bin" \
    || { echo "sandbox setup failed"; exit 1; }
  cp "$REPO/revit" "$R/"; cp "$REPO/scripts/lib/versions.sh" "$R/scripts/lib/"
  stub "$R/install.sh"; stub "$R/scripts/d8-addins.sh"; stub "$R/scripts/d7-launch.sh"
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
fake_install() { bash -c 'sleep 60; :' install.sh "$1" 2>/dev/null & PIDS="$PIDS $!"; sleep 1; } # looks like install.sh <year>
fake_script() { bash -c 'sleep 60; :' "$R/scripts/d8-addins.sh" "$1" 2>/dev/null & PIDS="$PIDS $!"; sleep 1; } # a script on bottle $1
fake_odis() { bash -c 'sleep 60; :' "$R/scripts/install-odis.sh" "$1" "$2" 2>/dev/null & PIDS="$PIDS $!"; sleep 1; } # <year> <bottle>
fake_unpack() { bash -c 'sleep 60; :' "$R/scripts/inspect-installer.sh" "$1" --extract 2>/dev/null & PIDS="$PIDS $!"; sleep 1; }
run() { # $1 = what to type at the prompt; rest = ./revit arguments. Sets OUT and RC.
  local input="$1"; shift; : > "$CALLS"
  OUT="$(cd / && printf '%s\n' "$input" | env -u REVIT_YEAR -u INSTALL_DRYRUN -u CX_RECREATE \
    HOME="$H" REVIT_CX="$CXF" /bin/bash "$R/revit" "$@" 2>&1)"; RC=$?
}
run_install() { # real install.sh in the sandbox; $1 = extra env (VAR=value or ""), rest = arguments
  local extra="$1"; shift; cp "$REPO/install.sh" "$R/install.sh"
  OUT="$(cd / && env -u INSTALL_DRYRUN -u CX_RECREATE HOME="$H" REVIT_CX="$CXF" $extra /bin/bash "$R/install.sh" "$@" 2>&1)"; RC=$?
}
run_racing() { # like run, but runs shell code $1 while ./revit waits at its prompt, then types $2
  local act="$1" input="$2" i; shift 2; : > "$CALLS"; : > "$T/out"
  { for i in $(seq 1 100); do grep -q "to continue" "$T/out" 2>/dev/null && break; sleep 0.1; done
    eval "$act"; printf '%s\n' "$input"; } \
    | (cd / && env -u REVIT_YEAR -u INSTALL_DRYRUN -u CX_RECREATE HOME="$H" REVIT_CX="$CXF" /bin/bash "$R/revit" "$@" > "$T/out" 2>&1)
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
reset; run "" install 2021;          expect "unsupported year" 1 "Revit 2021 is not supported yet"
reset; run "" remove rvt2024-a 2024; expect "swapped arguments" 1 '"rvt2024-a" is not a Revit year'
reset; run "" install 2024 default;  expect "bottle name default" 1 'cannot be "default"'
reset; run "" install 2024 "a b";    expect "bottle name with a space" 1 "Bottle name may contain only"
check "bad arguments run nothing" not_called "install.sh"

# ---- install, check ----
reset; run "" install 2024;          expect "install runs install.sh" 0 ""
check "install passes the year and the default bottle" called "install.sh 2024 rvt2024-a | REVIT_YEAR= INSTALL_DRYRUN= "
reset; run "" check 2025 rvt2025-b;  expect "check runs install.sh" 0 ""
check "check is a dry run of the named bottle" called "install.sh 2025 rvt2025-b | REVIT_YEAR= INSTALL_DRYRUN=1"
reset; fake_install 2024; run "" install 2024 rvt2024-b; expect "install refuses during an install of this year" 1 "An install of Revit 2024 is running."
check "install running: no second install" not_called "install.sh"
reset; bottle rvt2024-a 2024 2024; fake_script rvt2024-a; run "" install 2024; expect "install refuses while a script works on the bottle" 1 "A script is still working on rvt2024-a."

# ---- install.sh ----
reset; run_install "" 2024 default;  expect "install.sh refuses the bottle name default" 1 'cannot be "default"'
reset; run_install "" 2021;          expect "install.sh lists the supported years" 1 "Working versions: 2020, 2023, 2024, 2025, 2026, 2027."
reset; bottle rvt2024-b 2024 2024; run_install INSTALL_DRYRUN=1 2024 rvt2024-b
expect "install.sh: rebuild hint names the bottle" 1 "rebuild it: ./revit rebuild 2024 rvt2024-b"
expect "install.sh: final hint names the bottle" 1 "run ./revit install 2024 rvt2024-b again"
reset; bottle rvt2024-a 2024 2024; run_install INSTALL_DRYRUN=1 2024
check "install.sh: default bottle is not named" grep -qx '      fix: pick another name (./revit install 2024 rvt2024-b) or rebuild it: ./revit rebuild 2024' <<<"$OUT"

# ---- addins, stop, logs, debug ----
reset; run "" addins 2027;           expect "no add-ins for 2027" 1 "The add-in script is not set up for Revit 2027 yet."
reset; run "" addins 2024;           expect "addins needs the bottle" 1 "There is no bottle rvt2024-a. To install Revit 2024: ./revit install 2024"
reset; bottle rvt2024-a 2024 2024; run "" addins 2024; expect "addins runs the add-in script" 0 ""
check "addins passes the year and the bottle" called "d8-addins.sh rvt2024-a | REVIT_YEAR=2024"
reset; bottle rvt2024-a 2024 2024; fake_revit rvt2024-a 2024; run "" addins 2024
expect "addins refuses while Revit runs" 1 "Revit 2024 is running in rvt2024-a."
check "running: no add-ins installed" not_called "d8-addins.sh"
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
reset; run "" logs 2024;             expect "logs when there are none" 1 "No logs for rvt2024-a yet."
reset; mkdir -p "$R/logs/install-rvt2024-a-20261011-100000" "$R/logs/d7-rvt2024-a-default-20261011-110000" \
  "$R/logs/install-rvt2025-a-20261011-120000" "$R/logs/install-rvt2024-a-test-20261011-130000"
run "" logs 2024;                    expect "logs works without a bottle" 0 "d7-rvt2024-a-default-20261011-110000"
check "logs leaves out other bottles" eval '! grep -q -e rvt2025-a -e rvt2024-a-test <<<"$OUT"'
reset; ln -s "$BOTTLES/elsewhere" "$BOTTLES/rvt2024-a"; mkdir -p "$R/logs/install-rvt2024-a-20261011-100000"
run "" logs 2024;                    expect "logs is not blocked by a bottle link" 0 "install-rvt2024-a-20261011-100000"
reset; bottle rvt2024-a 2024 2024; run "" debug 2024; expect "debug starts Revit with logging" 0 "then run ./revit logs 2024."
check "debug passes the year" called "d7-launch.sh rvt2024-a | REVIT_YEAR=2024"
reset; bottle rvt2024-a 2024 2024; fake_revit rvt2024-a 2024; run "" debug 2024
expect "debug refuses while Revit runs" 1 "Revit 2024 is running in rvt2024-a."
reset; bottle rvt2024-a 2024 2024; fake_script rvt2024-a; run "" debug 2024
expect "debug refuses while a script works on the bottle" 1 "A script is still working on rvt2024-a."
reset; bottle rvt2024-a 2024 2024; fake_install 2024; run "" debug 2024
expect "debug refuses during an install of this year" 1 "An install of Revit 2024 is running."

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
check "remove deleted the Revit app" test ! -d "$H/Applications/Revit 2024 (rvt2024-a).app"
check "remove deleted the Sign-In app" test ! -d "$H/Applications/Autodesk Sign-In (rvt2024-a).app"
check "remove deleted the unpacked files" test ! -d "$R/installers/extracted/revit2024"
check "remove kept the downloads" test -f "$R/installers/revit2024/Create_Installer_RVT_2024_3_6_English_WIN64.exe"
check "remove kept the Mac's Documents" test -f "$H/Documents/project.rvt"
check "remove lines up the sizes" eval '[ "$(grep -E "^  (bottle|installers/extracted)" <<<"$OUT" | awk "{ print length(\$0) }" | sort -u | wc -l)" -eq 1 ]'
reset; bottle rvt2024-a 2024 2024; bottle rvt2024-b 2024 2024; mkdir -p "$R/installers/extracted/revit2024"
run "2024" remove 2024;              expect "remove keeps unpacked files another bottle uses" 0 "Kept: installers/extracted/revit2024 (bottle rvt2024-b still uses it)."
check "unpacked files still there" test -d "$R/installers/extracted/revit2024"
reset; bottle rvt2024-a 2024 2024; fake_install 2024
run "2024" remove 2024;              expect "remove refuses during an install of this year" 1 "An install of Revit 2024 is running."
check "install running: bottle kept" test -d "$BOTTLES/rvt2024-a"
reset; apps 2024 rvt2024-a; mkdir -p "$R/installers/extracted/revit2024"; fake_install 2024
run "2024" remove 2024;              expect "remove keeps unpacked files during an install" 0 "an install of Revit 2024 is running"
check "unpacked files kept during an install" test -d "$R/installers/extracted/revit2024"
reset; bottle rvt2024-a 2024 2024; fake_script rvt2024-a
run "2024" remove 2024;              expect "remove refuses while a script works on the bottle" 1 "A script is still working on rvt2024-a."
reset; bottle rvt2024-a 2024 2024; fake_odis 2024 rvt2024-a
run "2024" remove 2024;              expect "remove refuses while install-odis.sh works on the bottle" 1 "A script is still working on rvt2024-a."
reset; apps 2024 rvt2024-a; mkdir -p "$R/installers/extracted/revit2024"; fake_unpack 2024
run "2024" remove 2024;              expect "remove keeps unpacked files while they are being unpacked" 0 "an install of Revit 2024 is running"
check "unpacking: files kept" test -d "$R/installers/extracted/revit2024"
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

# ---- end ----
echo; echo "$((n - fails))/$n passed"; [ "$fails" -eq 0 ]
