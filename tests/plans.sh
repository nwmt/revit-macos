#!/usr/bin/env bash
# Plan snapshots and install.sh runs, in a sandbox: a copy of the repo, a fake HOME, no or a fake CrossOver.
#   ./revit check <year> (no CrossOver, no installers) prints the plan and the steps: compared with tests/plans/<year>.txt.
#   UPDATE=1 tests/plans.sh rewrites those files after a deliberate change — review the diff.
#   install.sh runs for real with stub actions: arguments with spaces, a failed action, failed steps after Revit.exe.
# Runs under /bin/bash 3.2. Nothing real is touched.
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
T="$TOP/sand box"; R="$T/repo"; H="$T/home"; CXF="$T/cx"
BOTTLES="$H/Library/Application Support/CrossOver/Bottles"
trap 'rm -rf "$TOP"' EXIT
n=0; fails=0
ok()   { n=$((n + 1)); echo "ok   $1"; }
fail() { n=$((n + 1)); fails=$((fails + 1)); echo "FAIL $1"; printf '%s\n' "${2:-}" | sed 's/^/     /'; }
reset() {
  rm -rf "$T"; mkdir -p "$R" "$H" "$BOTTLES"
  cp -R "$REPO/revit" "$REPO/install.sh" "$REPO/scripts" "$REPO/tools" "$R/"
}

# ---- snapshots ----
for y in 2020 2023 2024 2025 2026 2027; do
  reset
  out="$(cd / && env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$T/no-crossover" /bin/bash "$R/revit" check "$y" 2>&1 | sed -n '/^Plan:/,$p')"
  if [ "${UPDATE:-0}" = 1 ]; then printf '%s\n' "$out" > "$REPO/tests/plans/$y.txt"; ok "plan $y written"
  elif [ "$out" = "$(cat "$REPO/tests/plans/$y.txt")" ]; then ok "plan $y"
  else fail "plan $y" "$(diff <(printf '%s\n' "$out") "$REPO/tests/plans/$y.txt")"; fi
done

# ---- install.sh, run for real with stub actions ----
prep() { # preflight passes: fake CrossOver and tools, an unpacked installer, msls31.dll; every action is a stub
    reset; mkdir -p "$CXF/bin" "$T/bin" "$R/installers/extracted/revit2024" "$R/installers/redist/win7sp1/x64"
    # the Mac hardware checks pass in the sandbox copy, so these runs work on any machine
    sed -i '' -e 's|sysctl -n hw.optional.arm64|echo 1|' -e 's|sysctl -n sysctl.proc_translated|echo 0|' \
      -e 's|/usr/bin/arch -x86_64 /usr/bin/true|true|' "$R/install.sh"
    printf '#!/bin/bash\nexit 0\n' > "$CXF/bin/cxbottle"; chmod +x "$CXF/bin/cxbottle"
    local t; for t in 7zz winetricks cabextract; do printf '#!/bin/bash\nexit 0\n' > "$T/bin/$t"; chmod +x "$T/bin/$t"; done
    echo '<Setup/>' > "$R/installers/extracted/revit2024/setup.xml"; touch "$R/installers/redist/win7sp1/x64/msls31.dll"
    local s; for s in get-shims get-redist unpack-revit make-apps; do printf '#!/bin/bash\necho "%s $*" >> "%s/calls"\n' "$s" "$T" > "$R/scripts/$s.sh"; done
    cat > "$R/scripts/new-bottle.sh" <<EOF
#!/bin/bash
echo "new-bottle \$*" >> "$T/calls"; mkdir -p "$BOTTLES/\$2/drive_c"; printf '[Bottle]\n"Description" = "Revit %s"\n' "\$1" > "$BOTTLES/\$2/cxbottle.conf"
EOF
    cat > "$R/scripts/run-steps.sh" <<EOF
#!/bin/bash
echo "run-steps \$* RUN_DIR=\$RUN_DIR" >> "$T/calls"
mkdir -p "$BOTTLES/\$2/drive_c/Program Files/Autodesk/Revit \$1"; touch "$BOTTLES/\$2/drive_c/Program Files/Autodesk/Revit \$1/Revit.exe"
echo tlbpin >> "\$RUN_DIR/failed.txt"; exit 1
EOF
    chmod +x "$R"/scripts/*.sh
  }
  INST_ENV=(env "${CLEAN_ENV[@]}" HOME="$H" REVIT_CX="$CXF" PATH="$T/bin:$PATH")
  inst() { OUT="$(cd / && "${INST_ENV[@]}" /bin/bash "$R/install.sh" "$@" 2>&1)"; RC=$?; }
  # no Ghostscript anywhere on PATH (a Mac with Homebrew may have it): only the stubbed tools and the system
  prep; OUT="$(cd / && "${INST_ENV[@]}" PATH="$T/bin:/usr/bin:/bin" /bin/bash "$R/install.sh" 2024 rvt2024-t 2>&1)"
  if ! grep -q "gs not found" <<<"$OUT"; then ok "preflight does not ask for Ghostscript"; else fail "preflight does not ask for Ghostscript" "$OUT"; fi
  prep; inst 2024 rvt2024-t
  if [ "$RC" = 1 ] && grep -qF "Some steps failed" <<<"$OUT" && grep -qx "  tlbpin" <<<"$OUT"; then ok "install.sh goes on after a failed fix and lists it"
  else fail "install.sh goes on after a failed fix and lists it" "rc=$RC
$OUT"; fi
  grep -qF "make-apps 2024 rvt2024-t" "$T/calls" && ok "install.sh reaches make-apps" || fail "install.sh reaches make-apps" "$(cat "$T/calls")"
  grep -qF "RUN_DIR=$R/logs/rvt2024-t/" "$T/calls" && ok "install.sh passes its run folder" || fail "install.sh passes its run folder" "$(cat "$T/calls")"
  prep; OUT="$(cd / && exec 7>"$T/ev" && "${INST_ENV[@]}" REVIT_EVENTS_FD=7 /bin/bash "$R/install.sh" 2024 rvt2024-t 2>&1)"
  if grep -q '"event":"action","id":"shims","state":"running"' "$T/ev" && grep -q '"event":"action","id":"apps","state":"done","exit":0' "$T/ev"; then
    ok "install.sh emits each action"; else fail "install.sh emits each action" "$(cat "$T/ev")"; fi
  prep; printf '#!/bin/bash\nexit 1\n' > "$R/scripts/get-shims.sh"; inst 2024 rvt2024-t
  if [ "$RC" = 1 ] && grep -qF "Step failed: scripts/get-shims.sh" <<<"$OUT"; then ok "a failed action stops install.sh"; else fail "a failed action stops install.sh" "$OUT"; fi
  grep -qE '^   shims +exit=1 ' "$R"/logs/rvt2024-t/*-install/summary.txt && ok "the failed action is in summary.txt" || fail "the failed action is in summary.txt" ""
  OUT="$(cd / && HOME="$H" ROOT="$R" /bin/bash -c '. "$ROOT/scripts/lib/common.sh"; lock_free && echo free')"
  [ "$OUT" = free ] && ok "the lock is free after install.sh" || fail "the lock is free after install.sh" "$OUT"
  grep -qF "Last log:" <<<"$(cd / && "${INST_ENV[@]}" /bin/bash "$R/install.sh" 2024 rvt2024-t 2>&1)" \
    && ok "a failed action names its log" || fail "a failed action names its log" ""
  # a runner that stopped (or failed) without recording a failed step: install.sh stops, even with Revit.exe in place
  prep; cat > "$R/scripts/run-steps.sh" <<EOF
#!/bin/bash
mkdir -p "$BOTTLES/\$2/drive_c/Program Files/Autodesk/Revit \$1"; touch "$BOTTLES/\$2/drive_c/Program Files/Autodesk/Revit \$1/Revit.exe"
echo "Stopped." >&2; exit 1
EOF
  chmod +x "$R/scripts/run-steps.sh"; inst 2024 rvt2024-t
  if [ "$RC" = 1 ] && grep -qF "Step failed: scripts/run-steps.sh" <<<"$OUT" && ! grep -q make-apps "$T/calls"; then
    ok "a runner that stopped without a failed step stops install.sh"
  else fail "a runner that stopped without a failed step stops install.sh" "rc=$RC
$OUT"; fi
  # TERM (or Ctrl-C) during an action: install.sh passes TERM on, waits for the action to stop, then stops itself
  prep; cat > "$R/scripts/run-steps.sh" <<EOF
#!/bin/bash
trap 'echo stopping >> "$T/calls"; sleep 1; echo stopped >> "$T/calls"; exit 1' TERM
echo "run-steps started" >> "$T/calls"; sleep 10 >/dev/null 2>&1 9>&- & wait \$!
echo "run-steps was not stopped" >> "$T/calls"
EOF
  chmod +x "$R/scripts/run-steps.sh"
  (cd / && exec "${INST_ENV[@]}" /bin/bash "$R/install.sh" 2024 rvt2024-t) > "$T/out" 2>&1 & ip=$!
  for i in $(seq 1 50); do grep -q "run-steps started" "$T/calls" 2>/dev/null && break; sleep 0.2; done
  kill -TERM "$ip"; wait "$ip"; RC=$?
  if [ "$RC" = 1 ] && grep -qx stopped "$T/calls" && grep -qF "Stopped." "$T/out" && ! grep -q make-apps "$T/calls"; then
    ok "TERM: install.sh stops after the running action"
  else fail "TERM: install.sh stops after the running action" "rc=$RC
$(cat "$T/calls" "$T/out")"; fi
  prep; mkdir -p "$T/data/installers/extracted/revit2024" "$T/data/installers/redist/win7sp1/x64"
  echo '<Setup/>' > "$T/data/installers/extracted/revit2024/setup.xml"; touch "$T/data/installers/redist/win7sp1/x64/msls31.dll"
  rm -rf "$R/installers"; chmod -R a-w "$R"
  OUT="$(cd / && "${INST_ENV[@]}" REVIT_DATA="$T/data" /bin/bash "$R/install.sh" 2024 rvt2024-t 2>&1)"; RC=$?
  chmod -R u+w "$R"
  if [ "$RC" = 1 ] && grep -qF "Some steps failed" <<<"$OUT" && [ -d "$T/data/logs/rvt2024-t" ]; then ok "install.sh with DATA writes nothing into ROOT"
  else fail "install.sh with DATA writes nothing into ROOT" "rc=$RC
$OUT"; fi
  # ---- source decisions ----
  srcprep() { prep; cp "$REPO/tools/installer_source.py" "$R/tools/"; mkdir -p "$R/installers/revit2024"
    printf 'A' > "$R/installers/revit2024/RVT_2024_NA_win_db_002_002.zip"; }
  srcrec() { # $1 = source_id to record in the unpacked folder ("" = the real one of the current files)
    ( cd "$R" && python3 -I tools/installer_source.py resolve 2024 installers/revit2024 installers/revit2024 /dev/null "$T/s.json" >/dev/null \
      && python3 -I tools/installer_source.py finalize "$T/s.json" "$T/h.tsv" >/dev/null )
    [ -z "$1" ] || /usr/bin/perl -MJSON::PP -0 -i -pe '$_ = do { my $s = decode_json($_); $s->{source_id} = "'"$1"'"; encode_json($s) }' "$T/s.json"
    cp "$T/s.json" "$R/installers/extracted/revit2024/.source"; }
  srcprep; srcrec ""; inst 2024 rvt2024-t
  if grep -qF "Some steps failed" <<<"$OUT" && ! grep -qF "unpacked from another installer" <<<"$OUT"; then ok "same source: the install goes on"
  else fail "same source: the install goes on" "$OUT"; fi
  srcprep; srcrec old; inst 2024 rvt2024-t
  if [ "$RC" = 1 ] && grep -qF "was unpacked from another installer" <<<"$OUT" && ! grep -q "new-bottle" "$T/calls"; then ok "another source stops the install"
  else fail "another source stops the install" "rc=$RC
$OUT"; fi
  srcprep; srcrec old; OUT="$(cd / && "${INST_ENV[@]}" REVIT_REUSE_EXTRACTED=1 /bin/bash "$R/install.sh" 2024 rvt2024-t 2>&1)"
  grep -qF "Some steps failed" <<<"$OUT" && ok "--reuse-extracted goes on" || fail "--reuse-extracted goes on" "$OUT"
  check_src_kept() { [ -f "$R/installers/extracted/revit2024/.source" ] || return 1; grep -q '"source_id": *"old"' "$R/installers/extracted/revit2024/.source" 2>/dev/null || /usr/bin/perl -MJSON::PP -0 -ne 'exit(decode_json($_)->{source_id} eq "old" ? 0 : 1)' "$R/installers/extracted/revit2024/.source"; }
  check_src_kept && ok "--reuse-extracted keeps the old record" || fail "--reuse-extracted keeps the old record" ""
  srcprep; srcrec old; mkdir -p "$BOTTLES/rvt2024-b/drive_c/Program Files/Autodesk/Revit 2024"
  printf '[Bottle]\n"Description" = "Revit 2024"\n' > "$BOTTLES/rvt2024-b/cxbottle.conf"
  OUT="$(cd / && "${INST_ENV[@]}" REVIT_REEXTRACT=1 /bin/bash "$R/install.sh" 2024 rvt2024-t 2>&1)"; RC=$?
  if [ "$RC" = 1 ] && grep -qF "bottle rvt2024-b still uses it" <<<"$OUT" && [ -f "$R/installers/extracted/revit2024/setup.xml" ]; then ok "--reextract refuses while another bottle uses it"
  else fail "--reextract refuses while another bottle uses it" "rc=$RC
$OUT"; fi
  srcprep; srcrec old; mv "$R/installers/extracted/revit2024" "$R/installers/extracted/revit2024.old.77"
  sed -i '' 's|^echo "unpack-revit|echo "AGAIN=$REVIT_UNPACK_AGAIN unpack-revit|' "$R/scripts/unpack-revit.sh"
  ( cd / && "${INST_ENV[@]}" ROOT="$R" HOME="$H" /bin/bash -c '. "$ROOT/scripts/lib/common.sh"; lock_take test; REVIT_REEXTRACT=1 /bin/bash "$ROOT/install.sh" 2024 rvt2024-t' ) > "$T/out" 2>&1
  if [ -d "$R/installers/extracted/revit2024" ] && grep -qF "AGAIN=1 unpack-revit 2024" "$T/calls"; then ok "a cut-short swap is settled before the decision, and --reextract still unpacks again"
  else fail "a cut-short swap is settled before the decision" "$(cat "$T/out" "$T/calls")"; fi
  srcprep; rm -f "$R/installers/revit2024/"*; inst 2024 rvt2024-t
  grep -qF "Some steps failed" <<<"$OUT" && ok "unpacked files without installer files: used as before" || fail "unpacked without installer files" "$OUT"
  badci() { printf 'junk' > "$R/installers/revit2024/Create_Installer_RVT_2024_3_6_English_WIN64.exe"; }
  srcprep; badci; inst 2024 rvt2024-t
  grep -qF "Some steps failed" <<<"$OUT" && ok "a broken Create Installer, an unrecorded unpacked folder: used as before" || fail "broken CI, unrecorded unpacked" "$OUT"
  srcprep; srcrec ""; badci; OUT="$(cd / && "${INST_ENV[@]}" REVIT_REUSE_EXTRACTED=1 /bin/bash "$R/install.sh" 2024 rvt2024-t 2>&1)"
  grep -qF "Some steps failed" <<<"$OUT" && ok "--reuse-extracted does not read a broken Create Installer" || fail "--reuse-extracted with a broken CI" "$OUT"
  srcprep; srcrec ""; badci; inst 2024 rvt2024-t
  if [ "$RC" = 1 ] && grep -qF "reuse-extracted" <<<"$OUT"; then ok "a broken Create Installer next to a recorded unpacked folder stops, with the way out"
  else fail "broken CI, recorded unpacked" "rc=$RC
$OUT"; fi
  prep; printf '#!/bin/bash\nmkdir -p "%s/rvt2024-t/drive_c/Program Files/Autodesk/Revit 2024"; touch "%s/rvt2024-t/drive_c/Program Files/Autodesk/Revit 2024/Revit.exe"\n' "$BOTTLES" "$BOTTLES" > "$R/scripts/run-steps.sh"
  inst 2024 rvt2024-t
  if [ "$RC" = 0 ] && ! grep -q "No such file" <<<"$OUT"; then ok "a clean install prints no file error"; else fail "a clean install prints no file error" "rc=$RC
$OUT"; fi

echo; echo "$((n - fails))/$n passed"; [ "$fails" -eq 0 ]
