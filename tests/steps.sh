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

# ---- steps: runtimes, licensing ----
lic_rule() { # $1 = exit code of the fake licensing installer; it lays out AdskLicensing as the real one does
  rule "licensing.exe" "$1" "mkdir -p '$BOTTLES/rvt$2-t/drive_c/Program Files (x86)/Common Files/Autodesk Shared/AdskLicensing/16.1.0.1/helper' '$BOTTLES/rvt$2-t/drive_c/Program Files (x86)/Common Files/Autodesk Shared/AdskLicensing/Currentx'; touch '$BOTTLES/rvt$2-t/drive_c/Program Files (x86)/Common Files/Autodesk Shared/AdskLicensing/16.1.0.1/helper/AdskLicensingInstHelper.exe'"
}
AL2024="$BOTTLES/rvt2024-t/drive_c/Program Files (x86)/Common Files/Autodesk Shared/AdskLicensing"
reset; mkbottle rvt2024-t 2024 2024; mkdist 2024; lic_rule 84 2024; run_steps 2024 rvt2024-t licensing
expect "licensing: the expected 84 is success" 0 ""; check "licensing: in the summary" grep -qE '^   licensing +exit=0 +AdskLicensing' "$RUN/summary.txt"
check "licensing: Current points at the version" test "$(readlink "$AL2024/Current")" = 16.1.0.1
check "licensing: the mklink garbage folder is gone" test ! -e "$AL2024/Currentx"
check "licensing: version.ini written" grep -q "version=16.1.0.1" "$AL2024/version.ini"
run_steps 2024 rvt2024-t licensing; expect "licensing twice: the second run skips the installer" 0 ""; check "licensing twice: skipped the installer" grep -q "already installed: 16.1.0.1" "$RUN/summary.txt"
reset; mkbottle rvt2024-t 2024 2024; mkdist 2024; lic_rule 85 2024; run_steps 2024 rvt2024-t licensing
expect "licensing: another code fails" 1 "Step licensing failed"
reset; mkbottle rvt2024-t 2024 2024; teststeps; mkdist 2024; rule "licensing.exe" 5; run_steps 2024 rvt2024-t licensing t_ok
expect "a failed critical step stops the run" 1 "Step licensing failed, and the steps after it need it: stopped."
check "critical: the next step did not run" test ! -e "$T/order"
reset; mkbottle rvt2024-t 2024 2024; teststeps; run_steps 2024 rvt2024-t licensing
expect "a step that needs the installer checks for it first" 1 "No unpacked Revit 2024 installer"
reset; mkbottle rvt2024-t 2024 2024; mkdist 2024; rule "licensing.exe" 84; run_steps 2024 rvt2024-t licensing
expect "licensing: 84 without the installed files fails" 1 "Step licensing failed"
reset; mkbottle rvt2025-t 2025 2025; mkdist 2025; D="$R/installers/extracted/revit2025"
mkdir -p "$D/3rdParty/x64/VCRedist/2022" "$D/3rdParty/x86/VCRedist/2022" "$D/3rdParty/x86/VCRedist/2019"
touch "$D/3rdParty/x64/VCRedist/2022/VC_redist.x64.exe" "$D/3rdParty/x86/VCRedist/2022/VC_redist.x86.exe"
echo '<Package><InstallFile file="3rdParty/x86/VCRedist/2019/vc.exe" installParams="/q"/></Package>' > "$D/3rdParty/x86/VCRedist/2019/pkg.vc.xml"
rule "vc22x86" 194; run_steps 2025 rvt2025-t vc
expect "vc: 3010 (194) is success" 0 ""; check "vc: in the summary" grep -qE '^   vc +exit=0 ' "$RUN/summary.txt"
check "vc: the VC++ 2022 installers ran" called "[C:\\vc22x64.exe] [/install] [/quiet] [/norestart]"
check "vc: with VC++ 2022 present the XML list is not used" not_called "vc19"
reset; mkbottle rvt2026-t 2026 2026; mkdist 2026; D="$R/installers/extracted/revit2026"
mkdir -p "$D/3rdParty/x64/dotNet/80" "$D/3rdParty/x64/dotNet/100"
touch "$D/3rdParty/x64/dotNet/80/windowsdesktop-runtime-8.0.1-win-x64.exe" "$D/3rdParty/x64/dotNet/100/windowsdesktop-runtime-10.0.0-win-x64.exe"
run_steps 2026 rvt2026-t dotnet; expect "dotnet runs" 0 "dotnet"
check "dotnet: both runtimes, 8 before 10" test "$(grep -o 'netdesk[0-9]*' "$CALLS" | tr '\n' ' ')" = "netdesk80 netdesk100 "
reset; mkbottle rvt2024-t 2024 2024; mkdist 2024; run_steps 2024 rvt2024-t dotnet
expect "dotnet: skipped for .NET Framework years" 0 ""; check "dotnet: in the summary" grep -qE '^   dotnet +exit=skip ' "$RUN/summary.txt"
reset; mkbottle rvt2024-t 2024 2024; mkdist 2024; mkdir -p "$AL2024/16.1.0.1/helper"; ln -s 16.1.0.1 "$AL2024/Current"
run_steps 2024 rvt2024-t register
expect "register runs the licensing helper" 0 ""; check "register: in the summary" grep -qE '^   register +exit=0 +829P1 2024.0.0.F USER' "$RUN/summary.txt"
check "register: product key and version" called "[register] [--pk] [829P1] [--pv] [2024.0.0.F]"

# ---- steps: Revit and fixes ----
reset; mkbottle rvt2024-t 2024 ""; mkdist 2024; D="$R/installers/extracted/revit2024"
mkdir -p "$AL2024/16.1.0.1/helper" "$D/x64/RVTSP"; ln -s 16.1.0.1 "$AL2024/Current"; touch "$D/x64/RVTSP/RVTSP1.msp"
echo '<Package><InstallFile type="MSP" file="x64/RVTSP/RVTSP1.msp"/></Package>' > "$D/x64/pkg.RVTSP.xml"
rule "rvt.cmd" 0 "mkdir -p '$BOTTLES/rvt2024-t/drive_c/Program Files/Autodesk/Revit 2024'; touch '$BOTTLES/rvt2024-t/drive_c/Program Files/Autodesk/Revit 2024/Revit.exe'"
run_steps 2024 rvt2024-t rvt; expect "rvt installs RVT.msi with the update's patch" 0 ""; check "rvt: in the summary" grep -qE '^   rvt +exit=0 ' "$RUN/summary.txt"
check "rvt: the MSP goes in as PATCH (quoted: the sandbox path has a space)" grep -q 'PATCH="Z:.*RVTSP1.msp"' "$RUN/rvt.cmd"
check "rvt: product key and skipped register" grep -q 'ADLM_PRODKEY=829P1 .*CLM_SKIP_REGISTER=1' "$RUN/rvt.cmd"
check "rvt: first asks the licensing service" called "[upgrade] [isUpgraded]"
reset; mkbottle rvt2024-t 2024 ""; mkdist 2024; mkdir -p "$AL2024/16.1.0.1/helper"; ln -s 16.1.0.1 "$AL2024/Current"
run_steps 2024 rvt2024-t rvt; expect "rvt: no Revit.exe afterwards is a failure" 1 "Step rvt failed"
: > "$CALLS"; rule "isUpgraded" 1; run_steps 2024 rvt2024-t rvt
expect "rvt: a silent licensing service stops it" 1 "Step rvt failed"; check "rvt: RVT.msi did not run" not_called "rvt.cmd"
reset; mkbottle rvt2025-t 2025 2025; mkdist 2025; D="$R/installers/extracted/revit2025"; mkdir -p "$D/x64/BAD"
printf '<Packages><Package name="BAD" path="x64/BAD/pkg.BAD.xml"/></Packages>' > "$D/manifest/app.RVT.xml"
echo '<Package><InstallFile type="ADIX" file="x64/BAD/BAD.adix"/></Package>' > "$D/x64/BAD/pkg.BAD.xml"
python3 -I -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1], "w"); z.writestr("Registry.dat", b"garbage"); z.close()' "$D/x64/BAD/BAD.adix"
STEP_ENV=(ODIS_PKGS=BAD); run_steps 2025 rvt2025-t pkgs
expect "pkgs: a broken ADIX registry fails the step" 1 "pkgs"; check "pkgs: failed.txt" grep -qx pkgs "$RUN/failed.txt"
reset; mkbottle rvt2024-t 2024 2024; rm -rf "$BOTTLES/rvt2024-t/drive_c/windows/system32/wbem"; run_steps 2024 rvt2024-t wbemshim
expect "wbemshim: a failed copy fails the step even though nothing after it runs" 1 "wbemshim"
check "wbemshim: no registry change after the failed copy" not_called "4590F811"
reset; mkbottle rvt2024-t 2024 2024; mkdir -p "$R/installers/redist/win7sp1/x64"
for d in riched20 usp10 msls31 msftedit; do echo "ms $d" > "$R/installers/redist/win7sp1/x64/$d.dll"; done
run_steps 2024 rvt2024-t richedit tlbpin; expect "richedit and tlbpin" 0 "tlbpin"
S32="$BOTTLES/rvt2024-t/drive_c/windows/system32"; RV="$BOTTLES/rvt2024-t/drive_c/Program Files/Autodesk/Revit 2024"
check "richedit: msftedit only in system32" test -f "$S32/msftedit.dll" -a ! -e "$RV/msftedit.dll"
check "richedit: riched20 in both" test -f "$S32/riched20.dll" -a -f "$RV/riched20.dll"
check "tlbpin: the shim is msls31.dll, Microsoft's is msls31_ms.dll" grep -q "fake tlbpin" "$RV/msls31.dll"
check "tlbpin: msls31_ms.dll is Microsoft's" grep -q "ms msls31" "$S32/msls31_ms.dll"
reset; mkbottle rvt2024-t 2024 2024; run_steps 2024 rvt2024-t d3d9dxvk wv2fix
expect "d3d9dxvk and wv2fix" 0 "wv2fix"
check "d3d9dxvk: the copy has no builtin marker" grep -q "DXVK native  DLL" "$BOTTLES/rvt2024-t/drive_c/windows/system32/d3d9.dll"
check "wv2fix: version_orig.dll without the marker" grep -q "Wine orig    DLL" "$BOTTLES/rvt2024-t/drive_c/windows/system32/version_orig.dll"
check "wv2fix: native version.dll for the browser only" called "[HKCU\\Software\\Wine\\AppDefaults\\msedgewebview2.exe\\DllOverrides] [/v] [version]"
reset; mkbottle rvt2024-t 2024 2024; run_steps 2024 rvt2024-t pdfprinter
expect "pdfprinter" 0 "pdfprinter"
check "pdfprinter: the port path is quoted for /bin/sh (the sandbox path has a space)" called "|'$R/scripts/ps2pdf-port.sh'"
reset; mkbottle rvt2024-t 2024 2024; P="$BOTTLES/rvt2024-t/drive_c/ProgramData/Autodesk/RVT 2024/UserDataCache"; mkdir -p "$P"
python3 -I -c 'import sys; open(sys.argv[1], "wb").write(b"\xff\xfe" + "[Language]\r\nSelect=en-US\r\n".encode("utf-16-le"))' "$P/Revit.ini"
STEP_ENV=(REVIT_THEME=dark); run_steps 2024 rvt2024-t revitini; expect "revitini" 0 "revitini"
check "revitini: language and theme" grep -q "Select=ENU" <(iconv -f UTF-16 -t UTF-8 "$P/Revit.ini")
check "revitini: dark canvas" grep -q "CanvasTheme=0" <(iconv -f UTF-16 -t UTF-8 "$P/Revit.ini")
reset; mkbottle rvt2026-t 2026 2026; run_steps 2026 rvt2026-t dynamo gdoff
expect "dynamo and gdoff skip what is not there" 0 ""; check "gdoff: in the summary" grep -qE '^   gdoff +exit=skip ' "$RUN/summary.txt"

# ---- steps: add-ins ----
reset; mkbottle rvt2024-t 2024 2024; run_steps 2024 rvt2024-t wpfsw trust check
expect "add-in steps without add-ins" 0 ""; check "trust: in the summary" grep -qE '^   trust +exit=skip +no add-in assemblies' "$RUN/summary.txt"
run_steps 2024 rvt2024-t wpfsw trust check; expect "add-in steps again: still fine" 0 "check"
check "wpfsw sets software WPF" called "[HKCU\\Software\\Microsoft\\Avalon.Graphics] [/v] [DisableHWAcceleration]"
# fake wine rules match its arguments as one string: "reg query HKCU\Software\…"
rule "reg query HKCU\\Software\\Microsoft\\Avalon.Graphics" 1
run_steps 2024 rvt2024-t wpfhw; expect "wpfhw without the value is fine" 0 "wpfhw"
reset; mkbottle rvt2024-t 2024 2024; rule "reg query HKCU\\Software\\Microsoft\\Avalon.Graphics" 67
run_steps 2024 rvt2024-t wpfhw; expect "wpfhw: a failed registry query fails the step" 1 "wpfhw"
reset; mkbottle rvt2024-t 2024 2024; rule "reg delete HKCU\\Software\\Microsoft\\Avalon.Graphics" 1
run_steps 2024 rvt2024-t wpfhw; expect "wpfhw: a failed delete fails the step" 1 "wpfhw"
reset; mkbottle rvt2024-t 2024 2024; run_steps 2024 rvt2024-t revitlookup
expect "revitlookup without its installer says where it goes" 1 "revitlookup"
check "revitlookup: the log names the missing file" grep -q "RevitLookup-2024.3.4-SingleUser.msi" "$RUN/revitlookup.log"
reset; mkbottle rvt2027-t 2027 2027; run_steps 2027 rvt2027-t revitlookup
expect "revitlookup: not set up for 2027 is a skip" 0 ""; check "revitlookup: in the summary" grep -qE '^   revitlookup +exit=skip ' "$RUN/summary.txt"
reset; mkbottle rvt2024-t 2024 2024; run_steps 2024 rvt2024-t enscape
expect "enscape: not set up for 2024" 1 "enscape"

echo; echo "$((n - fails))/$n passed"; [ "$fails" -eq 0 ]
