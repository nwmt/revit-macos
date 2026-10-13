#!/usr/bin/env bash
# Builds a Revit 2020 bottle from scratch: new-bottle.sh → d3 .NET 4.0/4.7 → d2 VC++/fonts → d6 Revit and every fix.
# install.sh runs it for 2020 until Revit 2020 moves to scripts/run-steps.sh.
# Usage: ./scripts/build-bottle.sh <bottle> [template=win10_64]; CX_RECREATE=1 deletes an existing bottle first.
# Requires (installers/, see installers/README.md): Revit 2020 unpacked to installers/extracted/revit2020,
#   redist/dotNetFx40_Full_x86_x64.exe, redist/win7sp1/x64/{riched20,usp10,msls31}.dll; brew: sevenzip winetricks ghostscript.
# Logs: RUN_DIR (install.sh passes it) or a new logs/<bottle>/<time>-install/: build.log, d2.log, d3.log and d6's files.
set -uo pipefail
NAME="${1:?specify a bottle}"; TEMPLATE="${2:-win10_64}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/common.sh"
lock_take "build-bottle.sh $NAME"
if [ -z "${RUN_DIR:-}" ] || [ ! -d "$RUN_DIR" ]; then RUN_DIR="$(run_dir_new "$NAME" install)" || die "Cannot create a log folder."; fi
export RUN_DIR; LOG="$RUN_DIR/build.log"
step() { # $1 = name, rest = command. TERM/HUP/INT go on to it (run_child); the build stops after it
  local t0=$SECONDS name="$1" rc; shift
  stop_check
  echo "=== $(date +%T) $name: $*" | tee -a "$LOG"
  run_child "$@" >>"$LOG" 2>&1; rc=$?
  echo "--- $name rc=$rc in $((SECONDS - t0)) s" | tee -a "$LOG"
  stop_check
  return $rc
}
step D0-bottle   "$ROOT/scripts/new-bottle.sh" 2020 "$NAME" "$TEMPLATE" || exit 1
step D3-dotnet   "$ROOT/scripts/d3-dotnet47.sh" "$NAME" || exit 1
step D2-runtimes "$ROOT/scripts/d2-runtimes.sh" "$NAME" || exit 1
step D6-revit    "$ROOT/scripts/d6-install-revit.sh" "$NAME" || exit 1
echo "=== D6 summary:" | tee -a "$LOG"; tee -a "$LOG" < "$RUN_DIR/summary.txt"
echo "done in $((SECONDS / 60)) min; log $(tilde "$LOG")" | tee -a "$LOG"
