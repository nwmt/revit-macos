#!/usr/bin/env bash
# Tests for ./revit and the argument checks of install.sh, in a sandbox: a fake HOME, a fake CrossOver
# (REVIT_CX) and stub install scripts. Runs them under /bin/bash 3.2, as on a user's Mac. Nothing real is touched.
# Usage: tests/revit-cli.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TOP="$(cd "$(mktemp -d)" && pwd -P)"   # /var → /private/var: lsof reports real paths
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
fake_revit() { # $1 = bottle, $2 = year: a process that looks like Revit.exe and holds a file open in that bottle
  touch "$BOTTLES/$1/drive_c/open.tmp"
  perl -e 'open(my $f, "<", $ARGV[0]) or die; sleep 60' "$BOTTLES/$1/drive_c/open.tmp" \
    "C:\\Program Files\\Autodesk\\Revit $2\\Revit.exe" &
  PIDS="$PIDS $!"; sleep 1
}
fake_install() { bash -c 'sleep 60; :' install.sh "$1" & PIDS="$PIDS $!"; sleep 1; } # looks like install.sh <year>
fake_script() { bash -c 'sleep 60; :' "$R/scripts/d8-addins.sh" "$1" & PIDS="$PIDS $!"; sleep 1; } # a script on bottle $1
fake_odis() { bash -c 'sleep 60; :' "$R/scripts/install-odis.sh" "$1" "$2" & PIDS="$PIDS $!"; sleep 1; } # <year> <bottle>
fake_unpack() { bash -c 'sleep 60; :' "$R/scripts/inspect-installer.sh" "$1" --extract & PIDS="$PIDS $!"; sleep 1; }
run() { # $1 = what to type at the prompt; rest = ./revit arguments. Sets OUT and RC.
  local input="$1"; shift; : > "$CALLS"
  OUT="$(cd / && printf '%s\n' "$input" | env -u REVIT_YEAR -u INSTALL_DRYRUN -u CX_RECREATE \
    HOME="$H" REVIT_CX="$CXF" /bin/bash "$R/revit" "$@" 2>&1)"; RC=$?
}
run_install() { # real install.sh in the sandbox; $1 = extra env (VAR=value or ""), rest = arguments
  local extra="$1"; shift; cp "$REPO/install.sh" "$R/install.sh"
  OUT="$(cd / && env -u INSTALL_DRYRUN -u CX_RECREATE HOME="$H" REVIT_CX="$CXF" $extra /bin/bash "$R/install.sh" "$@" 2>&1)"; RC=$?
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

# ---- install.sh ----
reset; run_install "" 2024 default;  expect "install.sh refuses the bottle name default" 1 'cannot be "default"'
reset; run_install "" 2021;          expect "install.sh lists the supported years" 1 "Working versions: 2020, 2023, 2024, 2025, 2026, 2027."
reset; bottle rvt2024-b 2024 2024; run_install INSTALL_DRYRUN=1 2024 rvt2024-b
expect "install.sh: rebuild hint names the bottle" 1 "rebuild it: ./revit rebuild 2024 rvt2024-b"
expect "install.sh: final hint names the bottle" 1 "run ./revit install 2024 rvt2024-b again"
reset; bottle rvt2024-a 2024 2024; run_install INSTALL_DRYRUN=1 2024
check "install.sh: default bottle is not named" grep -qx '      fix: pick another name (./revit install 2024 rvt2024-b) or rebuild it: ./revit rebuild 2024' <<<"$OUT"

# ---- end ----
echo; echo "$((n - fails))/$n passed"; [ "$fails" -eq 0 ]
