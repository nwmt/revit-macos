#!/usr/bin/env bash
# Tests for the shared libraries, scripts/run-steps.sh and the install steps, in a sandbox: a copy of the repo, a fake
# HOME and a fake CrossOver (REVIT_CX) whose wine records its arguments and follows rules. Runs under /bin/bash 3.2.
# Nothing real is touched. Usage: tests/steps.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)" && [ -d "$TMP" ] || { echo "mktemp failed" >&2; exit 1; }
TOP="$(cd "$TMP" && pwd -P)" || exit 1
T="$TOP/sand box"                      # a space in every path
R="$T/repo"; H="$T/home"; CXF="$T/cx"; CALLS="$T/calls"; RULES="$T/rules"
BOTTLES="$H/Library/Application Support/CrossOver/Bottles"
PIDS=""
stop_bg() { local p; for p in $PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; PIDS=""; }
trap 'stop_bg; chmod -R u+w "$TOP" 2>/dev/null; rm -rf "$TOP"' EXIT
n=0; fails=0
ok()   { n=$((n + 1)); echo "ok   $1"; }
fail() { n=$((n + 1)); fails=$((fails + 1)); echo "FAIL $1"; printf '%s\n' "${2:-}" | sed 's/^/     /'; }
expect() { # $1 = name, $2 = exit code, $3 = text the output contains ("" = anything)
  if [ "$RC" = "$2" ] && { [ -z "$3" ] || grep -qF -- "$3" <<<"$OUT"; }; then ok "$1"
  else fail "$1" "rc=$RC (want $2), want text: $3
$OUT"; fi
}
check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name" "failed: $*"; fi; }
called()     { grep -qF -- "$1" "$CALLS"; }
not_called() { ! grep -qF -- "$1" "$CALLS"; }

reset() { # a fresh sandbox: the repo's scripts and tools, fake prebuilt shims, a fake CrossOver
  stop_bg; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"
  mkdir -p "$R" "$H/Applications" "$BOTTLES" "$CXF/bin" "$CXF/lib/dxvk/x86_64-windows" "$CXF/lib/wine/x86_64-windows" \
    || { echo "sandbox setup failed"; exit 1; }
  cp -R "$REPO/scripts" "$REPO/tools" "$R/"
  local f; for f in d3dwp/d3dwp.dll ncrypt-shim/ncrypt.dll pdf-printer/add_printer.exe rvtfix/rvtfix.dll \
    svcshim/svcshim.exe tlbpin/msls31.dll vkshim/vulkan-1.dll wbem-shim/wbemshim.dll wv2fix/version.dll; do
    mkdir -p "$R/build/$(dirname "$f")"; echo "fake $f" > "$R/build/$f"
  done
  echo 0.0.0 > "$R/build/.prebuilt"            # no toolchain in the sandbox: build scripts take these
  builtin_dll "$CXF/lib/dxvk/x86_64-windows/d3d9.dll"; builtin_dll "$CXF/lib/wine/x86_64-windows/version.dll"
  cat > "$CXF/bin/wine" <<EOF
#!/bin/bash
# fake wine: records its arguments (and FD9 when the lock's fd reached it), then the first matching rule of
# $RULES ("<text in the arguments><TAB><exit code><TAB><shell code>") decides; default exit 0
args="\$*"
{ printf 'wine'; for a in "\$@"; do printf ' [%s]' "\$a"; done; [ -e /dev/fd/9 ] && printf ' FD9'; echo; } >> "$CALLS"
while IFS=\$'\t' read -r pat rc code; do
  [ -n "\$pat" ] || continue
  case "\$args" in *"\$pat"*) [ -z "\$code" ] || eval "\$code"; exit "\$rc" ;; esac
done < "$RULES"
exit 0
EOF
  printf '#!/bin/bash\necho "wineserver $*" >> "%s"\nexit 0\n' "$CALLS" > "$CXF/bin/wineserver"
  chmod +x "$CXF/bin/wine" "$CXF/bin/wineserver"
  : > "$CALLS"; : > "$RULES"
}
builtin_dll() { # a file that carries Wine's builtin marker where Wine puts it (inside the first 0x100 bytes)
  mkdir -p "$(dirname "$1")"; { printf 'MZ'; head -c 62 /dev/zero; printf 'Wine builtin DLL'; head -c 64 /dev/zero; } > "$1"
}
rule() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$RULES"; }   # $1 = text in wine's arguments, $2 = exit, $3 = code
# control variables of the caller's shell must not reach the sandbox (a RUN_DIR could point at a real folder)
SANDBOX_ENV=(env -u RUN_DIR -u RUN_KIND -u CX_RECREATE -u INSTALL_DRYRUN -u REVIT_LANG -u ODIS_PKGS -u REVIT_THEME HOME="$H" REVIT_CX="$CXF")
in_repo() { # $1 = bash code run with ROOT set and common.sh loaded (cwd /, fake HOME and CrossOver). Sets OUT, RC
  OUT="$(cd / && "${SANDBOX_ENV[@]}" ROOT="$R" /bin/bash -c '. "$ROOT/scripts/lib/common.sh"; '"$1" 2>&1)"; RC=$?
}
hold_lock() { # $1 = owner text: a background process that holds the lock like a script would, until stop_bg
  mkdir -p "$R/logs"
  /usr/bin/perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die;
    open(my $o, ">", "$ARGV[0].owner") or die; print $o "$ARGV[1]\n"; close $o; sleep 60' "$R/logs/.lock" "$1" &
  PIDS="$PIDS $!"; sleep 0.5
}

# ---- versions.sh and profiles ----
reset; in_repo 'echo "${REVIT_SUPPORTED[*]}"'; expect "supported years come from the profiles" 0 "2020 2023 2024 2025 2026 2027"
reset; in_repo 'load_profile 2024 && echo "$YEAR $PRODKEY ${#STEPS[@]} ${REVITINI[1]}"'
expect "a profile loads" 0 '2024 829P1 22 Interoperability.RealDWGInstalledLocation=C:\Program Files\Autodesk\RealDWG Shared 2024\'
reset; in_repo 'load_profile 2021'; expect "a year without a profile is not loaded" 1 ""
reset; in_repo 'load_profile 2027; load_profile 2023; echo "[${ENSCAPE}] ${#ADDIN_STEPS[@]}"'
expect "loading a profile clears the previous one" 0 "[] 5"

# ---- run folder ----
reset; in_repo 'a="$(run_dir_new rvt2024-t steps)"; b="$(run_dir_new rvt2024-t steps)"; [ "$a" != "$b" ] && [ -d "$a" ] && [ -d "$b" ] && echo two'
expect "two run folders in the same second differ" 0 "two"

# ---- lock ----
reset; hold_lock "install.sh 2024 rvt2024-t"; in_repo 'lock_take test; echo took'
expect "a held lock refuses and names its owner" 1 "Another task is running: install.sh 2024 rvt2024-t."
stop_bg; in_repo 'lock_take test && echo took'; expect "the lock is free once its owner is gone" 0 "took"
reset; in_repo 'lock_take parent; ROOT="$ROOT" HOME="$HOME" /bin/bash -c ". \"\$ROOT/scripts/lib/common.sh\"; lock_take child && echo child-took"'
expect "a child script inherits the lock" 0 "child-took"
reset; hold_lock holder; in_repo 'exec 9</dev/null; lock_take test; echo took'
expect "a foreign fd 9 is not taken for the lock" 1 "Another task is running: holder."
reset; hold_lock holder; in_repo 'exec 9>>"$LOCK_FILE"; lock_take test; echo took'
expect "an unlocked fd on the lock file is not taken for the lock" 1 "Another task is running: holder."
reset; in_repo 'lock_take parent; sleep 3 >/dev/null 2>&1 & echo started'   # the parent exits, its child keeps fd 9
# (the child's stdout goes to /dev/null: a command substitution waits for every writer of its pipe)
in_repo 'lock_take test; echo took'; expect "a live child with the fd keeps the lock" 1 "Another task is running: parent."
sleep 3
reset; in_repo 'lock_take parent; sleep 3 >/dev/null 2>&1 9>&- & echo started'
in_repo 'lock_take test && echo took'; expect "a child started with 9>&- does not keep the lock" 0 "took"
reset; ( cd / && "${SANDBOX_ENV[@]}" ROOT="$R" /bin/bash -c '. "$ROOT/scripts/lib/common.sh"; lock_take execer; exec sleep 2' ) &
PIDS="$PIDS $!"; sleep 0.5; in_repo 'lock_take test; echo took'; expect "exec keeps the lock" 1 "Another task is running: execer."
reset; in_repo 'lock_free && echo free'; expect "lock_free: free" 0 "free"
reset; hold_lock holder; in_repo 'lock_free && echo free'; expect "lock_free: held" 1 ""

# ---- bottle_guard ----
mkbottle() { # $1 = name, $2 = year in the description ("" = none), $3 = year of the Revit folder ("" = none)
  local b="$BOTTLES/$1"; mkdir -p "$b/drive_c/windows/system32/wbem" "$b/drive_c/users/crossover"
  printf '[Bottle]\n%s\n[EnvironmentVariables]\n' "${2:+\"Description\" = \"Revit $2\"}" > "$b/cxbottle.conf"
  [ -z "$3" ] || mkdir -p "$b/drive_c/Program Files/Autodesk/Revit $3"
  local d; for d in d3d9 version vulkan-1 riched20 usp10 msls31 msftedit; do builtin_dll "$b/drive_c/windows/system32/$d.dll"; done
}
reset; mkbottle rvt2024-t 2024 ""; in_repo 'bottle_guard must_exist 2024 rvt2024-t && echo fine'; expect "guard: a half-installed bottle of the year" 0 "fine"
reset; mkbottle rvt2025-t 2025 2025; in_repo 'bottle_guard must_exist 2024 rvt2025-t'; expect "guard: another year" 1 "is for Revit 2025, not 2024"
reset; in_repo 'bottle_guard must_exist 2024 rvt2024-t'; expect "guard: missing bottle" 1 "There is no bottle rvt2024-t"
reset; in_repo 'bottle_guard allow_missing 2024 rvt2024-t && echo fine'; expect "guard: missing bottle allowed" 0 "fine"
reset; ln -s "$BOTTLES/nowhere" "$BOTTLES/rvt2024-t"; in_repo 'bottle_guard allow_missing 2024 rvt2024-t'
expect "guard: a dangling link is refused" 1 "is a link to another bottle"

# ---- wine.sh ----
in_bottle() { # $1 = bash code with wine.sh loaded for bottle rvt2024-t and a run folder; sets OUT, RC
  in_repo '. "$ROOT/scripts/lib/wine.sh"; . "$ROOT/scripts/lib/shims.sh"; wine_init rvt2024-t
    RUN_DIR="$(run_dir_new rvt2024-t test)"; '"$1"
}
reset; mkbottle rvt2024-t 2024 2024; in_bottle 'lock_take test; w some-program arg; echo rc=$?'
check "w runs wine with the bottle and waits" called "wine [--bottle] [rvt2024-t] [--wait-children] [some-program] [arg]"
check "wine never gets the lock's fd" not_called "FD9"
reset; mkbottle rvt2024-t 2024 2024; in_bottle 'accept_codes 194 0 194 102 && echo yes; accept_codes 67 0 194; echo no=$?'
expect "accept_codes: 194 accepted, 67 refused with 1" 0 "yes"; check "accept_codes returns 1, not the code" grep -q "no=1" <<<"$OUT"
reset; mkbottle rvt2024-t 2024 2024; echo new > "$T/new.dll"
in_bottle 'put_native_dll d3d9 "'"$T"'/new.dll" "$B/drive_c/Program Files/Autodesk/Revit 2024" Revit.exe && echo done'
expect "put_native_dll succeeds" 0 "done"
check "put_native_dll keeps Wine's stub" grep -q "Wine builtin DLL" "$BOTTLES/rvt2024-t/drive_c/windows/system32/d3d9.dll.wine-fake"
check "put_native_dll puts the file into system32" grep -q new "$BOTTLES/rvt2024-t/drive_c/windows/system32/d3d9.dll"
check "put_native_dll puts the second copy" test -f "$BOTTLES/rvt2024-t/drive_c/Program Files/Autodesk/Revit 2024/d3d9.dll"
check "put_native_dll sets native,builtin for the exe" called "[HKCU\\Software\\Wine\\AppDefaults\\Revit.exe\\DllOverrides] [/v] [d3d9] [/d] [native,builtin]"
in_bottle 'put_native_dll d3d9 "'"$T"'/new.dll" "" && echo again'
check "put_native_dll again keeps the first stub" grep -q "Wine builtin DLL" "$BOTTLES/rvt2024-t/drive_c/windows/system32/d3d9.dll.wine-fake"
reset; mkbottle rvt2024-t 2024 2024; chmod 555 "$BOTTLES/rvt2024-t/drive_c/windows/system32"; echo new > "$T/new.dll"
in_bottle 'put_native_dll d3d9 "'"$T"'/new.dll" "" Revit.exe; echo rc=$?'
check "put_native_dll fails when system32 is not writable" grep -q "rc=1" <<<"$OUT"
chmod 755 "$BOTTLES/rvt2024-t/drive_c/windows/system32"
reset; mkbottle rvt2024-t 2024 2024; in_bottle 'bottle_env "A=b c" >/dev/null; sh_path "/a b/x.sh"'
expect "sh_path quotes a path with a space" 0 "'/a b/x.sh'"
check "bottle_env writes cxbottle.conf" grep -q '"A" = "b c"' "$BOTTLES/rvt2024-t/cxbottle.conf"
reset; mkbottle rvt2024-t 2024 2024; rule "cmd /c" 103
in_bottle 'msi rvt "Z:\\x\\RVT.msi" "INSTALLDIR=C:\\Program Files\\Autodesk\\Revit 2024" A=1; echo rc=$?; cat "$RUN_DIR/rvt.cmd"'
expect "msi returns msiexec's code" 0 "rc=103"
check "msi quotes values with spaces" grep -qF 'INSTALLDIR="C:\Program Files\Autodesk\Revit 2024" A=1' <<<"$OUT"
reset; mkbottle rvt2024-t 2024 2024; in_bottle 'ensure_shim wbem-shim && echo built; ensure_shim nonsense; echo rc=$?'
expect "ensure_shim takes the prebuilt shim" 0 "built"; check "ensure_shim refuses an unknown shim" grep -q "rc=1" <<<"$OUT"

# ---- run-steps.sh ----
STEP_ENV=()   # VAR=value pairs for the next run_steps only (ODIS_PKGS, REVIT_THEME, RUN_DIR)
run_steps() { # $@ = arguments of run-steps.sh; sets OUT, RC and RUN (the newest run folder of bottle $2)
  OUT="$(cd / && "${SANDBOX_ENV[@]}" ${STEP_ENV[@]+"${STEP_ENV[@]}"} /bin/bash "$R/scripts/run-steps.sh" "$@" 2>&1)"; RC=$?
  RUN="$(ls -td "$R/logs/${2:-none}"/*/ 2>/dev/null | head -1)"; RUN="${RUN%/}"; STEP_ENV=()
}
teststeps() { # test-only steps, in the sandbox copy only
  mkdir -p "$R/scripts/steps"
  cat > "$R/scripts/steps/zz-test.sh" <<EOF
step_t_ok()   { echo t_ok >> "$T/order"; detail "fine"; }
step_t_two()  { echo t_two >> "$T/order"; }
step_t_fail() { echo t_fail >> "$T/order"; echo "it broke"; return 1; }
step_t_skip() { skip "not for this version"; return 0; }
step_t_wine() { w t-wine-call; }
step_t_slow() { echo t_slow >> "$T/order"; w t-slow; }
EOF
}
mkdist() { # $1 = year: a tiny unpacked ODIS installer
  local d="$R/installers/extracted/revit$1"
  mkdir -p "$d/manifest" "$d/x86/Licensing" "$d/x64/RVT" "$d/x64/AdskIdentityManager"
  echo '<Setup/>' > "$d/setup.xml"; echo '<Packages></Packages>' > "$d/manifest/app.RVT.xml"
  touch "$d/x86/Licensing/AdskLicensing-installer.exe" "$d/x64/RVT/RevitConfig.pit" \
    "$d/x64/AdskIdentityManager/AdskIdentityManager-Installer.exe"
}
reset; mkbottle rvt2024-t 2024 2024; teststeps; run_steps 2024 rvt2024-t t_ok nonsense
expect "an unknown step stops before anything runs" 2 "Unknown step: nonsense"
check "unknown step: nothing ran" test ! -e "$T/order"; check "unknown step: no run folder" test -z "$RUN"
reset; mkbottle rvt2024-t 2024 2024; teststeps; run_steps 2024 rvt2024-t t_two t_ok t_skip
expect "steps run" 0 ">> Revit 2024 → bottle rvt2024-t"
check "steps run in the given order" test "$(tr '\n' ' ' < "$T/order")" = "t_two t_ok "
check "summary has the detail" grep -qE '^   t_ok +exit=0 +fine \([0-9]+ s\)$' "$RUN/summary.txt"
check "a skipped step says skip" grep -qE '^   t_skip +exit=skip +not for this version' "$RUN/summary.txt"
check "a step's output goes to its log" test -f "$RUN/t_ok.log"
reset; mkbottle rvt2024-t 2024 2024; teststeps; run_steps 2024 rvt2024-t t_fail t_ok
expect "a failed step: the others still run, exit 1" 1 "t_fail"
check "failed: the next step ran" grep -qx t_ok "$T/order"
check "failed.txt lists it" grep -qx t_fail "$RUN/failed.txt"
check "the failure points at the log" grep -q 't_fail.log' "$RUN/summary.txt"
reset; mkbottle rvt2024-t 2024 2024; teststeps; run_steps 2024 rvt2024-t t_wine
check "Wine in a step does not get the lock's fd" not_called "FD9"
reset; mkbottle rvt2024-t 2024 2024; teststeps; hold_lock "install.sh 2025 rvt2025-t"; run_steps 2024 rvt2024-t t_ok
expect "a held lock stops run-steps" 1 "Another task is running: install.sh 2025 rvt2025-t."
reset; mkbottle rvt2025-t 2025 2025; teststeps; run_steps 2024 rvt2025-t t_ok
expect "run-steps checks the bottle's year" 1 "is for Revit 2025, not 2024"
reset; mkbottle rvt2024-t 2024 2024; teststeps; mkdir -p "$R/logs/rvt2024-t/given"
STEP_ENV=(RUN_DIR="$R/logs/rvt2024-t/given"); run_steps 2024 rvt2024-t t_ok
check "RUN_DIR from install.sh is used" test -f "$R/logs/rvt2024-t/given/summary.txt"
# TERM while a step runs Wine: the Wine program finishes, the run stops after that step, the lock is free
reset; mkbottle rvt2024-t 2024 2024; teststeps; rule "t-slow" 0 "sleep 2; touch '$T/slow-done'"
(cd / && exec "${SANDBOX_ENV[@]}" /bin/bash "$R/scripts/run-steps.sh" 2024 rvt2024-t t_slow t_ok) > "$T/out" 2>&1 &
rs=$!; sleep 1; kill -TERM "$rs"; wait "$rs"; RC=$?; OUT="$(cat "$T/out")"
expect "TERM stops the run with code 1" 1 "Stopped."
check "TERM: the running Wine program finished" test -f "$T/slow-done"
check "TERM: the next step did not run" test "$(tr '\n' ' ' < "$T/order")" = "t_slow "
in_repo 'lock_free && echo free'; expect "TERM: the lock is free afterwards" 0 "free"

echo; echo "$((n - fails))/$n passed"; [ "$fails" -eq 0 ]
