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
  -u INSTALL_DRYRUN -u REVIT_LANG -u ODIS_PKGS -u REVIT_THEME -u REVIT_DEFAULTS -u REVIT_YEAR -u SMOKE_TIMEOUT -u SMOKE_START_WAIT
  -u SMOKE_STALL -u SMOKE_WORKER_WAIT -u SMOKE_POLL -u SMOKE_PREP_TIMEOUT -u REVIT_CX_TMP -u REVIT_WATCH_IDLE -u REVIT_WATCH_LOCK_WAIT -u REVIT_WATCH_LSOF
  -u REVIT_RETINA -u REVIT_KEYS -u SETTINGS_SAVE_WAIT)
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
wait_for() { # $1 = seconds, rest = a command: until it succeeds
  local i; for i in $(seq 1 $(($1 * 10))); do "${@:2}" && return 0; sleep 0.1; done; return 1; }

reset() { # a fresh sandbox: the repo's scripts and tools, fake prebuilt shims, a fake CrossOver
  stop_bg; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"
  mkdir -p "$R" "$H/Applications" "$BOTTLES" "$CXF/bin" "$T/cxtmp" "$CXF/lib/dxvk/x86_64-windows" "$CXF/lib/wine/x86_64-windows" \
    || { echo "sandbox setup failed"; exit 1; }
  cp -R "$REPO/scripts" "$REPO/tools" "$R/"
  mkdir -p "$R/app" && cp "$REPO/app/tools.sh" "$R/app/"   # the pinned Python (scripts/lib/pymcp.sh)
  local f; for f in d3dwp/d3dwp.dll dpapi/dpapi.exe hittest/hittest.exe mcphost/mcphost.exe mcppipes/mcppipes.dll ncryptshim/ncrypt.dll pdfprinter/add_printer.exe rvtfix/rvtfix.dll \
    svcshim/svcshim.exe themeset/themeset.exe tlbpin/msls31.dll vkshim/vulkan-1.dll wbemshim/wbemshim.dll wv2fix/version.dll; do
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
reset; in_repo 'echo "${REVIT_SUPPORTED[*]}"'; expect "supported years come from the profiles" 0 "2020 2021 2023 2024 2025 2026 2027"
reset; in_repo 'load_profile 2024 && echo "$YEAR $PRODKEY ${#STEPS[@]} ${REVITINI[1]}"'
expect "a profile loads" 0 '2024 829P1 21 Interoperability.RealDWGInstalledLocation=C:\Program Files\Autodesk\RealDWG Shared 2024\'
# a version page lists Dynamo under Works only for a year whose install has the dynamo step
reset; in_repo 'for y in "${REVIT_SUPPORTED[@]}"; do load_profile "$y"; in_list dynamo "${STEPS[@]}" && continue
  awk "/^## Works/{f=1; next} /^## /{f=0} f" "'"$REPO"'/versions/$y.md" | grep -qi dynamo && echo "$y lists Dynamo"; done; echo checked'
check "no version page lists Dynamo under Works without the dynamo step" test "$OUT" = checked
reset; in_repo 'load_profile 2022'; expect "a year without a profile is not loaded" 1 ""
reset; in_repo 'load_profile 2027; load_profile 2023; echo "[${ENSCAPE}] ${#ADDIN_STEPS[@]}"'
expect "loading a profile clears the previous one" 0 "[] 5"
reset; in_repo '. "$ROOT/scripts/lib/wine.sh"; for f in "$ROOT"/scripts/steps/*.sh; do . "$f"; done
  for y in "${REVIT_SUPPORTED[@]}"; do load_profile "$y"
    for s in ${STEPS[@]+"${STEPS[@]}"} ${ADDIN_STEPS[@]+"${ADDIN_STEPS[@]}"}; do declare -F "step_$s" >/dev/null || echo "missing: $y $s"; done
  done; echo checked'
expect "every step of every profile has a function" 0 "checked"; check "no profile names a missing step" test -z "$(grep missing <<<"$OUT")"
# ./revit doctor has an entry for every step function (its checks, or why it has none), and none for a step that is gone
reset; in_repo '. "$ROOT/scripts/lib/wine.sh"; for f in "$ROOT"/scripts/steps/*.sh; do . "$f"; done
  declare -F | sed -n "s/^declare -f step_//p" | LC_ALL=C sort | tr "\n" " "; echo
  python3 -I -B -c "import sys; sys.path.insert(0, sys.argv[1]); import doctor; print(chr(32).join(sorted(doctor.FIXES)) + chr(32))" "$ROOT/tools"'
check "doctor's table covers every step function, and only those" eval '[ "$(sed -n 1p <<<"$OUT")" = "$(sed -n 2p <<<"$OUT")" ] && [ -n "$(sed -n 1p <<<"$OUT")" ]'
reset; in_repo 'load_profile 2020; profile_json; load_profile 2027; profile_json'
check "profile_json: one JSON object per profile, with its lists" eval '/usr/bin/perl -MJSON::PP -ne '"'"'my $j = decode_json($_);
  exit 1 unless ref $j->{STEPS} eq "ARRAY" && ref $j->{PKGS} eq "ARRAY" && ref $j->{RICHEDIT} eq "ARRAY"; print "$j->{YEAR} ",
  scalar @{$j->{STEPS}}, " $j->{STEPS}[0] ", scalar @{$j->{PKGS}}, " $j->{DOTNET} [$j->{ENSCAPE}] $j->{RVTFIX_ENV}[0]\n"'"'"' <<<"$OUT" |
  tr "\n" "|" | grep -qxF "2020 23 netfx 0 netfx47 [3] RVTFIX_CEF_ARGS=|2027 25 vc 32 net10 [4] |"'
reset; mkdir -p "$T/real"; ln -s "$T/real" "$T/link"; ln -s "$T/nowhere" "$T/dangling"
in_repo 'for p in "$HOME/not/there/yet" "'"$T"'/link/sub" "'"$T"'/dangling"; do free_gb "$p"; volume_id "$p"; done'
check "free_gb and volume_id: a number for a path that is not there, a link, a link to nothing" \
  eval '[ "$(grep -cE "^[0-9]+$" <<<"$OUT")" = 6 ] && [ "$(sed -n 2p <<<"$OUT")" = "$(stat -f %d "$T")" ]'
reset; in_repo 'load_profile 2020 && echo "${#STEPS[@]} ${STEPS[0]} ${STEPS[22]}"'; expect "the 2020 profile has its 23 steps" 0 "23 netfx mackeys"
reset; in_repo 'for y in "${REVIT_SUPPORTED[@]}"; do load_profile "$y"; in_list pdfprinter "${STEPS[@]}" && echo "$y"; done; echo checked'
expect "no year installs the PDF printer by default" 0 "checked"; check "pdfprinter in no STEPS" test "$OUT" = checked

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
step_t_why()  { echo "first line"; echo; echo "why it failed"; return 1; }
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

# ---- run record: <bottle>/revit-macos/runs.ndjson after a run of its own ----
runs() { echo "$BOTTLES/$1/revit-macos/runs.ndjson"; }
last_run() { # $1 = bottle: its newest record as "kind year result requested=a,b done=… skipped=… failed=… engine=…
  # shims=… crossover=… compatdb_sha256=… revit_build_expected=… run_id=… lines=N"; nothing unless every line is JSON
  /usr/bin/perl -MJSON::PP -ne 'my $x = eval { decode_json($_) }; ref $x eq "HASH" ? ($r = $x) : ($bad = 1); $n++;
    END { exit 3 if $bad || !$r; my $j = sub { join ",", @{$_[0]} };
      print join(" ", @$r{qw(kind year result)}, map("$_=" . $j->($r->{$_}), qw(requested done skipped failed)),
        map("$_=" . ($r->{$_} // "null"), qw(engine shims crossover compatdb_sha256 revit_build_expected run_id)), "lines=$n"), "\n" }' \
    "$(runs "$1")" 2>/dev/null
}
SV="$(sed -n 's/^SHIMS_VERSION=//p' "$REPO/scripts/lib/shims.sh")"
reset; mkbottle rvt2024-t 2024 2024; teststeps; STEP_ENV=(RUN_KIND=addins); run_steps 2024 rvt2024-t t_two t_ok t_skip
expect "run record: the run ends as before" 0 ">> Revit 2024"
check "run record: kind, steps, ok; engine unknown in a copy without .git; the release's shims" test "$(last_run rvt2024-t)" = \
  "addins 2024 ok requested=t_two,t_ok,t_skip done=t_two,t_ok skipped=t_skip failed= engine=unknown shims=$SV crossover=null compatdb_sha256=null revit_build_expected=null run_id=$(basename "$RUN") lines=1"
check "run record: the year is a number" grep -q '"year":2024,' "$(runs rvt2024-t)"
run_x() { /usr/bin/perl -MJSON::PP -ne '$x = decode_json($_)->{extracted}; END { print $x // "null" }' "$(runs "$1")"; }
check "run record: steps that read no unpacked installer name none" test "$(run_x rvt2024-t)" = null
check "run record: nothing about it on the terminal" eval '! grep -q "run record" <<<"$OUT"'
run_steps 2024 rvt2024-t t_fail t_ok
check "run record: a failed step is partial" test "$(last_run rvt2024-t | cut -d' ' -f1-7)" = "steps 2024 partial requested=t_fail,t_ok done=t_ok skipped= failed=t_fail"
check "run record: the second run adds a line; each line is JSON" eval 'last_run rvt2024-t | grep -q " lines=2$"'
reset; mkbottle rvt2024-t 2024 2024; teststeps; mkdist 2024; rule "licensing.exe" 5; run_steps 2024 rvt2024-t licensing t_ok
check "run record: a failed critical step is failed" test "$(last_run rvt2024-t | cut -d' ' -f1-7)" = "steps 2024 failed requested=licensing,t_ok done= skipped= failed=licensing"
check "run record: a step that reads the unpacked installer names its folder" \
  test "$(run_x rvt2024-t)" = "$(cd -P "$R/installers/extracted/revit2024" && pwd)"
reset; mkbottle rvt2024-t 2024 2024; teststeps; rule "t-slow" 0 "sleep 2"
(cd / && exec "${SANDBOX_ENV[@]}" /bin/bash "$R/scripts/run-steps.sh" 2024 rvt2024-t t_slow t_ok) > "$T/out" 2>&1 &
rs=$!; sleep 1; kill -TERM "$rs"; wait "$rs"; RC=$?; OUT="$(cat "$T/out")"
expect "run record: TERM still stops with code 1" 1 "Stopped."
check "run record: TERM during a step is stopped" test "$(last_run rvt2024-t | cut -d' ' -f1-7)" = "steps 2024 stopped requested=t_slow,t_ok done=t_slow skipped= failed="
# ./revit addins, Ctrl-C to the whole process group (python in the EXIT handler gets it too): one record, no noise.
# The Wine program ignores it here, so the step it is in ends done
reset; cp "$REPO/revit" "$REPO/install.sh" "$R/"; mkbottle rvt2024-t 2024 2024; teststeps; rule "t-slow" 0 "trap '' INT; sleep 2"
sed -i '' 's|^ADDIN_STEPS=.*|ADDIN_STEPS=(t_slow t_ok)|' "$R/scripts/profiles/2024.sh"
(cd / && exec "${SANDBOX_ENV[@]}" /usr/bin/perl -e '$SIG{INT}="DEFAULT"; setpgrp(0,0); exec @ARGV' \
  /bin/bash "$R/revit" addins 2024 rvt2024-t) > "$T/out" 2>&1 &
rs=$!; sleep 1; kill -INT -- "-$rs"; wait "$rs"; RC=$?; OUT="$(cat "$T/out")"
expect "run record: supervised Ctrl-C still stops the run" 1 "Stopped."
check "run record: ./revit addins and Ctrl-C: addins, stopped, the run id of ./revit" \
  test "$(last_run rvt2024-t | cut -d' ' -f1-7,13)" = "addins 2024 stopped requested=t_slow,t_ok done=t_slow skipped= failed= run_id=$(ls "$R/logs/runs")"
check "run record: written once, nothing printed about it" \
  eval 'last_run rvt2024-t | grep -q " lines=1$" && ! grep -qiE "record|traceback|terminated|interrupt" <<<"$OUT"'
reset; mkbottle rvt2024-t 2024 2024; teststeps; run_steps 2024 rvt2024-t licensing
expect "run record: a run that ends before its first step" 1 "No unpacked Revit 2024 installer"
check "run record: none before the first step" test ! -e "$BOTTLES/rvt2024-t/revit-macos"
run_steps 2024 rvt2024-t t_ok nonsense; check "run record: none for bad arguments" test ! -e "$BOTTLES/rvt2024-t/revit-macos"
run_steps 2024 rvt2024-x t_ok; check "run record: no bottle, none made" test ! -e "$BOTTLES/rvt2024-x"
mkdir -p "$R/logs/rvt2024-t/given"; STEP_ENV=(INSTALL_PARENT=1 RUN_DIR="$R/logs/rvt2024-t/given"); run_steps 2024 rvt2024-t t_ok t_fail
check "run record: under install.sh the runner writes none" test ! -e "$BOTTLES/rvt2024-t/revit-macos"
reset; mkbottle rvt2024-t 2024 2024; teststeps; mkdir -p "$BOTTLES/rvt2024-t/revit-macos"; chmod 555 "$BOTTLES/rvt2024-t/revit-macos"
run_steps 2024 rvt2024-t t_ok; expect "run record: a folder that cannot be written: a warning, exit 0 as before" 0 "could not write the run record: "
check "run record: one warning line" test "$(grep -c "run record" <<<"$OUT")" = 1
run_steps 2024 rvt2024-t t_fail; expect "run record: a folder that cannot be written: a warning, exit 1 as before" 1 "could not write the run record: "
chmod 755 "$BOTTLES/rvt2024-t/revit-macos"
# what ran it: CrossOver's build (CFBundleVersion), the newest compatdb, ./revit's run id, the app's version
reset; mkbottle rvt2024-t 2024 2024; teststeps; CXA="$T/CrossOver.app/Contents"; mkdir -p "$CXA/SharedSupport"
cp -R "$CXF" "$CXA/SharedSupport/CrossOver"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>26.3</string><key>CFBundleVersion</key><string>26.3.0.39832</string></dict></plist>\n' > "$CXA/Info.plist"
CDB="$H/Library/Application Support/CrossOver"; mkdir -p "$CDB"; printf 'old rules' > "$CDB/compatdb-25.dat"
touch -t 202001010000 "$CDB/compatdb-25.dat"; printf 'new rules' > "$CDB/compatdb-26.dat"; printf 'x' > "$CDB/compatdb-26.dat.sha256"
STEP_ENV=(REVIT_CX="$CXA/SharedSupport/CrossOver" REVIT_RUN_ID=r-test-1); run_steps 2024 rvt2024-t t_ok
check "run record: CrossOver's build, the newest compatdb, the run id" test "$(last_run rvt2024-t | cut -d' ' -f10,11,13)" = \
  "crossover=26.3.0.39832 compatdb_sha256=$(printf 'new rules' | shasum -a 256 | cut -d' ' -f1) run_id=r-test-1"
reset; mkbottle rvt2024-t 2024 2024; teststeps; printf 'app_name=Test App\napp_version=0.0.1\n' > "$R/.app-bundle"; run_steps 2024 rvt2024-t t_ok
check "run record: in the app, its version" test "$(last_run rvt2024-t | cut -d' ' -f8,9)" = "engine=app:0.0.1 shims=$SV"
# a clone: its commit and the tree of the shim sources; +dirty for changed tracked files (shims: new sources too)
reset; mkbottle rvt2024-t 2024 2024; teststeps; rm -f "$R/build/.prebuilt"
G=(git -C "$R" -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false)
"${G[@]}" init -q && "${G[@]}" add -A && "${G[@]}" commit -qm fixture || fail "run record: git fixture" ""
GH="$(git -C "$R" rev-parse --short HEAD)"; GS="$(git -C "$R" rev-parse --short HEAD:tools/shims)"
mkdir -p "$T/gitwrap"; printf '#!/bin/bash\n{ printf "git"; [ -e /dev/fd/9 ] && printf " FD9"; [ -e /dev/fd/7 ] && printf " FD7"; echo; } >> "%s"\nexec "%s" "$@"\n' \
  "$CALLS" "$(command -v git)" > "$T/gitwrap/git"; chmod +x "$T/gitwrap/git"
echo new > "$R/notes.txt"; exec 7>"$T/ev7"; STEP_ENV=(PATH="$T/gitwrap:$PATH"); run_steps 2024 rvt2024-t t_ok; exec 7>&-
check "run record: a clone: commit and shim sources; a new file is no change" test "$(last_run rvt2024-t | cut -d' ' -f8,9)" = "engine=git:$GH shims=source:$GS"
check "run record: git runs without the lock's or the events fd" eval 'called git && not_called FD9 && not_called FD7'
echo "# changed" >> "$R/scripts/lib/versions.sh"; run_steps 2024 rvt2024-t t_ok
check "run record: a changed tracked file: engine +dirty" test "$(last_run rvt2024-t | cut -d' ' -f8,9)" = "engine=git:$GH+dirty shims=source:$GS"
echo "/* new */" > "$R/tools/shims/rvtfix/new.c"; run_steps 2024 rvt2024-t t_ok
check "run record: a new shim source: shims +dirty" test "$(last_run rvt2024-t | cut -d' ' -f9)" = "shims=source:$GS+dirty"

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
reset; cp "$REPO/revit" "$REPO/install.sh" "$R/"; mkbottle rvt2020-t 2020 2020; mkdist2020; mkdir -p "$R/installers/redist"
touch "$R/installers/redist/dotNetFx40_Full_x86_x64.exe"; sed -i '' 's|^ADDIN_STEPS=.*|ADDIN_STEPS=(netfx vc)|' "$R/scripts/profiles/2020.sh"
rule "dotNetFx47.exe" 0 "sleep 2; touch '$T/net47-done'"; release_rule 0x70805
(cd / && exec "${SANDBOX_ENV[@]}" /usr/bin/perl -e '$SIG{INT}="DEFAULT"; setpgrp(0,0); exec @ARGV' \
  /bin/bash "$R/revit" addins 2020 rvt2020-t) > "$T/out" 2>&1 &
rs=$!; sleep 1; kill -INT -- "-$rs"; wait "$rs"; RC=$?; OUT="$(cat "$T/out")"
expect "supervised Ctrl-C during netfx stops the run" 1 "Stopped."
check "supervised Ctrl-C during netfx: the installer finished" test -f "$T/net47-done"
check "supervised Ctrl-C during netfx: Windows 10 again" test "$(grep -o 'winecfg\] \[-v\] \[[a-z0-9]*' "$CALLS" | tail -1)" = "winecfg] [-v] [win10"
check "supervised Ctrl-C during netfx: vc did not run" not_called "vc10x86"
reset; mkbottle rvt2020-t 2020 2020; mkdist2020; mkdir -p "$R/installers/redist"; touch "$R/installers/redist/dotNetFx40_Full_x86_x64.exe"
rule "OnlyUseLatestCLR" 5; run_steps 2020 rvt2020-t netfx
expect "netfx: a failed registry change as Windows XP fails the step" 1 "Step netfx failed"
check "netfx failed as Windows XP: Windows 10 again" test "$(grep -o 'winecfg\] \[-v\] \[[a-z0-9]*' "$CALLS" | tail -1)" = "winecfg] [-v] [win10"
check "netfx failed as Windows XP: no 4.7 installer" not_called "dotNetFx47"
reset; mkbottle rvt2024-t 2024 2024; mkdist 2024; mkdir -p "$AL2024/16.1.0.1/helper"; ln -s 16.1.0.1 "$AL2024/Current"
run_steps 2024 rvt2024-t register
expect "register runs the licensing helper" 0 ""; check "register: in the summary" grep -qE '^   register +exit=0 +829P1 2024.0.0.F USER' "$RUN/summary.txt"
check "register: product key and version" called "[register] [--pk] [829P1] [--pv] [2024.0.0.F]"
# the helper's list is JSON longer than 20 lines: register.log keeps all of it, so it still parses
reset; mkbottle rvt2024-t 2024 2024; mkdist 2024; mkdir -p "$AL2024/16.1.0.1/helper"; ln -s 16.1.0.1 "$AL2024/Current"
rule "InstHelper.exe list" 0 'printf "[\r\n"; for i in $(seq 1 30); do printf "  {\"n\": %d},\r\n" $i; done; printf "  {\"n\": 31}\r\n]\r\n"'
run_steps 2024 rvt2024-t register; expect "register: the list runs" 0 ""
check "register.log holds the whole list as JSON" python3 -I -c 'import json, sys; t = open(sys.argv[1]).read(); json.loads(t[t.index("["):t.rindex("]") + 1])' "$RUN/register.log"
AL2020="$BOTTLES/rvt2020-t/drive_c/Program Files (x86)/Common Files/Autodesk Shared/AdskLicensing"
reset; mkbottle rvt2020-t 2020 2020; mkdist2020; lic_rule 1 2020; run_steps 2020 rvt2020-t licensing
expect "licensing (2020): its expected 1 is success" 0 ""
check "licensing (2020): the installer from x86/AdskLicensing" called "[C:\\licensing.exe] [--mode] [unattended]"
check "licensing (2020): Current points at the version" test "$(readlink "$AL2020/Current")" = 16.1.0.1
reset; mkbottle rvt2020-t 2020 2020; mkdist2020; lic_rule 84 2020; run_steps 2020 rvt2020-t licensing
expect "licensing (2020): 84 is not its code" 1 "Step licensing failed"
sc_running() { rule "sc query" 0 "echo '        STATE              : 4  RUNNING'"; }
reset; mkbottle rvt2020-t 2020 2020; mkdir -p "$AL2020/9.2.2.2501"; ln -s 9.2.2.2501 "$AL2020/Current"; sc_running
run_steps 2020 rvt2020-t svcshim; expect "svcshim (2020): the service runs" 0 ""
check "svcshim (2020): the service starts from the version folder, not Current" \
  called '"C:\Program Files (x86)\Common Files\Autodesk Shared\AdskLicensing\svcshim.exe" "C:\Program Files (x86)\Common Files\Autodesk Shared\AdskLicensing\9.2.2.2501\AdskLicensingService\AdskLicensingService.exe"]'
reset; mkbottle rvt2020-t 2020 2020; mkdir -p "$AL2020"; sc_running; run_steps 2020 rvt2020-t svcshim
expect "svcshim (2020): no Current link fails" 1 "Step svcshim failed"
AL2021="$BOTTLES/rvt2021-t/drive_c/Program Files (x86)/Common Files/Autodesk Shared/AdskLicensing"
reset; mkbottle rvt2021-t 2021 2021; mkdir -p "$AL2021/10.2.0.4231"; ln -s 10.2.0.4231 "$AL2021/Current"; sc_running
run_steps 2021 rvt2021-t svcshim; expect "svcshim (2021, ODIS): the service runs" 0 ""
check "svcshim (2021, ODIS): AdskLicensing 10.2 starts from the version folder" \
  called '\AdskLicensing\10.2.0.4231\AdskLicensingService\AdskLicensingService.exe"]'
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
reset; mkbottle rvt2027-t 2027 2027; run_steps 2027 rvt2027-t downloads; expect "downloads" 0 "downloads"
check "downloads: the folder is in the bottle" test -d "$BOTTLES/rvt2027-t/drive_c/users/crossover/AppData/Local/Downloads"
check "downloads: Windows' Downloads folder points into the bottle" \
  called "[{374DE290-123F-4565-9164-39C4925E467B}] [/t] [REG_EXPAND_SZ] [/d] [%USERPROFILE%\\AppData\\Local\\Downloads]"
# retina, mackeys: registry values for Wine's Mac driver and DPI. Outside an install a step waits until Wine has saved
# them (user.reg, system.reg); here the files are written ahead, as Wine would have saved them, or not at all
regfile() { # $1 = bottle, $2 = user.reg | system.reg, then "[key]" or value lines, as Wine writes them
  local f="$BOTTLES/$1/$2"; shift 2; printf '%s\n' "$@" >> "$f"
}
MD='[Software\\Wine\\Mac Driver] 1792953065'; CPD='[Control Panel\\Desktop] 1792953065'
FHK='[System\\CurrentControlSet\\Hardware Profiles\\Current\\Software\\Fonts] 1792952095'
APPMD='[Software\\Wine\\AppDefaults\\Revit.exe\\Mac Driver] 1792953065'
reset; mkbottle rvt2027-t 2027 2027
regfile rvt2027-t user.reg "$MD" '"RetinaMode"="y"' "" "$CPD" '"LogPixels"=dword:000000c0'
regfile rvt2027-t system.reg "$FHK" '"LogPixels"=dword:000000c0'
STEP_ENV=(RUN_KIND=steps); run_steps 2027 rvt2027-t retina; expect "retina" 0 "RetinaMode=y, LogPixels=192 ("
check "retina: RetinaMode=y for the Mac driver" called "[reg] [add] [HKCU\\Software\\Wine\\Mac Driver] [/v] [RetinaMode] [/d] [y] [/f]"
check "retina: LogPixels 192 for the user" called "[HKCU\\Control Panel\\Desktop] [/v] [LogPixels] [/t] [REG_DWORD] [/d] [192] [/f]"
check "retina: LogPixels 192 for the machine" \
  called "[HKLM\\System\\CurrentControlSet\\Hardware Profiles\\Current\\Software\\Fonts] [/v] [LogPixels] [/t] [REG_DWORD] [/d] [192] [/f]"
check "retina: no note when Wine has saved them" eval '! grep -q "not saved" "$RUN/summary.txt"'
check "retina: the bottle is not stopped" not_called "wineserver"
check "retina: a run of its own is in the run record" test "$(last_run rvt2027-t | cut -d' ' -f1-5)" = "steps 2027 ok requested=retina done=retina"
reset; mkbottle rvt2027-t 2027 2027; STEP_ENV=(REVIT_RETINA=compact SETTINGS_SAVE_WAIT=1); run_steps 2027 rvt2027-t retina
expect "retina=compact: 144, and a note while Wine has not saved it" 0 "RetinaMode=y, LogPixels=144 (Wine has not saved them to disk yet"
reset; mkbottle rvt2027-t 2027 2027; STEP_ENV=(REVIT_RETINA=off SETTINGS_SAVE_WAIT=1); run_steps 2027 rvt2027-t retina
expect "retina=off: RetinaMode=n, 96" 0 "RetinaMode=n, LogPixels=96"
check "retina=off: 96 for the machine too" called "Fonts] [/v] [LogPixels] [/t] [REG_DWORD] [/d] [96] [/f]"
reset; mkbottle rvt2027-t 2027 2027; mkdir -p "$T/run"; STEP_ENV=(REVIT_RETINA=off INSTALL_PARENT=1 RUN_DIR="$T/run")
run_steps 2027 rvt2027-t retina; expect "retina under an install: no wait, no note" 0 "LogPixels=96 ("
check "retina under an install: no note" eval '! grep -q "not saved" "$T/run/summary.txt"'
reset; mkbottle rvt2027-t 2027 2027; STEP_ENV=(REVIT_RETINA=big); run_steps 2027 rvt2027-t retina
expect "retina: an unknown value fails the step" 1 "retina"; check "retina: the log says why" grep -q "unknown REVIT_RETINA=big" "$RUN/retina.log"
check "retina: nothing written for an unknown value" not_called "[RetinaMode]"
reset; mkbottle rvt2027-t 2027 2027; rule "reg add HKCU\\Software\\Wine\\Mac Driver /v RetinaMode" 1; run_steps 2027 rvt2027-t retina
expect "retina: a failed reg add fails the step" 1 "retina"; check "retina: no LogPixels after a failed RetinaMode" not_called "[LogPixels]"
reset; mkbottle rvt2027-t 2027 2027; regfile rvt2027-t user.reg "$MD" '"LeftCommandIsCtrl"="y"' '"RightCommandIsCtrl"="y"' '"LeftOptionIsAlt"="y"'
rule "reg query HKCU\\Software\\Wine\\AppDefaults\\Revit.exe\\Mac Driver" 1; run_steps 2027 rvt2027-t mackeys
expect "mackeys" 0 "Cmd → Ctrl, left Option → Alt ("
check "mackeys: Cmd is Ctrl, left Option is Alt" eval 'called "Mac Driver] [/v] [LeftCommandIsCtrl] [/d] [y] [/f]" &&
  called "Mac Driver] [/v] [RightCommandIsCtrl] [/d] [y] [/f]" && called "Mac Driver] [/v] [LeftOptionIsAlt] [/d] [y] [/f]"'
check "mackeys: no Revit.exe values to remove" not_called "[delete]"
check "mackeys: no note when Wine has saved them" eval '! grep -q "not saved" "$RUN/summary.txt"'
reset; mkbottle rvt2027-t 2027 2027; regfile rvt2027-t user.reg "$MD" '"LeftCommandIsCtrl"="y"' '"RightCommandIsCtrl"="y"' '"LeftOptionIsAlt"="y"' \
  "" "$APPMD" '"LeftCommandIsCtrl"="n"'
STEP_ENV=(SETTINGS_SAVE_WAIT=1); run_steps 2027 rvt2027-t mackeys
check "mackeys: values for Revit.exe, which Wine reads first, are removed" eval 'called "[reg] [delete] [HKCU\\Software\\Wine\\AppDefaults\\Revit.exe\\Mac Driver] [/v] [LeftCommandIsCtrl] [/f]" &&
  called "[delete] [HKCU\\Software\\Wine\\AppDefaults\\Revit.exe\\Mac Driver] [/v] [LeftOptionIsAlt] [/f]"'
expect "mackeys: a note while the removed value is still on disk" 0 "(Wine has not saved them to disk yet"
reset; mkbottle rvt2027-t 2027 2027; rule "reg query HKCU\\Software\\Wine\\AppDefaults\\Revit.exe\\Mac Driver" 2
run_steps 2027 rvt2027-t mackeys; expect "mackeys: a failed reg query fails the step" 1 "mackeys"
check "mackeys: the log says why" grep -q "reg query returned 2" "$RUN/mackeys.log"; check "mackeys: nothing written then" not_called "[add]"
reset; mkbottle rvt2027-t 2027 2027; rule "reg query HKCU\\Software\\Wine\\AppDefaults" 1; STEP_ENV=(REVIT_KEYS=windows SETTINGS_SAVE_WAIT=1)
run_steps 2027 rvt2027-t mackeys; expect "mackeys=windows: Wine's default, with the note" 0 "Cmd → Alt, Option types characters (Wine's default) (Wine has not"
check "mackeys=windows: n" called "Mac Driver] [/v] [LeftCommandIsCtrl] [/d] [n] [/f]"
reset; mkbottle rvt2027-t 2027 2027; STEP_ENV=(REVIT_KEYS=pc); run_steps 2027 rvt2027-t mackeys
expect "mackeys: an unknown value fails the step" 1 "mackeys"; check "mackeys: nothing done for it" not_called "[reg]"
# theme: themeset.exe and the mode file in the bottle, Revit.ini, the Windows theme; outside an install the Revit app
# again (make-apps.sh here records its call and fails while $T/apps-fail exists)
TDIR="$BOTTLES/rvt2027-t/drive_c/Program Files/revit-macos"
UINI="$BOTTLES/rvt2027-t/drive_c/users/crossover/AppData/Roaming/Autodesk/Revit/Autodesk Revit 2027/Revit.ini"
SINI="$BOTTLES/rvt2027-t/drive_c/ProgramData/Autodesk/RVT 2027/UserDataCache/Revit.ini"
PZ='[Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize] 1792953065'
theme_sandbox() { # $1 = what the fake defaults says (Dark or nothing); Revit.ini in the profile, and in the seed with $2=seed
  reset; mkbottle rvt2027-t 2027 2027; mkdir -p "$(dirname "$UINI")" "$T/bin"
  python3 -I -c 'import sys; open(sys.argv[1], "wb").write(b"\xff\xfe" + "[AppFrame]\r\nTheme=0\r\n[Colors]\r\nCanvasTheme=0\r\n".encode("utf-16-le"))' "$UINI"
  [ "${2:-}" != seed ] || { mkdir -p "$(dirname "$SINI")"; cp "$UINI" "$SINI"; }
  printf '#!/bin/bash\n[ -z "%s" ] || echo %s\n' "$1" "$1" > "$T/bin/defaults"; chmod +x "$T/bin/defaults"
  printf '#!/bin/bash\necho "make-apps $*" >> "%s"\n[ ! -e "%s" ]\n' "$CALLS" "$T/apps-fail" > "$R/scripts/make-apps.sh"
}
ini() { iconv -f UTF-16 -t UTF-8 "$1" | tr -d '\r'; }
theme_run() { STEP_ENV=(REVIT_DEFAULTS="$T/bin/defaults" SETTINGS_SAVE_WAIT=1 "$@"); run_steps 2027 rvt2027-t theme; }
theme_sandbox Dark seed; theme_run; expect "theme (mac) on a dark Mac" 0 "theme follows the Mac (dark now); Revit.ini: 2 file(s)"
check "theme: themeset.exe and the mode file in the bottle" eval '[ "$(cat "$TDIR/themeset.exe")" = "fake themeset/themeset.exe" ] &&
  [ "$(cat "$TDIR/theme")" = mac ] && [ ! -e "$TDIR/theme.new" ] && [ ! -e "$TDIR/themeset.exe.new" ]'
check "theme: Revit follows the system theme, the view too, in both Revit.ini" eval 'for f in "$UINI" "$SINI"; do
  ini "$f" | grep -qx FollowSystemColorTheme=1 && ini "$f" | grep -qx CanvasTheme=1 || exit 1; done'
check "theme: the Windows theme dark, from the bottle's themeset.exe" called "[C:\\Program Files\\revit-macos\\themeset.exe] [dark]"
check "theme: the Revit app again, Revit's alone" called "make-apps 2027 rvt2027-t --revit-only"
theme_sandbox ""; regfile rvt2027-t user.reg "$PZ" '"AppsUseLightTheme"=dword:00000001'; theme_run
expect "theme (mac) on a light Mac: no note once Wine has saved it" 0 "theme follows the Mac (light now); Revit.ini: 1 file(s)"
check "theme: the Windows theme light" called "themeset.exe] [light]"; check "theme: no save note" eval '! grep -q "not saved" "$RUN/summary.txt"'
theme_sandbox Dark; theme_run REVIT_THEME=light; expect "theme=light on a dark Mac: fixed light" 0 "theme fixed: light"
check "theme=light: Revit's own setting, light, the view light" eval 'ini "$UINI" | grep -qx FollowSystemColorTheme=0 &&
  ini "$UINI" | grep -qx Theme=1 && ini "$UINI" | grep -qx CanvasTheme=1 && [ "$(cat "$TDIR/theme")" = light ]'
check "theme=light: the Windows theme light too" called "themeset.exe] [light]"
theme_sandbox ""; theme_run REVIT_THEME=dark; expect "theme=dark" 0 "theme fixed: dark"
check "theme=dark: Theme=0, CanvasTheme=0, Windows dark" eval 'ini "$UINI" | grep -qx Theme=0 && ini "$UINI" | grep -qx CanvasTheme=0 &&
  called "themeset.exe] [dark]"'
theme_sandbox ""; theme_run REVIT_THEME=blue; expect "theme: an unknown value fails the step" 1 "theme"
check "theme: nothing done for it" eval 'grep -q "unknown REVIT_THEME=blue" "$RUN/theme.log" && [ ! -e "$TDIR" ] && not_called themeset'
theme_sandbox ""; rule "themeset.exe" 3; theme_run; expect "theme: a Revit window that did not answer is no failure" 0 "theme follows"
theme_sandbox ""; rule "themeset.exe" 1; theme_run; expect "theme: themeset failing fails the step" 1 "theme"
check "theme: the log says why" grep -q "themeset.exe returned 1" "$RUN/theme.log"
theme_sandbox ""; : > "$T/apps-fail"; theme_run; expect "theme: the Revit app not made fails the step" 1 "theme"
rm "$T/apps-fail"; theme_run; expect "theme again after that: done" 0 "theme follows"
check "theme again: the Revit app made" eval '[ "$(grep -c "make-apps 2027 rvt2027-t --revit-only" "$CALLS")" = 2 ]'
theme_sandbox ""; theme_run INSTALL_PARENT=1; expect "theme under an install" 0 "theme follows"
check "theme under an install: no Revit app (the plan's apps comes later)" not_called "make-apps"
theme_sandbox Dark; rm "$UINI"; STEP_ENV=(RUN_KIND=steps); theme_run; expect "theme without Revit.ini yet" 0 "Revit.ini: 0 file(s)"
reset; mkbottle rvt2027-t 2027 2027; mkdir -p "$(dirname "$UINI")"
python3 -I -c 'import sys; open(sys.argv[1], "wb").write(b"\xff\xfe" + "[Language]\r\nSelect=en-US\r\n".encode("utf-16-le"))' "$UINI"
STEP_ENV=(REVIT_THEME=dark); run_steps 2027 rvt2027-t revitini; expect "revitini 2027" 0 "revitini"
check "revitini 2027: anti-aliasing off, the theme left to the step theme" eval 'ini "$UINI" | grep -qx Antialiasing=0 &&
  ! ini "$UINI" | grep -q -e "^Theme=" -e FollowSystemColorTheme -e CanvasTheme'
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
rule "dotNetFx47.exe" 0 "mkdir -p '$BOTTLES/rvt2020-t/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319'; touch '$BOTTLES/rvt2020-t/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/clr.dll'"
STEP_ENV=(PATH="$T/bin:$PATH"); run_steps 2020 rvt2020-t
expect "the whole 2020 profile runs" 0 "samples"; miss=""
check "a run without failed steps prints no file error" eval '! grep -q "No such file" <<<"$OUT"'
for s in netfx vc fonts licensing svcshim adsso rcl rvt ret materials register ncryptshim ssoenv wbemshim richedit dynamo \
  d3d9dxvk warpshim rvtfix tlbpin samples; do grep -qE "^   $s +exit=0 " "$RUN/summary.txt" || miss+=" $s"; done
check "2020: every step done (missing:$miss)" test -z "$miss"
check "2020: no failed.txt" test ! -e "$RUN/failed.txt"
check "2020: rvtfix keeps CefSharp's flag off" grep -q '"RVTFIX_CEF_ARGS" = ""' "$BOTTLES/rvt2020-t/cxbottle.conf"
# ./revit doctor after it: every check of the fixes is ok (the fake wine writes no registry: those checks come later)
doctor_fixes() { # $1 = year, $2 = bottle: "<id> <status>" of each check of the fixes group that is not ok, then fixes=<count>
  cp "$REPO/revit" "$R/revit"
  (cd / && "${SANDBOX_ENV[@]}" /bin/bash "$R/revit" doctor "$1" "$2" --json 2>/dev/null) | /usr/bin/perl -MJSON::PP -e '
    my $j = eval { decode_json(join "", <STDIN>) } or do { print "no JSON\n"; exit }; my $n = 0;
    for (@{$j->{checks}}) { next unless $_->{group} eq "fixes"; $n++; print "$_->{id} $_->{status}\n" if $_->{status} ne "ok" }
    print "fixes=$n\n"'
}
OUT="$(doctor_fixes 2020 rvt2020-t)"
check "doctor 2020: every fix it checks is in place" grep -qxE "fixes=(1[0-9]|[2-9][0-9])" <<<"$OUT"
check "doctor 2020: none of them fails" test "$(wc -l <<<"$OUT" | tr -d ' ')" = 1

# the whole 2026 profile, then doctor: all of its fixes ok; one artifact removed or changed: exactly its check fails
reset; mkbottle rvt2026-t 2026 ""; mkdist 2026; D="$R/installers/extracted/revit2026"; C26="$BOTTLES/rvt2026-t/drive_c"
RV26="$C26/Program Files/Autodesk/Revit 2026"; WV26="$C26/Program Files (x86)/Microsoft/EdgeWebView/Application/141.0.3537.71"
mkdir -p "$D/3rdParty/x64/VCRedist/2022" "$D/3rdParty/x86/VCRedist/2022" "$D/3rdParty/x64/dotNet/80" "$D/3rdParty/x64/WebView2" \
  "$D/x64/ONE" "$R/installers/redist/win7sp1/x64" "$R/installers/redist/webview2" "$T/bin"
touch "$R/installers/redist/webview2/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"   # the fresh one, as get-redist.sh leaves it
touch "$D/3rdParty/x64/VCRedist/2022/VC_redist.x64.exe" "$D/3rdParty/x86/VCRedist/2022/VC_redist.x86.exe" "$D/x64/ONE/one.msi" \
  "$D/3rdParty/x64/dotNet/80/windowsdesktop-runtime-8.0.1-win-x64.exe" "$D/3rdParty/x64/WebView2/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
printf '<Packages><Package name="ONE" path="x64/ONE/pkg.ONE.xml"/></Packages>' > "$D/manifest/app.RVT.xml"
echo '<Package><InstallFile type="MSI" file="x64/ONE/one.msi"/></Package>' > "$D/x64/ONE/pkg.ONE.xml"
for d in riched20 usp10 msls31 msftedit; do echo "ms $d" > "$R/installers/redist/win7sp1/x64/$d.dll"; done
printf '#!/bin/bash\nexit 0\n' > "$T/bin/winetricks"; chmod +x "$T/bin/winetricks"
lic_rule 84 2026; sc_running
rule "netdesk80" 0 "mkdir -p '$C26/Program Files/dotnet/shared/Microsoft.WindowsDesktop.App/8.0.1'"
rule "idmgr.exe" 0 "mkdir -p '$C26/Program Files/Autodesk/AdskIdentityManager/1.2.3'"
rule "rvt.cmd" 0 "mkdir -p '$RV26'; touch '$RV26/Revit.exe'"
rule "webview2.exe" 0 "mkdir -p '$WV26'; touch '$WV26/msedgewebview2.exe'"
STEP_ENV=(PATH="$T/bin:$PATH" ODIS_PKGS=ONE); run_steps 2026 rvt2026-t
expect "the whole 2026 profile runs" 0 "wv2fix"; check "2026: no failed.txt" test ! -e "$RUN/failed.txt"
OUT="$(doctor_fixes 2026 rvt2026-t)"
check "doctor 2026: every fix it checks is in place" grep -qxE "fixes=(1[5-9]|[2-9][0-9])" <<<"$OUT"
check "doctor 2026: nothing else" test "$(wc -l <<<"$OUT" | tr -d ' ')" = 1
rm "$RV26/d3dwp.dll"; OUT="$(doctor_fixes 2026 rvt2026-t)"
check "doctor: a removed fix file fails its own check only" test "$(sed '$d' <<<"$OUT")" = "fixes.warpshim.revit.d3dwp.dll fail"
cp "$R/build/d3dwp/d3dwp.dll" "$RV26/"; printf 'x' >> "$C26/windows/system32/version_orig.dll"; OUT="$(doctor_fixes 2026 rvt2026-t)"
check "doctor: a changed copy of a CrossOver file warns on its own check only" \
  test "$(sed '$d' <<<"$OUT")" = "fixes.warpshim.system32.version_orig.dll warn"
python3 -I "$R/tools/pe_mark.py" "$CXF/lib/wine/x86_64-windows/version.dll" "$C26/windows/system32/version_orig.dll" "Wine orig    DLL"
rm -rf "$WV26"; OUT="$(doctor_fixes 2026 rvt2026-t)"
check "doctor: a missing WebView2 runtime fails its own check only" test "$(sed '$d' <<<"$OUT")" = "fixes.webview2 fail"

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
reset; mkbottle rvt2024-t 2024 2024; printf '#!/bin/bash\nexit 22\n' > "$T/curl"; chmod +x "$T/curl"   # never the real GitHub
STEP_ENV=(PATH="$T:$PATH"); run_steps 2024 rvt2024-t revitlookup
expect "revitlookup without its installer says where it goes" 1 "revitlookup"
check "revitlookup: the log names the missing file" grep -q "RevitLookup-2024.3.4-SingleUser.msi" "$RUN/revitlookup.log"
reset; mkbottle rvt2027-t 2027 2027; printf '#!/bin/bash\nexit 22\n' > "$T/curl"; chmod +x "$T/curl"
STEP_ENV=(PATH="$T:$PATH"); run_steps 2027 rvt2027-t revitlookup
expect "revitlookup 2027 without its installer says where it goes" 1 "revitlookup"
check "revitlookup 2027: the log names its file" grep -q "RevitLookup-2027.0.4-SingleUser.msi" "$RUN/revitlookup.log"
reset; mkbottle rvt2024-t 2024 2024; run_steps 2024 rvt2024-t enscape
expect "enscape: not set up for 2024" 1 "enscape"
pyrevit_bottle() { # $1 = year, $2 = installer under installers/addins/: bottle rvt<year>-t whose fake installer leaves
  # the admin config in ProgramData, as pyRevit 4.8's does. Sets PYU (the user config) and PYA (the admin config)
  local pd="$BOTTLES/rvt$1-t/drive_c/ProgramData/pyRevit"
  mkbottle "rvt$1-t" "$1" "$1"; mkdir -p "$R/installers/addins/$(dirname "$2")"; touch "$R/installers/addins/$2"
  rule "pyRevit-setup.exe" 0 "mkdir -p '$pd' && echo admin > '$pd/pyRevit_config.ini'"
  PYA="$pd/pyRevit_config.ini"; PYU="$BOTTLES/rvt$1-t/drive_c/users/crossover/AppData/Roaming/pyRevit/pyRevit_config.ini"
}
reset; pyrevit_bottle 2020 pyrevit48/pyRevit_4.8.12.22247_signed.exe; run_steps 2020 rvt2020-t pyrevit
expect "pyrevit 2020 installs" 0 "pyrevit"; check "pyrevit 2020: attached to Revit 2020" called "[attach] [master] [277] [2020]"
check "pyrevit 2020: the admin config is copied to the user's" cmp -s "$PYA" "$PYU"
reset; pyrevit_bottle 2020 pyrevit48/pyRevit_4.8.12.22247_signed.exe; mkdir -p "$(dirname "$PYU")"; echo mine > "$PYU"
run_steps 2020 rvt2020-t pyrevit; expect "pyrevit 2020 with a user config installs" 0 "pyrevit"
check "pyrevit 2020: an existing user config is kept" grep -qx mine "$PYU"
reset; pyrevit_bottle 2024 pyrevit7/pyRevit_7.0.0.26278_signed.exe; run_steps 2024 rvt2024-t pyrevit
expect "pyrevit 2024 installs" 0 "pyrevit"; check "pyrevit 7: no user config made" test ! -e "$PYU"

# ---- add-in catalog ----
reset; in_repo '. "$ROOT/scripts/lib/addins.sh"; echo "${ADDIN_IDS[*]}"'; expect "the catalog lists its add-ins" 0 "enscape pdfprinter pyrevit python-mcp revitlookup"
reset; in_repo '. "$ROOT/scripts/lib/addins.sh"; for id in "${ADDIN_IDS[@]}"; do addin_load "$id" || echo "bad $id"
    [ -n "$ADDIN_NAME" ] && [ -n "$ADDIN_STEP" ] || echo "fields $id"; declare -F "addin_files" >/dev/null || echo "files $id"
    for y in "${REVIT_SUPPORTED[@]}"; do addin_files "$y" | while IFS=$'"'"'\t'"'"' read -r s f u h; do
      case "$s" in tool) ;; auto) [[ "$h" =~ ^[0-9a-f]{64}$ ]] && [[ "$u" =~ ^https://github.com/ ]] || echo "auto $id $y" ;; own) ;; *) echo "src $id $y" ;; esac; done; done; done; echo checked'
expect "every catalog file is complete, every auto file has a URL and a sha256" 0 "checked"
check "catalog: no problems" test "$OUT" = checked
reset; in_repo '. "$ROOT/scripts/lib/addins.sh"; load_profile 2020; addin_plan revitlookup; echo; load_profile 2025; addin_plan pdfprinter; echo; addin_plan revitlookup pyrevit'
check "2020: RevitLookup without wpfsw" grep -qx "revitlookup trust check" <<<"$OUT"
check "pdfprinter alone: no wpfsw, no trust" grep -qx "pdfprinter check" <<<"$OUT"
check "2025: RevitLookup and pyRevit, trust then wpfsw once" grep -qx "revitlookup pyrevit trust wpfsw check" <<<"$OUT"
reset; mkbottle rvt2020-t 2020 2020; mkdir -p "$R/installers/addins/enscape" "$R/installers/redist/nuget"
touch "$R/installers/addins/enscape/Enscape-3.4.4-94564.msi" "$R/installers/redist/nuget/system.valuetuple.4.5.0.nupkg"
run_steps 2020 rvt2020-t enscape; expect "enscape without EULA consent refuses" 1 "enscape"
check "enscape: the log says how to accept" grep -q "REVIT_ACCEPT_EULA=enscape" "$RUN/enscape.log"
check "enscape: no installer ran" not_called "Enscape.msi"
reset; mkbottle rvt2024-t 2024 2024; printf '#!/bin/bash\necho "curl $*" >> "%s"; exit 22\n' "$CALLS" > "$T/curl"; chmod +x "$T/curl"
OUT="$(cd / && "${SANDBOX_ENV[@]}" PATH="$T:$PATH" /bin/bash "$R/scripts/run-steps.sh" 2024 rvt2024-t revitlookup 2>&1)"; RC=$?
expect "revitlookup without its file tries to download it" 1 "revitlookup"
check "revitlookup: the download is from GitHub" called "curl -fL"
reset; in_repo '. "$ROOT/scripts/lib/addins.sh"; for y in "${REVIT_SUPPORTED[@]}"; do load_profile "$y"
    addin_load revitlookup; [ -z "$LOOKUP" ] || addin_files "$y" | cut -f2 | grep -qx "$LOOKUP" || echo "lookup $y"
    addin_load pyrevit; [ -z "$PYREVIT" ] || addin_files "$y" | cut -f2 | grep -qx "$PYREVIT" || echo "pyrevit $y"; done; echo checked'
expect "the catalog names the files the profiles name" 0 "checked"; check "catalog = profiles" test "$OUT" = checked

# ---- the Revit MCP Server: ready for ./revit mcp (files only) ----
mcp_bottle() { # $1 = bottle, $2 = variant folder: a 2027 bottle with that MCP Server variant installed and ready
  local b="$BOTTLES/$1" d="$BOTTLES/$1/drive_c/Program Files/Autodesk/$2" s
  mkbottle "$1" 2027 2027; mkdir -p "$d" "$b/drive_c/Program Files/Autodesk/Revit/Addins/2027" "$b/drive_c/ProgramData/revit-macos" \
    "$b/drive_c/Program Files/Common Files/Autodesk/AdpDesktopSDK/bin"
  for s in mcphost/mcphost.exe mcppipes/mcppipes.dll; do
    [ -f "$R/build/$s" ] || { mkdir -p "$R/build/$(dirname "$s")"; echo "fake $s" > "$R/build/$s"; }
    cp "$R/build/$s" "$d/"
  done
  touch "$d/Autodesk.RevitMcpServer.Stdio.exe" "$b/drive_c/Program Files/Common Files/Autodesk/AdpDesktopSDK/bin/AdpSDKCore.dll"
  printf '<?xml version="1.0" encoding="utf-8"?>\r\n<RevitAddIns>\r\n\t<AddIn Type="Application">\r\n\t\t<Assembly>C:\\Program Files\\Autodesk\\%s\\Autodesk.RevitMcpServer.Addin.dll</Assembly>\r\n\t</AddIn>\r\n</RevitAddIns>\r\n' \
    "$2" > "$b/drive_c/Program Files/Autodesk/Revit/Addins/2027/Autodesk.RevitMcpServer.addin"
  echo 6.3.44.3 > "$b/drive_c/ProgramData/revit-macos/adp"
}
MCPW="Revit 2027 MCP Server Write-Tools Technical Preview"; MCPE="Revit 2027 MCP Server Experimental-Tools Technical Preview"
mcp_state() { # bash code that changes bottle rvt2027-t first; prints "<variant>|<missing>" for both variants, then
  # "ready" (mcp_ready) and "catalog" (the catalog's addin_is_installed) for Write-Tools
  in_repo '. "$ROOT/scripts/lib/addins.sh"; load_profile 2027; B="$BOTTLES/rvt2027-t"; D="$(mcp_folder revitmcp)"; '"$1"'
    echo "$(mcp_installed_variant)|$(mcp_missing revitmcp)|$(mcp_missing revitmcp-experimental)"; mcp_ready revitmcp && echo ready
    addin_load revitmcp && addin_is_installed && echo catalog'
}
reset; mcp_bottle rvt2027-t "$MCPW"; mcp_state ''
check "mcp: a complete Write-Tools install is ready" test "$OUT" = "revitmcp||the MCP Server files
ready
catalog"
reset; mcp_bottle rvt2027-t "$MCPE"; mcp_state ''
check "mcp: a complete Experimental install is ready as that variant" grep -qx "revitmcp-experimental|the MCP Server files|" <<<"$OUT"
for c in 'rm "$D/Autodesk.RevitMcpServer.Stdio.exe"|the MCP Server files' \
  'rm "$(mcp_manifest)"|the MCP add-in manifest' \
  'sed -i "" "s/Write-Tools/Experimental-Tools/" "$(mcp_manifest)"|an add-in manifest for this variant' \
  'rm "$D/mcphost.exe"|mcphost.exe' 'rm "$D/mcppipes.dll"|mcppipes.dll' \
  'echo other >> "$D/mcphost.exe"|the current mcphost.exe' 'echo other >> "$D/mcppipes.dll"|the current mcppipes.dll' \
  'rm "$(mcp_adp_marker)"|Autodesk analytics (ADP)' ': > "$(mcp_adp_marker)"|Autodesk analytics (ADP)' \
  'rm "$(mcp_adp_core)"|Autodesk analytics (ADP)'; do
  i=$((${i:-0} + 1)); reset; mcp_bottle rvt2027-t "$MCPW"; mcp_state "${c%|*}"
  check "mcp: not ready without ${c#*|} (case $i)" eval 'grep -q "|${c#*|}|" <<<"$OUT" && ! grep -qx -e ready -e catalog <<<"$OUT"'
  mcp_bottle rvt2027-t "$MCPW"; mcp_state ''
  check "mcp: ready again once ${c#*|} is back (case $i)" eval 'grep -qx ready <<<"$OUT" && grep -qx catalog <<<"$OUT"'
done
reset; mkbottle rvt2027-t 2027 2027; mcp_state 'echo "$(mcp_adp_version)|$?"'
check "mcp: no installer, no ADP version, nothing ready" test "$OUT" = "|1
|the MCP Server files|the MCP Server files"
reset; mkdir -p "$R/installers/extracted/revit2027/x64/AdpSdk"
printf '<Package>\n  <Identity>\n    <BuildNumber>6.3.44.3</BuildNumber>\n  </Identity>\n</Package>\n' > "$R/installers/extracted/revit2027/x64/AdpSdk/pkg.adp-desktop-sdk.xml"
echo '<Setup/>' > "$R/installers/extracted/revit2027/setup.xml"; mkbottle rvt2027-t 2027 2027; mcp_state 'mcp_adp_version'
check "mcp: the ADP version from the unpacked installer" grep -qx "6.3.44.3" <<<"$OUT"
reset; mcp_bottle rvt2027-t "$MCPW"; mcp_state 'unset DIST; mcp_field revitmcp 5; mcp_field revitmcp-experimental 3; mcp_field nosuch 2 || echo none'
check "mcp: the table's ProductCode, MSI path and an unknown id" grep -qF "{A2B3C4D5-2701-0010-4804-C5384500AB01}
x64/RMCE/RMCE.msi
none" <<<"$OUT"

# ---- the Revit MCP Server: the install step ----
MW="$BOTTLES/rvt2027-t/drive_c/Program Files/Autodesk/$MCPW"; ME="$BOTTLES/rvt2027-t/drive_c/Program Files/Autodesk/$MCPE"
MCPM="$BOTTLES/rvt2027-t/drive_c/Program Files/Autodesk/Revit/Addins/2027/Autodesk.RevitMcpServer.addin"
ADPM="$BOTTLES/rvt2027-t/drive_c/ProgramData/revit-macos/adp"
ADPC="$BOTTLES/rvt2027-t/drive_c/Program Files/Common Files/Autodesk/AdpDesktopSDK/bin/AdpSDKCore.dll"
CODEW="{A2B3C4D5-2701-0010-4804-C5384500AB01}"; CODEE="{A4B5C6D7-2701-0010-4804-C5384500AB01}"
mcp_world() { # a 2027 bottle, the MCP Server installers, the unpacked Revit installer with ADP, a fake 7zz
  mkbottle rvt2027-t 2027 2027; mkdist 2027
  local a="$R/installers/extracted/revit2027/x64/AdpSdk"; mkdir -p "$a" "$T/bin" "$T/zip" "$R/installers/addins/publicmcpserver"
  printf '<Package>\n  <Identity>\n    <BuildNumber>6.3.44.3</BuildNumber>\n  </Identity>\n</Package>\n' > "$a/pkg.adp-desktop-sdk.xml"
  touch "$a/InstallCustomAction.exe" "$T/zip/AdpSDKCore.dll" "$R/installers/addins/publicmcpserver/PublicMcpServer.exe" \
    "$R/installers/addins/publicmcpserver/PublicMcpServerExperimental.exe"
  (cd "$T/zip" && zip -q "$a/adp-desktop-sdk.zip" AdpSDKCore.dll)
  # fake 7zz: x -y -o<dir> <exe> <x64/RMxx/*> makes <dir>/x64/RMxx/RMxx.msi
  { echo '#!/bin/bash'; echo "echo \"7zz \$*\" >> \"$CALLS\""
    echo 'o=""; for a in "$@"; do case "$a" in -o*) o="${a#-o}" ;; esac; done'
    echo 'p="${@: -1}"; d="${p%/*}"; mkdir -p "$o/$d" && echo msi > "$o/$d/${d##*/}.msi"'; } > "$T/bin/7zz"
  # what the fake MSI of variant folder $1 leaves: the server and the manifest that points at it
  { echo '#!/bin/bash'; echo "d=\"$BOTTLES/rvt2027-t/drive_c/Program Files/Autodesk/\$1\"; m=\"$MCPM\""
    echo 'mkdir -p "$d" "$(dirname "$m")" && touch "$d/Autodesk.RevitMcpServer.Stdio.exe" &&'
    echo "  printf '<RevitAddIns><AddIn><Assembly>C:\\\\Program Files\\\\Autodesk\\\\%s\\\\Autodesk.RevitMcpServer.Addin.dll</Assembly></AddIn></RevitAddIns>\\r\\n' \"\$1\" > \"\$m\""; } > "$T/mcp-msi.sh"
  chmod +x "$T/bin/7zz" "$T/mcp-msi.sh"
}
mcp_rules() { # $1 = exit code of the Write-Tools MSI, then the ProductCodes the fake live registry knows (others: 1)
  local c rc="$1"; shift
  for c in "$@"; do rule "Uninstall\\$c" 0; done
  rule "Uninstall\\{" 1; rule "revitmcp.cmd" "$rc" "\"$T/mcp-msi.sh\" '$MCPW'"; rule "revitmcp-experimental.cmd" 0 "\"$T/mcp-msi.sh\" '$MCPE'"
}
mcp_run() { STEP_ENV=(PATH="$T/bin:$PATH" REVIT_ACCEPT_EULA="${MCP_EULA:-}"); run_steps 2027 rvt2027-t "$@"; }
reset; mcp_world; mcp_rules 0; MCP_EULA="" mcp_run revitmcp
expect "revitmcp without consent refuses" 1 "revitmcp"
check "revitmcp: the log has the notice and the flag" grep -q "turns ADP on in this bottle. To accept: add --accept-eula revitmcp" "$RUN/revitmcp.log"
check "revitmcp without consent: nothing ran" eval '! grep -q -e "7zz" -e "\[cmd\]" -e InstallCustomAction "$CALLS"'
reset; mcp_world; mcp_rules 0; MCP_EULA=revitmcp mcp_run revitmcp; expect "revitmcp: a first install" 0 "revitmcp"
check "first install: the fake manifest names the folder" grep -qF 'C:\Program Files\Autodesk\Revit 2027 MCP Server Write-Tools Technical Preview\Autodesk' "$MCPM"
check "first install: x64/RMCP only, from the ODIS exe" grep -q 'PublicMcpServer.exe x64/RMCP/\*$' "$CALLS"
check "first install: msiexec waits for itself alone (no --wait-children)" grep -qF "[--bottle] [rvt2027-t] [cmd] [/c] [C:\\revitmcp.cmd]" "$CALLS"
check "first install: start /wait in the .cmd" grep -q '^start "" /wait msiexec /i "C:\\revitmcp.msi" .*ADSK_SETUP_EXE=1' "$RUN/revitmcp.cmd"
check "first install: not a repair" eval '! grep -q REINSTALL "$RUN/revitmcp.cmd"'
check "first install: the live registry was asked" called "[reg] [query] [HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\$CODEW]"
check "first install: ADP pre, then post" eval '[ "$(grep -o "InstallCustomAction.exe\] \[action=[a-z]*" "$CALLS" | tr "\n" " ")" = "InstallCustomAction.exe] [action=pre InstallCustomAction.exe] [action=post " ]'
check "first install: ADP marker and AdpSDKCore.dll" eval '[ "$(cat "$ADPM")" = 6.3.44.3 ] && [ -f "$ADPC" ]'
check "first install: mcphost and mcppipes next to the server" eval 'cmp -s "$R/build/mcphost/mcphost.exe" "$MW/mcphost.exe" && cmp -s "$R/build/mcppipes/mcppipes.dll" "$MW/mcppipes.dll"'
check "first install: no MSI left in drive_c" test ! -e "$BOTTLES/rvt2027-t/drive_c/revitmcp.msi"
check "first install: no system.reg was needed" test ! -e "$BOTTLES/rvt2027-t/system.reg"
for g in 'rm "$MW/Autodesk.RevitMcpServer.Stdio.exe"|Stdio.exe' 'rm "$MCPM"|the manifest'; do
  reset; mcp_world; mcp_rules 0 "$CODEW"; "$T/mcp-msi.sh" "$MCPW"; MCP_EULA=revitmcp mcp_run revitmcp
  : > "$CALLS"; eval "${g%|*}"; MCP_EULA=revitmcp mcp_run revitmcp
  expect "revitmcp again without ${g#*|}: ready again" 0 "revitmcp"
  check "without ${g#*|}: registered → a repair, not a first install" grep -q 'ADSK_SETUP_EXE=1 REINSTALL=ALL REINSTALLMODE=amus' "$RUN/revitmcp.cmd"
done
reset; mcp_world; mcp_rules 0 "$CODEW"; "$T/mcp-msi.sh" "$MCPW"; MCP_EULA=revitmcp mcp_run revitmcp
: > "$CALLS"; rm "$MW/mcphost.exe"; MCP_EULA=revitmcp mcp_run revitmcp
expect "revitmcp again without mcphost.exe: ready again" 0 "revitmcp"
check "without mcphost.exe: no MSI, the launcher copied again" eval '! grep -q "\[cmd\]" "$CALLS" && [ -f "$MW/mcphost.exe" ]'
check "without mcphost.exe: ADP skipped (marker and DLL there)" not_called "InstallCustomAction"
reset; mcp_world; mcp_rules 0; "$T/mcp-msi.sh" "$MCPE"; MCP_EULA=revitmcp mcp_run revitmcp
expect "revitmcp with the Experimental manifest refuses" 1 "revitmcp"
check "other variant: the log says to rebuild" grep -q "only one can be. To switch: ./revit rebuild 2027 rvt2027-t" "$RUN/revitmcp.log"
check "other variant: no msiexec" not_called "[cmd]"
reset; mcp_world; mcp_rules 0 "$CODEE"; MCP_EULA=revitmcp mcp_run revitmcp
expect "revitmcp with Experimental registered, its manifest gone, refuses" 1 "revitmcp"; check "other registered: no msiexec" not_called "[cmd]"
reset; mcp_world; mcp_rules 194; MCP_EULA=revitmcp mcp_run revitmcp; expect "revitmcp: msiexec 194 (reboot) is fine" 0 "revitmcp"
reset; mcp_world; mcp_rules 67; MCP_EULA=revitmcp mcp_run revitmcp; expect "revitmcp: msiexec 67 (1603) fails" 1 "revitmcp"
check "1603: the log names the code" grep -q "MSI returned 67" "$RUN/revitmcp.log"; check "1603: no ADP" not_called "InstallCustomAction"
reset; mcp_world; mcp_rules 0; MCP_EULA=revitmcp-experimental mcp_run revitmcp_experimental
expect "revitmcp_experimental: a first install" 0 "revitmcp_experimental"
check "experimental: x64/RMCE, the launcher in its folder" eval 'grep -q "PublicMcpServerExperimental.exe x64/RMCE/\*$" "$CALLS" && [ -f "$ME/mcphost.exe" ]'
for a in "action=pre|pre" "unzip|unzip" "action=post|post"; do
  reset; mcp_world; mcp_rules 0
  case "${a%|*}" in unzip) : > "$R/installers/extracted/revit2027/x64/AdpSdk/adp-desktop-sdk.zip" ;; *) rule "${a%|*}" 5 ;; esac
  MCP_EULA=revitmcp mcp_run revitmcp; expect "ADP failing at ${a#*|}: the step fails" 1 "revitmcp"
  check "ADP failing at ${a#*|}: no marker" test ! -e "$ADPM"
done
: > "$RULES"; mcp_rules 0 "$CODEW"; : > "$CALLS"; MCP_EULA=revitmcp mcp_run revitmcp
check "ADP: a rerun after a failed post runs pre again and writes the marker" eval 'grep -q "action=pre" "$CALLS" && [ -s "$ADPM" ]'
reset; mcp_world; mcp_rules 0; MCP_EULA=revitmcp mcp_run revitmcp; rm "$ADPC"; : > "$RULES"; rule "action=post" 5; mcp_rules 0 "$CODEW"
MCP_EULA=revitmcp mcp_run revitmcp; expect "ADP: marker but no DLL, post fails" 1 "revitmcp"; check "ADP: the old marker is gone" test ! -e "$ADPM"
reset; mcp_world; mcp_rules 0; MCP_EULA=revitmcp mcp_run revitmcp; : > "$RULES"; mcp_rules 0 "$CODEW"; : > "$CALLS"; MCP_EULA=revitmcp mcp_run revitmcp
expect "revitmcp twice" 0 ""; check "twice: ADP skipped, no msiexec" eval '! grep -q -e InstallCustomAction -e "\[cmd\]" "$CALLS"'
reset; mcp_world; mcp_rules 0; rm -rf "$R/installers/extracted/revit2027"; MCP_EULA=revitmcp mcp_run revitmcp
expect "revitmcp without the unpacked installer" 1 "revitmcp"
check "no unpacked installer: the hint, before any msiexec" eval 'grep -q "not unpacked: ./scripts/unpack-revit.sh 2027" "$RUN/revitmcp.log" && ! grep -q "\[cmd\]" "$CALLS"'

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
OUT="$(cd / && "${SANDBOX_ENV[@]}" REVIT_CX_TMP="$T/cxtmp" REVIT_LAUNCH_WAIT=3 /bin/bash "$R/scripts/launch.sh" 2024 rvt2024-t 2>&1)"; RC=$?
expect "launch.sh starts Revit and returns once it runs" 0 "Revit 2024 started (backend default)"
check "launch.sh: the bottle's wineserver under watch-server first, then Revit" eval '[ "$(sed -n 1p "$CALLS")" = "wineserver -k0" ] &&
  wait_for 3 grep -q "Revit.exe" "$CALLS"'
in_repo 'lock_free && echo free'; expect "launch.sh: the Revit it started does not hold the lock" 0 "free"
sleep 4

# ---- watch-server: the bottle's wineserver with its log and how it ended ----
CRASH='wineserver crashed, please enable coredumps (ulimit -c unlimited) and restart.'
W="$TOP/ws"   # outside the sandbox's long path: a UNIX socket path has a limit
ws_end() { # the supervisors and fake servers of the last test
  pkill -f "watch-server.pl $CXF" 2>/dev/null; [ ! -f "$W/pid" ] || kill -9 "$(cat "$W/pid")" 2>/dev/null; return 0
}
ws_setup() { # $@ = mode lines (key=value): a bottle and a fake wineserver that follows them. -k0: 0 while one runs;
  # -f: records how it was called, says the lines of say= (| between them) on stderr, ends at once with now=, else
  # holds server-x/lock, leaves a dead server's socket (stale=1), waits before=, ends with die= before it listens,
  # binds, waits gap= seconds, listens (not with nolisten=1), and ends with the code ws_stop writes
  ws_end; reset; rm -rf "$W"; mkdir -p "$W"
  WB="$BOTTLES/rvt2027-w"; WL="$WB/revit-macos/wineserver.log"; WJ="$WB/revit-macos/wineserver.last"
  mkdir -p "$WB/revit-macos"; printf '%s\n' "$@" > "$W/mode"
  cat > "$CXF/bin/wineserver" <<EOF
#!/usr/bin/perl
use strict; use warnings; use IO::Socket::UNIX; use Socket;
my \$W = "$W";
open(my \$c, '>>', "$CALLS") or die;
print \$c "wineserver @ARGV WINEPREFIX=\$ENV{WINEPREFIX}", (-e "/dev/fd/9" ? " FD9" : ""), (-e "/dev/fd/7" ? " FD7" : ""), "\n";
close \$c;
if (\$ARGV[0] eq '-k0') { open(my \$f, '<', "\$W/pid") or exit 1; my \$p = <\$f>; exit(kill(0, \$p) ? 0 : 1) }
exit 0 unless \$ARGV[0] eq '-f';
my %m; open(my \$f, '<', "\$W/mode") or die; while (<\$f>) { chomp; my (\$k, \$v) = split /=/, \$_, 2; \$m{\$k} = \$v if defined \$v }
open(my \$p, '>', "\$W/pid") or die; print \$p "\$\$\n"; close \$p;
\$| = 1; print STDERR "\$_\n" for grep { length } split /\|/, \$m{say} // '';
exit \$m{now} if defined \$m{now};
mkdir "\$W/srv"; mkdir "\$W/srv/server-x"; my \$sp = "\$W/srv/server-x/socket";
open(my \$lock, '>>', "\$W/srv/server-x/lock") or die;
if (\$m{stale}) { unlink \$sp; my \$s = IO::Socket::UNIX->new(Type => SOCK_STREAM, Local => \$sp, Listen => 1) or die "stale: \$!"; close \$s }
select(undef, undef, undef, \$m{before}) if \$m{before};
exit \$m{die} if defined \$m{die};
unlink \$sp; socket(my \$s, PF_UNIX, SOCK_STREAM, 0) or die; bind(\$s, pack_sockaddr_un(\$sp)) or die "bind: \$!";
select(undef, undef, undef, \$m{gap}) if \$m{gap};
unless (\$m{nolisten}) { listen(\$s, 5) or die; open(my \$l, '>', "\$W/listening"); close \$l }
while (1) {
  if (open(my \$f, '<', "\$W/stop")) { my \$c = <\$f>; close \$f; unlink "\$W/stop"; exit \$c + 0 }
  select(undef, undef, undef, 0.1);
}
EOF
  chmod +x "$CXF/bin/wineserver"; : > "$CALLS"
}
ws_run() { # watch-server as the Revit app runs it, with fds 7 and 9 open as in a script of ours. RC; SECS it took
  local t0; t0="$(/usr/bin/perl -MTime::HiRes=time -e 'print time')"
  ( cd / && "${SANDBOX_ENV[@]}" REVIT_CX_TMP="$T/cxtmp" REVIT_WATCH_IDLE="${WS_IDLE:-60}" \
    REVIT_WATCH_LOCK_WAIT="${WS_LOCK_WAIT:-30}" REVIT_WATCH_LSOF="${WS_LSOF:-/usr/sbin/lsof}" /usr/bin/perl "$R/scripts/watch-server.pl" "$CXF" "$WB" \
    </dev/null >/dev/null 2>&1 7>"$T/fd7" 9>"$T/fd9" ); RC=$?
  SECS="$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.1f", time - $ARGV[0]' "$t0")"
  SUP="$(sed -n 's/.* start [0-9]*-\([0-9]*\) server .*/\1/p' "$WL" 2>/dev/null | tail -1)"
}
ws_stop() { echo "$1" > "$W/stop"; wait_for 5 grep -qs " ended " "$WL"; }   # the fake server ends with code $1
srv_alive() { [ -f "$W/pid" ] && kill -0 "$(cat "$W/pid")" 2>/dev/null; }
secs_ge() { /usr/bin/perl -e 'exit !($ARGV[0] >= $ARGV[1])' "$1" "$2"; }   # $1 >= $2, fractions too
cxlock_free() { /usr/bin/perl -MFcntl=:flock -e 'for (@ARGV) { open(my $f, ">>", $_) or exit 1; flock($f, LOCK_EX | LOCK_NB) or exit 1 }' \
  "$T"/cxtmp/.wine-*/bottle-*.lock; }
elsewhere() { # a Windows program outside the bottle: watch-server's pgrep finds one, so it asks lsof (on a Mac
  # where nothing else runs, it would not)
  /usr/bin/perl -e 'sleep 30' 'C:\windows\elsewhere.exe' & PIDS="$PIDS $!"
}
hold_cxlock() { # $1 = seconds: CrossOver's lock of the bottle held that long, as cx_bottle_lock holds it
  ( cd / && "${SANDBOX_ENV[@]}" REVIT_CX_TMP="$T/cxtmp" ROOT="$R" /bin/bash -c '. "$ROOT/scripts/lib/common.sh"
    cx_bottle_lock "$1" && sleep "$2"' _ "$WB" "$1" ) & PIDS="$PIDS $!"; sleep 0.5
}

ws_setup; echo $$ > "$W/pid"; ws_run
check "watch-server: the bottle's server runs already → nothing started" eval '[ "$RC" = 0 ] && not_called "wineserver -f" && [ ! -e "$WL" ]'
rm -f "$W/pid"
ws_setup; ws_run
check "watch-server: exits 0 as soon as the server answers, while it runs" eval '[ "$RC" = 0 ] && srv_alive'
check "watch-server: the server is the bottle's, in the foreground" called "wineserver -f WINEPREFIX=$WB"
check "watch-server: start and ready in the log" eval 'grep -q " start [0-9]*-$SUP server [0-9]*$" "$WL" && grep -q " ready$" "$WL"'
check "watch-server: fds 7 and 9 reach no server" not_called " FD"
check "watch-server: the supervisor holds no fd 7 or 9" eval 'lsof -w -p "$SUP" -Ff | grep -qx f1 && [ -z "$(lsof -w -p "$SUP" -a -d 7,9 2>/dev/null)" ]'
check "watch-server: the supervisor has its own session" eval '[ "$(ps -o pgid= -p "$SUP" | tr -d " ")" = "$SUP" ]'
check "watch-server: CrossOver's lock is free while the server runs" cxlock_free
ws_stop 0
check "watch-server: an exit 0 is normal, in the log and in .last" eval 'grep -q " ended [0-9]*-$SUP class normal exit 0$" "$WL" &&
  wait_for 3 grep -q "^{\"gen\":1,\"id\":\"[0-9]*-$SUP\",\"start\":[0-9]*,\"end\":[0-9]*,\"class\":\"normal\",\"exit\":0,\"signal\":null}$" "$WJ"'
check "watch-server: the supervisor ends with its server" wait_for 3 eval '! kill -0 "$SUP" 2>/dev/null'
ws_setup "say=$CRASH"; ws_run; ws_stop 1
check "watch-server: Wine's crash line and exit 1 → crashed" eval 'grep -qF "$SUP $CRASH" "$WL" && grep -q "class crashed exit 1$" "$WL" && wait_for 3 grep -q "\"class\":\"crashed\",\"exit\":1," "$WJ"'
ws_setup "say=wineserver: something|another line"; ws_run; ws_stop 1
check "watch-server: exit 1 without the crash line → other" eval 'grep -q "class other exit 1$" "$WL" && grep -q " another line$" "$WL"'
ws_setup "say=the last wineserver crashed"; ws_run; kill -9 "$(cat "$W/pid")"; wait_for 5 grep -q " ended " "$WL"
check "watch-server: a message about an earlier crash, then SIGKILL → signal 9" eval 'grep -q "class signal signal 9$" "$WL" &&
  wait_for 3 grep -q "\"class\":\"signal\",\"exit\":null,\"signal\":9}" "$WJ"'
ws_setup "now=2"; ws_run; wait_for 5 grep -q " ended " "$WL"
check "watch-server: exit 2 at once → lost, logged, no .last" eval '[ "$RC" = 0 ] && grep -q "class lost exit 2$" "$WL" && grep -q " not ready$" "$WL" && [ ! -e "$WJ" ]'
ws_setup "stale=1" "gap=2"; ws_run
check "watch-server: a dead server's socket and a bound socket are not ready; listening is" eval 'secs_ge "$SECS" 2 && [ -e "$W/listening" ] && grep -q " ready$" "$WL"'
ws_setup "nolisten=1"; ws_run
check "watch-server: a server that never listens: the caller gives up within 6 s, exit 0" eval '[ "$RC" = 0 ] && secs_ge "$SECS" 4.5 && secs_ge 7 "$SECS" && grep -q " not ready$" "$WL"'
ws_setup "stale=1" "before=1" "die=3"; ws_run; wait_for 5 grep -q " ended " "$WL"
check "watch-server: a server that ends before it listens: not ready, other exit 3" eval '[ "$RC" = 0 ] && secs_ge 4 "$SECS" && grep -q " not ready$" "$WL" && grep -q "class other exit 3$" "$WL"'
ws_setup; ws_run; echo '{"gen":2,"id":"1-1","start":1,"end":1,"class":"normal","exit":0,"signal":null}' > "$WJ"; ws_stop 1
check "watch-server: an older start never replaces a newer end" eval 'grep -q "class other exit 1$" "$WL" && sleep 1 && grep -q "^{\"gen\":2," "$WJ" && [ "$(cat "$WB/revit-macos/wineserver.gen")" = 1 ]'
ws_setup; ws_run; ws_stop 0; ws_run; ws_stop 0
check "watch-server: each start a new generation" eval 'wait_for 3 grep -q "^{\"gen\":2," "$WJ"'
ws_setup; hold_cxlock 2; ws_run
check "watch-server: waits for CrossOver's lock of the bottle" eval 'secs_ge "$SECS" 1 && called "wineserver -f"'
ws_setup; hold_cxlock 3; WS_LOCK_WAIT=1 ws_run
check "watch-server: CrossOver's lock busy too long → no server" eval '[ "$RC" = 0 ] && not_called "wineserver -f" && [ ! -e "$WL" ]'
ws_setup; hold_cxlock 2; ( sleep 0.5; mv "$WB" "$WB.old"; mkdir -p "$WB/revit-macos" ) & ws_run
check "watch-server: the bottle made again while it waited → no server" eval 'not_called "wineserver -f" && [ ! -e "$WL" ] && [ ! -e "$WB.old/revit-macos/wineserver.log" ]'
ws_setup; ws_run; mv "$WB" "$WB.old"; mkdir -p "$WB"; ws_stop 0 >/dev/null; wait_for 5 grep -q " ended " "$WB.old/revit-macos/wineserver.log"
check "watch-server: a bottle made again before the end gets nothing" eval 'wait_for 3 eval "! kill -0 $SUP 2>/dev/null" && [ -z "$(ls -A "$WB")" ]'
ws_setup; ws_run; rm -rf "$WB"; echo 0 > "$W/stop"
check "watch-server: a deleted bottle: no folder made again" eval 'wait_for 5 eval "! kill -0 $SUP 2>/dev/null" && [ ! -e "$WB" ]'
ws_setup; head -c 300000 /dev/zero | tr '\0' x > "$WL"; echo '{"gen":7}' > "$WJ"; ws_run
check "watch-server: a log over 256 KB moves to .log.1; .last stays" eval '[ "$(wc -c < "$WL.1" | tr -d " ")" = 300000 ] &&
  grep -q " start " "$WL" && [ "$(wc -c < "$WL" | tr -d " ")" -lt 1000 ] && [ "$(cat "$WJ")" = "{\"gen\":7}" ]'
ws_setup; elsewhere; printf '#!/bin/bash\nsleep 30\n' > "$W/lsof"; chmod +x "$W/lsof"; WS_LSOF="$W/lsof" WS_IDLE=1 ws_run
check "watch-server: a hung lsof: not ready within 6 s, exit 0" eval '[ "$RC" = 0 ] && secs_ge 7 "$SECS" && grep -q " not ready$" "$WL"'
ws_stop 0
check "watch-server: a hung lsof never keeps the supervisor from writing the end" eval 'grep -q "class normal exit 0$" "$WL" &&
  ! grep -q "no Windows program" "$WL" && ! pgrep -f "$W/lsof" >/dev/null'
ws_setup; printf '#!/bin/bash\nexec >&-\nsleep 30\n' > "$W/lsof"; chmod +x "$W/lsof"; WS_LSOF="$W/lsof" ws_run
check "watch-server: an lsof that closes its output and keeps running is not waited for" eval '[ "$RC" = 0 ] && secs_ge 7 "$SECS" &&
  wait_for 2 grep -q " not ready$" "$WL"'
ws_stop 0; check "watch-server: ... and the end is written" grep -q "class normal exit 0$" "$WL"
ws_setup; elsewhere; printf '#!/bin/bash\nexit 3\n' > "$W/lsof"; chmod +x "$W/lsof"; WS_LSOF="$W/lsof" WS_IDLE=1 ws_run; sleep 2
check "watch-server: an lsof that fails is not an answer: no note" eval 'grep -q " not ready$" "$WL" && ! grep -q "no Windows program" "$WL"'
ws_setup; elsewhere; WS_IDLE=1 ws_run
check "watch-server: no Windows program within the time → a note, the server stays" eval 'wait_for 4 grep -q " no Windows program yet$" "$WL" && srv_alive'
ws_setup; mkdir -p "$WB/drive_c"; touch "$WB/drive_c/held"
/usr/bin/perl -e 'open(my $f, "<", $ARGV[0]) or die; sleep 30' "$WB/drive_c/held" 'C:\windows\notepad.exe' & PIDS="$PIDS $!"
WS_IDLE=1 ws_run; sleep 2.5
check "watch-server: a Windows program in the bottle → no note" eval 'grep -q " ready$" "$WL" && ! grep -q "no Windows program" "$WL"'
ws_end

# ---- events ----
reset; in_repo 'json_str "a\"b\\c	t
n"'; expect "json_str escapes quotes, backslashes, tabs, newlines" 0 '"a\"b\\c\tt\nn"'
reset; in_repo 'emit step id "$(json_str x)"; echo after'; expect "emit without the fd prints nothing" 0 "after"
check "emit without the fd: no JSON" eval '! grep -q "{" <<<"$OUT"'
reset; in_repo 'exec 7>"'"$T"'/ev"; export REVIT_EVENTS_FD=7; emit step id "$(json_str rvt)" state "$(json_str done)"'
check "emit writes one JSON line on fd 7" grep -qx '{"event":"step","id":"rvt","state":"done"}' "$T/ev"
reset; mkdir -p "$T/ctx"; touch "$T/ctx/.ended"
in_repo 'exec 7>"'"$T"'/ev"; export REVIT_EVENTS_FD=7 REVIT_RUN_CTX="'"$T"'/ctx"; emit step id "$(json_str late)"'
check "nothing is emitted after the end" test ! -s "$T/ev"
reset; mkdir -p "$T/ctx"; exec 7>"$T/ev"
( export REVIT_EVENTS_FD=7 REVIT_RUN_CTX="$T/ctx" ROOT="$R"; . "$R/scripts/lib/common.sh"
  ( for i in $(seq 1 200); do emit progress done "$i"; done ) &
  sleep 0.3; printf '{"event":"end"}\n' | emit_line end; wait )
exec 7>&-
check "a writer racing the end never writes after it" eval 'tail -1 "$T/ev" | grep -qx "{\"event\":\"end\"}"' 
reset; mkbottle rvt2024-t 2024 2024; teststeps
OUT="$(cd / && exec 7>"$T/ev" && "${SANDBOX_ENV[@]}" REVIT_EVENTS_FD=7 /bin/bash "$R/scripts/run-steps.sh" 2024 rvt2024-t t_ok t_skip t_fail 2>&1)"; RC=$?
check "steps emit running and a result each" eval '[ "$(grep -c "\"event\":\"step\"" "$T/ev")" = 6 ]'
check "a skipped step is skipped" grep -q '"id":"t_skip","state":"skipped"' "$T/ev"
check "a failed step is failed" grep -q '"id":"t_fail","state":"failed"' "$T/ev"
check "no event reaches the terminal" eval '! grep -q "\"event\"" <<<"$OUT"'
norm_logs() { sed -e 's|logs/rvt2024-t/[^ )]*|logs/RUN|g' -e 's/([0-9]* s)/(N s)/g' <<<"$1"; }   # run folders and times differ
reset; mkbottle rvt2024-t 2024 2024; teststeps
OUT="$(cd / && exec 7>"$T/ev" && "${SANDBOX_ENV[@]}" REVIT_EVENTS_FD=7 /bin/bash "$R/scripts/run-steps.sh" 2024 rvt2024-t t_ok t_why 2>&1)"; with7="$OUT"
OUT="$(cd / && "${SANDBOX_ENV[@]}" /bin/bash "$R/scripts/run-steps.sh" 2024 rvt2024-t t_ok t_why 2>&1)"
check "run-steps: a failed step's log tail is an error event: every line is JSON" /usr/bin/perl -MJSON::PP -ne 'JSON::PP->new->decode($_)' "$T/ev"
check "run-steps: a failed step's log tail is an error event" /usr/bin/perl -MJSON::PP -e 'my $ok = 0; open(my $f, "<", $ARGV[0]) or exit 1;
  while (<$f>) { my $e = decode_json($_); $ok = 1 if $e->{event} eq "message" && $e->{level} eq "error" && $e->{text} =~ /^t_why: / && $e->{text} =~ /why it failed/ } exit !$ok' "$T/ev"
check "run-steps: the error event changes nothing on the terminal" test "$(norm_logs "$with7")" = "$(norm_logs "$OUT")"

# ---- data folder ----
reset; in_repo 'echo "$DATA"'; expect "DATA defaults to ROOT" 0 "$R"
reset; OUT="$(cd / && "${SANDBOX_ENV[@]}" ROOT="$R" REVIT_DATA="$T/data" /bin/bash -c '. "$ROOT/scripts/lib/common.sh"
  run_dir_new rvt2024-t steps; revit_input 2024; revit_extracted 2024' 2>&1)"; RC=$?
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

# ---- source: download and unpack ----
mkzip() { python3 -I -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1], "w")
for a in sys.argv[2:]: n, c = a.split("=", 1); z.writestr(n, c)
z.close()' "$@"; }
srv_curl() { # a curl that serves $T/srv/<basename of the URL>: -I gives Content-Length, -o writes the file
  mkdir -p "$T/srv"; cat > "$T/curl" <<EOF
#!/bin/bash
out=""; head=0; for a in "\$@"; do case "\$a" in -I|-fsSIL) head=1 ;; esac; done
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift ;; https://*) url="\$1" ;; esac; shift; done
f="$T/srv/\$(basename "\$url")"; [ -f "\$f" ] || exit 22
if [ \$head = 1 ]; then printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' "\$(stat -f %z "\$f")"; exit 0; fi
cp "\$f" "\$out"
EOF
  chmod +x "$T/curl"; }
reset; srv_curl; D="$T/my data"; mkdir -p "$D/installers/revit2025" "$T/user"
mkzip "$T/srv/RVT_2025_B_002_002.7z" "setup.xml=<Setup/>" "x64/a.txt=1"
mkzip "$T/user/Create_Installer_RVT_2025_5_English_WIN64.exe" "collection.xml=<C><BrowserImageUrl>https://dds.autodesk.com/x/RVT_2025_B_001_002.exe;https://dds.autodesk.com/x/RVT_2025_B_002_002.7z</BrowserImageUrl></C>"
printf 'MZ-downloader' > "$T/srv/RVT_2025_B_001_002.exe"
rmdir "$D/installers/revit2025"; ln -s "$T/user" "$D/installers/revit2025"; chmod a-w "$T/user"
OUT="$(cd / && "${SANDBOX_ENV[@]}" PATH="$T:$PATH" REVIT_DATA="$D" /bin/bash "$R/scripts/get-revit.sh" 2025 2>&1)"; RC=$?
expect "get-revit downloads into the downloads folder, paths with spaces" 0 "installer ready"
check "the base is in revit2025-dl" test -f "$D/installers/revit2025-dl/RVT_2025_B_002_002.7z"
OUT="$(cd / && "${SANDBOX_ENV[@]}" PATH="$T:$PATH" REVIT_DATA="$D" /bin/bash "$R/scripts/unpack-revit.sh" 2025 2>&1)"; RC=$?
chmod u+w "$T/user"
expect "unpack takes the payload, not the downloader" 0 "unpacking RVT_2025_B_002_002.7z"
check "unpack writes .source with a source_id" eval 'test -f "$D/installers/extracted/revit2025/.source" && /usr/bin/perl -MJSON::PP -0 -ne "exit(decode_json(\$_)->{source_id} ? 0 : 1)" "$D/installers/extracted/revit2025/.source"'
check "the user's installer folder is not written" eval '[ "$(ls -A "$T/user")" = "Create_Installer_RVT_2025_5_English_WIN64.exe" ]'
first="$(/usr/bin/perl -MJSON::PP -0 -ne 'print decode_json($_)->{source_id}' "$D/installers/extracted/revit2025/.source")"
OUT="$(cd / && "${SANDBOX_ENV[@]}" PATH="$T:$PATH" REVIT_DATA="$D" /bin/bash "$R/scripts/get-revit.sh" 2025 2>&1)"
check "a second download run: nothing to fetch" grep -q "already here" <<<"$OUT"
again="$(cd "$D" && python3 -I "$R/tools/installer_source.py" resolve 2025 installers/revit2025 installers/revit2025-dl /dev/null "$T/s2.json" >/dev/null; python3 -I "$R/tools/installer_source.py" finalize "$T/s2.json" "$T/h2.tsv" >/dev/null; /usr/bin/perl -MJSON::PP -0 -ne 'print decode_json($_)->{source_id}' "$T/s2.json")"
check "the source_id is stable across runs (unknown base sum)" test "$first" = "$again"
reset; srv_curl; D="$T/my data"; mkdir -p "$D/installers" "$T/user"
mkzip "$T/srv/RVT_2025_B_002_002.7z" "setup.xml=<Setup/>" "x64/a.txt=1"; head -c 10 "$T/srv/RVT_2025_B_002_002.7z" > "$T/user/RVT_2025_B_002_002.7z"
mkzip "$T/user/Create_Installer_RVT_2025_5_English_WIN64.exe" "collection.xml=<C><BrowserImageUrl>https://dds.autodesk.com/x/RVT_2025_B_002_002.7z</BrowserImageUrl></C>"
ln -s "$T/user" "$D/installers/revit2025"; before="$(ls -l "$T/user")"
OUT="$(cd / && "${SANDBOX_ENV[@]}" PATH="$T:$PATH" REVIT_DATA="$D" /bin/bash "$R/scripts/get-revit.sh" 2025 2>&1)"; RC=$?
expect "an incomplete file in the user's folder is refused, not resumed there" 1 "is incomplete"
check "the user's folder is exactly as it was" test "$(ls -l "$T/user")" = "$before"
reset; mkdir -p "$R/installers/revit2023" "$R/installers/extracted/revit2023"; echo '<Setup/>' > "$R/installers/extracted/revit2023/setup.xml"
echo old > "$R/installers/extracted/revit2023/marker"; touch "$R/installers/revit2023/Revit_2023_G1_dlm_001_002.sfx.exe"
OUT="$(cd / && "${SANDBOX_ENV[@]}" REVIT_UNPACK_AGAIN=1 /bin/bash "$R/scripts/unpack-revit.sh" 2023 2>&1)"; RC=$?
expect "unpack again with an incomplete installer refuses" 1 "not complete"
check "unpack again: the old unpacked files are kept" test -f "$R/installers/extracted/revit2023/marker"
reset; mkdir -p "$R/installers/extracted/revit2023.old.123"; echo '<Setup/>' > "$R/installers/extracted/revit2023.old.123/setup.xml"
OUT="$(cd / && "${SANDBOX_ENV[@]}" /bin/bash "$R/scripts/unpack-revit.sh" 2023 2>&1)"; RC=$?
check "a swap cut short after the backup: the backup comes back" test -f "$R/installers/extracted/revit2023/setup.xml"
reset; mkdir -p "$R/installers/extracted/revit2023" "$R/installers/extracted/revit2023.old.9"; echo '<Setup/>' > "$R/installers/extracted/revit2023/setup.xml"
OUT="$(cd / && "${SANDBOX_ENV[@]}" /bin/bash "$R/scripts/unpack-revit.sh" 2023 2>&1)"
check "a swap cut short after the publish: the backup goes" test ! -e "$R/installers/extracted/revit2023.old.9"
reset; mkdir -p "$R/installers/revit2025/update" "$R/installers/extracted/revit2025"; echo '<Setup/>' > "$R/installers/extracted/revit2025/setup.xml"
mkzip "$R/installers/revit2025/RVT_2025_NA_win_db_002_002.zip" "setup.xml=<Setup/>"; mkzip "$R/installers/revit2025/update/U.exe" "x64/p/new.txt=1"
OUT="$(cd / && "${SANDBOX_ENV[@]}" REVIT_REUSE_EXTRACTED=1 /bin/bash "$R/scripts/unpack-revit.sh" 2025 2>&1)"
check "--reuse-extracted leaves an unrecorded unpacked folder exactly as it is" test ! -e "$R/installers/extracted/revit2025/x64/p/new.txt"
reset; mkdir -p "$R/installers/revit2025/update" "$R/installers/revit2025-dl/update" "$R/installers/extracted/revit2025"; echo '<Setup/>' > "$R/installers/extracted/revit2025/setup.xml"
mkzip "$R/installers/revit2025/RVT_2025_NA_win_db_002_002.zip" "setup.xml=<Setup/>"
mkzip "$R/installers/revit2025/update/U.exe" "x64/p/one.txt=1"; mkzip "$R/installers/revit2025-dl/update/U.exe" "x64/p/two.txt=2"
mv "$R/installers/revit2025" "$T/user25"; ln -s "$T/user25" "$R/installers/revit2025"
OUT="$(cd / && "${SANDBOX_ENV[@]}" /bin/bash "$R/scripts/unpack-revit.sh" 2025 2>&1)"; RC=$?
expect "an unrecorded unpacked folder: two different copies of an update stop it" 1 "two different updates named U.exe"
check "an unrecorded unpacked folder: no update was laid on" test ! -e "$R/installers/extracted/revit2025/x64/p/one.txt"
OUT="$(cd / && "${SANDBOX_ENV[@]}" REVIT_REUSE_EXTRACTED=1 /bin/bash "$R/scripts/unpack-revit.sh" 2025 2>&1)"; RC=$?
expect "--reuse-extracted does not care about broken or conflicting installer files" 0 "ready"
reset; mkdir -p "$R/installers/revit2025/update" "$R/installers/extracted/revit2025"; echo '<Setup/>' > "$R/installers/extracted/revit2025/setup.xml"
mkzip "$R/installers/revit2025/update/U.exe" "x64/p/up.txt=1"
OUT="$(cd / && "${SANDBOX_ENV[@]}" /bin/bash "$R/scripts/unpack-revit.sh" 2025 2>&1)"; RC=$?
expect "base gone, an update left: it is laid on the unrecorded unpacked folder, as today" 0 "applying update U.exe"
check "base gone, an update left: its files are there" test -f "$R/installers/extracted/revit2025/x64/p/up.txt"
reset; srv_curl; sed -i '' 's/^cp /sleep 3; cp /' "$T/curl"; mkdir -p "$R/installers/revit2025"
mkzip "$T/srv/RVT_2025_B_002_002.7z" "setup.xml=<Setup/>"
mkzip "$R/installers/revit2025/Create_Installer_RVT_2025_5_English_WIN64.exe" "collection.xml=<C><BrowserImageUrl>https://dds.autodesk.com/x/RVT_2025_B_002_002.7z</BrowserImageUrl></C>"
OUT="$(cd / && exec 7>"$T/ev" && "${SANDBOX_ENV[@]}" PATH="$T:$PATH" REVIT_EVENTS_FD=7 /bin/bash "$R/scripts/get-revit.sh" 2025 2>&1)"
check "progress events while downloading" grep -q '"event":"progress"' "$T/ev"
check "progress: no event reaches the terminal" eval '! grep -q "\"event\"" <<<"$OUT"'
reset; srv_curl; sed -i '' 's/^cp /sleep 3; cp /' "$T/curl"; mkdir -p "$R/installers/revit2025"
mkzip "$T/srv/RVT_2025_B_002_002.7z" "setup.xml=<Setup/>"
mkzip "$R/installers/revit2025/Create_Installer_RVT_2025_5_English_WIN64.exe" "collection.xml=<C><BrowserImageUrl>https://dds.autodesk.com/x/RVT_2025_B_002_002.7z</BrowserImageUrl></C>"
(cd / && exec 7>"$T/ev" && exec "${SANDBOX_ENV[@]}" PATH="$T:$PATH" REVIT_EVENTS_FD=7 /bin/bash "$R/scripts/get-revit.sh" 2025) >/dev/null 2>&1 &
gp=$!; sleep 1; kill -9 "$gp"; wait "$gp" 2>/dev/null; sleep 3
check "no poller outlives the downloader" eval '! pgrep -f "sand box/repo/scripts/get-revit.sh" >/dev/null'
reset; mkdir -p "$R/installers/revit2025/update"; touch "$R/installers/revit2025/update/Revit_2025_5_0.exe"
mkzip "$R/installers/revit2025/RVT_2025_NA_win_db_002_002.zip" "setup.xml=<Setup/>"
in_repo 'revit_main_installer 2025'; expect "the main installer is not an update" 0 "RVT_2025_NA_win_db_002_002.zip"
# the Revit build of what is unpacked goes into the source list and .source: real 7z archives, the base's manifest with a
# namespace and attributes, the update's build from its own setup.xml
build_of() { /usr/bin/perl -MJSON::PP -0 -ne 'print decode_json($_)->{revit_build_expected} // "null"' "$1" 2>/dev/null; }
reset; mkdir -p "$T/a/x64/p" "$T/u/x64/q" "$R/installers/revit2025/update"
printf '<?xml version="1.0"?>\n<Bundle version="1" xmlns="urn:example:b"><Identity><BuildNumber envvar="B">25.0.2.419</BuildNumber></Identity></Bundle>\n' > "$T/a/setup.xml"
printf '<Bundle><Identity><Type>UPD</Type><BuildNumber>25.5.0.57</BuildNumber></Identity><Packages/></Bundle>\n' > "$T/u/setup.xml"
echo 1 > "$T/a/x64/p/a.txt"; echo 2 > "$T/u/x64/q/b.txt"
( cd "$T/a" && 7zz a -t7z "$R/installers/revit2025/RVT_2025_B_002_002.7z" . >/dev/null ) \
  && ( cd "$T/u" && 7zz a -t7z "$R/installers/revit2025/update/Revit_2025_5_0.exe" . >/dev/null ) || fail "7z archives for the build" ""
OUT="$(cd / && "${SANDBOX_ENV[@]}" /bin/bash "$R/scripts/unpack-revit.sh" 2025 2>&1)"; RC=$?
expect "unpack lays the update on the base" 0 "applying update Revit_2025_5_0.exe"
check "unpack keeps the build of what it unpacked in .source" test "$(build_of "$R/installers/extracted/revit2025/.source")" = 25.5.0.57
check "and in its source list" test "$(build_of "$(ls -d "$R"/logs/revit2025/*-unpack | tail -1)/source.list")" = 25.5.0.57
cp "$R/installers/extracted/revit2025/.source" "$T/dot"; echo '{"files": []}' > "$T/list.json"
rm "$R/installers/revit2025/update/Revit_2025_5_0.exe"   # its build is in no list now: .source keeps what the unpack found
OUT="$(cd / && "${SANDBOX_ENV[@]}" REVIT_REUSE_EXTRACTED=1 REVIT_SOURCE_LIST="$T/list.json" /bin/bash "$R/scripts/unpack-revit.sh" 2025 2>&1)"; RC=$?
expect "--reuse-extracted: the unpacked folder as it is" 0 "ready"
check "--reuse-extracted: its build goes into the source list" test "$(build_of "$T/list.json")" = 25.5.0.57
check "--reuse-extracted: .source stays as it was" cmp -s "$T/dot" "$R/installers/extracted/revit2025/.source"
rm "$R/installers/extracted/revit2025/.source"; echo '{"files": []}' > "$T/list.json"
OUT="$(cd / && "${SANDBOX_ENV[@]}" REVIT_REUSE_EXTRACTED=1 REVIT_SOURCE_LIST="$T/list.json" /bin/bash "$R/scripts/unpack-revit.sh" 2025 2>&1)"; RC=$?
check "--reuse-extracted, no record: an applied update of unknown build makes it unknown" test "$(build_of "$T/list.json")" = null

# ---- review fixes ----
# Ctrl-C (events mode notes it) while json_str runs: the value stays, so no event gets an empty JSON value
reset; /usr/bin/perl -0pi -e 's/(json_str\(\) \{.*?-e .)my \$s = shift;/$1select(undef, undef, undef, 1); my \$s = shift;/s' "$R/scripts/lib/common.sh"
OUT="$(cd / && "${SANDBOX_ENV[@]}" ROOT="$R" /usr/bin/perl -e 'setpgrp(0,0); my $p = fork; if (!$p) { exec @ARGV } $SIG{INT} = "IGNORE";
  select(undef, undef, undef, 0.4); kill "INT", -getpgrp(); waitpid($p, 0)' /bin/bash -c '. "$ROOT/scripts/lib/common.sh"; trap "g=1" INT; v="$(json_str abc)"; echo "[$v]"' 2>&1)"
check "json_str survives a Ctrl-C" grep -qx '\["abc"\]' <<<"$OUT"
reset; in_repo 'exec 7>"'"$T"'/ev"; export REVIT_EVENTS_FD=7; emit step id "" state "$(json_str done)"'
check "emit never writes an empty JSON value" eval '! grep -q ":," "$T/ev" && ! grep -q ":}" "$T/ev"'
# an unpacked folder made before .source, a Create Installer that cannot be read: used as before
reset; mkdir -p "$R/installers/revit2025" "$R/installers/extracted/revit2025"; echo '<Setup/>' > "$R/installers/extracted/revit2025/setup.xml"
printf 'junk' > "$R/installers/revit2025/Create_Installer_RVT_2025_5_English_WIN64.exe"
OUT="$(cd / && "${SANDBOX_ENV[@]}" /bin/bash "$R/scripts/unpack-revit.sh" 2025 2>&1)"; RC=$?
expect "an unrecorded unpacked folder with a broken Create Installer: used as before" 0 "ready"

# CrossOver's wine deletes WINEDLLOVERRIDES (only its --dll sets one): a step that sets the variable changes nothing
check "no script sets WINEDLLOVERRIDES" test -z "$(grep -rn 'WINEDLLOVERRIDES=' "$R/scripts" | grep -v '^[^:]*:[0-9]*: *#')"

# WebView2: a failed download stops get-redist; the step with only the installer's old runtime installs it and fails
reset; printf '#!/bin/bash\nexit 22\n' > "$T/curl"; chmod +x "$T/curl"   # never the real Microsoft
OUT="$(cd / && "${SANDBOX_ENV[@]}" PATH="$T:$PATH" /bin/bash "$R/scripts/get-redist.sh" 2025 2>&1)"; RC=$?
expect "get-redist: a failed WebView2 download stops it" 1 "no fresh WebView2 runtime"
check "get-redist: the failure says what to do" grep -qF "Check the internet connection" <<<"$OUT"
# failure reasons for the app (the result file's reason): download (Retry resumes) and no_space; a checksum mismatch has none
reason_of() { sed -n 's/^reason=//p' "$T/ctx/result" 2>/dev/null; }
reset; mkdir -p "$T/ctx"; printf '#!/bin/bash\nexit 22\n' > "$T/curl"; chmod +x "$T/curl"
OUT="$(cd / && "${SANDBOX_ENV[@]}" PATH="$T:$PATH" REVIT_RUN_CTX="$T/ctx" /bin/bash "$R/scripts/get-redist.sh" 2025 2>&1)"; RC=$?
check "get-redist: a failed download gives reason download" eval '[ "$RC" = 1 ] && [ "$(reason_of)" = download ]'
reset; mkdir -p "$T/ctx"; printf '#!/bin/bash\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && echo junk > "$2"; shift; done\nexit 0\n' > "$T/curl"; chmod +x "$T/curl"
OUT="$(cd / && "${SANDBOX_ENV[@]}" PATH="$T:$PATH" REVIT_RUN_CTX="$T/ctx" /bin/bash "$R/scripts/get-redist.sh" 2020 2>&1)"; RC=$?
check "get-redist: a checksum mismatch has no reason" eval '[ "$RC" = 1 ] && grep -qF "checksum mismatch" <<<"$OUT" && [ -z "$(reason_of)" ]'
# Cancel during the unpack (install.sh passes TERM on to unpack-revit): 7zz ends, nothing half-unpacked is left
reset; mkdir -p "$T/ctx" "$T/stub7" "$R/installers/revit2025"; mkzip "$R/installers/revit2025/RVT_2025_NA_win_db_002_002.zip" "setup.xml=<Setup/>"
printf '#!/bin/bash\n[ "$1" = x ] || exit 0\ntouch "%s/7z-started"; exec sleep 30\n' "$T" > "$T/stub7/7zz"; chmod +x "$T/stub7/7zz"
( cd / && exec "${SANDBOX_ENV[@]}" PATH="$T/stub7:$PATH" REVIT_RUN_CTX="$T/ctx" /bin/bash "$R/scripts/unpack-revit.sh" 2025 ) > "$T/out" 2>&1 & ur=$!
for i in $(seq 1 100); do [ -f "$T/7z-started" ] && break; sleep 0.1; done
t0=$SECONDS; kill -TERM "$ur"; wait "$ur"; RC=$?
check "unpack-revit: TERM during the unpack stops it at once" eval '[ -f "$T/7z-started" ] && [ "$RC" = 1 ] && [ $((SECONDS - t0)) -lt 10 ] && grep -qF "Stopped." "$T/out"'
check "unpack-revit: a stopped unpack is result stopped and leaves no unpacked folder" eval 'grep -qx "result=stopped" "$T/ctx/result" && [ ! -e "$R/installers/extracted/revit2025" ] && [ ! -e "$R/installers/extracted/revit2025.partial" ]'
check "unpack-revit: no 7zz is left running" eval '! pgrep -f "sand box/stub7/7zz" >/dev/null'
pkill -f "sand box/stub7/7zz" 2>/dev/null
# an update laid straight onto an unpacked folder made before .source finishes before the stop (no half-written files)
reset; mkdir -p "$T/ctx" "$T/stub7" "$R/installers/revit2025/update" "$R/installers/extracted/revit2025"
echo '<Setup/>' > "$R/installers/extracted/revit2025/setup.xml"; mkzip "$R/installers/revit2025/update/U.exe" "x64/p/up.txt=1"
printf '#!/bin/bash\n[ "$1" = x ] || exit 0\ntouch "%s/7z-started"; sleep 2; touch "%s/overlay-done"\n' "$T" "$T" > "$T/stub7/7zz"; chmod +x "$T/stub7/7zz"
( cd / && exec "${SANDBOX_ENV[@]}" PATH="$T/stub7:$PATH" REVIT_RUN_CTX="$T/ctx" /bin/bash "$R/scripts/unpack-revit.sh" 2025 ) > "$T/out" 2>&1 & ur=$!
for i in $(seq 1 100); do [ -f "$T/7z-started" ] && break; sleep 0.1; done
kill -TERM "$ur"; wait "$ur"; RC=$?
check "unpack-revit: a stop during an update onto an old unpacked folder lets the update finish, then stops" \
  eval '[ -f "$T/overlay-done" ] && grep -qx "U.exe" "$R/installers/extracted/revit2025/applied-updates.txt" && [ "$RC" = 1 ] && grep -qx "result=stopped" "$T/ctx/result"'
# a stop while no child runs (the checksum pass) is not lost: nothing is unpacked after it
PY="$(command -v python3)"
reset; mkdir -p "$T/ctx" "$T/stub7" "$R/installers/revit2025"; mkzip "$R/installers/revit2025/RVT_2025_NA_win_db_002_002.zip" "setup.xml=<Setup/>"
printf '#!/bin/bash\n[ "$1" = x ] || exit 0\ntouch "%s/7z-started"; exec sleep 30\n' "$T" > "$T/stub7/7zz"
printf '#!/bin/bash\ncase "$*" in *finalize*) touch "%s/fin-started"; sleep 2 ;; esac\nexec "%s" "$@"\n' "$T" "$PY" > "$T/stub7/python3"; chmod +x "$T/stub7/7zz" "$T/stub7/python3"
( cd / && exec "${SANDBOX_ENV[@]}" PATH="$T/stub7:$PATH" REVIT_RUN_CTX="$T/ctx" /bin/bash "$R/scripts/unpack-revit.sh" 2025 ) > "$T/out" 2>&1 & ur=$!
for i in $(seq 1 100); do [ -f "$T/fin-started" ] && break; sleep 0.1; done
kill -TERM "$ur"; wait "$ur"; RC=$?
check "unpack-revit: a stop during the checksum pass starts no unpack" \
  eval '[ -f "$T/fin-started" ] && [ ! -f "$T/7z-started" ] && [ "$RC" = 1 ] && grep -qx "result=stopped" "$T/ctx/result" && [ ! -e "$R/installers/extracted/revit2025.partial" ]'
pkill -f "sand box/stub7/7zz" 2>/dev/null
# the size probe before a download can be stopped (a stalled server must not hold Cancel forever)
reset; srv_curl; mkdir -p "$T/ctx" "$R/installers/revit2025"; mkzip "$T/srv/RVT_2025_B_002_002.7z" "setup.xml=<Setup/>"
mkzip "$R/installers/revit2025/Create_Installer_RVT_2025_5_English_WIN64.exe" "collection.xml=<C><BrowserImageUrl>https://dds.autodesk.com/x/RVT_2025_B_002_002.7z</BrowserImageUrl></C>"
sed -i '' "s|^if \[ \\\$head = 1 \]; then|if [ \\\$head = 1 ]; then touch '$T/probe-started'; exec sleep 30; fi; if false; then|" "$T/curl"
( cd / && exec "${SANDBOX_ENV[@]}" PATH="$T:$PATH" REVIT_RUN_CTX="$T/ctx" /bin/bash "$R/scripts/get-revit.sh" 2025 ) > "$T/out" 2>&1 & gr=$!
for i in $(seq 1 50); do [ -f "$T/probe-started" ] && break; sleep 0.1; done
t0=$SECONDS; kill -TERM "$gr"; wait "$gr"; RC=$?
check "get-revit: TERM during the size probe stops it at once" eval '[ -f "$T/probe-started" ] && [ "$RC" = 1 ] && [ $((SECONDS - t0)) -lt 10 ] && grep -qx "result=stopped" "$T/ctx/result"'
pkill -f "sand box/curl" 2>/dev/null
# get-redist: a stop during a runtime's download ends it at once; the .part stays
reset; mkdir -p "$T/ctx"
printf '#!/bin/bash\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && echo part > "$2"; shift; done\ntouch "%s/dl-started"; exec sleep 30\n' "$T" > "$T/curl"; chmod +x "$T/curl"
( cd / && exec "${SANDBOX_ENV[@]}" PATH="$T:$PATH" REVIT_RUN_CTX="$T/ctx" /bin/bash "$R/scripts/get-redist.sh" 2025 ) > "$T/out" 2>&1 & gd=$!
for i in $(seq 1 50); do [ -f "$T/dl-started" ] && break; sleep 0.1; done
t0=$SECONDS; kill -TERM "$gd"; wait "$gd"; RC=$?
check "get-redist: TERM during a download stops it at once and keeps the .part" \
  eval '[ -f "$T/dl-started" ] && [ "$RC" = 1 ] && [ $((SECONDS - t0)) -lt 10 ] && grep -qx "result=stopped" "$T/ctx/result" && ls "$R"/installers/redist/webview2/*.part >/dev/null 2>&1'
pkill -f "sand box/curl" 2>/dev/null
# Cancel during the download (install.sh passes TERM on to get-revit): curl ends, get-revit stops at once as stopped,
# the .part stays for the next run
reset; srv_curl; mkdir -p "$T/ctx" "$R/installers/revit2025"; mkzip "$T/srv/RVT_2025_B_002_002.7z" "setup.xml=<Setup/>" "x64/a.txt=1234567890"
mkzip "$R/installers/revit2025/Create_Installer_RVT_2025_5_English_WIN64.exe" "collection.xml=<C><BrowserImageUrl>https://dds.autodesk.com/x/RVT_2025_B_002_002.7z</BrowserImageUrl></C>"
sed -i '' "s|^cp \"\\\$f\" \"\\\$out\"\$|head -c 100 \"\\\$f\" > \"\\\$out\"; touch '$T/curl-started'; exec sleep 30|" "$T/curl"
printf '#!/bin/bash\necho 999999999999999\n' > "$T/osascript"; chmod +x "$T/osascript"
( cd / && exec "${SANDBOX_ENV[@]}" PATH="$T:$PATH" REVIT_RUN_CTX="$T/ctx" /bin/bash "$R/scripts/get-revit.sh" 2025 ) > "$T/out" 2>&1 & gr=$!
for i in $(seq 1 50); do [ -f "$T/curl-started" ] && break; sleep 0.1; done
t0=$SECONDS; kill -TERM "$gr"; wait "$gr"; RC=$?
check "get-revit: TERM during the download stops it at once" eval '[ "$RC" = 1 ] && [ $((SECONDS - t0)) -lt 10 ] && grep -qF "Stopped." "$T/out"'
check "get-revit: a stopped download is result stopped and keeps its .part" eval 'grep -qx "result=stopped" "$T/ctx/result" && [ -s "$R/installers/revit2025/RVT_2025_B_002_002.7z.part" ]'
check "get-revit: no curl is left running" eval '! pgrep -f "sand box/curl" >/dev/null'
pkill -f "sand box/curl" 2>/dev/null
ci2025() { mkdir -p "$R/installers/revit2025"; mkzip "$R/installers/revit2025/Create_Installer_RVT_2025_5_English_WIN64.exe" \
  "collection.xml=<C><BrowserImageUrl>https://dds.autodesk.com/x/RVT_2025_B_002_002.7z</BrowserImageUrl></C>"; }
reset; srv_curl; ci2025; mkdir -p "$T/ctx"   # nothing on the server: the size probe fails
OUT="$(cd / && "${SANDBOX_ENV[@]}" PATH="$T:$PATH" REVIT_RUN_CTX="$T/ctx" /bin/bash "$R/scripts/get-revit.sh" 2025 2>&1)"; RC=$?
check "get-revit: an unreachable server gives reason download" eval '[ "$RC" = 1 ] && grep -qF "cannot reach" <<<"$OUT" && [ "$(reason_of)" = download ]'
reset; srv_curl; ci2025; mkdir -p "$T/ctx"; mkzip "$T/srv/RVT_2025_B_002_002.7z" "setup.xml=<Setup/>"
printf '#!/bin/bash\necho 1000\n' > "$T/osascript"; chmod +x "$T/osascript"
OUT="$(cd / && "${SANDBOX_ENV[@]}" PATH="$T:$PATH" REVIT_RUN_CTX="$T/ctx" /bin/bash "$R/scripts/get-revit.sh" 2025 2>&1)"; RC=$?
check "get-revit: no space gives reason no_space" eval '[ "$RC" = 1 ] && grep -qF "not enough disk space" <<<"$OUT" && [ "$(reason_of)" = no_space ]'
reset; srv_curl; ci2025; mkdir -p "$T/ctx"; mkzip "$T/srv/RVT_2025_B_002_002.7z" "setup.xml=<Setup/>" "x64/a.txt=1234567890"
sed -i '' 's|^cp "\$f" "\$out"$|head -c $(( $(stat -f %z "$f") / 2 )) "$f" > "$out"|' "$T/curl"
printf '#!/bin/bash\necho 999999999999999\n' > "$T/osascript"; printf '#!/bin/bash\nexit 0\n' > "$T/sleep"; chmod +x "$T/osascript" "$T/sleep"
OUT="$(cd / && "${SANDBOX_ENV[@]}" PATH="$T:$PATH" REVIT_RUN_CTX="$T/ctx" /bin/bash "$R/scripts/get-revit.sh" 2025 2>&1)"; RC=$?
check "get-revit: a download that stays incomplete gives reason download" eval '[ "$RC" = 1 ] && grep -qF "incomplete; run again" <<<"$OUT" && [ "$(reason_of)" = download ]'
reset; mkbottle rvt2025-t 2025 2025; mkdist 2025; mkdir -p "$R/installers/extracted/revit2025/3rdParty/x64/WebView2"
touch "$R/installers/extracted/revit2025/3rdParty/x64/WebView2/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
run_steps 2025 rvt2025-t webview2; expect "webview2 with only the installer's runtime fails" 1 "webview2"
check "webview2: the installer's runtime is still installed" called "[C:\\webview2.exe] [/silent] [/install]"
check "webview2: the log says why" grep -qF "no fresh WebView2 runtime" "$RUN/webview2.log"
mkdir -p "$R/installers/redist/webview2"; touch "$R/installers/redist/webview2/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
run_steps 2025 rvt2025-t webview2; expect "webview2 with a fresh runtime" 0 ""
WVA="$BOTTLES/rvt2025-t/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application"
rule "webview2.exe" 13; mkdir -p "$WVA/103.0.1264.37"
run_steps 2025 rvt2025-t webview2; expect "webview2: exit 13 over only the installer's runtime 103 fails" 1 "webview2"
mkdir -p "$WVA/155.0.4283.62"   # idmgr fetched a newer runtime: "Higher version of WebView is already installed"
run_steps 2025 rvt2025-t webview2; expect "webview2: exit 13 over a current runtime is ok" 0 ""
rm "$R/installers/redist/webview2/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
run_steps 2025 rvt2025-t webview2; expect "webview2: the installer's runtime over a current one is ok" 0 ""

# make-apps: Revit Viewer only when the installer made its shortcut (2027 has none); an old Viewer app goes. osacompile,
# codesign, PlistBuddy, lsregister and the shortcut reader are stubs, so nothing is registered with macOS
make_apps_sandbox() { # $1 = year, $2 = bottle, $3… = Start Menu shortcut titles
  local y="$1" b="$2" menu t; shift 2
  mkbottle "$b" "$y" "$y"; mkdir -p "$BOTTLES/$b/drive_c/Program Files/Autodesk/AdskIdentityManager/1.0.0"
  menu="$BOTTLES/$b/drive_c/users/crossover/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Autodesk/Revit $y"
  mkdir -p "$menu" "$T/stubs"; for t in "$@"; do : > "$menu/$t.lnk"; done
  # osacompile as the real one: an app only for a path that ends in .app, a plain script file otherwise; it records the
  # path, keeps the script (Contents/Resources/script.txt) and fails while $T/osa-fail exists
  cat > "$T/stubs/osacompile" <<EOF
#!/bin/bash
o=""; e=""; while [ \$# -gt 0 ]; do case "\$1" in -o) o="\$2"; shift ;; -e) e="\$2"; shift ;; esac; shift; done
echo "osacompile [\$o]" >> "$CALLS"; [ ! -e "$T/osa-fail" ] || exit 1
case "\$o" in *.app) mkdir -p "\$o/Contents/Resources"; printf '%s' "\$e" > "\$o/Contents/Resources/script.txt" ;; *) printf '%s' "\$e" > "\$o" ;; esac
EOF
  printf '#!/bin/bash\nexit 0\n' > "$T/stubs/codesign"; cp "$T/stubs/codesign" "$T/stubs/PlistBuddy"; cp "$T/stubs/codesign" "$T/stubs/lsregister"
  chmod +x "$T/stubs/"*
  printf 'import sys\nprint("C:\\\\Program Files\\\\Autodesk\\\\Revit %s\\\\Revit.exe\\t%s\\t", end="")\n' \
    "$y" '/language ENU' > "$R/tools/win_shortcut.py"
  /usr/bin/perl -pi -e 's{^LSREGISTER=.*}{LSREGISTER="\$STUBS/lsregister"}; s{/usr/libexec/PlistBuddy}{"\$STUBS/PlistBuddy"}g' \
    "$R/scripts/make-apps.sh"
}
run_make_apps() { OUT="$(cd / && "${SANDBOX_ENV[@]}" STUBS="$T/stubs" PATH="$T/stubs:$PATH" /bin/bash "$R/scripts/make-apps.sh" "$@" 2>&1)"; RC=$?; }
reset; make_apps_sandbox 2027 rvt2027-t "Revit 2027"; mkdir -p "$H/Applications/Revit Viewer 2027 (rvt2027-t).app"
run_make_apps 2027 rvt2027-t; expect "make-apps 2027: the Revit app" 0 "done: ~/Applications/Revit 2027 (rvt2027-t).app"
check "make-apps 2027: no Revit Viewer app, the old one removed" test ! -e "$H/Applications/Revit Viewer 2027 (rvt2027-t).app"
reset; make_apps_sandbox 2026 rvt2026-t "Revit 2026" "Revit Viewer 2026"
run_make_apps 2026 rvt2026-t; expect "make-apps 2026: the Revit Viewer app from its shortcut" 0 "done: ~/Applications/Revit Viewer 2026 (rvt2026-t).app"
check "make-apps 2026: no theme part (no step theme)" eval '! grep -q "revit-macos/theme" "$H/Applications/Revit 2026 (rvt2026-t).app/Contents/Resources/script.txt"'
check "make-apps 2026: watch-server first, from its copy in the bottle" eval 'grep -q "^do shell script \"(cd ~ && : revit-macos/watch-server; \[ -f .*/rvt2026-t/revit-macos/watch-server.pl. \] && /usr/bin/perl .* 7>&- 8>&- 9>&-; .*Revit.exe" "$H/Applications/Revit 2026 (rvt2026-t).app/Contents/Resources/script.txt" &&
  cmp -s "$R/scripts/watch-server.pl" "$BOTTLES/rvt2026-t/revit-macos/watch-server.pl"'
check "make-apps 2026: watch-server only in the Revit app" eval '! grep -q watch-server "$H/Applications/Revit Viewer 2026 (rvt2026-t).app/Contents/Resources/script.txt"'
# each app is built in a hidden <title> (<bottle>).new.app and replaces the old one only when complete
APP27="$H/Applications/Revit 2027 (rvt2027-t).app"
reset; make_apps_sandbox 2027 rvt2027-t "Revit 2027"; run_make_apps 2027 rvt2027-t
expect "make-apps 2027 with the step theme" 0 "done: ~/Applications/Revit 2027 (rvt2027-t).app"
check "make-apps: built in the hidden .new.app, none left" eval 'called "osacompile [$H/Applications/.Revit 2027 (rvt2027-t).new.app]" &&
  [ ! -e "$H/Applications/.Revit 2027 (rvt2027-t).new.app" ] && [ -f "$APP27/Contents/Resources/script.txt" ]'
check "make-apps 2027: watch-server, the theme part, then Revit" grep -q "^do shell script \"(cd ~ && : revit-macos/watch-server;.*revit-macos/theme.*themeset.exe.*Revit.exe" "$APP27/Contents/Resources/script.txt"
check "make-apps 2027: the copy of watch-server in the bottle" cmp -s "$R/scripts/watch-server.pl" "$BOTTLES/rvt2027-t/revit-macos/watch-server.pl"
echo old > "$APP27/old"; mv "$BOTTLES/rvt2027-t/revit-macos" "$T/rm-saved"; : > "$BOTTLES/rvt2027-t/revit-macos"; run_make_apps 2027 rvt2027-t
expect "make-apps: watch-server cannot be copied → 1" 1 ""
check "make-apps: no copy, the old app kept" eval '[ -f "$APP27/old" ] && [ ! -e "$H/Applications/.Revit 2027 (rvt2027-t).new.app" ]'
rm "$BOTTLES/rvt2027-t/revit-macos"; mv "$T/rm-saved" "$BOTTLES/rvt2027-t/revit-macos"
mkdir -p "$H/Applications/Revit Viewer 2027 (rvt2027-t).app"; echo old > "$APP27/old"; : > "$T/osa-fail"
run_make_apps 2027 rvt2027-t; expect "make-apps: osacompile fails → 1" 1 ""
check "make-apps: a failed build keeps the old app, no .new.app left" eval '[ -f "$APP27/old" ] && [ ! -e "$H/Applications/.Revit 2027 (rvt2027-t).new.app" ]'
rm -f "$T/osa-fail"; printf '#!/bin/bash\nexit 1\n' > "$T/stubs/codesign"; run_make_apps 2027 rvt2027-t
expect "make-apps: codesign fails → 1" 1 ""
check "make-apps: an app that could not be signed does not replace the old one" eval '[ -f "$APP27/old" ] && [ ! -e "$H/Applications/.Revit 2027 (rvt2027-t).new.app" ]'
printf '#!/bin/bash\nexit 0\n' > "$T/stubs/codesign"
rm -f "$T/osa-fail"; rm -rf "$H/Applications/Autodesk Sign-In (rvt2027-t).app"; : > "$CALLS"; run_make_apps 2027 rvt2027-t --revit-only
expect "make-apps --revit-only" 0 "done: ~/Applications/Revit 2027 (rvt2027-t).app"
check "make-apps --revit-only: the new Revit app, the Viewer app kept, no Sign-In app" eval '[ ! -f "$APP27/old" ] &&
  [ -d "$H/Applications/Revit Viewer 2027 (rvt2027-t).app" ] && [ ! -e "$H/Applications/Autodesk Sign-In (rvt2027-t).app" ]'
run_make_apps 2027 rvt2027-t --bogus; expect "make-apps: an unknown third word → 2" 2 "Usage: scripts/make-apps.sh <year> <bottle> [--revit-only]"
# the real osacompile and osascript (on a Mac): the app's script runs the theme part and Revit with every path quoted
if [ -x /usr/bin/osacompile ] && [ -x /usr/bin/osascript ]; then
  reset; make_apps_sandbox 2027 rvt2027-t "Revit 2027"; rm "$T/stubs/osacompile"
  Q="$T/cx 'q"; cp -R "$CXF" "$Q"   # a CrossOver path with a quote and a space
  printf '#!/bin/bash\necho Dark\n' > "$T/dark-defaults"; chmod +x "$T/dark-defaults"
  TD="$BOTTLES/rvt2027-t/drive_c/Program Files/revit-macos"
  osa_run() { : > "$CALLS"; (cd / && env -i HOME="$H" PATH=/usr/bin:/bin REVIT_CX_TMP="$T/cxtmp" /usr/bin/osascript "$APP27/Contents/Resources/Scripts/main.scpt" >/dev/null 2>&1)
    local i; for i in $(seq 1 50); do grep -q 'Revit.exe' "$CALLS" && break; sleep 0.1; done; }
  OUT="$(cd / && "${SANDBOX_ENV[@]}" REVIT_CX="$Q" REVIT_DEFAULTS="$T/dark-defaults" STUBS="$T/stubs" PATH="$T/stubs:$PATH" \
    /bin/bash "$R/scripts/make-apps.sh" 2027 rvt2027-t 2>&1)"; RC=$?
  expect "make-apps with the real osacompile" 0 "done: ~/Applications/Revit 2027 (rvt2027-t).app"
  check "the app's script carries the theme marker (osadecompile)" eval '/usr/bin/osadecompile "$APP27/Contents/Resources/Scripts/main.scpt" | grep -q "revit-macos/theme"'
  mkdir -p "$TD"; echo mac > "$TD/theme"; : > "$TD/themeset.exe"; osa_run
  check "app, mode mac on a dark Mac: watch-server, themeset dark, then Revit" eval '[ "$(grep -c . "$CALLS")" = 3 ] &&
    [ "$(sed -n 1p "$CALLS")" = "wineserver -k0" ] &&
    sed -n 2p "$CALLS" | grep -qF "[--bottle] [rvt2027-t] [C:\Program Files\revit-macos\themeset.exe] [dark]" &&
    sed -n 3p "$CALLS" | grep -qF "[C:\Program Files\Autodesk\Revit 2027\Revit.exe] [/language] [ENU]"'
  check "app: watch-server takes CrossOver's lock where it is told (no file in the real one)" eval 'ls "$T"/cxtmp/.wine-*/bottle-*.lock >/dev/null 2>&1'
  echo light > "$TD/theme"; osa_run
  check "app, mode light: watch-server, no themeset, Revit starts" eval '[ "$(grep -c . "$CALLS")" = 2 ] && [ "$(sed -n 1p "$CALLS")" = "wineserver -k0" ] && grep -q "Revit.exe" "$CALLS"'
  rm "$BOTTLES/rvt2027-t/revit-macos/watch-server.pl"; osa_run
  check "app, no copy of watch-server: Revit still starts" eval '! grep -q wineserver "$CALLS" && grep -q "Revit.exe" "$CALLS"'
  echo mac > "$TD/theme"; rule "themeset.exe" 1; osa_run
  check "app, themeset fails: Revit still starts" eval 'grep -q "themeset.exe" "$CALLS" && grep -q "Revit.exe" "$CALLS"'
  rm "$TD/themeset.exe"; osa_run
  check "app, no themeset.exe: no themeset, Revit starts" eval '! grep -q "themeset.exe" "$CALLS" && grep -q "Revit.exe" "$CALLS"'
fi

# ---- python-mcp: the Mac side's Python and venv (scripts/lib/pymcp.sh) ----
pymcp_world() { # a fake python-build-standalone archive on a fake curl; its python3 fakes venv and pip into $CALLS
  mkdir -p "$T/srv/pysrc/python/bin" "$T/py"
  cat > "$T/srv/pysrc/python/bin/python3" <<EOF
#!/bin/bash
echo "python3 \$*" >> "$CALLS"
if [ "\$1 \$2" = "-m venv" ]; then mkdir -p "\$3/bin" && cp "\$0" "\$3/bin/python3"; exit 0; fi
if [ "\$1 \$2" = "-m pip" ]; then [ -z "\${FAKE_PIP_FAIL:-}" ] || { echo "pip: hash mismatch" >&2; exit 1; }; exit 0; fi
exit 0
EOF
  chmod +x "$T/srv/pysrc/python/bin/python3"; (cd "$T/srv/pysrc" && tar czf "$T/srv/py.tar.gz" python)
  PYSHA="$(shasum -a 256 "$T/srv/py.tar.gz" | cut -d' ' -f1)"
  printf 'PYTHON_VERSION=3.14.8\nPYTHON_URL=https://example.invalid/py.tar.gz\nPYTHON_SHA256=%s\n' "${1:-$PYSHA}" > "$R/app/tools.sh"
  cat > "$T/curl" <<EOF
#!/bin/bash
echo "curl \$*" >> "$CALLS"; out=""; while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out="\$2"; shift; done
cp "$T/srv/py.tar.gz" "\$out"
EOF
  chmod +x "$T/curl"; D="$T/my data"; mkdir -p "$D"
}
pymcp() { OUT="$(cd / && "${SANDBOX_ENV[@]}" PATH="$T:$PATH" REVIT_DATA="$D" ROOT="$R" ${PYMCP_ENV[@]+"${PYMCP_ENV[@]}"} /bin/bash -c '. "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/pymcp.sh"; '"$1" 2>&1)"; RC=$?; PYMCP_ENV=(); }
PYMCP_ENV=()
reset; pymcp_world; pymcp 'pymcp_python'
expect "pymcp_python: a clone downloads the pinned Python into the data folder" 0 "$D/mcp/python-3.14.8/bin/python3"
check "pymcp_python: the file is there" test -x "$D/mcp/python-3.14.8/bin/python3"
: > "$CALLS"; pymcp 'pymcp_python'
check "pymcp_python: a second call downloads nothing" not_called "curl"
reset; pymcp_world 0000000000000000000000000000000000000000000000000000000000000000; pymcp 'pymcp_python'
expect "pymcp_python: a wrong download is refused by its sha256" 1 "PYTHON_SHA256"
check "pymcp_python: nothing kept after a wrong download" test ! -e "$D/mcp/python-3.14.8"
reset; pymcp_world; mkdir -p "$T/app/python/bin"; cp "$T/srv/pysrc/python/bin/python3" "$T/app/python/bin/"
PYMCP_ENV=(REVIT_BUNDLED=1 APP_RES="$T/app"); pymcp 'pymcp_python'
expect "pymcp_python: the app's own Python" 0 "$T/app/python/bin/python3"
check "pymcp_python: the app downloads nothing" not_called "curl"
reset; pymcp_world; pymcp 'pymcp_venv_ensure && pymcp_venv_python'
expect "pymcp_venv_ensure: a venv under the data folder" 0 "$D/mcp/python-mcp/6ca46b3ea96a8f7cce9894cf865d8f19ca2c549d/venv/bin/python3"
check "pymcp_venv_ensure: pip with --require-hashes and --no-deps from the pinned file" \
  called "-m pip install -q --disable-pip-version-check --require-hashes --no-deps -r $R/tools/python-mcp-requirements.txt"
: > "$CALLS"; pymcp 'pymcp_venv_ensure'
check "pymcp_venv_ensure: unchanged requirements, no pip" not_called "-m pip"
echo "# changed" >> "$R/tools/python-mcp-requirements.txt"; : > "$CALLS"; pymcp 'pymcp_venv_ensure'
check "pymcp_venv_ensure: changed requirements, pip again" called "-m pip install"
printf '#!/bin/bash\nexit 1\n' > "$D/mcp/python-mcp/6ca46b3ea96a8f7cce9894cf865d8f19ca2c549d/venv/bin/python3"; : > "$CALLS"; pymcp 'pymcp_venv_ensure'
check "pymcp_venv_ensure: a venv whose Python no longer works is made again" called "-m pip install"
reset; pymcp_world; PYMCP_ENV=(FAKE_PIP_FAIL=1); pymcp 'pymcp_venv_ensure'
expect "pymcp_venv_ensure: a failing pip is a refusal" 1 "the Python packages could not be installed"
check "pymcp_venv_ensure: no half venv left" test ! -e "$D/mcp/python-mcp/6ca46b3ea96a8f7cce9894cf865d8f19ca2c549d/venv"

# ---- python-mcp: who listens on the Routes port (pymcp_listener), under pipefail as scripts/mcp-launch.sh runs it ----
pm_lsof() { # $1 = address: a fake lsof (a wineserver of bottle rvt2020-t with as many open files as a real one) and ps
  mkdir -p "$T/lsofbin"; cat > "$T/lsofbin/lsof" <<EOF
#!/bin/bash
case "\$*" in
  *-iTCP*) printf 'p4242\nf1435\nn%s\n' "$1" ;;
  *"-p 4242"*) for i in \$(seq 1 20000); do echo "n$BOTTLES/rvt2020-t/drive_c/windows/f\$i"; done ;;
esac
EOF
  printf '#!/bin/bash\necho /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/../../bin/wineserver\n' > "$T/lsofbin/ps"
  chmod +x "$T/lsofbin/lsof" "$T/lsofbin/ps"
}
reset; mkbottle rvt2020-t 2020 2020; pm_lsof 127.0.0.1:48884
OUT="$(cd / && "${SANDBOX_ENV[@]}" PATH="$T/lsofbin:$PATH" ROOT="$R" /bin/bash -c 'set -o pipefail; . "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/pymcp.sh"; B="$(bottle_path rvt2020-t)"; pymcp_listener 48884' 2>&1)"; RC=$?
expect "pymcp_listener: a real wineserver's long lsof output under pipefail is ok" 0 "ok"
check "pymcp_listener: not foreign" test "$OUT" = ok

# ---- python-mcp: the add-in and its step (scripts/addins/python-mcp.sh, step_pythonmcp) ----
PMC=6ca46b3ea96a8f7cce9894cf865d8f19ca2c549d
PMSRV="$(bash "$REPO/tests/fixtures.sh" "https://raw.githubusercontent.com/pyrevitlabs/pyRevit/v4.8.12.22247%2B0031/pyrevitlib/pyrevit/routes/server/server.py" 3ac12d53d4b6935f75fbdd2466774076cc8bfa379340034958ac398ac4454f9a pyrevit48-server.py)"; PMRC=$?
PMTAR="$(bash "$REPO/tests/fixtures.sh" "https://github.com/mcp-servers-for-revit/mcp-server-for-revit-python/archive/$PMC.tar.gz" 6406be6574efe9519b34110ccf04d1499bb47f0e3fc36ba902a30b9575e1f0f6 python-mcp-6ca46b3.tar.gz)" || PMRC=$?
if [ "$PMRC" = 77 ]; then echo "SKIP python-mcp step cases: no network for the fixtures"
else
pm_world() { # $1 = year: bottle rvt<year>-t with pyRevit (4.8 for 2020: the reference server.py with CRLF, user config);
  # a curl that serves the pinned archive and the fake Python of pymcp_world. Sets PB (bottle), PS (server.py), PC
  # (config), PE (extension folder), PP (pairing folder), PD (the Mac side's folder)
  pymcp_world; srv_curl; cp "$PMTAR" "$T/srv/$PMC.tar.gz"
  mkbottle "rvt$1-t" "$1" "$1"; PB="$BOTTLES/rvt$1-t"
  PS="$PB/drive_c/users/crossover/AppData/Roaming/pyRevit-Master/pyrevitlib/pyrevit/routes/server/server.py"
  PC="$PB/drive_c/users/crossover/AppData/Roaming/pyRevit/pyRevit_config.ini"
  PE="$PB/drive_c/users/crossover/AppData/Roaming/pyRevit/Extensions/revit-mcp-python.extension"
  PP="$PB/drive_c/users/crossover/AppData/Local/RevitMCPPython"; PD="$D/mcp/python-mcp/$PMC"
  mkdir -p "$(dirname "$PS")" "$(dirname "$PC")"
  perl -pe 's/\n/\r\n/' "$PMSRV" > "$PS"
  printf '[core]\nbincache = true\n\n[routes]\nEnabled = True\nport = 9999\n' > "$PC"
}
pm_snap() { # what the add-in installs, as one checksum list (the runner's own logs left out)
  (cd "$PB" && find drive_c/users/crossover/AppData -type f 2>/dev/null | sort | while IFS= read -r f; do shasum -a 256 "$f"; done
   [ -d "$D/mcp" ] && find "$D/mcp" -type f | sort | while IFS= read -r f; do shasum -a 256 "$f"; done) 2>/dev/null
}
pm_run() { # run-steps.sh with the data folder $D; RUN = its run folder there
  STEP_ENV=(PATH="$T:$PATH" REVIT_DATA="$D" ${PM_ENV[@]+"${PM_ENV[@]}"}); PM_ENV=(); run_steps "$@"
  RUN="$(ls -td "$D/logs/$2"/*/ 2>/dev/null | head -1)"; RUN="${RUN%/}"; }
PM_ENV=()
reset; pm_world 2020; before="$(pm_snap)"; pm_run 2020 rvt2020-t pythonmcp
expect "pythonmcp without consent: refused" 1 "pythonmcp"; check "pythonmcp without consent: refused: the reason" grep -qF -- "--accept-eula python-mcp" "$RUN/pythonmcp.log"
check "pythonmcp without consent changes nothing" test "$(pm_snap)" = "$before"
check "pythonmcp without consent: nothing downloaded" not_called "$PMC"
reset; pm_world 2027; before="$(pm_snap)"; PM_ENV=(REVIT_ACCEPT_EULA=python-mcp); pm_run 2027 rvt2027-t pythonmcp
expect "pythonmcp on 2027: the year refusal" 1 "pythonmcp"; check "pythonmcp on 2027: the year refusal: the reason" grep -qF -- "MCP server for Revit (Python) is for Revit 2020 here." "$RUN/pythonmcp.log"
check "pythonmcp on 2027 changes nothing" test "$(pm_snap)" = "$before"
reset; pm_world 2020; rm -rf "$PB/drive_c/users/crossover/AppData/Roaming/pyRevit-Master"; PM_ENV=(REVIT_ACCEPT_EULA=python-mcp)
pm_run 2020 rvt2020-t pythonmcp; expect "pythonmcp without pyRevit" 1 "pythonmcp"; check "pythonmcp without pyRevit: the reason" grep -qF -- "install pyRevit first: ./revit addins 2020 rvt2020-t --only pyrevit" "$RUN/pythonmcp.log"
reset; pm_world 2020; rm "$PC"; PM_ENV=(REVIT_ACCEPT_EULA=python-mcp); pm_run 2020 rvt2020-t pythonmcp
expect "pythonmcp without user config" 1 "pythonmcp"; check "pythonmcp without user config: the reason" grep -qF -- "install pyRevit first: ./revit addins 2020 rvt2020-t --only pyrevit" "$RUN/pythonmcp.log"
reset; pm_world 2020; mkdir -p "$PP"; echo blob > "$PP/pairing.dpapi"; PM_ENV=(REVIT_ACCEPT_EULA=python-mcp); pm_run 2020 rvt2020-t pythonmcp
expect "pythonmcp installs" 0 "python-mcp 6ca46b3"
check "pythonmcp: the extension folder, without tests, docs, images" eval '[ -f "$PE/startup.py" ] && [ -d "$PE/MCP.tab" ] && [ ! -e "$PE/tests" ] && [ ! -e "$PE/docs" ] && [ ! -e "$PE/images" ] && [ ! -e "$PE/.github" ]'
check "pythonmcp: the extension patches are applied" eval 'grep -q "startup-error.txt" "$PE/startup.py" && grep -q "_printer(captured_output)" "$PE/revit_mcp/code_execution.py"'
check "pythonmcp: our module beside server.py" cmp -s "$R/tools/pyrevit48/revitmacos_serial.py" "$(dirname "$PS")/revitmacos_serial.py"
check "pythonmcp: server.py patched, CRLF" eval 'grep -q "revitmacos_serial.dispatch" "$PS" && [ "$(tr -d "\r" < "$PS" | wc -c)" -lt "$(wc -c < "$PS")" ] && perl -ne "exit 1 unless /\r\n\z/" "$PS"'
check "pythonmcp: routes keys" eval '[ "$(python3 -I "$R/tools/pyrevit_ini.py" get "$PC" routes enabled)" = true ] && [ "$(python3 -I "$R/tools/pyrevit_ini.py" get "$PC" routes host)" = "\"127.0.0.1\"" ]'
check "pythonmcp: user port becomes 48884" test "$(python3 -I "$R/tools/pyrevit_ini.py" get "$PC" routes port)" = 48884
check "pythonmcp: the extension is enabled" test "$(python3 -I "$R/tools/pyrevit_ini.py" get "$PC" revit-mcp-python.extension disabled)" = false
check "pythonmcp: Enabled = True replaced, not doubled" test "$(grep -ci '^enabled' "$PC")" = 1
check "pythonmcp: the venv and the sources" eval '[ -x "$PD/venv/bin/python3" ] && [ -f "$PD/src/main.py" ] && grep -q "Uri.UnescapeDataString" "$PD/src/revit_mcp/views.py"'
check "pythonmcp keeps the pairing" test "$(cat "$PP/pairing.dpapi")" = blob
before="$(pm_snap)"; : > "$CALLS"; PM_ENV=(REVIT_ACCEPT_EULA=python-mcp); pm_run 2020 rvt2020-t pythonmcp
expect "pythonmcp again" 0 "python-mcp 6ca46b3"
check "pythonmcp again is a no-op for server.py" test "$(pm_snap)" = "$before"
echo "old module" > "$(dirname "$PS")/revitmacos_serial.py"; PM_ENV=(REVIT_ACCEPT_EULA=python-mcp); pm_run 2020 rvt2020-t pythonmcp
expect "pythonmcp stale module" 0 "python-mcp 6ca46b3"
check "pythonmcp stale module is replaced" cmp -s "$R/tools/pyrevit48/revitmacos_serial.py" "$(dirname "$PS")/revitmacos_serial.py"
reset; pm_world 2020; printf 'foreign\r\n' > "$PS"; PM_ENV=(REVIT_ACCEPT_EULA=python-mcp); pm_run 2020 rvt2020-t pythonmcp
expect "pythonmcp foreign server.py refuses" 1 "pythonmcp"; check "pythonmcp foreign server.py refuses: the reason" grep -qF -- "server.py is not the one of pyRevit 4.8.12" "$RUN/pythonmcp.log"
check "pythonmcp foreign server.py: no module written" test ! -e "$(dirname "$PS")/revitmacos_serial.py"
reset; in_repo '. "$ROOT/scripts/lib/addins.sh"; YEAR=2027; addin_load python-mcp; addin_available && echo yes || echo no'
expect "addins: python-mcp is not offered for 2027" 0 "no"
fi

echo; echo "$((n - fails))/$n passed"; [ "$fails" -eq 0 ]
