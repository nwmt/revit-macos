#!/usr/bin/env bash
# Plan snapshots and install.sh runs, in a sandbox: a copy of the repo, a fake HOME, no or a fake CrossOver.
#   ./revit check <year> (no CrossOver, no installers) prints the plan and the steps: compared with tests/plans/<year>.txt.
#   UPDATE=1 tests/plans.sh rewrites those files after a deliberate change — review the diff.
#   install.sh runs for real with stub actions: arguments with spaces, a failed action, failed steps after Revit.exe.
# Runs under /bin/bash 3.2. Nothing real is touched.
set -uo pipefail
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
  out="$(cd / && env -u INSTALL_DRYRUN -u CX_RECREATE -u RUN_DIR HOME="$H" REVIT_CX="$T/no-crossover" /bin/bash "$R/revit" check "$y" 2>&1 | sed -n '/^Plan:/,$p')"
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
    local t; for t in 7zz winetricks cabextract gs; do printf '#!/bin/bash\nexit 0\n' > "$T/bin/$t"; chmod +x "$T/bin/$t"; done
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
  INST_ENV=(env -u RUN_DIR -u RUN_KIND -u CX_RECREATE -u INSTALL_DRYRUN HOME="$H" REVIT_CX="$CXF" PATH="$T/bin:$PATH")
  inst() { OUT="$(cd / && "${INST_ENV[@]}" /bin/bash "$R/install.sh" "$@" 2>&1)"; RC=$?; }
  prep; inst 2024 rvt2024-t
  if [ "$RC" = 1 ] && grep -qF "Some steps failed" <<<"$OUT" && grep -qx "  tlbpin" <<<"$OUT"; then ok "install.sh goes on after a failed fix and lists it"
  else fail "install.sh goes on after a failed fix and lists it" "rc=$RC
$OUT"; fi
  grep -qF "make-apps 2024 rvt2024-t" "$T/calls" && ok "install.sh reaches make-apps" || fail "install.sh reaches make-apps" "$(cat "$T/calls")"
  grep -qF "RUN_DIR=$R/logs/rvt2024-t/" "$T/calls" && ok "install.sh passes its run folder" || fail "install.sh passes its run folder" "$(cat "$T/calls")"
  prep; printf '#!/bin/bash\nexit 1\n' > "$R/scripts/get-shims.sh"; inst 2024 rvt2024-t
  if [ "$RC" = 1 ] && grep -qF "Step failed: scripts/get-shims.sh" <<<"$OUT"; then ok "a failed action stops install.sh"; else fail "a failed action stops install.sh" "$OUT"; fi
  grep -qE '^   shims +exit=1 ' "$R"/logs/rvt2024-t/*-install/summary.txt && ok "the failed action is in summary.txt" || fail "the failed action is in summary.txt" ""
  OUT="$(cd / && HOME="$H" ROOT="$R" /bin/bash -c '. "$ROOT/scripts/lib/common.sh"; lock_free && echo free')"
  [ "$OUT" = free ] && ok "the lock is free after install.sh" || fail "the lock is free after install.sh" "$OUT"
  grep -qF "Last log:" <<<"$(cd / && "${INST_ENV[@]}" /bin/bash "$R/install.sh" 2024 rvt2024-t 2>&1)" \
    && ok "a failed action names its log" || fail "a failed action names its log" ""
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

echo; echo "$((n - fails))/$n passed"; [ "$fails" -eq 0 ]
