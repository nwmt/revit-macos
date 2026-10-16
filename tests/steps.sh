#!/usr/bin/env bash
# Tests for the shared libraries, scripts/run-steps.sh and the install steps, in a sandbox: a copy of the repo, a fake
# HOME and a fake CrossOver (REVIT_CX) whose wine records its arguments and follows rules. Runs under /bin/bash 3.2.
# Nothing real is touched. Usage: tests/steps.sh
set -uo pipefail
# every control variable of the engine: none of the caller's may reach the sandbox (a REVIT_DATA or REVIT_SOURCE_LIST
# could point at real folders); tests set what they need after this
CLEAN_ENV=(-u REVIT_DATA -u REVIT_LOCK_DIR -u SHIMS_DIR -u REVIT_BUNDLED -u REVIT_EVENTS_FD -u REVIT_RUN_ID -u REVIT_RUN_CTX
  -u REVIT_ACCEPT_EULA -u REVIT_SOURCE_LIST -u REVIT_REUSE_EXTRACTED -u REVIT_REEXTRACT -u REVIT_UNPACK_AGAIN
  -u REVIT_FOR_BOTTLE -u INSTALL_PARENT -u W_CACHE -u SHIMS_FROM_SOURCE -u RUN_DIR -u RUN_KIND -u CX_RECREATE
  -u INSTALL_DRYRUN -u REVIT_LANG -u ODIS_PKGS -u REVIT_THEME -u REVIT_YEAR)
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
  local f; for f in d3dwp/d3dwp.dll ncryptshim/ncrypt.dll pdfprinter/add_printer.exe rvtfix/rvtfix.dll \
    svcshim/svcshim.exe tlbpin/msls31.dll vkshim/vulkan-1.dll wbemshim/wbemshim.dll wv2fix/version.dll; do
    mkdir -p "$R/build/$(dirname "$f")"; echo "fake $f" > "$R/build/$f"
  done
  sed -n 's/^SHIMS_VERSION=//p' "$R/scripts/lib/shims.sh" > "$R/build/.prebuilt"   # no toolchain: the steps take these
  printf '#!/bin/bash\necho "no toolchain in the sandbox" >&2\nexit 1\n' > "$R/scripts/get-toolchain.sh"
  builtin_dll "$CXF/lib/dxvk/x86_64-windows/d3d9.dll"; builtin_dll "$CXF/lib/wine/x86_64-windows/version.dll"
  cat > "$CXF/bin/wine" <<EOF
#!/bin/bash
# fake wine: records its arguments (and FD9/FD7 when the lock's or the events fd reached it), then the first matching rule of
# $RULES ("<text in the arguments><TAB><exit code><TAB><shell code>") decides; default exit 0
args="\$*"
{ printf 'wine'; for a in "\$@"; do printf ' [%s]' "\$a"; done; [ -e /dev/fd/9 ] && printf ' FD9'; [ -e /dev/fd/7 ] && printf ' FD7'; echo; } >> "$CALLS"
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
SANDBOX_ENV=(env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF")
in_repo() { # $1 = bash code run with ROOT set and common.sh loaded (cwd /, fake HOME and CrossOver). Sets OUT, RC
  OUT="$(cd / && "${SANDBOX_ENV[@]}" ROOT="$R" /bin/bash -c '. "$ROOT/scripts/lib/common.sh"; '"$1" 2>&1)"; RC=$?
}
hold_lock() { # $1 = owner text: a background process that holds the lock like a script would, until stop_bg
  mkdir -p "$H/Library/Application Support/revit-macos"
  /usr/bin/perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die;
    open(my $o, ">", "$ARGV[0].owner") or die; print $o "$ARGV[1]\n"; close $o; sleep 60' "$H/Library/Application Support/revit-macos/lock" "$1" &
  PIDS="$PIDS $!"; sleep 0.5
}

# ---- versions.sh and profiles ----
reset; in_repo 'echo "${REVIT_SUPPORTED[*]}"'; expect "supported years come from the profiles" 0 "2020 2023 2024 2025 2026 2027"
reset; in_repo 'load_profile 2024 && echo "$YEAR $PRODKEY ${#STEPS[@]} ${REVITINI[1]}"'
expect "a profile loads" 0 '2024 829P1 22 Interoperability.RealDWGInstalledLocation=C:\Program Files\Autodesk\RealDWG Shared 2024\'
reset; in_repo 'load_profile 2021'; expect "a year without a profile is not loaded" 1 ""
reset; in_repo 'load_profile 2027; load_profile 2023; echo "[${ENSCAPE}] ${#ADDIN_STEPS[@]}"'
expect "loading a profile clears the previous one" 0 "[] 5"
reset; in_repo '. "$ROOT/scripts/lib/wine.sh"; for f in "$ROOT"/scripts/steps/*.sh; do . "$f"; done
  for y in "${REVIT_SUPPORTED[@]}"; do load_profile "$y"
    for s in ${STEPS[@]+"${STEPS[@]}"} ${ADDIN_STEPS[@]+"${ADDIN_STEPS[@]}"}; do declare -F "step_$s" >/dev/null || echo "missing: $y $s"; done
  done; echo checked'
expect "every step of every profile has a function" 0 "checked"; check "no profile names a missing step" test -z "$(grep missing <<<"$OUT")"
reset; in_repo 'load_profile 2020 && echo "${#STEPS[@]} ${STEPS[0]} ${STEPS[21]}"'; expect "the 2020 profile has its 22 steps" 0 "22 netfx samples"

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
reset; mkdir -p "$T/other/scripts/lib"; cp "$R/scripts/lib/"*.sh "$T/other/scripts/lib/"; cp -R "$R/scripts/profiles" "$T/other/scripts/"
hold_lock "install.sh 2024 rvt2024-t"
OUT="$(cd / && "${SANDBOX_ENV[@]}" ROOT="$T/other" /bin/bash -c '. "$ROOT/scripts/lib/common.sh"; lock_take test; echo took' 2>&1)"; RC=$?
expect "two ROOTs share the lock" 1 "Another task is running: install.sh 2024 rvt2024-t."
stop_bg
reset; in_repo 'REVIT_RUN_ID=r1 REVIT_RUN_CTX=/x/ctx; lock_take "./revit install 2025 rvt2025-a"; cat "$LOCK_FILE.owner"; echo; lock_owner'
expect "the owner file has its fields" 0 "command=./revit install 2025 rvt2025-a"
check "owner: run_id" grep -qx "run_id=r1" <<<"$OUT"
check "owner: ctx" grep -qx "ctx=/x/ctx" <<<"$OUT"
check "owner: pid and its start time" eval 'grep -qE "^pid=[0-9]+$" <<<"$OUT" && grep -qE "^pid_start=[A-Z][a-z]{2} " <<<"$OUT"'
check "lock_owner prints the command only" eval '[ "$(tail -1 <<<"$OUT")" = "./revit install 2025 rvt2025-a" ]'
reset; mkdir -p "$H/Library/Application Support/revit-macos"
printf 'install.sh 2023 rvt2023-a\n' > "$H/Library/Application Support/revit-macos/lock.owner"
in_repo 'lock_owner'; expect "a one-line owner file still names the owner" 0 "install.sh 2023 rvt2023-a"
reset; in_repo 'lock_take --no-trap quiet; trap -p INT; echo end'
check "lock_take --no-trap sets no trap" eval '! grep -q "trap --" <<<"$OUT"'
reset; in_repo 'lock_take test; echo took'; expect "first run creates the lock folder" 0 "took"
check "the lock is outside the repo" test -e "$H/Library/Application Support/revit-macos/lock"
check "no lock in the repo" test ! -e "$R/logs/.lock"
reset; hold_lock holder; mkdir -p "$T/ctx"; in_repo 'REVIT_RUN_CTX="'"$T"'/ctx"; lock_take x'; check "a busy lock is a busy result" grep -qx "result=busy" "$T/ctx/result"

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
reset; mkbottle rvt2024-t 2024 2024; exec 7>"$T/ev7"; in_bottle 'w x'; exec 7>&-
check "wine never gets the events fd" not_called "FD7"
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
reset; mkbottle rvt2024-t 2024 2024; in_bottle 'ensure_shim wbemshim && echo built; ensure_shim nonsense; echo rc=$?'
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
mkdist2020() { # a tiny unpacked Setup.ini installer: multi-part 2020 downloads unpack into one subfolder. Sets D20
  D20="$R/installers/extracted/revit2020/Revit_2020_G1_Win_64bit_r3_dlm"; local d="$D20" v a
  mkdir -p "$d/Setup" "$d/x86/AdskLicensing" "$d/x64/AdSSO" "$d/x64/RCL" "$d/x64/RVT" "$d/x64/RET" \
    "$d/3rdParty/NET/47/wcu/dotNetFramework" "$d/Content/ADSKMaterials/2020/CM" "$d/Content/ADSKMaterials/2020/ILB" \
    "$d/Content/ADSKMaterials/2020/PLB" "$d/Content/ADSKMaterials/2020/PLL"
  echo '[Setup]' > "$d/Setup.ini"
  touch "$d/Setup/RevitConfig.pit" "$d/x86/AdskLicensing/AdskLicensing-installer.exe" "$d/x64/AdSSO/AdSSO.msi" \
    "$d/x64/RCL/RCL.msi" "$d/x64/RVT/RVT.msi" "$d/x64/RET/RET.msi" \
    "$d/3rdParty/NET/47/wcu/dotNetFramework/dotNetFx47_Full_x86_x64.exe" \
    "$d/Content/ADSKMaterials/2020/CM/MaterialLibrary2020.msi" "$d/Content/ADSKMaterials/2020/ILB/BaseImageLibrary2020.msi" \
    "$d/Content/ADSKMaterials/2020/PLB/PrismBaseImageLibrary2020.msi" "$d/Content/ADSKMaterials/2020/PLL/PrismLowImageLibrary2020.msi"
  for a in x86 x64; do
    for v in 2010SP1 2012 2013; do mkdir -p "$d/3rdParty/$a/VCRedist/$v"; touch "$d/3rdParty/$a/VCRedist/$v/vcredist_$a.exe"; done
    for v in 2015 2017; do mkdir -p "$d/3rdParty/$a/VCRedist/$v"; touch "$d/3rdParty/$a/VCRedist/$v/VC_redist.$a.exe"; done
  done
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
reset; mkbottle rvt2020-t 2020 2020; mkdist2020; run_steps 2020 rvt2020-t vc
expect "vc (2020): runs" 0 ""; check "vc (2020): in the summary" grep -qE '^   vc +exit=0 +VC\+\+ 2010 SP1' "$RUN/summary.txt"
check "vc (2020): 2010 SP1, 2012, 2013, 2017, x86 before x64, never 2015" \
  test "$(grep -o 'vc1[0-9]x[0-9]*' "$CALLS" | tr '\n' ' ')" = "vc10x86 vc10x64 vc12x86 vc12x64 vc13x86 vc13x64 vc17x86 vc17x64 "
check "vc (2020): the 2010 overrides" called "[HKCU\\Software\\Wine\\DllOverrides] [/v] [msvcr100] [/d] [native,builtin]"
check "vc (2020): 2017 with its switches" called "[C:\\vc17x64.exe] [/install] [/quiet] [/norestart]"
reset; mkbottle rvt2020-t 2020 2020; mkdist2020; rule "vc12x64" 67; run_steps 2020 rvt2020-t vc
expect "vc (2020): a failed runtime fails the step" 1 "Step vc failed"; check "vc (2020): the others still ran" called "vc17x64"
reset; mkbottle rvt2026-t 2026 2026; mkdist 2026; D="$R/installers/extracted/revit2026"
mkdir -p "$D/3rdParty/x64/dotNet/80" "$D/3rdParty/x64/dotNet/100"
touch "$D/3rdParty/x64/dotNet/80/windowsdesktop-runtime-8.0.1-win-x64.exe" "$D/3rdParty/x64/dotNet/100/windowsdesktop-runtime-10.0.0-win-x64.exe"
run_steps 2026 rvt2026-t dotnet; expect "dotnet runs" 0 "dotnet"
check "dotnet: both runtimes, 8 before 10" test "$(grep -o 'netdesk[0-9]*' "$CALLS" | tr '\n' ' ')" = "netdesk80 netdesk100 "
reset; mkbottle rvt2024-t 2024 2024; mkdist 2024; run_steps 2024 rvt2024-t dotnet
expect "dotnet: skipped for .NET Framework years" 0 ""; check "dotnet: in the summary" grep -qE '^   dotnet +exit=skip ' "$RUN/summary.txt"
release_rule() { rule "NDP\\v4\\Full" 0 "echo '    Release    REG_DWORD    $1'"; }   # $1 = what reg query reports
reset; mkbottle rvt2020-t 2020 2020; mkdist2020; mkdir -p "$R/installers/redist"; touch "$R/installers/redist/dotNetFx40_Full_x86_x64.exe"
release_rule 0x70805; run_steps 2020 rvt2020-t netfx
expect "netfx (2020): .NET Framework 4.7" 0 ""; check "netfx (2020): in the summary" grep -qE '^   netfx +exit=0 +Release=460805' "$RUN/summary.txt"
check "netfx (2020): the installer's 4.7" called "[C:\\dotNetFx47.exe] [/q] [/norestart]"
check "netfx (2020): never 4.8 (Revit 2020 crashes on it)" not_called "dotNetFx48"
check "netfx (2020): back on Windows 10" test "$(grep -o 'winecfg\] \[-v\] \[[a-z0-9]*' "$CALLS" | tail -1)" = "winecfg] [-v] [win10"
reset; mkbottle rvt2020-t 2020 2020; mkdist2020; mkdir -p "$R/installers/redist"; touch "$R/installers/redist/dotNetFx40_Full_x86_x64.exe"
release_rule 0x6040e; run_steps 2020 rvt2020-t netfx
expect "netfx (2020): an older release than 4.7 fails" 1 "Step netfx failed"
reset; mkbottle rvt2024-t 2024 2024; mkdist 2024; mkdir -p "$R/installers/redist" "$R/installers/extracted/revit2024/3rdParty/dotNetFramework/48"
touch "$R/installers/redist/dotNetFx40_Full_x86_x64.exe" "$R/installers/extracted/revit2024/3rdParty/dotNetFramework/48/dotNetFx48_Full_x86_x64.exe"
release_rule 0x80ea8; run_steps 2024 rvt2024-t netfx
expect "netfx (2024): .NET Framework 4.8" 0 ""; check "netfx (2024): the installer's 4.8" called "[C:\\dotNetFx48.exe] [/q] [/norestart]"
# Ctrl-C (SIGINT to the whole process group, as a terminal sends it) while the 4.7 installer runs as Windows 7: the
# installer finishes, the bottle is back on Windows 10, the run stops. perl gives the runner its own group and the
# default SIGINT (a background job of this script would get it ignored)
reset; mkbottle rvt2020-t 2020 2020; mkdist2020; mkdir -p "$R/installers/redist"; touch "$R/installers/redist/dotNetFx40_Full_x86_x64.exe"
rule "dotNetFx47.exe" 0 "sleep 2; touch '$T/net47-done'"; release_rule 0x70805
(cd / && exec "${SANDBOX_ENV[@]}" /usr/bin/perl -e '$SIG{INT}="DEFAULT"; setpgrp(0,0); exec @ARGV' \
  /bin/bash "$R/scripts/run-steps.sh" 2020 rvt2020-t netfx vc) > "$T/out" 2>&1 &
rs=$!; sleep 1; kill -INT -- "-$rs"; wait "$rs"; RC=$?; OUT="$(cat "$T/out")"
expect "Ctrl-C during netfx stops the run" 1 "Stopped."
check "Ctrl-C during netfx: the installer finished" test -f "$T/net47-done"
check "Ctrl-C during netfx: Windows 10 again" test "$(grep -o 'winecfg\] \[-v\] \[[a-z0-9]*' "$CALLS" | tail -1)" = "winecfg] [-v] [win10"
check "Ctrl-C during netfx: vc did not run" not_called "vc10x86"
# a failure while the bottle is Windows XP x64: the step fails and still puts Windows 10 back
reset; mkbottle rvt2020-t 2020 2020; mkdist2020; mkdir -p "$R/installers/redist"; touch "$R/installers/redist/dotNetFx40_Full_x86_x64.exe"
rule "OnlyUseLatestCLR" 5; run_steps 2020 rvt2020-t netfx
expect "netfx: a failed registry change as Windows XP fails the step" 1 "Step netfx failed"
check "netfx failed as Windows XP: Windows 10 again" test "$(grep -o 'winecfg\] \[-v\] \[[a-z0-9]*' "$CALLS" | tail -1)" = "winecfg] [-v] [win10"
check "netfx failed as Windows XP: no 4.7 installer" not_called "dotNetFx47"
reset; mkbottle rvt2024-t 2024 2024; mkdist 2024; mkdir -p "$AL2024/16.1.0.1/helper"; ln -s 16.1.0.1 "$AL2024/Current"
run_steps 2024 rvt2024-t register
expect "register runs the licensing helper" 0 ""; check "register: in the summary" grep -qE '^   register +exit=0 +829P1 2024.0.0.F USER' "$RUN/summary.txt"
check "register: product key and version" called "[register] [--pk] [829P1] [--pv] [2024.0.0.F]"
AL2020="$BOTTLES/rvt2020-t/drive_c/Program Files (x86)/Common Files/Autodesk Shared/AdskLicensing"
reset; mkbottle rvt2020-t 2020 2020; mkdist2020; lic_rule 1 2020; run_steps 2020 rvt2020-t licensing
expect "licensing (2020): its expected 1 is success" 0 ""
check "licensing (2020): the installer from x86/AdskLicensing" called "[C:\\licensing.exe] [--mode] [unattended]"
check "licensing (2020): Current points at the version" test "$(readlink "$AL2020/Current")" = 16.1.0.1
reset; mkbottle rvt2020-t 2020 2020; mkdist2020; lic_rule 84 2020; run_steps 2020 rvt2020-t licensing
expect "licensing (2020): 84 is not its code" 1 "Step licensing failed"
sc_running() { rule "sc query" 0 "echo '        STATE              : 4  RUNNING'"; }
reset; mkbottle rvt2020-t 2020 2020; mkdir -p "$AL2020/16.1.0.1"; ln -s 16.1.0.1 "$AL2020/Current"; sc_running
run_steps 2020 rvt2020-t svcshim; expect "svcshim (2020): the service runs" 0 ""
check "svcshim (2020): the service starts from the version folder, not Current" \
  called '"C:\Program Files (x86)\Common Files\Autodesk Shared\AdskLicensing\svcshim.exe" "C:\Program Files (x86)\Common Files\Autodesk Shared\AdskLicensing\16.1.0.1\AdskLicensingService\AdskLicensingService.exe"]'
reset; mkbottle rvt2020-t 2020 2020; mkdir -p "$AL2020"; sc_running; run_steps 2020 rvt2020-t svcshim
expect "svcshim (2020): no Current link fails" 1 "Step svcshim failed"
reset; mkbottle rvt2024-t 2024 2024; mkdir -p "$AL2024/16.1.0.1"; ln -s 16.1.0.1 "$AL2024/Current"; sc_running
run_steps 2024 rvt2024-t svcshim; expect "svcshim (2024): the service runs" 0 ""
check "svcshim (2024): ImagePath is svcshim.exe alone" called '\AdskLicensing\svcshim.exe"] [/f]'
reset; mkbottle rvt2020-t 2020 2020; mkdist2020; mkdir -p "$AL2020/16.1.0.1/helper"; ln -s 16.1.0.1 "$AL2020/Current"
run_steps 2020 rvt2020-t register
expect "register (2020)" 0 ""; check "register (2020): product key and version" called "[register] [--pk] [829L1] [--pv] [2020.0.0.F]"
check "register (2020): RevitConfig.pit from Setup/" test -f "$BOTTLES/rvt2020-t/drive_c/ProgramData/Autodesk/Revit/Revit 2020/Setup/RevitConfig.pit"

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
# since 2025 Revit.exe comes from an ADIX package (step pkgs), not from RVT.msi: no Revit.exe after it is fine
run_steps 2024 rvt2024-t rvt; expect "rvt: RVT.msi that leaves no Revit.exe is not a failure" 0 ""
: > "$CALLS"; rule "rvt.cmd" 67; run_steps 2024 rvt2024-t rvt; expect "rvt: RVT.msi failing (1603) fails the step" 1 "Step rvt failed"
reset; mkbottle rvt2024-t 2024 ""; mkdist 2024; mkdir -p "$AL2024/16.1.0.1/helper"; ln -s 16.1.0.1 "$AL2024/Current"
: > "$CALLS"; rule "isUpgraded" 1; run_steps 2024 rvt2024-t rvt
expect "rvt: a silent licensing service stops it" 1 "Step rvt failed"; check "rvt: RVT.msi did not run" not_called "rvt.cmd"
reset; mkbottle rvt2020-t 2020 ""; mkdist2020; mkdir -p "$AL2020/16.1.0.1/helper"; ln -s 16.1.0.1 "$AL2020/Current"
run_steps 2020 rvt2020-t rvt; expect "rvt (2020)" 0 ""
check "rvt (2020): Setup.exe's properties" grep -qF 'TRANSFORMS=:en-US.mst;:all.mst ADSK_SETUP_EXE=1 ADSK_EULA_STATUS=#1 ADLM_PRODKEY=829L1 ADLM_EULA_COUNTRY=US INSTALLDIR="C:\Program Files\Autodesk\Revit 2020"' "$RUN/rvt.cmd"
check "rvt (2020): RVT.msi registers itself (no ODIS properties)" test -z "$(grep -E 'CLM_SKIP_REGISTER|REVITLANGUAGE' "$RUN/rvt.cmd")"
reset; mkbottle rvt2020-t 2020 2020; mkdist2020; run_steps 2020 rvt2020-t rcl ret materials
expect "rcl, ret, materials (2020)" 0 ""
check "rcl: into Revit Content 2020" grep -qF 'TRANSFORMS=:en-US.mst ADSK_SETUP_EXE=1 ADSK_EULA_STATUS=#1 ADLM_PRODKEY=829L1 ADLM_EULA_COUNTRY=US INSTALLDIR="C:\Program Files\Autodesk\Revit Content 2020"' "$RUN/rcl.cmd"
check "ret: RET.msi" grep -q 'x64\\RET\\RET.msi' "$RUN/ret.cmd"
check "materials: three libraries" test -f "$RUN/cm.cmd" -a -f "$RUN/cmilb.cmd" -a -f "$RUN/cmplb.cmd"
check "materials: the PLB one is the Prism base library" grep -q PrismBaseImageLibrary2020.msi "$RUN/cmplb.cmd"
check "materials: one line each" test "$(grep -cE '^   (cm|cmilb|cmplb) +exit=0 ' "$RUN/summary.txt")" = 3
reset; mkbottle rvt2020-t 2020 2020; mkdist2020; rule "cmilb.cmd" 67; run_steps 2020 rvt2020-t materials
expect "materials: a failed library fails the step" 1 "materials"; check "materials: the next one still ran" test -f "$RUN/cmplb.cmd"
# msi does not check its file and the fake msiexec succeeds: each step checks its MSI itself
reset; mkbottle rvt2020-t 2020 2020; mkdist2020; rm "$D20/x64/RCL/RCL.msi" "$D20/x64/RET/RET.msi" "$D20/Content/ADSKMaterials/2020/ILB/BaseImageLibrary2020.msi"
run_steps 2020 rvt2020-t rcl ret materials; expect "rcl, ret, materials: a missing MSI fails" 1 ""
check "missing MSI: rcl, ret and materials failed" test "$(tr '\n' ' ' < "$RUN/failed.txt")" = "rcl ret materials "
reset; mkbottle rvt2024-t 2024 2024; mkdist 2024; run_steps 2024 rvt2024-t rcl ret materials
expect "rcl, ret, materials: ODIS installers skip them" 0 ""
check "rcl (2024): skip" grep -qE '^   rcl +exit=skip ' "$RUN/summary.txt"; check "rcl (2024): no msiexec" not_called "[cmd] [/c]"
reset; mkbottle rvt2020-t 2020 2020; S="$BOTTLES/rvt2020-t/drive_c/Program Files/Autodesk/Revit 2020/Samples"; mkdir -p "$S"
touch "$S/rac_basic_sample_project.rvt" "$S/rac_basic_sample_family.rfa"; run_steps 2020 rvt2020-t samples
expect "samples" 0 ""; check "samples: copies in C:\\rvt-tests" test -f "$BOTTLES/rvt2020-t/drive_c/rvt-tests/rac_basic_sample_project.rvt"
rm "$S/rac_basic_sample_family.rfa"; run_steps 2020 rvt2020-t samples; expect "samples: a missing sample fails" 1 "samples"
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
reset; mkbottle rvt2024-t 2024 2024; run_steps 2024 rvt2024-t warpshim
expect "warpshim" 0 "warpshim"
check "warpshim: d3dwp.dll next to Revit.exe" grep -q "fake d3dwp" "$BOTTLES/rvt2024-t/drive_c/Program Files/Autodesk/Revit 2024/d3dwp.dll"
check "warpshim: our version.dll in system32 (it loads rvtfix into the material preview process)" \
  grep -q "fake wv2fix" "$BOTTLES/rvt2024-t/drive_c/windows/system32/version.dll"
check "warpshim: native version.dll for AdPreviewGenerator.exe" called "[HKCU\\Software\\Wine\\AppDefaults\\AdPreviewGenerator.exe\\DllOverrides] [/v] [version]"
check "warpshim: not for the browser (that is wv2fix)" not_called "[HKCU\\Software\\Wine\\AppDefaults\\msedgewebview2.exe\\DllOverrides]"
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
reset; mkbottle rvt2026-t 2026 2026; mkdist 2026; rm -f "$R/installers/extracted/revit2026/manifest/app.RVT.xml"
run_steps 2026 rvt2026-t asc; expect "asc: an unreadable manifest fails the step, not a skip" 1 "asc"

# the whole 2020 profile, in its order, on the fake CrossOver: every step finds what the steps before it left
reset; mkbottle rvt2020-t 2020 ""; mkdist2020; RV20="$BOTTLES/rvt2020-t/drive_c/Program Files/Autodesk/Revit 2020"
mkdir -p "$R/installers/redist/win7sp1/x64" "$T/bin"; touch "$R/installers/redist/dotNetFx40_Full_x86_x64.exe"
for d in riched20 usp10 msls31; do echo "ms $d" > "$R/installers/redist/win7sp1/x64/$d.dll"; done
printf '#!/bin/bash\nexit 0\n' > "$T/bin/winetricks"; chmod +x "$T/bin/winetricks"
lic_rule 1 2020; release_rule 0x70805; sc_running
rule "rvt.cmd" 0 "mkdir -p '$RV20/Samples'; touch '$RV20/Revit.exe' '$RV20/Samples/rac_basic_sample_project.rvt' '$RV20/Samples/rac_basic_sample_family.rfa'"
STEP_ENV=(PATH="$T/bin:$PATH"); run_steps 2020 rvt2020-t
expect "the whole 2020 profile runs" 0 "samples"; miss=""
for s in netfx vc fonts licensing svcshim adsso rcl rvt ret materials register ncryptshim ssoenv wbemshim richedit dynamo \
  d3d9dxvk warpshim rvtfix pdfprinter tlbpin samples; do grep -qE "^   $s +exit=0 " "$RUN/summary.txt" || miss+=" $s"; done
check "2020: every step done (missing:$miss)" test -z "$miss"
check "2020: no failed.txt" test ! -e "$RUN/failed.txt"
check "2020: rvtfix keeps CefSharp's flag off" grep -q '"RVTFIX_CEF_ARGS" = ""' "$BOTTLES/rvt2020-t/cxbottle.conf"

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

# ---- scripts around the install ----
reset; cat > "$CXF/bin/cxbottle" <<EOF
#!/bin/bash
echo "cxbottle \$*" >> "$CALLS"
b=""; while [ \$# -gt 0 ]; do case "\$1" in --bottle) b="\$2"; shift ;; --description) d="\$2"; shift ;; --create) c=1 ;; --delete) x=1 ;; esac; shift; done
[ -n "\${x:-}" ] && rm -rf "$BOTTLES/\$b"
[ -n "\${c:-}" ] && { mkdir -p "$BOTTLES/\$b/drive_c"; printf '[Bottle]\n"Description" = "%s"\n' "\$d" > "$BOTTLES/\$b/cxbottle.conf"; }
exit 0
EOF
chmod +x "$CXF/bin/cxbottle"
OUT="$(cd / && "${SANDBOX_ENV[@]}" /bin/bash "$R/scripts/new-bottle.sh" 2024 rvt2024-t 2>&1)"; RC=$?
expect "new-bottle creates the bottle" 0 "done"
check "new-bottle describes it as Revit <year>" grep -q '"Description" = "Revit 2024"' "$BOTTLES/rvt2024-t/cxbottle.conf"
OUT="$(cd / && "${SANDBOX_ENV[@]}" /bin/bash "$R/scripts/new-bottle.sh" 2024 rvt2024-t 2>&1)"; RC=$?
expect "new-bottle refuses an existing bottle" 1 "already exists"
OUT="$(cd / && "${SANDBOX_ENV[@]}" CX_RECREATE=1 /bin/bash "$R/scripts/new-bottle.sh" 2025 rvt2024-t 2>&1)"; RC=$?
expect "new-bottle: CX_RECREATE checks the year first" 1 "is for Revit 2024, not 2025"
# the fake "Revit" is the fake wine itself: Revit.exe in its arguments and the bottle's drive_c as its folder, so
# revit_running sees it, as it sees the real one
reset; mkbottle rvt2024-t 2024 2024; rule "Revit.exe" 0 "sleep 4"
OUT="$(cd / && "${SANDBOX_ENV[@]}" REVIT_LAUNCH_WAIT=3 /bin/bash "$R/scripts/launch.sh" 2024 rvt2024-t 2>&1)"; RC=$?
expect "launch.sh starts Revit and returns once it runs" 0 "Revit 2024 started (backend default)"
in_repo 'lock_free && echo free'; expect "launch.sh: the Revit it started does not hold the lock" 0 "free"
sleep 4
reset; mkdir -p "$R/installers/revit2025/update"; touch "$R/installers/revit2025/update/Revit_2025_5_0.exe"
python3 -I -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1], "w"); z.writestr("setup.xml", "<Setup/>"); z.close()' "$R/installers/revit2025/RVT_2025_NA_win_db_002_002.zip"
in_repo 'revit_main_installer 2025'; expect "the main installer is not an update" 0 "RVT_2025_NA_win_db_002_002.zip"

# ---- data folder ----
reset; in_repo 'echo "$DATA"'; expect "DATA defaults to ROOT" 0 "$R"
reset; OUT="$(cd / && "${SANDBOX_ENV[@]}" ROOT="$R" REVIT_DATA="$T/data" /bin/bash -c '. "$ROOT/scripts/lib/common.sh"
  run_dir_new rvt2024-t steps; revit_installers 2024; revit_extracted 2024' 2>&1)"; RC=$?
expect "run folders live in DATA" 0 "$T/data/logs/rvt2024-t/"
check "installers live in DATA" grep -qx "$T/data/installers/revit2024" <<<"$OUT"
check "unpacked files live in DATA" grep -qx "$T/data/installers/extracted/revit2024" <<<"$OUT"
reset; mkbottle rvt2024-t 2024 2024; mkdir -p "$T/data"; chmod -R a-w "$R"
OUT="$(cd / && "${SANDBOX_ENV[@]}" REVIT_DATA="$T/data" /bin/bash "$R/scripts/run-steps.sh" 2024 rvt2024-t wpfsw 2>&1)"; RC=$?
chmod -R u+w "$R"
expect "DATA≠ROOT: ROOT stays untouched" 0 "wpfsw"
check "DATA≠ROOT: the run folder is in DATA" test -d "$T/data/logs/rvt2024-t"
check "DATA≠ROOT: nothing new in ROOT" test ! -e "$R/logs"
reset; mkbottle rvt2024-t 2024 2024; mkdir -p "$T/data"
OUT="$(cd / && "${SANDBOX_ENV[@]}" REVIT_DATA="$T/data" /bin/bash "$R/scripts/run-steps.sh" 2024 rvt2024-t pdfprinter 2>&1)"; RC=$?
expect "pdfprinter with DATA runs" 0 "pdfprinter"
check "pdfprinter copies its helper into DATA" test -x "$T/data/libexec/ps2pdf-port.sh"
check "pdfprinter registers the DATA copy" called "|'$T/data/libexec/ps2pdf-port.sh'"
reset; mkbottle rvt2024-t 2024 2024; run_steps 2024 rvt2024-t pdfprinter
check "pdfprinter without DATA registers the repo script" called "|'$R/scripts/ps2pdf-port.sh'"
reset; mkdir -p "$T/shims"; cp -R "$R/build/." "$T/shims/"; rm -rf "$R/build"
OUT="$(cd / && "${SANDBOX_ENV[@]}" ROOT="$R" SHIMS_DIR="$T/shims" REVIT_BUNDLED=1 /bin/bash -c '. "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/shims.sh"
  ensure_shim rvtfix && echo have; shim_dir' 2>&1)"; RC=$?
expect "bundled: ensure_shim takes SHIMS_DIR" 0 "have"
check "bundled: shim_dir is SHIMS_DIR" grep -qx "$T/shims" <<<"$OUT"
check "bundled: no build folder appeared" test ! -e "$R/build"
reset; mkdir -p "$T/shims"; cp -R "$R/build/." "$T/shims/"; rm -f "$T/shims/rvtfix/rvtfix.dll"
OUT="$(cd / && "${SANDBOX_ENV[@]}" ROOT="$R" SHIMS_DIR="$T/shims" REVIT_BUNDLED=1 /bin/bash -c '. "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/shims.sh"
  ensure_shim rvtfix; echo rc=$?' 2>&1)"
check "bundled: a missing shim is an error, not a build" grep -q "rc=1" <<<"$OUT"
reset; mkdir -p "$T/shims"; cp -R "$R/build/." "$T/shims/"; printf '#!/bin/bash\necho GIT >> "%s"\nexit 1\n' "$CALLS" > "$T/git"; chmod +x "$T/git"
OUT="$(cd / && "${SANDBOX_ENV[@]}" PATH="$T:$PATH" SHIMS_DIR="$T/shims" REVIT_BUNDLED=1 /bin/bash "$R/scripts/get-shims.sh" 2>&1)"; RC=$?
expect "bundled: get-shims accepts the bundled release" 0 "prebuilt shims"
check "bundled: get-shims never calls git" not_called "GIT"

echo; echo "$((n - fails))/$n passed"; [ "$fails" -eq 0 ]
